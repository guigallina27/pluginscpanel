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
print $cpanel->header('Ferramentas');
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

    my $before = _count_user_procs($user);

    # Fork: o pkill precisa ocorrer fora do processo atual porque a propria
    # requisicao roda sob o mesmo UID e seria encerrada junto.
    my $pid = fork();
    return { success => \0, message => 'Falha ao bifurcar processo para encerramento.' }
        if !defined $pid;

    if ( $pid == 0 ) {
        # Filho: se destaca, espera a resposta HTTP ir embora e executa pkill.
        close STDIN;
        close STDOUT;
        close STDERR;
        open STDOUT, '>', '/dev/null';
        open STDERR, '>', '/dev/null';
        POSIX::setsid();
        sleep 3;
        exec( '/usr/bin/pkill', '-9', '-u', $user );
        exit 0;
    }

    return {
        success => \1,
        message => "Encerramento agendado. $before processo(s) detectado(s) - serao finalizados em instantes. Sua sessao pode cair temporariamente; recarregue a pagina se isso ocorrer.",
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
        return { success => \0, message => 'Nenhum document root foi localizado para sua conta.' };
    }

    my $msg = "Permissoes normalizadas em $count diretorio(s) (owner $user, dirs 755, arquivos 644, scripts .cgi/.pl 755).";
    $msg .= " Ocorreram $errors aviso(s) durante a operacao." if $errors;

    return { success => \1, message => $msg };
}

