#!/usr/local/cpanel/3rdparty/bin/perl
#
# UserTools — interface WHM (root + revendedores)
#
# - Root: pode atuar em qualquer conta cPanel do servidor.
# - Revendedor: apenas em contas cuja propriedade (OWNER em
#   /var/cpanel/users/<alvo>) seja igual ao seu REMOTE_USER.
#
# Executado pelo daemon whostmgr (contexto root), por isso pode aplicar
# pkill -9 em qualquer UID alvo e chown/chmod em qualquer diretorio.

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

    # Kill imediato - o addon_usertools.cgi roda como root (contexto
    # whostmgr), entao matar processos do usuario alvo nao encerra
    # a propria requisicao. Diferente do lado cPanel onde o pkill
    # e diferido porque o CGI roda sob o mesmo UID do alvo.
    system( '/usr/bin/pkill', '-9', '-ceiu', $user );

    # Pequeno delay para o kernel atualizar a tabela de processos antes
    # do pgrep pos-kill - sem isso o before e after mostram o mesmo valor.
    select( undef, undef, undef, 0.5 );

    my $after = qx{/usr/bin/pgrep -c -u \Q$user\E 2>/dev/null};
    chomp $after;
    $after = '0' unless defined $after && length $after;

    my $killed = ( $before =~ /^\d+$/ && $after =~ /^\d+$/ ) ? ( $before - $after ) : 0;
    $killed = 0 if $killed < 0;

    my $msg;
    if ( $killed > 0 ) {
        my $plural = $killed == 1 ? 'processo encerrado' : 'processos encerrados';
        $msg = '<strong>Finalização concluída</strong>'
             . qq{<div style="display:flex;align-items:center;gap:12px;margin:10px 0 6px;">}
             . qq{<span style="font-size:28px;font-weight:700;line-height:1;">$killed</span>}
             . qq{<span style="font-size:13px;opacity:0.85;">$plural<br>na conta <strong>$user</strong></span>}
             . '</div>'
             . qq{<div style="display:grid;grid-template-columns:auto 1fr;gap:4px 14px;font-size:13px;margin-top:8px;">}
             . qq{<span style="font-weight:600;opacity:0.75;">Antes da operação</span><span>$before processos ativos</span>}
             . qq{<span style="font-weight:600;opacity:0.75;">Após a operação</span><span>$after processos ativos</span>}
             . qq{<span style="font-weight:600;opacity:0.75;">Método</span><span><code>pkill -9 -ceiu</code></span>}
             . '</div>';
    }
    elsif ( $before eq '0' ) {
        $msg = '<strong>Conta ociosa</strong><br>'
             . qq{A conta <strong>$user</strong> não possuía processos ativos no momento da operação. Nenhuma ação foi necessária.};
    }
    else {
        $msg = '<strong>Finalização parcial</strong>'
             . qq{<div style="display:grid;grid-template-columns:auto 1fr;gap:4px 14px;font-size:13px;margin-top:8px;">}
             . qq{<span style="font-weight:600;opacity:0.75;">Antes da operação</span><span>$before processos ativos</span>}
             . qq{<span style="font-weight:600;opacity:0.75;">Após a operação</span><span>$after processos ativos (reiniciados pelo sistema)</span>}
             . '</div>'
             . qq{<div style="font-size:13px;opacity:0.85;margin-top:8px;">}
             . 'Isso é normal: PHP-FPM pool e cron reiniciam automaticamente. Aguarde um minuto e verifique novamente se o problema persistir.'
             . '</div>';
    }

    json_out( { success => \1, message => $msg } );
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

    my $user_uid = $pw[2];
    my $user_gid = $pw[3];

    # 1. Owner recursivo em TODO o home.
    system('/bin/chown', '-R', "$user:$user", $home);

    # 2. Permissoes base em todo o home: dirs 755, arquivos 644.
    system('/usr/bin/find', $home, '-type', 'd', '-exec', '/bin/chmod', '755', '{}', '+');
    system('/usr/bin/find', $home, '-type', 'f', '-exec', '/bin/chmod', '644', '{}', '+');

    # 3. Scripts mantem bit de execucao.
    system('/usr/bin/find', $home, '-type', 'f',
        '(', '-name', '*.cgi', '-o', '-name', '*.pl', '-o', '-name', '*.sh', ')',
        '-exec', '/bin/chmod', '755', '{}', '+');

    # 4. Casos especiais seguindo o padrao oficial /scripts/unsuspendacct.
    #    WHM roda como root, entao chown para grupo 'nobody' e permitido.
    chmod 0711, $home;

    my $fileprotect = -e '/var/cpanel/fileprotect';
    my $noanonftp   = -e '/var/cpanel/noanonftp';

    my @nb = getgrnam('nobody');
    my $nobody_gid = @nb ? $nb[2] : $user_gid;

    # public_html e .htpasswds: com fileprotect viram user:nobody 750;
    # sem fileprotect, user:user 755. Padrao do unsuspendacct.
    for my $dir ("$home/public_html", "$home/.htpasswds") {
        next unless -d $dir;
        if ($fileprotect) {
            chown $user_uid, $nobody_gid, $dir;
            chmod 0750, $dir;
        } else {
            chown $user_uid, $user_gid, $dir;
            chmod 0755, $dir;
        }
    }

    # public_ftp: com noanonftp vira 750 user:user; sem noanonftp, 755 user:user
    my $public_ftp = "$home/public_ftp";
    if (-d $public_ftp) {
        chown $user_uid, $user_gid, $public_ftp;
        chmod +( $noanonftp ? 0750 : 0755 ), $public_ftp;
    }

    # .ssh: 700 user:user, arquivos 600 (chaves privadas SSH)
    my $ssh_dir = "$home/.ssh";
    if (-d $ssh_dir) {
        chmod 0700, $ssh_dir;
        system('/usr/bin/find', $ssh_dir, '-type', 'f', '-exec', '/bin/chmod', '600', '{}', '+');
    }

    # etc/: 750 user:mail (dovecot/exim)
    my $etc_dir = "$home/etc";
    if (-d $etc_dir) {
        my @mg = getgrnam('mail');
        if (@mg) {
            system('/bin/chown', '-R', "$user:mail", $etc_dir);
            chmod 0750, $etc_dir;
        }
    }

    # mail/: 751
    my $mail_dir = "$home/mail";
    chmod 0751, $mail_dir if -d $mail_dir;

    my $pubhtml_mode  = $fileprotect ? '750' : '755';
    my $pubhtml_owner = $fileprotect ? 'user:nobody' : 'user:user';
    my $pubftp_mode   = $noanonftp ? '750' : '755';

    my $msg = '<strong>Permissões normalizadas</strong>'
            . qq{<div style="font-size:13px;opacity:0.85;margin:8px 0;">}
            . qq{Aplicado em toda a conta <strong>$user</strong> (<code>/home/$user</code>)}
            . qq{</div>}
            . qq{<div style="display:grid;grid-template-columns:auto 1fr;gap:4px 14px;font-size:13px;margin-top:8px;">}
            . qq{<span style="font-weight:600;opacity:0.75;">Diretórios</span><span><code>755</code></span>}
            . qq{<span style="font-weight:600;opacity:0.75;">Arquivos</span><span><code>644</code></span>}
            . qq{<span style="font-weight:600;opacity:0.75;">Scripts .cgi/.pl/.sh</span><span><code>755</code></span>}
            . qq{<span style="font-weight:600;opacity:0.75;">Home</span><span><code>711</code></span>}
            . qq{<span style="font-weight:600;opacity:0.75;">public_html / .htpasswds</span><span><code>$pubhtml_mode</code> $pubhtml_owner</span>}
            . qq{<span style="font-weight:600;opacity:0.75;">public_ftp</span><span><code>$pubftp_mode</code></span>}
            . qq{<span style="font-weight:600;opacity:0.75;">.ssh (e chaves)</span><span><code>700</code> / <code>600</code></span>}
            . qq{<span style="font-weight:600;opacity:0.75;">mail</span><span><code>751</code></span>}
            . qq{<span style="font-weight:600;opacity:0.75;">etc</span><span><code>750</code> user:mail</span>}
            . qq{</div>};

    json_out({ success => \1, message => $msg });
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
