#!/usr/local/cpanel/3rdparty/bin/perl
#
# UserTools — interface WHM (root + revendedores)
#
# - Root: pode atuar em qualquer conta cPanel do servidor.
# - Revendedor: apenas em contas que ele possui (checkowner).
#
# Executado pelo daemon whostmgr (contexto privilegiado), por isso pode
# rodar pkill e /scripts/fixhomedirperms diretamente.

BEGIN {
    unshift @INC, '/usr/local/cpanel';
}

use strict;
use warnings;
use utf8;

use CGI                              ();
use JSON::XS                         ();
use Cpanel::Template                 ();
use Whostmgr::ACLS                   ();
use Cpanel::AcctUtils::Account       ();

Whostmgr::ACLS::init_acls();

my $cgi  = CGI->new;
my $json = JSON::XS->new->utf8;

# O WHM so aceita root ou reseller autenticado no endpoint /cgi/addons/,
# entao se chegou aqui com REMOTE_USER definido ja esta autorizado.
# hasroot() distingue root de reseller. Whostmgr::ACLS nao expoe
# hasreseller() na versao atual do cPanel - detectamos reseller como
# 'autenticado e nao-root' com fallback em /var/cpanel/resellers.
my $remote = $ENV{'REMOTE_USER'} || '';
if ( !$remote ) {
    print "Status: 403 Forbidden\r\nContent-type: text/plain\r\n\r\nAcesso negado.";
    exit;
}

my $is_root = Whostmgr::ACLS::hasroot();
if ( !$is_root ) {
    # Valida que o nome esta na lista de resellers (defesa extra).
    my $is_reseller = 0;
    if ( open( my $rfh, '<', '/var/cpanel/resellers' ) ) {
        while ( my $line = <$rfh> ) {
            if ( $line =~ /^\Q$remote\E\s*:/ ) { $is_reseller = 1; last; }
        }
        close $rfh;
    }
    if ( !$is_reseller ) {
        print "Status: 403 Forbidden\r\nContent-type: text/plain\r\n\r\nAcesso negado.";
        exit;
    }
}
my $reseller = $ENV{'REMOTE_USER'} || '';
my $action   = $cgi->param('action') || '';

# ---------- Endpoints JSON --------------------------------------------------
if ( $action eq 'list_users' ) {
    api_list_users();
    exit;
}
elsif ( $action eq 'kill_procs' || $action eq 'fix_perms' ) {
    api_run_action($action);
    exit;
}

# ---------- UI HTML ---------------------------------------------------------
render_ui( $is_root ? 'root' : 'revendedor' );
exit;

# ============================================================================

sub json_out {
    my ($data) = @_;
    print "Content-type: application/json; charset=utf-8\r\n\r\n";
    print $json->encode($data);
}

sub api_list_users {
    my @users = eval { _list_cpanel_accounts() };
    if ($@) {
        # Detalhes tecnicos ficam no log; usuario ve mensagem generica.
        my $err = $@; $err =~ s/\s+$//;
        warn "[usertools] list_users failed: $err\n";
        json_out( {
            success => \0,
            message => 'Não foi possível carregar a lista de contas neste momento. Recarregue a página em alguns segundos.',
        } );
        return;
    }
    json_out( { success => \1, users => \@users } );
}

sub api_run_action {
    my ($act) = @_;

    my $target = $cgi->param('user') || '';

    # Sanitiza — apenas [a-z0-9_-], máx 32 caracteres
    if ( $target !~ /^[a-z0-9_\-]{1,32}$/ ) {
        json_out( {
            success => \0,
            message => 'Nome de usuário em formato inválido. Selecione uma conta válida na lista e tente novamente.',
        } );
        return;
    }

    if ( !Cpanel::AcctUtils::Account::accountexists($target) ) {
        json_out( {
            success => \0,
            message => "A conta \"$target\" não existe ou foi removida. Atualize a lista de contas e escolha novamente.",
        } );
        return;
    }

    # Revendedor só atua em clientes dele
    if ( !$is_root && !_is_reseller_owner( $reseller, $target ) ) {
        json_out( {
            success => \0,
            message => "Acesso negado. A conta \"$target\" não pertence à sua carteira de revendedor — você só pode executar ações em contas sob o seu gerenciamento.",
        } );
        return;
    }

    eval {
        if ( $act eq 'kill_procs' ) { do_kill_procs($target); }
        else                        { do_fix_perms($target); }
        1;
    } or do {
        my $err = $@ || 'erro desconhecido'; $err =~ s/\s+$//;
        warn "[usertools] $act on $target failed: $err\n";
        json_out( {
            success => \0,
            message => 'A operação não pôde ser concluída devido a um erro interno. Verifique /usr/local/cpanel/logs/error_log para detalhes técnicos.',
        } );
    };
}

