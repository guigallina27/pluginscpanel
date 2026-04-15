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

use CGI                              ();
use JSON::XS                         ();
use Whostmgr::ACLS                   ();
use Whostmgr::AcctInfo::Owner        ();
use Whostmgr::Accounts               ();
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
    my @users;

    if ($is_root) {
        my ( undef, $accts ) = Whostmgr::Accounts::listaccts();
        @users = map { { user => $_->{user}, domain => $_->{domain} // '' } }
            @{ $accts || [] };
    }
    else {
        my ( undef, $accts ) = Whostmgr::Accounts::listaccts(
            'searchtype' => 'owner',
            'search'     => $reseller,
        );
        @users = map { { user => $_->{user}, domain => $_->{domain} // '' } }
            @{ $accts || [] };
    }

    # Remove contas de sistema
    @users = grep {
        $_->{user} ne 'root'
            && $_->{user} ne 'nobody'
            && $_->{user} ne 'cpanel'
    } @users;

    @users = sort { $a->{user} cmp $b->{user} } @users;

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
    if ( !$is_root ) {
        if ( !Whostmgr::AcctInfo::Owner::checkowner( $reseller, $target ) ) {
            json_out(
                {
                    success => \0,
                    message =>
                        "Você não tem permissão para agir sobre '$target'.",
                }
            );
            return;
        }
    }

    if ( $act eq 'kill_procs' ) {
        do_kill_procs($target);
    }
    else {
        do_fix_perms($target);
    }
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

    my $output = qx{/scripts/fixhomedirperms \Q$user\E 2>&1};
    my $exit   = $? >> 8;

    json_out(
        {
            success => $exit == 0 ? \1 : \0,
            message => $exit == 0
                ? "Owner e permissões corrigidos em /home/$user."
                : "Falha ao corrigir (exit=$exit).",
            output => $output,
        }
    );
}

sub render_ui {
    my ($role) = @_;

    print "Content-type: text/html; charset=utf-8\r\n\r\n";
    print _html_page($role);
}

sub _html_page {
    my ($role) = @_;
    my $role_label = $role eq 'root' ? 'ROOT' : 'REVENDEDOR';

    return <<"HTML";
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Ferramentas do Usuário — WHM</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons\@1.11.3/font/bootstrap-icons.min.css">
<style>
:root {
  --color-bg-primary: #F8F9FA;
  --color-bg-secondary: #FFFFFF;
  --color-bg-surface: #F1F3F5;
  --color-text-primary: #1A1A2E;
  --color-text-secondary: #4A4A5E;
  --color-text-muted: #6B7280;
  --color-accent: #2563EB;
  --color-accent-hover: #1D4ED8;
  --color-border: #E5E7EB;
  --color-shadow: rgba(0,0,0,0.06);
  --color-success: #16A34A;
  --color-warning: #D97706;
  --color-error: #DC2626;
  --color-info: #0EA5E9;
}
\@media (prefers-color-scheme: dark) {
  :root {
    --color-bg-primary: #0F0F13;
    --color-bg-secondary: #1A1A2E;
    --color-bg-surface: #1F1F33;
    --color-text-primary: #E8E8F0;
    --color-text-secondary: #B8B8C8;
    --color-text-muted: #8B8BA0;
    --color-border: #2A2A42;
    --color-shadow: rgba(0,0,0,0.4);
  }
}
* { box-sizing: border-box; }
body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  background: var(--color-bg-primary);
  color: var(--color-text-primary);
  margin: 0; padding: 24px; font-size: 14px; line-height: 1.5;
}
.container { max-width: 900px; margin: 0 auto; }
.card {
  background: var(--color-bg-secondary);
  border: 1px solid var(--color-border);
  border-radius: 12px;
  padding: 24px; margin-bottom: 16px;
  box-shadow: 0 1px 3px var(--color-shadow);
}
.card-header {
  display: flex; align-items: center; gap: 14px;
  margin-bottom: 20px; padding-bottom: 16px;
  border-bottom: 1px solid var(--color-border);
}
.card-header .icon-wrap {
  width: 48px; height: 48px; border-radius: 10px;
  background: color-mix(in srgb, var(--color-accent) 15%, transparent);
  display: flex; align-items: center; justify-content: center;
  color: var(--color-accent); font-size: 24px; flex-shrink: 0;
}
.card-header h2 { margin: 0; font-size: 18px; font-weight: 700; }
.card-header p { margin: 4px 0 0; font-size: 13px; color: var(--color-text-muted); }
label { display: block; font-weight: 600; margin-bottom: 6px; font-size: 13px; }
select, input {
  width: 100%;
  padding: 10px 12px;
  border: 1px solid var(--color-border);
  border-radius: 8px;
  background: var(--color-bg-surface);
  color: var(--color-text-primary);
  font-size: 14px;
  font-family: inherit;
}
select:focus, input:focus {
  outline: none;
  border-color: var(--color-accent);
  box-shadow: 0 0 0 3px color-mix(in srgb, var(--color-accent) 20%, transparent);
}
.btn-group { display: flex; gap: 12px; margin-top: 20px; flex-wrap: wrap; }
.btn {
  display: inline-flex; align-items: center; gap: 8px;
  padding: 10px 18px; border: none; border-radius: 8px;
  font-size: 14px; font-weight: 600; cursor: pointer;
  transition: background 0.15s, transform 0.05s;
  font-family: inherit;
}
.btn:hover:not(:disabled) { transform: translateY(-1px); }
.btn:active:not(:disabled) { transform: translateY(0); }
.btn:disabled { opacity: 0.5; cursor: not-allowed; }
.btn-danger  { background: var(--color-error); color: #fff; }
.btn-danger:hover:not(:disabled)  { background: #B91C1C; }
.btn-primary { background: var(--color-accent); color: #fff; }
.btn-primary:hover:not(:disabled) { background: var(--color-accent-hover); }
.result {
  margin-top: 20px; padding: 12px 16px;
  border-radius: 8px; display: none; font-size: 13px;
  word-break: break-word;
}
.result.show { display: block; }
.result.success {
  background: color-mix(in srgb, var(--color-success) 12%, transparent);
  color: var(--color-success);
  border: 1px solid color-mix(in srgb, var(--color-success) 40%, transparent);
}
.result.error {
  background: color-mix(in srgb, var(--color-error) 12%, transparent);
  color: var(--color-error);
  border: 1px solid color-mix(in srgb, var(--color-error) 40%, transparent);
}
.badge {
  display: inline-block; padding: 2px 8px; border-radius: 4px;
  background: var(--color-accent); color: #fff;
  font-size: 11px; font-weight: 700; letter-spacing: 0.5px;
  margin-left: 8px;
}
.spinner {
  display: inline-block; width: 14px; height: 14px;
  border: 2px solid currentColor; border-right-color: transparent;
  border-radius: 50%; animation: spin 0.75s linear infinite;
}
\@keyframes spin { to { transform: rotate(360deg); } }
.info-list {
  margin: 0 0 16px; padding: 12px 16px;
  background: var(--color-bg-surface);
  border-left: 3px solid var(--color-info);
  border-radius: 6px; font-size: 13px;
  color: var(--color-text-secondary);
}
.info-list strong { color: var(--color-text-primary); }
</style>
</head>
<body>
<div class="container">
  <div class="card">
    <div class="card-header">
      <div class="icon-wrap"><i class="bi bi-tools" aria-hidden="true"></i></div>
      <div>
        <h2>Ferramentas do Usuário<span class="badge">$role_label</span></h2>
        <p>Finaliza processos e corrige owner/permissões do diretório home.</p>
      </div>
    </div>

    <div class="info-list">
      <strong>Atenção:</strong> finalizar processos interrompe PHP-FPM,
      cron, SSH e qualquer aplicação do usuário. Corrigir permissões
      reescreve owner/grupo e modos do diretório home.
    </div>

    <label for="user-select">Selecione a conta cPanel</label>
    <select id="user-select" aria-label="Conta cPanel">
      <option value="">Carregando...</option>
    </select>

    <div class="btn-group">
      <button id="btn-kill" type="button" class="btn btn-danger" disabled>
        <i class="bi bi-x-octagon" aria-hidden="true"></i>
        Finalizar Processos
      </button>
      <button id="btn-fix" type="button" class="btn btn-primary" disabled>
        <i class="bi bi-wrench-adjustable" aria-hidden="true"></i>
        Corrigir Permissões &amp; Owner
      </button>
    </div>

    <div id="result" class="result" role="status" aria-live="polite"></div>
  </div>
</div>

<script>
(function() {
  'use strict';
  const URL_SELF = 'addon_usertools.cgi';
  const sel     = document.getElementById('user-select');
  const btnKill = document.getElementById('btn-kill');
  const btnFix  = document.getElementById('btn-fix');
  const result  = document.getElementById('result');

  function showResult(ok, msg) {
    result.className = 'result show ' + (ok ? 'success' : 'error');
    result.textContent = msg;
  }
  function clearResult() { result.className = 'result'; result.textContent = ''; }

  async function loadUsers() {
    try {
      const r = await fetch(URL_SELF + '?action=list_users', { credentials: 'same-origin' });
      const d = await r.json();
      if (!d.success) { showResult(false, d.message || 'Falha ao listar usuários.'); return; }
      sel.innerHTML = '';
      const placeholder = document.createElement('option');
      placeholder.value = '';
      placeholder.textContent = d.users.length ? '— escolher —' : 'Nenhuma conta disponível';
      sel.appendChild(placeholder);
      d.users.forEach(u => {
        const o = document.createElement('option');
        o.value = u.user;
        o.textContent = u.user + (u.domain ? '  ·  ' + u.domain : '');
        sel.appendChild(o);
      });
    } catch (e) {
      sel.innerHTML = '<option value="">Erro ao carregar</option>';
      showResult(false, 'Erro de rede: ' + e.message);
    }
  }

  sel.addEventListener('change', () => {
    const has = !!sel.value;
    btnKill.disabled = !has;
    btnFix.disabled  = !has;
    clearResult();
  });

  async function runAction(act, btn, confirmMsg) {
    if (!sel.value) return;
    if (!confirm(confirmMsg)) return;

    const originalHTML = btn.innerHTML;
    btnKill.disabled = true; btnFix.disabled = true;
    btn.innerHTML = '<span class="spinner"></span> Executando...';
    clearResult();

    try {
      const form = new FormData();
      form.append('action', act);
      form.append('user', sel.value);
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
    'Finalizar TODOS os processos de "' + sel.value + '"?\\n\\n' +
    'Isso mata sites, cron, SSH e qualquer processo do usuário.'
  ));
  btnFix.addEventListener('click', () => runAction(
    'fix_perms', btnFix,
    'Corrigir owner e permissões do /home/' + sel.value + '?\\n\\n' +
    'Isso pode levar alguns segundos em contas grandes.'
  ));

  loadUsers();
})();
</script>
</body>
</html>
HTML
}
