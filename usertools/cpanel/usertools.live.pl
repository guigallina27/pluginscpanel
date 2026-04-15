#!/usr/local/cpanel/3rdparty/bin/perl
#
# UserTools — interface cPanel (usuário agindo em si mesmo)
#
# Roda no contexto do usuário cPanel. Não tem privilégio para matar
# processos nem corrigir owner, então delega para o AdminBin
# (/usr/local/cpanel/bin/admin/Cpanel/usertools).
#
# O AdminBin só aceita comandos para o próprio caller ($REMOTE_USER),
# impossibilitando que um usuário aja em outro.

BEGIN {
    unshift @INC, '/usr/local/cpanel';
}

use strict;
use warnings;

use CGI                     ();
use JSON::XS                ();
use Cpanel::LiveAPI         ();
use Cpanel::AdminBin::Call  ();

my $cgi  = CGI->new;
my $json = JSON::XS->new->utf8;

my $action = $cgi->param('action') || '';

if ( $action eq 'kill_procs' ) {
    run_adminbin('KILL_PROCS');
    exit;
}
elsif ( $action eq 'fix_perms' ) {
    run_adminbin('FIX_PERMS');
    exit;
}

render_ui();
exit;

# ============================================================================

sub json_out {
    my ($data) = @_;
    print "Content-type: application/json; charset=utf-8\r\n\r\n";
    print $json->encode($data);
}

sub run_adminbin {
    my ($cmd) = @_;

    my $result = eval {
        Cpanel::AdminBin::Call::call( 'Cpanel', 'usertools', $cmd );
    };
    if ( my $err = $@ ) {
        my $msg = ref($err) && $err->can('to_string') ? $err->to_string : "$err";
        $msg =~ s/\s+$//;
        json_out( { success => \0, message => "Falha: $msg" } );
        return;
    }

    json_out($result);
}