sub _count_user_procs {
    my ($user) = @_;
    my $count = qx{/usr/bin/pgrep -c -u \Q$user\E 2>/dev/null};
    chomp $count if defined $count;
    return ( defined $count && length $count ) ? $count : '0';
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

.usertools-root {
  --ut-bg-primary: #F8FAFC;
  --ut-bg-secondary: #FFFFFF;
  --ut-bg-surface: #F1F5F9;
  --ut-text-primary: #0F172A;
  --ut-text-muted: #64748B;
  --ut-accent: #8b5cf6;
  --ut-accent-hover: #7c3aed;
  --ut-sapphire: #4f46e5;
  --ut-sapphire-hover: #4338ca;
  --ut-border: #E2E8F0;
  --ut-error: #ef4444;
  --ut-success: #10b981;
  --ut-info: #3b82f6;
  --ut-warn: #f59e0b;

  font-family: 'Inter', system-ui, -apple-system, sans-serif;
  color: var(--ut-text-primary);
  font-size: 14px;
  line-height: 1.6;
  max-width: 900px;
  margin: 30px auto;
  padding: 0 16px;
}

\@media (prefers-color-scheme: dark) {
  .usertools-root {
    --ut-bg-primary: #0F172A;
    --ut-bg-secondary: #1E293B;
    --ut-bg-surface: #334155;
    --ut-text-primary: #F8FAFC;
    --ut-text-muted: #94A3B8;
    --ut-border: #334155;
  }
}

.usertools-root * { box-sizing: border-box; }

.usertools-root .card {
  background: var(--ut-bg-secondary);
  border: 1px solid var(--ut-border);
  border-radius: 16px;
  padding: 32px;
  box-shadow: 0 10px 25px -5px rgba(0,0,0,0.05);
}
.usertools-root .card-header {
  display: flex; align-items: center; gap: 18px;
  margin-bottom: 24px; padding-bottom: 20px;
  border-bottom: 1px solid var(--ut-border);
}
.usertools-root .icon-wrap {
  width: 56px; height: 56px; border-radius: 14px;
  background: linear-gradient(135deg, var(--ut-accent), var(--ut-sapphire));
  display: flex; align-items: center; justify-content: center;
  color: #fff; font-size: 26px; flex-shrink: 0;
  box-shadow: 0 4px 14px 0 rgba(139,92,246,0.39);
}
.usertools-root h2 { margin: 0; font-size: 22px; font-weight: 700; letter-spacing: -0.02em; }
.usertools-root .subtitle { margin: 6px 0 0; font-size: 14px; color: var(--ut-text-muted); }

.usertools-root .info-box {
  margin: 0 0 24px; padding: 16px 20px;
  background: var(--ut-bg-surface);
  border-left: 4px solid var(--ut-info);
  border-radius: 8px;
  display: flex; align-items: flex-start; gap: 12px;
}
.usertools-root .info-box i { color: var(--ut-info); font-size: 18px; margin-top: 2px; }

.usertools-root .actions { display: grid; grid-template-columns: 1fr; gap: 20px; }
\@media (min-width: 768px) {
  .usertools-root .actions { grid-template-columns: 1fr 1fr; }
}

.usertools-root .action-card {
  border: 1px solid var(--ut-border);
  border-radius: 12px; padding: 24px;
  background: var(--ut-bg-secondary);
  display: flex; flex-direction: column; gap: 12px;
  transition: transform 0.2s, box-shadow 0.2s, border-color 0.2s;
}
.usertools-root .action-card:hover {
  transform: translateY(-2px);
  box-shadow: 0 12px 20px -8px rgba(0,0,0,0.08);
  border-color: var(--ut-accent);
}
.usertools-root .action-card h3 {
  margin: 0; font-size: 17px; font-weight: 600;
  display: flex; align-items: center; gap: 10px;
}
.usertools-root .action-card h3.danger-title { color: var(--ut-error); }
.usertools-root .action-card h3.primary-title { color: var(--ut-sapphire); }
.usertools-root .action-card p {
  margin: 0; font-size: 14px; color: var(--ut-text-muted); flex-grow: 1;
}

.usertools-root .btn {
  display: inline-flex; align-items: center; justify-content: center; gap: 8px;
  padding: 12px 20px; border: none; border-radius: 10px;
  font-size: 14px; font-weight: 600; cursor: pointer;
  font-family: inherit; transition: all 0.2s;
  margin-top: 8px; outline: none;
}
.usertools-root .btn:active { transform: scale(0.98); }
.usertools-root .btn:disabled { opacity: 0.6; cursor: not-allowed; transform: none; }

.usertools-root .btn-danger {
  background: rgba(239,68,68,0.1); color: var(--ut-error);
  border: 1px solid rgba(239,68,68,0.2);
}
.usertools-root .btn-danger:hover:not(:disabled) {
  background: var(--ut-error); color: #fff;
  box-shadow: 0 4px 12px rgba(239,68,68,0.3);
}
.usertools-root .btn-primary {
  background: linear-gradient(to right, var(--ut-sapphire), var(--ut-accent)); color: #fff;
}
.usertools-root .btn-primary:hover:not(:disabled) {
  background: linear-gradient(to right, var(--ut-sapphire-hover), var(--ut-accent-hover));
  box-shadow: 0 4px 14px rgba(139,92,246,0.4);
}

.usertools-root .result {
  margin-top: 24px; padding: 16px 20px;
  border-radius: 10px; display: none; font-size: 14px;
  word-break: break-word;
}
.usertools-root .result.show { display: flex; align-items: flex-start; gap: 12px; }
.usertools-root .result.success {
  background: rgba(16,185,129,0.1); color: var(--ut-success);
  border: 1px solid rgba(16,185,129,0.2);
}
.usertools-root .result.error {
  background: rgba(239,68,68,0.1); color: var(--ut-error);
  border: 1px solid rgba(239,68,68,0.2);
}

.usertools-root .user-pill {
  display: inline-block; padding: 4px 12px; border-radius: 20px;
  background: var(--ut-bg-surface);
  border: 1px solid var(--ut-border);
  font-weight: 500; font-size: 13px; color: var(--ut-accent);
}

.usertools-root .spinner {
  display: inline-block; width: 16px; height: 16px;
  border: 2px solid currentColor; border-right-color: transparent;
  border-radius: 50%; animation: ut-spin 0.8s linear infinite;
}
\@keyframes ut-spin { to { transform: rotate(360deg); } }

/* Modal */
.ut-modal { position: fixed; inset: 0; background: rgba(15,23,42,0.6);
  backdrop-filter: blur(4px); display: flex; align-items: center;
  justify-content: center; z-index: 9999; }
.ut-modal[hidden] { display: none; }
.ut-modal-box { background: var(--ut-bg-secondary); border-radius: 16px;
  padding: 32px; max-width: 460px; width: 90%;
  box-shadow: 0 20px 25px -5px rgba(0,0,0,0.25);
  display: flex; flex-direction: column; gap: 20px; }
.ut-modal-icon { font-size: 38px; color: var(--ut-warn); text-align: center; }
.ut-modal-title { font-size: 18px; font-weight: 600; margin: 0; text-align: center; }
.ut-modal-msg { font-size: 14px; color: var(--ut-text-muted); margin: 0; text-align: center; line-height: 1.5; }
.ut-modal-actions { display: flex; gap: 12px; justify-content: center; }
.ut-modal-actions .btn { margin: 0; min-width: 120px; }
.ut-modal-actions .btn-secondary {
  background: var(--ut-bg-surface); color: var(--ut-text-primary);
  border: 1px solid var(--ut-border);
}
</style>

<div class="usertools-root">
  <div class="card">
    <div class="card-header">
      <div class="icon-wrap"><i class="bi bi-tools" aria-hidden="true"></i></div>
      <div>
        <h2>Ferramentas de Manutencao</h2>
        <p class="subtitle">Acoes de recuperacao na sua conta <span class="user-pill">$user</span></p>
      </div>
    </div>

    <div class="info-box">
      <i class="bi bi-info-circle-fill" aria-hidden="true"></i>
      <div>
        <strong>Quando usar:</strong> site travado, memoria esgotada, erros 403/500 apos upload via FTP/SSH, ou processos PHP-FPM presos consumindo recursos.
      </div>
    </div>

    <div class="actions">
      <div class="action-card">
        <h3 class="danger-title"><i class="bi bi-cpu" aria-hidden="true"></i> Encerrar processos</h3>
        <p>Finaliza todos os processos ativos da sua conta (PHP-FPM, scripts travados, cron em loop). Servicos essenciais sao reiniciados automaticamente em seguida.</p>
        <button id="ut-btn-kill" type="button" class="btn btn-danger">
          <i class="bi bi-power" aria-hidden="true"></i> Encerrar processos
        </button>
      </div>

      <div class="action-card">
        <h3 class="primary-title"><i class="bi bi-shield-check" aria-hidden="true"></i> Reparar permissoes</h3>
        <p>Restaura owner e permissoes dos seus document roots para os valores recomendados pelo cPanel (755 para pastas, 644 para arquivos, 755 para scripts).</p>
        <button id="ut-btn-fix" type="button" class="btn btn-primary">
          <i class="bi bi-wrench-adjustable" aria-hidden="true"></i> Reparar permissoes
        </button>
      </div>
    </div>

    <div id="ut-result" class="result" role="status" aria-live="polite"></div>
  </div>
</div>

<div id="ut-modal" class="ut-modal" hidden>
  <div class="ut-modal-box">
    <div class="ut-modal-icon"><i class="bi bi-exclamation-triangle-fill" aria-hidden="true"></i></div>
    <h3 class="ut-modal-title" id="ut-modal-title"></h3>
    <p class="ut-modal-msg" id="ut-modal-msg"></p>
    <div class="ut-modal-actions">
      <button type="button" class="btn btn-secondary" id="ut-modal-cancel">Cancelar</button>
      <button type="button" class="btn btn-primary" id="ut-modal-ok">Confirmar</button>
    </div>
  </div>
</div>

<script>
(function() {
  'use strict';
  const URL_SELF = window.location.pathname;
  const btnKill  = document.getElementById('ut-btn-kill');
  const btnFix   = document.getElementById('ut-btn-fix');
  const result   = document.getElementById('ut-result');
  const modal    = document.getElementById('ut-modal');
  const mTitle   = document.getElementById('ut-modal-title');
  const mMsg     = document.getElementById('ut-modal-msg');
  const mOk      = document.getElementById('ut-modal-ok');
  const mCancel  = document.getElementById('ut-modal-cancel');

  function showResult(ok, msg) {
    const icon = ok
      ? '<i class="bi bi-check-circle-fill" style="margin-top:2px;font-size:18px"></i>'
      : '<i class="bi bi-exclamation-triangle-fill" style="margin-top:2px;font-size:18px"></i>';
    result.className = 'result show ' + (ok ? 'success' : 'error');
    result.innerHTML = icon + '<div>' + msg + '</div>';
  }
  function clearResult() { result.className = 'result'; result.innerHTML = ''; }

  function confirmModal(title, msg) {
    return new Promise(resolve => {
      mTitle.textContent = title;
      mMsg.textContent   = msg;
      modal.hidden = false;
      const done = (val) => {
        modal.hidden = true;
        mOk.onclick = mCancel.onclick = null;
        resolve(val);
      };
      mOk.onclick     = () => done(true);
      mCancel.onclick = () => done(false);
    });
  }

  async function runAction(act, btn, confirmTitle, confirmMsg) {
    const ok = await confirmModal(confirmTitle, confirmMsg);
    if (!ok) return;

    const originalHTML = btn.innerHTML;
    btnKill.disabled = true;
    btnFix.disabled  = true;
    btn.innerHTML = '<span class="spinner"></span> Processando...';
    clearResult();

    try {
      const form = new FormData();
      form.append('action', act);
      const r = await fetch(URL_SELF, {
        method: 'POST', body: form, credentials: 'same-origin'
      });
      const text = await r.text();
      let d;
      try { d = JSON.parse(text); }
      catch (e) {
        showResult(false, 'Resposta invalida do servidor. Detalhe tecnico: ' + e.message);
        return;
      }
      showResult(!!d.success, d.message || (d.success ? 'Operacao concluida.' : 'Nao foi possivel concluir a operacao.'));
    } catch (e) {
      showResult(false, 'Falha na comunicacao com o servidor: ' + e.message);
    } finally {
      btn.innerHTML = originalHTML;
      btnKill.disabled = false;
      btnFix.disabled  = false;
    }
  }

  btnKill.addEventListener('click', () => runAction(
    'kill_procs', btnKill,
    'Encerrar todos os seus processos?',
    'Isso ira finalizar scripts PHP, cron jobs e conexoes ativas da sua conta. O site pode ficar indisponivel por alguns segundos enquanto o cPanel reinicia os servicos essenciais.'
  ));
  btnFix.addEventListener('click', () => runAction(
    'fix_perms', btnFix,
    'Reparar permissoes dos seus arquivos?',
    'O cPanel ira ajustar owner e permissoes dos diretorios public_html e de dominios adicionados aos valores padrao (pastas 755, arquivos 644, scripts 755). A operacao pode levar alguns segundos conforme o volume de arquivos.'
  ));
})();
</script>
HTML
}
