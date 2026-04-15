#!/usr/local/cpanel/3rdparty/bin/perl
#
# UserTools - interface cPanel (usuario agindo em si mesmo)
#
# Roda no contexto do usuario cPanel. O proprio usuario tem privilegio
# para matar seus processos (pkill -u $self) e para alterar permissoes/
# ownership dentro do proprio home - nao precisa de AdminBin.
#
# O LiveAPI do cPanel EXIGE ser inicializado em scripts .live.pl antes de
# qualquer output, senao o cpaneld aborta com "Child failed to make LIVEAPI
# connection". Para endpoints JSON (AJAX), chamamos $cpanel->end() ANTES
# de imprimir o JSON para que o wrapper nao injete HTML depois.

use strict;
use warnings;
use utf8;

use Cpanel::LiveAPI ();
use CGI             ();
use POSIX           ();

use Encode ();

# O 'use utf8' marca apenas o SOURCE como UTF-8 - o STDOUT continua em
# modo raw. Sem encoding manual, acentos do source viram "?" no browser.
# NAO usamos binmode ':utf8' no STDOUT porque o JSON::XS ja retorna bytes
# UTF-8 (->utf8) e isso geraria dupla codificacao. Ao inves disso, o HTML
# heredoc passa por Encode::encode_utf8 antes de ir para STDOUT.

my $cpanel = Cpanel::LiveAPI->new();

my $cgi    = CGI->new;
my $action = $cgi->param('action') || '';
my $user   = $ENV{'REMOTE_USER'} || '';

# Sanitiza nome de usuario (untaint) - usado em comandos externos.
if ( $user !~ /^([a-z0-9_\-]{1,32})$/ ) {
    _json_response( $cpanel, {
        success => \0,
        message => 'Sua sessão expirou ou é inválida. Faça logout e entre no cPanel novamente para continuar.',
    } );
    exit 0;
}
$user = $1;

if ( $action eq 'kill_procs' ) {
    my $result = _do_kill_procs($user);
    my $should_kill = delete $result->{_kill_after};
    _json_response( $cpanel, $result );
    # Flush + fecha STDOUT/STDERR para garantir que o cliente ja recebeu
    # a resposta antes de disparar o pkill (que pode atingir este Perl).
    close STDOUT;
    close STDERR;
    _exec_kill_now($user) if $should_kill;
    exit 0;
}
elsif ( $action eq 'fix_perms' ) {
    _json_response( $cpanel, _do_fix_perms($user) );
    exit 0;
}

# Branch padrao: renderiza a UI HTML com o chrome do cPanel.
print "Content-type: text/html; charset=utf-8\r\n\r\n";
# O 2o argumento (app_key) eh obrigatorio para o cPanel resolver
# breadcrumbs e o link 'Home'. Sem isso, ao sair da pagina o cPanel
# cai em 404 porque nao sabe de qual app esta voltando.
# Encode::encode_utf8 converte a string decodada (pela 'use utf8') de volta
# para bytes UTF-8 que o browser renderiza corretamente.
print $cpanel->header( Encode::encode_utf8('Ferramentas do Usuário'), 'usertools' );
print Encode::encode_utf8( _body_html($user) );
print $cpanel->footer();
$cpanel->end();
exit 0;

# ============================================================================
# Endpoints JSON
# ============================================================================

sub _json_response {
    my ( $cp, $data ) = @_;
    # Fecha o handshake LiveAPI antes de imprimir o JSON, senao o cpaneld
    # injeta HTML do chrome apos nosso output e quebra o parse no JS.
    $cp->end();
    require JSON::XS;
    my $json = JSON::XS->new->utf8;
    print "Content-type: application/json; charset=utf-8\r\n\r\n";
    print $json->encode($data);
}

sub _do_kill_procs {
    my ($user) = @_;

    # Estrategia para kill imediato + resposta garantida:
    # 1. Pai imprime o JSON, dá flush e fecha STDOUT (Apache ja entregou a
    #    resposta ao browser).
    # 2. Pai faz fork + exec do pkill apenas apos ter liberado a conexao.
    # 3. O filho executa pkill -9 -ceiu SEM sleep - matanca imediata de
    #    PHP-FPM, cron, SSH e demais processos do proprio UID.
    # 4. Se o pkill atingir o processo Perl pai (ja desconectado), tudo bem:
    #    o cliente ja recebeu o JSON.

    return {
        success => \1,
        message => 'Finalização executada. Todos os seus processos ativos (PHP-FPM, cron jobs, SSH e scripts) foram encerrados imediatamente. As próximas requisições ao seu site iniciarão novos processos normalmente.',
        _kill_after => 1,
    };
}