sub render_ui {
    my $cpanel = Cpanel::LiveAPI->new();
    my $user   = $ENV{'REMOTE_USER'} || '';

    # URL absoluta do próprio script, para o JS não depender de URL relativa
    # (que pode falhar dentro do wrapper do cPanel).
    my $self_url = $ENV{'SCRIPT_NAME'}
        // '/frontend/jupiter/3rdparty/usertools/usertools.live.pl';
    $self_url =~ s/[<>'"&]//g;

    print "Content-type: text/html; charset=utf-8\r\n\r\n";
    print $cpanel->header('Ferramentas');
    print _body_html( $user, $self_url );
    print $cpanel->footer();
    $cpanel->end();
}

sub _body_html {
    my ( $user, $self_url ) = @_;
    $user =~ s/[<>&"']//g;  # sanitização mínima para exibição

    return <<"HTML";
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.min.css">
<style>
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap');

.usertools-root {
  --color-bg-primary: #F8FAFC;
  --color-bg-secondary: #FFFFFF;
  --color-bg-surface: #F1F5F9;
  --color-text-primary: #0F172A;
  --color-text-muted: #64748B;
  --color-accent: #8b5cf6;
  --color-accent-hover: #7c3aed;
  --color-sapphire: #4f46e5;
  --color-sapphire-hover: #4338ca;
  --color-border: #E2E8F0;
  --color-error: #ef4444;
  --color-success: #10b981;
  --color-info: #3b82f6;

  font-family: 'Inter', system-ui, -apple-system, sans-serif;
  color: var(--color-text-primary);
  font-size: 14px;
  line-height: 1.6;
  max-width: 900px;
  margin: 30px auto;
  padding: 0 16px;
  background-color: transparent;
}

\@media (prefers-color-scheme: dark) {
  .usertools-root {
    --color-bg-primary: #0F172A;
    --color-bg-secondary: #1E293B;
    --color-bg-surface: #334155;
    --color-text-primary: #F8FAFC;
    --color-text-muted: #94A3B8;
    --color-border: #334155;
  }
}

.usertools-root * { box-sizing: border-box; }

.usertools-root .card {
  background: var(--color-bg-secondary);
  border: 1px solid var(--color-border);
  border-radius: 16px;
  padding: 32px;
  box-shadow: 0 10px 25px -5px rgba(0, 0, 0, 0.05), 0 8px 10px -6px rgba(0, 0, 0, 0.01);
  transition: all 0.3s ease;
}

.usertools-root .card-header {
  display: flex; align-items: center; gap: 18px;
  margin-bottom: 24px; padding-bottom: 20px;
  border-bottom: 1px solid var(--color-border);
}

.usertools-root .icon-wrap {
  width: 56px; height: 56px; border-radius: 14px;
  background: linear-gradient(135deg, var(--color-accent), var(--color-sapphire));
  display: flex; align-items: center; justify-content: center;
  color: #fff; font-size: 26px; flex-shrink: 0;
  box-shadow: 0 4px 14px 0 rgba(139, 92, 246, 0.39);
}

.usertools-root h2 { margin: 0; font-size: 22px; font-weight: 700; letter-spacing: -0.02em; }
.usertools-root .subtitle { margin: 6px 0 0; font-size: 14px; color: var(--color-text-muted); }

.usertools-root .info-list {
  margin: 0 0 24px; padding: 16px 20px;
  background: var(--color-bg-surface);
  border-left: 4px solid var(--color-info);
  border-radius: 8px; font-size: 14px;
  display: flex; align-items: flex-start; gap: 12px;
}
.usertools-root .info-list i { color: var(--color-info); font-size: 18px; margin-top: 2px; }

.usertools-root .actions { display: grid; grid-template-columns: 1fr; gap: 20px; }
\@media (min-width: 768px) {
  .usertools-root .actions { grid-template-columns: 1fr 1fr; }
}

.usertools-root .action-card {
  border: 1px solid var(--color-border);
  border-radius: 12px;
  padding: 24px;
  background: var(--color-bg-secondary);
  display: flex; flex-direction: column; gap: 12px;
  transition: transform 0.2s, box-shadow 0.2s, border-color 0.2s;
}
.usertools-root .action-card:hover {
  transform: translateY(-2px);
  box-shadow: 0 12px 20px -8px rgba(0,0,0,0.08);
  border-color: var(--color-accent);
}

.usertools-root .action-card h3 {
  margin: 0; font-size: 17px; font-weight: 600;
  display: flex; align-items: center; gap: 10px;
}
.usertools-root .action-card h3.danger-title { color: var(--color-error); }
.usertools-root .action-card h3.primary-title { color: var(--color-sapphire); }

.usertools-root .action-card p {
  margin: 0; font-size: 14px; color: var(--color-text-muted); flex-grow: 1; line-height: 1.5;
}

.usertools-root .btn {
  display: inline-flex; align-items: center; justify-content: center; gap: 8px;
  padding: 12px 20px; border: none; border-radius: 10px;
  font-size: 14px; font-weight: 600; cursor: pointer;
  font-family: inherit; transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
  margin-top: 8px; letter-spacing: 0.01em; outline: none;
}
.usertools-root .btn:active { transform: scale(0.98); }
.usertools-root .btn:disabled { opacity: 0.6; cursor: not-allowed; transform: none; }

.usertools-root .btn-danger { 
  background: rgba(239, 68, 68, 0.1); color: var(--color-error);
  border: 1px solid rgba(239, 68, 68, 0.2);
}
.usertools-root .btn-danger:hover:not(:disabled) { 
  background: var(--color-error); color: #fff;
  box-shadow: 0 4px 12px rgba(239, 68, 68, 0.3);
}

.usertools-root .btn-primary { 
  background: linear-gradient(to right, var(--color-sapphire), var(--color-accent)); color: #fff; 
}
.usertools-root .btn-primary:hover:not(:disabled) { 
  background: linear-gradient(to right, var(--color-sapphire-hover), var(--color-accent-hover));
  box-shadow: 0 4px 14px rgba(139, 92, 246, 0.4);
}

.usertools-root .result {
  margin-top: 24px; padding: 16px 20px;
  border-radius: 10px; display: none; font-size: 14px;
  word-break: break-word; line-height: 1.5;
  animation: slideDown 0.3s ease-out;
}
\@keyframes slideDown {
  from { opacity: 0; transform: translateY(-10px); }
  to { opacity: 1; transform: translateY(0); }
}

.usertools-root .result.show { display: flex; align-items: flex-start; gap: 12px; }
.usertools-root .result.success {
  background: rgba(16, 185, 129, 0.1);
  color: var(--color-success);
  border: 1px solid rgba(16, 185, 129, 0.2);
}
.usertools-root .result.error {
  background: rgba(239, 68, 68, 0.1);
  color: var(--color-error);
  border: 1px solid rgba(239, 68, 68, 0.2);
}

.usertools-root .user-pill {
  display: inline-block; padding: 4px 12px; border-radius: 20px;
  background: var(--color-bg-surface);
  border: 1px solid var(--color-border);
  font-family: 'Inter', monospace; font-weight: 500;
  font-size: 13px; color: var(--color-accent);
}

.usertools-root .spinner {
  display: inline-block; width: 16px; height: 16px;
  border: 2px solid currentColor; border-right-color: transparent;
  border-radius: 50%; animation: utspin 0.8s linear infinite;
}
\@keyframes utspin { to { transform: rotate(360deg); } }
</style>

<div class="usertools-root">
  <div class="card">
    <div class="card-header">
      <div class="icon-wrap"><i class="bi bi-tools" aria-hidden="true"></i></div>
      <div>
        <h2>Ações de Sistema</h2>
        <p class="subtitle">Manutenção da sua conta cPanel <span class="user-pill">$user</span></p>
      </div>
    </div>

    <div class="info-list">
      <i class="bi bi-info-circle-fill"></i>
      <div>
        <strong>Diagnóstico e Soluções:</strong> Utilize estas ferramentas em caso de site travado, consumo de memória excedido, ou erros 403 Forbidden causados após manipulação de arquivos (FTP/SSH).
      </div>
    </div>

    <div class="actions">
      <div class="action-card">
        <h3 class="danger-title"><i class="bi bi-cpu" aria-hidden="true"></i> Finalizar Processos</h3>
        <p>Encerra imediatamente todos os processos ativos originados na sua conta (PHP-FPM, scripts pendurados). O cPanel reiniciará os vitais logo a seguir.</p>
        <button id="btn-kill" type="button" class="btn btn-danger">
          <i class="bi bi-power" aria-hidden="true"></i>
          Encerrar Tudo
        </button>
      </div>

      <div class="action-card">
        <h3 class="primary-title"><i class="bi bi-shield-check" aria-hidden="true"></i> Corrigir Permissões</h3>
        <p>Restaura o owner/grupo original e ajusta as permissões seguras recomendadas pelo cPanel em todos os seus arquivos de document root.</p>
        <button id="btn-fix" type="button" class="btn btn-primary">
          <i class="bi bi-wrench-adjustable" aria-hidden="true"></i>
          Reparar Permissões
        </button>
      </div>
    </div>

    <div id="ut-result" class="result" role="status" aria-live="polite"></div>
  </div>
</div>

<script>
(function() {
  'use strict';
  const URL_SELF = window.location.pathname;
  const btnKill = document.getElementById('btn-kill');
  const btnFix  = document.getElementById('btn-fix');
  const result  = document.getElementById('ut-result');

  function showResult(ok, msg) {
    const icon = ok ? '<i class="bi bi-check-circle-fill" style="margin-top:2px;"></i>' : '<i class="bi bi-exclamation-triangle-fill" style="margin-top:2px;"></i>';
    result.className = 'result show ' + (ok ? 'success' : 'error');
    result.innerHTML = icon + '<div>' + msg + '</div>';
  }
  function clearResult() { result.className = 'result'; result.innerHTML = ''; }

  async function runAction(act, btn, confirmMsg) {
    if (!confirm(confirmMsg)) return;

    const originalHTML = btn.innerHTML;
    btnKill.disabled = true; btnFix.disabled = true;
    btn.innerHTML = '<span class="spinner"></span> Executando...';
    clearResult();

    try {
      const form = new FormData();
      form.append('action', act);
      const r = await fetch(URL_SELF, {
        method: 'POST', body: form, credentials: 'same-origin'
      });
      const d = await r.json();
      showResult(!!d.success, d.message || (d.success ? 'Concluído com sucesso.' : 'A operação falhou.'));
    } catch (e) {
      showResult(false, 'Erro de conexão: ' + e.message);
    } finally {
      btn.innerHTML = originalHTML;
      btnKill.disabled = false; btnFix.disabled = false;
    }
  }

  btnKill.addEventListener('click', () => runAction(
    'kill_procs', btnKill,
    'Deseja forçar parada em todos os seus processos?\\n\\n' +
    'Atenção: Seu site pode ficar momentaneamente inacessível até a reinicialização dos serviços pelo sistema.'
  ));
  btnFix.addEventListener('click', () => runAction(
    'fix_perms', btnFix,
    'Restaurar permissões originais do cPanel no seu espaço?\\n\\n' +
    'Esta operação pode levar alguns segundos dependendo do volume de arquivos.'
  ));
})();
</script>
HTML
}
