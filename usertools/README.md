# UserTools — Plugin para cPanel/WHM

Plugin de manutenção que oferece duas ações de recuperação rápida:

1. **Finalizar processos** — encerra todos os processos ativos de uma conta cPanel (`pkill -9 -ceiu <usuário>`). Útil para sites travados, PHP-FPM preso, cron em loop ou SSH pendurado.
2. **Corrigir permissões & owner** — varre todos os *document roots* da conta (public_html, domínios adicionais, subdomínios e parked) via `/var/cpanel/userdata/<user>/*` e restaura: pastas em **755**, arquivos em **644**, scripts `.cgi`/`.pl` em **755** e proprietário `user:user`. Útil após upload problemático via FTP/SSH ou erros 403/500.

## Quem enxerga e quem executa

| Contexto | O que vê | Em quem pode agir |
|----------|----------|-------------------|
| Usuário cPanel | Ícone **Ferramentas do Usuário** na seção *Software* | Somente na própria conta |
| Revendedor (WHM) | Entrada **Ferramentas do Usuário** nos *Plugins* do WHM | Somente contas da própria carteira (OWNER) |
| Root (WHM) | Entrada **Ferramentas do Usuário** nos *Plugins* do WHM | Qualquer conta cPanel do servidor |

O usuário cPanel executa as ações no próprio contexto (sem escalação de privilégio) — o cpaneld já garante que ele só pode afetar a própria conta. Para revendedores, o script valida `OWNER` em `/var/cpanel/users/<alvo>` antes de cada operação; tentativa de agir em conta fora da carteira retorna 403.

## Estrutura do repositório

```
usertools/
├── install.sh              # instalador idempotente (roda como root)
├── uninstall.sh            # desinstalador
├── README.md               # este arquivo
├── cpanel/
│   ├── usertools.conf      # AppConfig cPanel (features=usertools, itemgroup=Software)
│   └── usertools.live.pl   # UI cPanel + endpoints JSON (contexto do user)
└── whm/
    ├── usertools.conf      # AppConfig WHM (service=whostmgr, acls=any)
    ├── addon_usertools.cgi # UI WHM + endpoints JSON (contexto root)
    └── templates/
        └── main.tmpl       # template Toolkit com o chrome oficial do WHM
```

> O plugin **não usa AdminBin**. O usuário cPanel tem privilégio nativo para encerrar os próprios processos (`pkill -u $self`) e alterar permissões/ownership dentro do próprio `$HOME`.

## Instalação

Como `root` no servidor cPanel/WHM:

```bash
cd /root
git clone https://github.com/guigallina27/pluginscpanel.git
cd pluginscpanel/usertools
bash install.sh
```

Para **atualizar** depois:

```bash
cd /root/pluginscpanel
git pull
cd usertools
bash install.sh
```

A instalação é idempotente — rodar de novo apenas sobrescreve arquivos e reregistra os AppConfigs.

### O que o `install.sh` faz

1. Normaliza CRLF → LF em arquivos de texto (quebra de linha do Windows invalida o parser do cPanel).
2. Instala os arquivos:
   - `whm/addon_usertools.cgi` → `/usr/local/cpanel/whostmgr/docroot/cgi/addons/usertools/` (0755, root:root)
   - `whm/templates/main.tmpl` → `/var/cpanel/addons/usertools/templates/` (0644, root:root)
   - `cpanel/usertools.live.pl` → `/usr/local/cpanel/base/frontend/jupiter/3rdparty/usertools/` (0755, root:root)
3. Cria o redirector `/usr/local/cpanel/base/frontend/jupiter/3rdparty/index.html` para evitar 404 ao sair do plugin.
4. Grava o descritor do Jupiter em `/usr/local/cpanel/base/frontend/jupiter/dynamicui/dynamicui_usertools.conf` (senão o ícone não é renderizado mesmo com a feature habilitada).
5. Decodifica o `icon_base64` do AppConfig e grava o SVG em `/usr/local/cpanel/base/frontend/jupiter/assets/application_icons/usertools.svg` (o Jupiter busca ícones neste caminho, **não** no diretório do plugin).
6. Remove resíduos de AdminBin de versões anteriores em `/usr/local/cpanel/bin/admin/Cpanel/`.
7. Registra a feature no Feature Manager em dois pontos (ambos necessários):
   - Arquivo `/usr/local/cpanel/whostmgr/addonfeatures/usertools` no formato `usertools:Ferramentas do Usuario` (ASCII, sem acentos — acentos quebram o render da UI).
   - Linha `usertools` em `/usr/local/cpanel/whostmgr/addonfeatures/addonfeatures.txt` (índice usado pelo Feature Manager).
