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

use Cpanel::LiveAPI ();
use CGI             ();
use POSIX           ();

my $cpanel = Cpanel::LiveAPI->new();

my $cgi    = CGI->new;
my $action = $cgi->param('action') || '';
my $user   = $ENV{'REMOTE_USER'} || '';

# Sanitiza nome de usuario (untaint) - usado em comandos externos.
if ( $user !~ /^([a-z0-9_\-]{1,32})$/ ) {
    _json_response( $cpanel, { success => \0, message => 'Sessao invalida.' } );
    exit 0;
}
$user = $1;

if ( $action eq 'kill_procs' ) {
    _json_response( $cpanel, _do_kill_procs($user) );
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
print $cpanel->header( 'Ferramentas do Usuário', 'usertools' );
print _body_html($user);
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

    # Fork: o pkill precisa ocorrer fora do processo atual porque a propria
    # requisicao roda sob o mesmo UID e seria encerrada junto.
    my $pid = fork();
    return { success => \0, message => 'Nao foi possivel iniciar a operacao no servidor. Tente novamente em instantes.' }
        if !defined $pid;

    if ( $pid == 0 ) {
        close STDIN;
        close STDOUT;
        close STDERR;
        open STDOUT, '>', '/dev/null';
        open STDERR, '>', '/dev/null';
        POSIX::setsid();
        sleep 3;
        exec( '/usr/bin/pkill', '-9', '-ceiu', $user );
        exit 0;
    }

    return {
        success => \1,
        message => 'Comando de finalizacao enviado. Seus processos ativos serao encerrados em alguns segundos. Se a pagina travar, basta recarregar - sua sessao sera restabelecida automaticamente.',
    };
}

sub _do_fix_perms {
    my ($user) = @_;

    my @pw = getpwnam($user);
    return { success => \0, message => 'Conta de usuario nao localizada no sistema.' }
        if !@pw;

    my $user_uid = $pw[2];
    my $user_gid = $pw[3];
    my $home     = $pw[7];

    return { success => \0, message => 'Diretorio home invalido.' }
        if !defined $home || !-d $home || $home eq '/' || $home eq '/root';

    # Ajuste do home (711 - permite o Apache servir o user sem listar).
    chmod 0711, $home;

    my @docroots;
    my $public_html = "$home/public_html";
    push @docroots, $public_html if -d $public_html;

    # Descobre docroots adicionais (addon/sub/parked) via /var/cpanel/userdata/<user>/
    my $userdata_dir = "/var/cpanel/userdata/$user";
    if ( -d $userdata_dir && opendir( my $dh, $userdata_dir ) ) {
        my %seen = ( $public_html => 1 );
        while ( my $entry = readdir $dh ) {
            next if $entry =~ /^\./ || $entry =~ /\.cache$/ || $entry =~ /_SSL$/ || $entry eq 'main';
            my $file = "$userdata_dir/$entry";
            next unless -f $file;

            open( my $fh, '<', $file ) or next;
            while ( my $line = <$fh> ) {
                next unless $line =~ /^\s*documentroot\s*:\s*(.+?)\s*$/;
                my $dr = $1;
                $dr =~ s/^["']|["']$//g;
                # Untaint + bloqueio de traversal: so aceita caminhos dentro do home.
                next unless $dr =~ m{^(\Q$home\E/[A-Za-z0-9_./\-]+)$};
                $dr = $1;
                next if $seen{$dr}++;
                push @docroots, $dr if -d $dr;
            }
            close $fh;
        }
        closedir $dh;
    }

    my $count = 0;
    my $errors = 0;
    for my $dr (@docroots) {
        # chown recursivo para user:user; find para separar dirs e arquivos.
        system( '/bin/chown', '-R', "$user_uid:$user_gid", $dr ) == 0 or $errors++;
        system( '/usr/bin/find', $dr, '-type', 'd', '-exec', '/bin/chmod', '755', '{}', '+' );
        system( '/usr/bin/find', $dr, '-type', 'f', '-exec', '/bin/chmod', '644', '{}', '+' );
        system( '/usr/bin/find', $dr, '-type', 'f',
            '(', '-name', '*.cgi', '-o', '-name', '*.pl', ')',
            '-exec', '/bin/chmod', '755', '{}', '+' );

        # Raiz do public_html = 750 para isolar entre contas.
        chmod 0750, $dr if $dr eq $public_html;
        $count++;
    }

    if ( $count == 0 ) {
        return {
            success => \0,
            message => 'Nenhum diretorio publico foi encontrado na sua conta. Verifique se voce possui ao menos um dominio configurado.',
        };
    }

    my $plural = $count == 1 ? 'diretorio' : 'diretorios';
    my $msg = "Permissoes restauradas com sucesso em $count $plural. Pastas agora com modo 755, arquivos com 644, scripts .cgi/.pl com 755 e dono restabelecido para $user.";
    $msg .= " (Alguns arquivos protegidos nao puderam ser alterados - isso e esperado em contas com integracao especial.)" if $errors;

    return { success => \1, message => $msg };
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
            showResult(false, 'Resposta inválida do servidor: ' + e.message);
            return;
          }
          showResult(!!d.success, d.message || (d.success ? 'Operação concluída.' : 'Não foi possível concluir a operação.'));
        })
        .catch(function(e) { showResult(false, 'Falha na comunicação: ' + e.message); })
        .then(function() {
          btn.innerHTML = originalHTML;
          btnKill.disabled = false; btnFix.disabled = false;
        });
    });
  }

  btnKill.addEventListener('click', function() {
    runAction('kill_procs', btnKill,
      'Isso irá encerrar TODOS os processos ativos da sua conta (PHP-FPM, cron em execução, sessões SSH e scripts em loop).<br><br>' +
      'O site pode ficar indisponível por alguns segundos enquanto o cPanel reinicia os serviços essenciais.'
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