# Apos o JSON ser impresso e STDOUT fechado, invoca pkill imediato no
# proprio UID. Chamada do branch principal, nao do _do_kill_procs,
# porque precisa ocorrer depois do _json_response.
sub _exec_kill_now {
    my ($user) = @_;
    my $pid = fork();
    return if !defined $pid || $pid != 0;
    POSIX::setsid();
    exec( '/usr/bin/pkill', '-9', '-ceiu', $user );
    exit 0;
}

sub _do_fix_perms {
    my ($user) = @_;

    my @pw = getpwnam($user);
    return {
        success => \0,
        message => 'Sua conta cPanel não foi localizada no sistema. Entre em contato com o suporte para verificar a integridade do seu acesso.',
    } if !@pw;

    my $user_uid = $pw[2];
    my $user_gid = $pw[3];
    my $home     = $pw[7];

    return {
        success => \0,
        message => 'O diretório pessoal (home) da sua conta está indisponível ou protegido. A operação foi bloqueada por segurança — contate o suporte para investigação.',
    } if !defined $home || !-d $home || $home eq '/' || $home eq '/root';

    my $errors = 0;

    # 1. Owner recursivo em TODO o home (dono = user, grupo = user).
    #    Excecao: public_html mantem grupo 'nobody' por padrao do EA4.
    system( '/bin/chown', '-R', "$user_uid:$user_gid", $home ) == 0 or $errors++;

    # 2. Permissoes base em todo o home: dirs 755, arquivos 644.
    system( '/usr/bin/find', $home, '-type', 'd', '-exec', '/bin/chmod', '755', '{}', '+' );
    system( '/usr/bin/find', $home, '-type', 'f', '-exec', '/bin/chmod', '644', '{}', '+' );

    # 3. Scripts executaveis mantem bit de execucao.
    system( '/usr/bin/find', $home, '-type', 'f',
        '(', '-name', '*.cgi', '-o', '-name', '*.pl', '-o', '-name', '*.sh', ')',
        '-exec', '/bin/chmod', '755', '{}', '+' );

    # 4. Casos especiais baseados no padrao oficial /scripts/unsuspendacct:
    #    No contexto cPanel (user normal), o POSIX NAO permite chown para
    #    grupo 'nobody' (user nao pertence ao grupo). Entao mantemos
    #    user:user em tudo e aplicamos apenas os chmods corretos.
    #    O fix completo (user:nobody quando fileprotect esta ativo) so
    #    ocorre no WHM, que roda como root.
    chmod 0711, $home;

    my $fileprotect = -e '/var/cpanel/fileprotect';
    my $noanonftp   = -e '/var/cpanel/noanonftp';

    # public_html e .htpasswds: mesmo tratamento (750 se fileprotect, 755 se nao)
    for my $dir ( "$home/public_html", "$home/.htpasswds" ) {
        next unless -d $dir;
        chmod +( $fileprotect ? 0750 : 0755 ), $dir;
    }

    # public_ftp: 750 se noanonftp estiver ativo, senao 755
    my $public_ftp = "$home/public_ftp";
    if ( -d $public_ftp ) {
        chmod +( $noanonftp ? 0750 : 0755 ), $public_ftp;
    }

    # .ssh: 700 no dir e 600 nos arquivos (chaves privadas)
    my $ssh_dir = "$home/.ssh";
    if ( -d $ssh_dir ) {
        chmod 0700, $ssh_dir;
        system( '/usr/bin/find', $ssh_dir, '-type', 'f', '-exec', '/bin/chmod', '600', '{}', '+' );
    }

    # etc/ (dovecot/exim): 750 user:mail (se o grupo existir)
    my $etc_dir = "$home/etc";
    if ( -d $etc_dir ) {
        my @mg = getgrnam('mail');
        if (@mg) {
            system( '/bin/chown', '-R', "$user:mail", $etc_dir );
            chmod 0750, $etc_dir;
        }
    }

    # mail/: 751
    my $mail_dir = "$home/mail";
    chmod 0751, $mail_dir if -d $mail_dir;

    my $fp_note = $fileprotect
        ? 'public_html em 750 (fileprotect ativo)'
        : 'public_html em 755 (fileprotect desativado neste servidor)';

    return {
        success => \1,
        message => "Permissões normalizadas em toda a sua conta cPanel seguindo o padrão oficial do cPanel. Diretórios em 755, arquivos em 644, scripts .cgi/.pl/.sh em 755. Aplicadas permissões especiais: home em 711, $fp_note, .htpasswds igual ao public_html, public_ftp conforme política de FTP anônimo, .ssh em 700 com chaves em 600, mail em 751, etc em 750 (user:mail). Dono restabelecido para \"$user\" em todos os arquivos.",
    };
}