# Lê /var/cpanel/users/* — cada arquivo representa um usuário cPanel.
# Formato: chaves no estilo KEY=value (DNS, DOMAIN, OWNER, etc).
# Para reseller, filtra só quem tem OWNER=<reseller>.
sub _list_cpanel_accounts {
    my $users_dir = '/var/cpanel/users';
    opendir( my $dh, $users_dir )
        or die "Não foi possível abrir $users_dir: $!\n";

    my @out;
    while ( my $entry = readdir $dh ) {
        next if $entry =~ /^\./;
        next if $entry eq 'root' || $entry eq 'nobody' || $entry eq 'cpanel';
        my $file = "$users_dir/$entry";
        next unless -f $file;

        my $info = _read_user_file($file);
        next unless $info;

        # Reseller: só seus clientes
        if ( !$is_root ) {
            next unless ( $info->{OWNER} // 'root' ) eq $reseller;
        }

        push @out,
            {
                user   => $entry,
                domain => $info->{DOMAIN} // $info->{DNS} // '',
            };
    }
    closedir $dh;

    @out = sort { $a->{user} cmp $b->{user} } @out;
    return @out;
}

sub _read_user_file {
    my ($file) = @_;
    open( my $fh, '<', $file ) or return;
    my %info;
    while ( my $line = <$fh> ) {
        chomp $line;
        $info{$1} = $2 if $line =~ /^([A-Z0-9_]+)=(.*)$/;
    }
    close $fh;
    return \%info;
}

sub _is_reseller_owner {
    my ( $reseller, $user ) = @_;
    my $file = "/var/cpanel/users/$user";
    return 0 unless -f $file;
    my $info = _read_user_file($file);
    return 0 unless $info;
    return ( $info->{OWNER} // 'root' ) eq $reseller ? 1 : 0;
}

sub do_kill_procs {
    my ($user) = @_;

    my $before = qx{/usr/bin/pgrep -c -u \Q$user\E 2>/dev/null};
    chomp $before;
    $before = '0' unless defined $before && length $before;

    system( '/usr/bin/pkill', '-9', '-ceiu', $user );

    sleep 1;

    my $after = qx{/usr/bin/pgrep -c -u \Q$user\E 2>/dev/null};
    chomp $after;
    $after = '0' unless defined $after && length $after;

    my $killed = ( $before =~ /^\d+$/ && $after =~ /^\d+$/ ) ? ( $before - $after ) : 0;
    $killed = 0 if $killed < 0;

    my $msg;
    my $ok = \1;
    if ( $killed > 0 ) {
        my $plural = $killed == 1 ? 'processo foi encerrado' : 'processos foram encerrados';
        $msg = "Finalização concluída: $killed $plural da conta \"$user\" (de $before ativos antes da operação restam $after). Os serviços essenciais serão reiniciados automaticamente pelo cPanel.";
    }
    elsif ( $before eq '0' ) {
        $msg = "A conta \"$user\" já estava ociosa — nenhum processo ativo foi encontrado. Nenhuma ação foi necessária.";
    }
    else {
        $msg = "Comando de finalização enviado, porém $after processo(s) continuam ativos (de $before detectados). Isso é normal: alguns processos são reiniciados imediatamente pelo sistema (PHP-FPM pool, cron). Aguarde um minuto e verifique novamente se o problema persiste.";
    }

    json_out( { success => $ok, message => $msg } );
}

sub do_fix_perms {
    my ($user) = @_;

    my @pw = getpwnam($user);
    if (!@pw) {
        json_out({
            success => \0,
            message => "A conta \"$user\" não foi localizada na base do sistema. Ela pode ter sido removida recentemente — atualize a lista de contas.",
        });
        return;
    }

    my $home = $pw[7];
    if (!defined $home || !-d $home || $home eq '/' || $home eq '/root') {
        json_out({
            success => \0,
            message => "O diretório pessoal da conta \"$user\" está indisponível ou aponta para um caminho protegido. A operação foi bloqueada por segurança.",
        });
        return;
    }

    # Pegamos ids de permissões base
    my $user_uid = $pw[2];
    my $nobody_gid;
    my @nb_pw = getgrnam('nobody');
    $nobody_gid = $nb_pw[2] if @nb_pw;

    # Trava e ajusta home inicial
    system('/bin/chmod', '711', $home);
    system('/bin/chown', "$user:$user", $home);

    my @docroots;
    my $public_html = "$home/public_html";
    push @docroots, $public_html if -d $public_html;

    # Varre userdata atras de docroots externos ou isolados (Addons)
    my $userdata_dir = "/var/cpanel/userdata/$user";
    if (-d $userdata_dir) {
        opendir(my $dh, $userdata_dir);
        if ($dh) {
            my @files;
            while (my $entry = readdir $dh) {
                next if $entry =~ /^\./ || $entry =~ /\.cache$/ || $entry =~ /_SSL$/ || $entry eq 'main';
                push @files, "$userdata_dir/$entry" if -f "$userdata_dir/$entry";
            }
            closedir $dh;
            
            my %seen;
            $seen{$public_html} = 1;
            for my $file (@files) {
                open(my $fh, '<', $file) or next;
                while (my $line = <$fh>) {
                    next unless $line =~ /^\s*documentroot\s*:\s*(.+?)\s*$/;
                    my $dr = $1;
                    $dr =~ s/^["']|["']$//g;
                    next unless $dr =~ m{^\Q$home\E/}; # Impede traversal
                    next if $seen{$dr}++;
                    push @docroots, $dr if -d $dr;
                }
                close $fh;
            }
        }
    }

    my $count = 0;
    for my $dr (@docroots) {
        system('/bin/chown', '-R', "$user:$user", $dr);
        system('/usr/bin/find', $dr, '-type', 'd', '-exec', '/bin/chmod', '755', '{}', '+');
        system('/usr/bin/find', $dr, '-type', 'f', '-exec', '/bin/chmod', '644', '{}', '+');
        system('/usr/bin/find', $dr, '-type', 'f', '(', '-name', '*.cgi', '-o', '-name', '*.pl', ')', '-exec', '/bin/chmod', '755', '{}', '+');
        
        if ($dr eq $public_html) {
            system('/bin/chmod', '750', $public_html);
            if (defined $nobody_gid) {
                chown($user_uid, $nobody_gid, $public_html);
            }
        } else {
            system('/bin/chmod', '755', $dr);
        }
        $count++;
    }

    if ( $count == 0 ) {
        json_out({
            success => \0,
            message => "A conta \"$user\" não possui nenhum site ativo. Para reparar permissões é preciso ter ao menos um domínio com pasta pública configurada (public_html ou domínio adicional).",
        });
        return;
    }

    my $plural = $count == 1 ? 'site' : 'sites';
    json_out({
        success => \1,
        message => "Permissões normalizadas em $count $plural da conta \"$user\". Pastas em 755, arquivos em 644, scripts .cgi/.pl em 755 e proprietário restabelecido para o próprio usuário. Se o problema que motivou esta ação persistir, aguarde alguns minutos para o servidor web reprocessar os arquivos.",
    });
}
sub render_ui {
    my ($role) = @_;

    # Content-type SEMPRE é o primeiro byte (cpsrvd não injeta).
    print "Content-type: text/html; charset=utf-8\r\n\r\n";

    # Renderiza usando Template Toolkit com o WRAPPER master do Jupiter.
    # O master template injeta a sidebar, header e breadcrumbs do WHM em
    # volta do conteúdo do plugin — é o padrão oficial do cPanel para
    # plugins integrados (ver addon_securityadvisor).
    Cpanel::Template::process_template(
        'whostmgr',
        {
            'template_file' =>
                '/var/cpanel/addons/usertools/templates/main.tmpl',
            'data' => {
                role       => $role,
                role_label => ( $role eq 'root' ? 'ROOT' : 'REVENDEDOR' ),
            },
            'print' => 1,
        },
    );
}
