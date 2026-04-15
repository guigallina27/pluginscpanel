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

    print "Content-type: text/html; charset=utf-8\r\n\r\n";
    print $cpanel->header('Ferramentas');
    print _body_html($user);
    print $cpanel->footer();
    $cpanel->end();
}

sub _body_html {
    my ($user) = @_;
    $user =~ s/[<>&"']//g;  # sanitização mínima para exibição

    return <<"HTML";
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons\@1.11.3/font/bootstrap-icons.min.css">
<style>
.usertools-root {
  --color-bg-primary: #F8F9FA;
  --color-bg-secondary: #FFFFFF;
  --color-bg-surface: #F1F3F5;
  --color-text-primary: #1A1A2E;
  --color-text-muted: #6B7280;
  --color-accent: #2563EB;
  --color-accent-hover: #1D4ED8;
  --color-border: #E5E7EB;
  --color-success: #16A34A;
  --color-error: #DC2626;
  --color-info: #0EA5E9;

  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  color: var(--color-text-primary);
  font-size: 14px;
  line-height: 1.5;
  max-width: 820px;
  margin: 20px auto;
  padding: 0 12px;
}
\@media (prefers-color-scheme: dark) {
  .usertools-root {
    --color-bg-primary: #0F0F13;
    --color-bg-secondary: #1A1A2E;
    --color-bg-surface: #1F1F33;
    --color-text-primary: #E8E8F0;
    --color-text-muted: #8B8BA0;
    --color-border: #2A2A42;
  }
}
.usertools-root * { box-sizing: border-box; }
.usertools-root .card {
  background: var(--color-bg-secondary);
  border: 1px solid var(--color-border);
  border-radius: 12px;
  padding: 24px;
  margin-bottom: 16px;
}
.usertools-root .card-header {
  display: flex; align-items: center; gap: 14px;
  margin-bottom: 18px; padding-bottom: 16px;
  border-bottom: 1px solid var(--color-border);
}
.usertools-root .icon-wrap {
  width: 48px; height: 48px; border-radius: 10px;
  background: color-mix(in srgb, var(--color-accent) 15%, transparent);
  display: flex; align-items: center; justify-content: center;
  color: var(--color-accent); font-size: 24px; flex-shrink: 0;
}
.usertools-root h2 { margin: 0; font-size: 18px; font-weight: 700; }
.usertools-root .subtitle { margin: 4px 0 0; font-size: 13px; color: var(--color-text-muted); }
.usertools-root .info-list {
  margin: 0 0 18px; padding: 12px 16px;
  background: var(--color-bg-surface);
  border-left: 3px solid var(--color-info);
  border-radius: 6px; font-size: 13px;
}
.usertools-root .info-list strong { color: var(--color-text-primary); }
.usertools-root .actions { display: grid; grid-template-columns: 1fr; gap: 14px; }
\@media (min-width: 640px) {
  .usertools-root .actions { grid-template-columns: 1fr 1fr; }
}
.usertools-root .action-card {
  border: 1px solid var(--color-border);
  border-radius: 10px;
  padding: 18px;
  background: var(--color-bg-surface);
  display: flex; flex-direction: column; gap: 10px;
}
.usertools-root .action-card h3 {
  margin: 0; font-size: 15px; font-weight: 700;
  display: flex; align-items: center; gap: 8px;
}
.usertools-root .action-card p {
  margin: 0; font-size: 13px; color: var(--color-text-muted); flex-grow: 1;
}
.usertools-root .btn {
  display: inline-flex; align-items: center; justify-content: center; gap: 8px;
  padding: 10px 16px; border: none; border-radius: 8px;
  font-size: 14px; font-weight: 600; cursor: pointer;
  font-family: inherit; transition: background 0.15s;
  margin-top: 4px;
}
.usertools-root .btn:disabled { opacity: 0.5; cursor: not-allowed; }
.usertools-root .btn-danger  { background: var(--color-error); color: #fff; }
.usertools-root .btn-danger:hover:not(:disabled)  { background: #B91C1C; }
.usertools-root .btn-primary { background: var(--color-accent); color: #fff; }
.usertools-root .btn-primary:hover:not(:disabled) { background: var(--color-accent-hover); }
.usertools-root .result {
  margin-top: 20px; padding: 12px 16px;
  border-radius: 8px; display: none; font-size: 13px;
  word-break: break-word;
}
.usertools-root .result.show { display: block; }
.usertools-root .result.success {
  background: color-mix(in srgb, var(--color-success) 12%, transparent);
  color: var(--color-success);
  border: 1px solid color-mix(in srgb, var(--color-success) 40%, transparent);
}
.usertools-root .result.error {
  background: color-mix(in srgb, var(--color-error) 12%, transparent);
  color: var(--color-error);
  border: 1px solid color-mix(in srgb, var(--color-error) 40%, transparent);
}
.usertools-root .user-pill {
  display: inline-block; padding: 2px 10px; border-radius: 12px;
  background: var(--color-bg-surface);
  border: 1px solid var(--color-border);
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 12px;
}
.usertools-root .spinner {
  display: inline-block; width: 14px; height: 14px;
  border: 2px solid currentColor; border-right-color: transparent;
  border-radius: 50%; animation: utspin 0.75s linear infinite;
}
\@keyframes utspin { to { transform: rotate(360deg); } }
</style>

<div class="usertools-root">
  <div class="card">
    <div class="card-header">
      <div class="icon-wrap"><i class="bi bi-tools" aria-hidden="true"></i></div>
      <div>
        <h2>Ferramentas</h2>
        <p class="subtitle">Ações de manutenção na sua conta <span class="user-pill">$user</span></p>
      </div>
    </div>

    <div class="info-list">
      <strong>Quando usar:</strong> site travado, consumo alto de memória,
      processos pendurados, arquivos com owner errado após restore/upload
      via SSH ou após mudanças manuais.
    </div>

    <div class="actions">
      <div class="action-card">
        <h3><i class="bi bi-x-octagon" aria-hidden="true"></i> Finalizar Processos</h3>
        <p>Encerra todos os processos da sua conta: PHP-FPM, cron, SSH e qualquer daemon. O cPanel reinicia automaticamente os essenciais em seguida.</p>
        <button id="btn-kill" type="button" class="btn btn-danger">
          <i class="bi bi-x-octagon" aria-hidden="true"></i>
          Finalizar Processos
        </button>
      </div>

      <div class="action-card">
        <h3><i class="bi bi-wrench-adjustable" aria-hidden="true"></i> Corrigir Permissões</h3>
        <p>Restaura owner/grupo e permissões padrão do seu diretório home. Resolve erros de "403 Forbidden" causados por owner errado.</p>
        <button id="btn-fix" type="button" class="btn btn-primary">
          <i class="bi bi-wrench-adjustable" aria-hidden="true"></i>
          Corrigir Permissões
        </button>
      </div>
    </div>

    <div id="ut-result" class="result" role="status" aria-live="polite"></div>
  </div>
</div>

<script>
(function() {
  'use strict';
  const URL_SELF = 'usertools.live.pl';
  const btnKill = document.getElementById('btn-kill');
  const btnFix  = document.getElementById('btn-fix');
  const result  = document.getElementById('ut-result');

  function showResult(ok, msg) {
    result.className = 'result show ' + (ok ? 'success' : 'error');
    result.textContent = msg;
  }
  function clearResult() { result.className = 'result'; result.textContent = ''; }

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
      showResult(!!d.success, d.message || (d.success ? 'Concluído.' : 'Falhou.'));
    } catch (e) {
      showResult(false, 'Erro: ' + e.message);
    } finally {
      btn.innerHTML = originalHTML;
      btnKill.disabled = false; btnFix.disabled = false;
    }
  }

  btnKill.addEventListener('click', () => runAction(
    'kill_procs', btnKill,
    'Finalizar TODOS os seus processos?\\n\\n' +
    'Isso derruba seus sites, cron jobs e sessões SSH por alguns segundos ' +
    'até o cPanel reiniciar o PHP-FPM.'
  ));
  btnFix.addEventListener('click', () => runAction(
    'fix_perms', btnFix,
    'Corrigir owner e permissões do seu diretório home?\\n\\n' +
    'Em contas grandes pode levar alguns segundos.'
  ));
})();
</script>
HTML
}