8. Registra os dois AppConfigs via `/usr/local/cpanel/bin/register_appconfig`.
9. Habilita `usertools=1` em todas as feature lists em `/var/cpanel/features/*` **exceto** `disabled` (a lista `disabled` é global — qualquer presença da chave marca a feature como bloqueada na UI).
10. Chama `whmapi1 update_featurelist featurelist=default usertools=1` para a lista compilada `default` (que não fica em disco).
11. Limpa caches em `/var/cpanel/features.cache/` e `/home/*/.cpanel/caches/dynamicui/` para forçar relleitura.
12. Reinicia `cpsrvd`.

## Verificação pós-instalação

```bash
# Feature registrada no indice?
grep -x usertools /usr/local/cpanel/whostmgr/addonfeatures/addonfeatures.txt

# AppConfigs ativos?
ls /var/cpanel/apps/usertools.conf /var/cpanel/apps/whm_usertools.conf

# Feature habilitada na lista default?
whmapi1 get_featurelist_data featurelist=default | grep -A2 "id: usertools"

# Icone no lugar certo?
ls /usr/local/cpanel/base/frontend/jupiter/assets/application_icons/usertools.svg

# dynamicui gerado?
ls /usr/local/cpanel/base/frontend/jupiter/dynamicui/dynamicui_usertools.conf
```

## Uso

### Usuário cPanel

1. Acesse o cPanel → seção **Software** → **Ferramentas do Usuário**.
2. Clique em **Finalizar processos** ou **Reparar permissões** e confirme no modal.
3. A página retorna uma mensagem de status detalhando o resultado.

### Revendedor / root no WHM

1. WHM → menu lateral → **Plugins** → **Ferramentas do Usuário**.
2. Busque a conta pelo usuário ou domínio no combobox.
3. Selecione a conta e escolha a ação.

## Desinstalação

```bash
bash /root/pluginscpanel/usertools/uninstall.sh
```

Remove os arquivos instalados, desregistra os AppConfigs e limpa caches.

## Segurança

- **Sanitização de usuário**: regex `^[a-z0-9_\-]{1,32}$` com captura para *untaint* explícito antes de qualquer `system()` / `exec()`.
- **Validação de sessão**: `$ENV{REMOTE_USER}` obrigatório; sem ele → 403.
- **Escopo de revendedor**: para cada ação WHM, o script relê `/var/cpanel/users/<alvo>` e compara `OWNER` com `$ENV{REMOTE_USER}` — nada confia apenas no ID enviado pelo front-end.
- **Proteção contra path traversal**: document roots lidos de `/var/cpanel/userdata/` são validados com regex ancorada que exige o caminho estar dentro de `$HOME` antes de entrar no `chmod`/`chown`.
- **Confirmação obrigatória**: modal HTML5 customizado antes de toda ação destrutiva, com título e cor específicos por operação.
- **Mensagens de erro genéricas**: stack traces e detalhes técnicos vão para `/usr/local/cpanel/logs/error_log` via `warn`; o usuário final recebe mensagens genéricas com orientação do próximo passo.
- **Fork destacado para pkill**: no cPanel, o `pkill -9 -u $self` mataria a própria requisição CGI antes do JSON voltar — o script faz `fork()` + `setsid()` + `sleep 3` + `exec pkill` para garantir que a resposta HTTP chegue antes do sinal.

## Solução de problemas

| Sintoma | Causa provável | Correção |
|---------|----------------|----------|
| Ícone não aparece no cPanel do usuário | Cache do browser ou feature não habilitada no plano do usuário | Ctrl+Shift+F5 + verificar `whmapi1 get_featurelist_data featurelist=<plano do user> \| grep usertools` |
| Plugin não aparece no Feature Manager | Falta a entrada em `addonfeatures.txt` | Rodar `install.sh` de novo (idempotente) |
| "Desabilitado" forçado no Feature Manager | Chave `usertools=` presente em `/var/cpanel/features/disabled` | `sed -i '/^usertools=/d' /var/cpanel/features/disabled && /usr/local/cpanel/scripts/restartsrv_cpsrvd` |
| 403 "features missing for url" | `feature=usertools` em vez de `features=usertools` (plural) no AppConfig | Reinstalar (já corrigido no `.conf`) |
| 404 ao sair do plugin | Faltando `/frontend/jupiter/3rdparty/index.html` | Reinstalar (criado pelo `install.sh`) |
| 500 para revendedor no WHM | `Whostmgr::ACLS::hasreseller()` não existe | Reinstalar (já corrigido) |

## Requisitos

- cPanel/WHM 11.90+ com tema **Jupiter** (tema cPanel moderno)
- Perl 5 do cPanel (`/usr/local/cpanel/3rdparty/bin/perl`) — já incluso
- Acesso root para instalação
- Módulos Perl: `Cpanel::LiveAPI`, `CGI`, `JSON::XS`, `Cpanel::Template`, `Whostmgr::ACLS`, `Cpanel::AcctUtils::Account` — todos nativos do cPanel
