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

# Só root ou revendedor passam daqui.
if ( !Whostmgr::ACLS::hasroot() && !Whostmgr::ACLS::hasreseller() ) {
    print "Status: 403 Forbidden\r\nContent-type: text/plain\r\n\r\nAcesso negado.";
    exit;
}

my $is_root  = Whostmgr::ACLS::hasroot();
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
    if ( my $err = $@ ) {
        $err =~ s/\s+$//;
        json_out( { success => \0, message => "Erro ao listar: $err" } );
        return;
    }
    json_out( { success => \1, users => \@users } );
}

sub api_run_action {
    my ($act) = @_;

    my $target = $cgi->param('user') || '';

    # Sanitiza — apenas [a-z0-9_-], máx 32 caracteres
    if ( $target !~ /^[a-z0-9_\-]{1,32}$/ ) {
        json_out( { success => \0, message => 'Nome de usuário inválido.' } );
        return;
    }

    if ( !Cpanel::AcctUtils::Account::accountexists($target) ) {
        json_out( { success => \0, message => "Usuário '$target' não encontrado." } );
        return;
    }

    # Revendedor só atua em clientes dele
    if ( !$is_root && !_is_reseller_owner( $reseller, $target ) ) {
        json_out(
            {
                success => \0,
                message =>
                    "Você não tem permissão para agir sobre '$target'.",
            }
        );
        return;
    }

    eval {
        if ( $act eq 'kill_procs' ) { do_kill_procs($target); }
        else                        { do_fix_perms($target); }
        1;
    } or do {
        my $err = $@ || 'erro desconhecido';
        $err =~ s/\s+$//;
        json_out( { success => \0, message => "Falha na execução: $err" } );
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

    system( '/usr/bin/pkill', '-9', '-u', $user );

    sleep 1;

    my $after = qx{/usr/bin/pgrep -c -u \Q$user\E 2>/dev/null};
    chomp $after;
    $after = '0' unless defined $after && length $after;

    json_out(
        {
            success => \1,
            message =>
                "Processos finalizados para '$user'. Antes: $before, depois: $after.",
        }
    );
}

sub do_fix_perms {
    my ($user) = @_;

    my @pw = getpwnam($user);
    if (!@pw) {
        json_out({ success => \0, message => "Usuário '$user' não encontrado." });
        return;
    }
    
    my $home = $pw[7];
    if (!defined $home || !-d $home || $home eq '/' || $home eq '/root') {
        json_out({ success => \0, message => "Home do usuário inválido ou protegido contra modificações." });
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

    json_out({
        success => \1,
        message => "OK: Owner e permissões normalizados com segurança ($count DocRoots varridos).",
        output  => "Correção efetuada via comandos nativos Perl (fixhomedirperms bypass).",
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