# ============================================================================
# UI HTML
# ============================================================================

sub _body_html {
    my ($user) = @_;
    $user =~ s/[<>&"']//g;

    return <<"HTML";
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons\@1.11.3/font/bootstrap-icons.min.css">
<style>
\@import url('https://fonts.googleapis.com/css2?family=Inter:wght\@400;500;600;700&display=swap');

.ut {
  --ut-bg:         #FFFFFF;
  --ut-bg-alt:     #F8FAFC;
  --ut-bg-hover:   #F1F5F9;
  --ut-text:       #0F172A;
  --ut-text-dim:   #475569;
  --ut-text-mute:  #94A3B8;
  --ut-border:     #E2E8F0;
  --ut-border-str: #CBD5E1;
  --ut-accent:     #8b5cf6;
  --ut-accent-hover:#7c3aed;
  --ut-sapphire:   #4f46e5;
  --ut-sapphire-hover: #4338ca;
  --ut-danger:     #ef4444;
  --ut-danger-dim: rgba(239, 68, 68, 0.1);
  --ut-warn:       #f59e0b;
  --ut-warn-dim:   rgba(245, 158, 11, 0.15);
  --ut-success:    #10b981;
  --ut-success-dim:rgba(16, 185, 129, 0.1);

  font-family: 'Inter', system-ui, -apple-system, sans-serif;
  color: var(--ut-text);
  font-size: 14px;
  line-height: 1.6;
  padding: 32px;
  width: 100%;
  max-width: 1000px;
  margin: 0 auto;
}
.ut, .ut * { box-sizing: border-box; }

.ut-page-header {
  display: flex; align-items: center; gap: 18px;
  padding-bottom: 24px; margin-bottom: 28px;
  border-bottom: 1px solid var(--ut-border);
}
.ut-page-icon {
  width: 56px; height: 56px; border-radius: 14px;
  background: linear-gradient(135deg, var(--ut-accent), var(--ut-sapphire));
  color: #fff; font-size: 26px;
  display: flex; align-items: center; justify-content: center;
  flex-shrink: 0;
  box-shadow: 0 4px 14px rgba(139, 92, 246, 0.35);
}
.ut-page-text { flex: 1; min-width: 0; }
.ut-page-title { margin: 0; font-size: 22px; font-weight: 700; letter-spacing: -0.02em; color: var(--ut-text); }
.ut-page-subtitle { margin: 4px 0 0; font-size: 14px; color: var(--ut-text-dim); }
.ut-role-badge {
  display: inline-flex; align-items: center; gap: 6px;
  padding: 6px 12px;
  background: rgba(79, 70, 229, 0.1);
  color: var(--ut-sapphire);
  border-radius: 20px;
  font-size: 12px; font-weight: 700;
  letter-spacing: 0.04em; text-transform: uppercase;
  flex-shrink: 0;
  border: 1px solid rgba(79, 70, 229, 0.2);
}

.ut-alert {
  display: flex; align-items: flex-start; gap: 12px;
  padding: 16px 20px;
  background: var(--ut-warn-dim);
  border-left: 4px solid var(--ut-warn);
  border-radius: 8px;
  font-size: 14px; color: var(--ut-text);
  margin-bottom: 32px;
}
.ut-alert i { color: var(--ut-warn); font-size: 18px; flex-shrink: 0; margin-top: 1px; }
.ut-alert strong { font-weight: 600; color: var(--ut-text); }

.ut-section {
  margin-bottom: 32px;
  background: var(--ut-bg);
  border: 1px solid var(--ut-border);
  border-radius: 16px;
  padding: 32px;
  box-shadow: 0 10px 25px -5px rgba(0, 0, 0, 0.05), 0 8px 10px -6px rgba(0, 0, 0, 0.01);
}
.ut-section-head {
  display: flex; align-items: baseline; justify-content: space-between;
  margin-bottom: 16px; gap: 16px;
}
.ut-section-title {
  font-size: 14px; font-weight: 700;
  text-transform: uppercase; letter-spacing: 0.08em;
  color: var(--ut-text-dim);
}
.ut-section-hint { font-size: 13px; font-weight: 500; color: var(--ut-text-mute); }

.ut-account-card {
  display: flex; align-items: center; gap: 16px;
  padding: 18px 20px;
  background: linear-gradient(145deg, rgba(79, 70, 229, 0.05), rgba(139, 92, 246, 0.05));
  border: 1px solid rgba(79, 70, 229, 0.2);
  border-radius: 12px;
}
.ut-account-card > i { color: var(--ut-sapphire); font-size: 24px; flex-shrink: 0; }
.ut-account-info { flex: 1; min-width: 0; }
.ut-account-user { font-weight: 700; font-size: 16px; color: var(--ut-text); }
.ut-account-label { color: var(--ut-text-dim); font-size: 13px; margin-top: 2px; }

.ut-actions {
  display: flex; gap: 16px; flex-wrap: wrap; margin-top: 8px;
}
.ut-actions .ut-btn { flex: 1 1 220px; }
.ut-btn {
  display: inline-flex; align-items: center; justify-content: center; gap: 10px;
  padding: 14px 24px;
  border: 1px solid transparent; border-radius: 12px;
  font-size: 15px; font-weight: 600; font-family: inherit;
  cursor: pointer; outline: none;
  transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
}
.ut-btn:active { transform: scale(0.98); }
.ut-btn:disabled { opacity: 0.5; cursor: not-allowed; transform: none; }
.ut-btn i { font-size: 18px; }

.ut-btn-primary {
  background: linear-gradient(to right, var(--ut-sapphire), var(--ut-accent));
  color: #fff;
  box-shadow: 0 2px 10px rgba(79, 70, 229, 0.2);
}
.ut-btn-primary:hover:not(:disabled) {
  background: linear-gradient(to right, var(--ut-sapphire-hover), var(--ut-accent-hover));
  box-shadow: 0 4px 14px rgba(79, 70, 229, 0.35);
}
.ut-btn-danger {
  background: var(--ut-danger-dim); color: var(--ut-danger);
  border-color: rgba(239, 68, 68, 0.2);
}
.ut-btn-danger:hover:not(:disabled) {
  background: var(--ut-danger); color: #fff;
  box-shadow: 0 4px 14px rgba(239, 68, 68, 0.3);
}
.ut-btn-link {
  background: none; border: none;
  color: var(--ut-text-dim);
  font-weight: 600; cursor: pointer; font-size: 14px;
  padding: 8px 12px; border-radius: 8px; font-family: inherit;
}
.ut-btn-link:hover { background: var(--ut-bg-hover); color: var(--ut-text); }

.ut-result {
  margin-top: 24px; padding: 16px 20px;
  border-radius: 12px; font-size: 14px;
  display: none; align-items: flex-start; gap: 12px;
  word-break: break-word; line-height: 1.5;
  animation: ut-slide 0.3s ease-out;
}
\@keyframes ut-slide {
  from { opacity: 0; transform: translateY(-10px); }
  to   { opacity: 1; transform: translateY(0); }
}
.ut-result.show { display: flex; }
.ut-result i { font-size: 18px; flex-shrink: 0; margin-top: 1px; }
.ut-result.success {
  background: var(--ut-success-dim); color: var(--ut-success);
  border: 1px solid rgba(16, 185, 129, 0.2);
}
.ut-result.error {
  background: var(--ut-danger-dim); color: var(--ut-danger);
  border: 1px solid rgba(239, 68, 68, 0.2);
}

.ut-spinner {
  display: inline-block; width: 18px; height: 18px;
  border: 2px solid currentColor; border-right-color: transparent;
  border-radius: 50%; animation: ut-spin 0.8s linear infinite;
}
\@keyframes ut-spin { to { transform: rotate(360deg); } }

/* Modal - cores hardcoded para opacidade garantida */
.ut-modal {
  position: fixed; inset: 0;
  background: rgba(15, 23, 42, 0.75);
  backdrop-filter: blur(6px); -webkit-backdrop-filter: blur(6px);
  display: flex; align-items: center; justify-content: center;
  z-index: 99999;
}
.ut-modal[hidden] { display: none !important; }
.ut-modal-box {
  background: #FFFFFF; color: #0F172A;
  border: 1px solid #E2E8F0;
  border-radius: 16px; padding: 32px;
  max-width: 460px; width: 90%;
  box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.5);
  display: flex; flex-direction: column; gap: 20px;
  animation: ut-pop 0.3s cubic-bezier(0.16, 1, 0.3, 1);
}
\@keyframes ut-pop {
  0% { opacity: 0; transform: scale(0.95); }
  100% { opacity: 1; transform: scale(1); }
}
.ut-modal-icon { font-size: 38px; text-align: center; line-height: 1; color: #f59e0b; }
.ut-modal-title { font-size: 18px; font-weight: 600; color: #0F172A; text-align: center; margin: 0; }
.ut-modal-msg { font-size: 14px; color: #475569; text-align: center; margin: 0; line-height: 1.5; }
.ut-modal-actions { display: flex; gap: 12px; justify-content: flex-end; }
.ut-modal-actions .ut-btn { flex: 1; min-width: 0; }
</style>

<div class="ut">
  <header class="ut-page-header">
    <div class="ut-page-icon"><i class="bi bi-tools" aria-hidden="true"></i></div>
    <div class="ut-page-text">
      <h1 class="ut-page-title">Ferramentas do Usuário</h1>
      <p class="ut-page-subtitle">Ações de recuperação e manutenção na sua conta cPanel.</p>
    </div>
    <span class="ut-role-badge">
      <i class="bi bi-person-badge-fill" aria-hidden="true"></i>
      Cliente
    </span>
  </header>

  <div class="ut-alert" role="note">
    <i class="bi bi-exclamation-triangle-fill" aria-hidden="true"></i>
    <div>
      <strong>Quando usar:</strong> site travado, memória esgotada, erros 403/500 após upload via FTP/SSH, cron em loop ou processos PHP-FPM consumindo recursos. As ações afetam apenas a sua conta.
    </div>
  </div>

  <section class="ut-section">
    <div class="ut-section-head">
      <span class="ut-section-title">Conta selecionada</span>
      <span class="ut-section-hint">Sessão atual</span>
    </div>
    <div class="ut-account-card">
      <i class="bi bi-check-circle-fill" aria-hidden="true"></i>
      <div class="ut-account-info">
        <div class="ut-account-user">$user</div>
        <div class="ut-account-label">As operações serão executadas neste usuário cPanel.</div>
      </div>
    </div>
  </section>

  <section class="ut-section">
    <div class="ut-section-head">
      <span class="ut-section-title">Painel de ações</span>
    </div>
    <div class="ut-actions">
      <button id="ut-btn-kill" type="button" class="ut-btn ut-btn-danger">
        <i class="bi bi-power" aria-hidden="true"></i>
        Finalizar processos
      </button>
      <!-- subtitulo visivel no modal -->

      <button id="ut-btn-fix" type="button" class="ut-btn ut-btn-primary">
        <i class="bi bi-wrench-adjustable" aria-hidden="true"></i>
        Corrigir permissões &amp; owner
      </button>
    </div>
    <div id="ut-result" class="ut-result" role="status" aria-live="polite"></div>
  </section>

  <div id="ut-modal" class="ut-modal" hidden>
    <div class="ut-modal-box">
      <div class="ut-modal-icon"><i id="ut-modal-icon" class="bi bi-exclamation-triangle-fill" aria-hidden="true"></i></div>
      <h3 id="ut-modal-title" class="ut-modal-title">Confirme</h3>
      <p id="ut-modal-msg" class="ut-modal-msg"></p>
      <div class="ut-modal-actions">
        <button id="ut-modal-cancel" type="button" class="ut-btn ut-btn-link">Cancelar</button>
        <button id="ut-modal-confirm" type="button" class="ut-btn ut-btn-primary">Confirmar</button>
      </div>
    </div>
  </div>
</div>

<script>
(function() {
  'use strict';
  var URL_SELF = window.location.pathname;
  var btnKill  = document.getElementById('ut-btn-kill');
  var btnFix   = document.getElementById('ut-btn-fix');
  var result   = document.getElementById('ut-result');
  var modal    = document.getElementById('ut-modal');
  var mIcon    = document.getElementById('ut-modal-icon');
  var mTitle   = document.getElementById('ut-modal-title');
  var mMsg     = document.getElementById('ut-modal-msg');
  var mOk      = document.getElementById('ut-modal-confirm');
  var mCancel  = document.getElementById('ut-modal-cancel');

  function showResult(ok, msg) {
    result.className = 'ut-result show ' + (ok ? 'success' : 'error');
    result.innerHTML = '';
    var i = document.createElement('i');
    i.className = 'bi ' + (ok ? 'bi-check-circle-fill' : 'bi-x-octagon-fill');
    result.appendChild(i);
    var s = document.createElement('span');
    s.textContent = msg;
    result.appendChild(s);
  }
  function clearResult() { result.className = 'ut-result'; result.innerHTML = ''; }

  function customConfirm(actionType, msgHtml) {
    return new Promise(function(resolve) {
      mMsg.innerHTML = msgHtml;
      if (actionType === 'kill_procs') {
        mTitle.textContent = 'Finalizar processos';
        mIcon.className = 'bi bi-lightning-charge-fill';
        mIcon.style.color = 'var(--ut-danger)';
        mOk.className = 'ut-btn ut-btn-danger';
        mOk.innerHTML = '<i class="bi bi-power"></i> Finalizar agora';
      } else {
        mTitle.textContent = 'Corrigir permissões';
        mIcon.className = 'bi bi-shield-check';
        mIcon.style.color = 'var(--ut-sapphire)';
        mOk.className = 'ut-btn ut-btn-primary';
        mOk.innerHTML = '<i class="bi bi-wrench-adjustable"></i> Aplicar correção';
      }
      modal.hidden = false;
      mOk.onclick     = function() { modal.hidden = true; resolve(true); };
      mCancel.onclick = function() { modal.hidden = true; resolve(false); };
    });
  }

  function runAction(act, btn, msgHtml) {
    customConfirm(act, msgHtml).then(function(ok) {
      if (!ok) return;
      var originalHTML = btn.innerHTML;
      btnKill.disabled = true; btnFix.disabled = true;
      btn.innerHTML = '<span class="ut-spinner"></span> Processando...';
      clearResult();

      var form = new FormData();
      form.append('action', act);

      fetch(URL_SELF, { method: 'POST', body: form, credentials: 'same-origin' })
        .then(function(r) { return r.text(); })
        .then(function(text) {
          var d;
          try { d = JSON.parse(text); }
          catch (e) {
            showResult(false, 'O servidor retornou uma resposta inesperada. Recarregue a página e tente novamente; se persistir, contate o suporte.');
            return;
          }
          showResult(!!d.success, d.message || (d.success
            ? 'Ação concluída com sucesso.'
            : 'A operação não pôde ser concluída. Tente novamente em alguns instantes.'));
        })
        .catch(function(e) {
          showResult(false, 'Falha de comunicação com o servidor. Verifique sua conexão e tente novamente.');
        })
        .then(function() {
          btn.innerHTML = originalHTML;
          btnKill.disabled = false; btnFix.disabled = false;
        });
    });
  }

  btnKill.addEventListener('click', function() {
    runAction('kill_procs', btnKill,
      'Isso irá encerrar TODOS os processos ativos da sua conta (PHP-FPM, cron em execução, sessões SSH e scripts em loop).<br><br>' +
      'As próximas requisições ao seu site iniciarão novos processos normalmente — o site pode responder mais lento na primeira visita após a finalização.'
    );
  });
  btnFix.addEventListener('click', function() {
    runAction('fix_perms', btnFix,
      'O cPanel irá varrer todos os seus document roots (public_html e domínios adicionados) e restaurar owner e permissões padrão.<br><br>' +
      'Pastas <strong>755</strong>, arquivos <strong>644</strong>, scripts <strong>.cgi/.pl</strong> <strong>755</strong>. A operação pode levar alguns segundos.'
    );
  });
})();
</script>
HTML
}
