# UserTools — Plugin para cPanel/WHM

Plugin que oferece duas ações rápidas de manutenção por usuário do cPanel:

1. **Finalizar Processos** — executa `pkill -9 -u <usuário>` encerrando todos os processos daquele usuário.
2. **Corrigir Permissões & Owner** — executa `/scripts/fixhomedirperms <usuário>` (script nativo do cPanel que restaura owner/grupo e permissões padrão do home inteiro: `/home/user`, `public_html`, `mail/`, `.ssh/`, `etc/`, `cgi-bin/` e remove SUID/SGID indevidos) e em seguida aplica um complemento para **addon/subdomínios com documentroot FORA de `public_html`** (lidos em `/var/cpanel/userdata/<user>/*`), ajustando owner/grupo e permissões padrão também neles.

## Quem enxerga e quem executa

| Contexto | O que vê | Em quem pode agir |
|----------|----------|-------------------|
| Usuário cPanel | Ícone **Ferramentas** no painel dele | Somente na própria conta |
| Revendedor (WHM) | Entrada **Ferramentas do Usuário** no menu WHM | Somente nas contas que ele possui |
| Root (WHM) | Entrada **Ferramentas do Usuário** no menu WHM | Qualquer usuário cPanel do servidor |

A verificação de propriedade usa `Whostmgr::AcctInfo::Owner::checkowner` — revendedor tentando agir em conta de outro recebe erro 403.

## Estrutura de arquivos

```
usertools/
├── install.sh              # instalador (roda no servidor)
├── uninstall.sh            # desinstalador
├── README.md               # este arquivo
├── whm/
│   ├── usertools.conf      # AppConfig (WHM)
│   └── addon_usertools.cgi # interface WHM (roda como root via whostmgr)
├── cpanel/
│   ├── usertools.conf      # AppConfig (cPanel)
│   └── usertools.live.pl   # interface cPanel (chama AdminBin)
└── bin/
    ├── usertools           # AdminBin (escala privilégios para executar como root)
    └── usertools.conf      # config do AdminBin
```

## Instalação

Logue como `root` no servidor cPanel/WHM e rode:

```bash
cd /root
rm -rf pluginscpanel pluginscpanel-main
wget -qO- https://github.com/guigallina27/pluginscpanel/archive/refs/heads/main.tar.gz | tar -xz
mv pluginscpanel-main pluginscpanel
bash /root/pluginscpanel/usertools/install.sh
```

Isso é tudo — o `install.sh` cuida do processo completo.

### O que o install.sh faz

1. Copia `whm/addon_usertools.cgi` → `/usr/local/cpanel/whostmgr/docroot/cgi/addons/usertools/`, owner `root:root`, modo `0755`.
2. Copia `cpanel/usertools.live.pl` → `/usr/local/cpanel/base/frontend/jupiter/usertools/`, owner `cpanel:cpanel`, modo `0755`.
3. Copia `bin/usertools` → `/usr/local/cpanel/bin/admin/Cpanel/usertools`, owner `root:root`, modo `0700` (só root pode ler/executar).
4. Copia `bin/usertools.conf` → mesmo diretório do AdminBin (define `mode=full`).
5. Registra os dois AppConfigs chamando `/usr/local/cpanel/bin/register_appconfig`.
6. Dispara `/usr/local/cpanel/scripts/rebuild_sprites` para o cPanel atualizar os ícones.

Operação é idempotente: rodar de novo apenas sobrescreve os arquivos e refaz os registros (útil para atualização).

## Pós-instalação (manual, uma vez)

- **WHM → Home → Feature Manager** — adicione a feature `usertools` aos planos que devem enxergar o ícone no cPanel do cliente.
- **WHM → Plugins → Ferramentas do Usuário** — já aparece automaticamente para root e revendedores.
- **cPanel do cliente** — com a feature liberada no plano, aparece a seção "Ferramentas".

## Atualização

Mesmo comando da instalação — baixa o `main` atual, sobrescreve e reinstala sem perder nada.

## Desinstalação

```bash
bash /root/pluginscpanel/usertools/uninstall.sh
```

Remove arquivos, desregistra AppConfigs e apaga o AdminBin.

## Segurança

- **Sanitização de usuário** — apenas `[a-z0-9_\-]` aceito, máx 32 caracteres.
- **Verificação de existência** — `Cpanel::AcctUtils::Account::accountexists` antes de agir.
- **Verificação de propriedade** — revendedor só age em contas dele (checkowner).
- **Execução de root isolada** — no contexto cPanel, o usuário nunca chama `pkill` direto; ele aciona um AdminBin com conjunto fixo de ações (`KILL_PROCS`, `FIX_PERMS`) que recebem como alvo apenas o próprio `$caller_username`.
- **AdminBin não aceita argumento de usuário** — impossível um usuário cPanel matar processos de outro.
- **Confirmação no front-end** — todos os botões pedem confirmação antes de executar.

## Requisitos

- cPanel/WHM 11.90+ (Jupiter theme)
- Perl 5 (já incluso no cPanel)
- Privilégios de root na instalação
