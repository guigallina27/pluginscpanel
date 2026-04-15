# UserTools — Plugin para cPanel/WHM

Plugin de manutenção que oferece duas ações de recuperação rápida para contas cPanel:

1. **Finalizar processos** — encerra imediatamente (SIGKILL) todos os processos ativos de uma conta: `pkill -9 -ceiu <usuário>`. Útil para sites travados, PHP-FPM preso, cron em loop ou sessões SSH penduradas.
2. **Corrigir permissões & owner** — varre **toda a home da conta** aplicando o padrão oficial do cPanel (alinhado com `/scripts/unsuspendacct`): pastas em 755, arquivos em 644, scripts `.cgi`/`.pl`/`.sh` em 755 e owner restabelecido. Aplica também permissões especiais por diretório (`$HOME` 711, `public_html` 750/755 conforme `/var/cpanel/fileprotect`, `.ssh` 700 com chaves 600, `mail/` 751, `etc/` 750 user:mail, `public_ftp` conforme `/var/cpanel/noanonftp`).

## Quem enxerga e quem executa

| Contexto | O que vê | Em quem pode agir |
|----------|----------|-------------------|
| Usuário cPanel | Ícone **Ferramentas do Usuário** na seção *Software* | Somente na própria conta |
| Revendedor (WHM) | Entrada **Ferramentas do Usuário** nos *Plugins* do WHM | Somente contas da própria carteira (OWNER validado a cada request) |
| Root (WHM) | Entrada **Ferramentas do Usuário** nos *Plugins* do WHM | Qualquer conta cPanel do servidor |

O usuário cPanel executa as ações no próprio contexto (sem escalação de privilégio) — o POSIX garante que ele só pode afetar a própria conta. Para revendedores, o script valida `OWNER` em `/var/cpanel/users/<alvo>` antes de cada operação; tentativa de agir em conta fora da carteira retorna 403.

> **Nota importante sobre fileprotect**: no lado cPanel o POSIX não permite um usuário comum alterar o grupo para `nobody` (grupo do qual não é membro). Quando `/var/cpanel/fileprotect` está ativo no servidor, a correção do `public_html` para `user:nobody` só é aplicada via WHM (contexto root). A mensagem de retorno informa se o fileprotect está ativo.

## Estrutura do repositório

```
usertools/
├── install.sh              # instalador idempotente (roda como root)
├── uninstall.sh            # desinstalador
├── README.md               # este arquivo
├── cpanel/
│   ├── usertools.conf      # AppConfig cPanel (features=usertools, itemgroup=Software)
│   ├── usertools.live.pl   # UI cPanel + endpoints JSON (contexto do próprio user)
│   └── usertools.png       # ícone 48×48 do plugin
└── whm/
    ├── usertools.conf      # AppConfig WHM (service=whostmgr, acls=any)
    ├── addon_usertools.cgi # UI WHM + endpoints JSON (contexto root)
    └── templates/
        └── main.tmpl       # Template Toolkit com chrome oficial do WHM
```

> O plugin **não usa AdminBin**. O usuário cPanel tem privilégio nativo para encerrar os próprios processos (`pkill -u $self`) e alterar permissões/ownership dentro do próprio `$HOME`.

## Instalação

Método recomendado (sempre instalação limpa, dispensa `git`) — como `root`:

```bash
cd /root
rm -rf pluginscpanel pluginscpanel-main
wget -qO- https://github.com/guigallina27/pluginscpanel/archive/refs/heads/main.tar.gz | tar -xz
mv pluginscpanel-main pluginscpanel
bash /root/pluginscpanel/usertools/install.sh
```

Alternativa via `git` (útil em dev para atualizar com `git pull`):

```bash
cd /root
git clone https://github.com/guigallina27/pluginscpanel.git
bash /root/pluginscpanel/usertools/install.sh
```

A instalação é idempotente — rodar de novo sobrescreve arquivos, reregistra os AppConfigs e regenera o spritemap de ícones.

### O que o `install.sh` faz

1. Normaliza CRLF → LF em arquivos de texto (quebras de linha do Windows invalidam o parser do cPanel).
2. Instala os arquivos:
   - `whm/addon_usertools.cgi` → `/usr/local/cpanel/whostmgr/docroot/cgi/addons/usertools/` (0755, root:root)
   - `whm/templates/main.tmpl` → `/var/cpanel/addons/usertools/templates/` (0644, root:root)
   - `cpanel/usertools.live.pl` → `/usr/local/cpanel/base/frontend/jupiter/3rdparty/usertools/` (0755, root:root)
3. Cria o redirector `/usr/local/cpanel/base/frontend/jupiter/3rdparty/index.html` para evitar 404 ao sair do plugin.
4. Grava o descritor do Jupiter em `/usr/local/cpanel/base/frontend/jupiter/dynamicui/dynamicui_usertools.conf` (obrigatório para renderizar o ícone).
5. Copia `cpanel/usertools.png` para `/usr/local/cpanel/base/frontend/jupiter/assets/application_icons/usertools.png` e remove qualquer SVG residual de versões anteriores.
6. Remove resíduos de AdminBin de versões anteriores em `/usr/local/cpanel/bin/admin/Cpanel/`.
7. Registra a feature no Feature Manager em dois pontos (ambos necessários):
   - Arquivo `/usr/local/cpanel/whostmgr/addonfeatures/usertools` no formato `usertools:Ferramentas do Usuario` (ASCII, sem acentos — acentos quebram o render da UI).
   - Linha `usertools` em `/usr/local/cpanel/whostmgr/addonfeatures/addonfeatures.txt` (índice usado pelo Feature Manager).
8. Registra os dois AppConfigs via `/usr/local/cpanel/bin/register_appconfig`.
9. Habilita `usertools=1` em todas as feature lists em `/var/cpanel/features/*` **exceto** `disabled` (a lista `disabled` é global — qualquer presença da chave marca a feature como bloqueada na UI).
10. Chama `whmapi1 update_featurelist featurelist=default usertools=1` para a lista compilada `default` (que não fica em disco).
11. Limpa caches em `/var/cpanel/features.cache/` e `/home/*/.cpanel/caches/dynamicui/` para forçar releitura.
12. Executa `/usr/local/cpanel/bin/sprite_generator` — o Jupiter não serve SVGs/PNGs individuais; ele usa um sprite CSS consolidado (`icon_spritemap.png` + `.css`) e novos ícones só aparecem após essa regeneração.
13. Reinicia `cpsrvd`.

## Verificação pós-instalação

```bash
# Feature registrada no indice do Feature Manager?
grep -x usertools /usr/local/cpanel/whostmgr/addonfeatures/addonfeatures.txt

# AppConfigs ativos?
ls /var/cpanel/apps/usertools.conf /var/cpanel/apps/whm_usertools.conf

# Feature habilitada na lista default?
whmapi1 get_featurelist_data featurelist=default | grep -A2 "id: usertools"

# Ícone copiado?
ls /usr/local/cpanel/base/frontend/jupiter/assets/application_icons/usertools.png

# Ícone incluído no sprite?
grep -c "\.icon-usertools" /usr/local/cpanel/base/frontend/jupiter/assets/application_icons/sprites/icon_spritemap.css

# dynamicui gerado?
ls /usr/local/cpanel/base/frontend/jupiter/dynamicui/dynamicui_usertools.conf
```

## Uso

### Usuário cPanel

1. Acesse o cPanel → seção **Software** → **Ferramentas do Usuário**.
2. Clique em **Finalizar processos** ou **Corrigir permissões & owner** e confirme no modal.
3. Um relatório estruturado aparece com detalhes: quantidade de processos finalizados, modos de permissão aplicados por diretório especial, etc.

### Revendedor / root no WHM

1. WHM → menu lateral → **Plugins** → **Ferramentas do Usuário**.
2. Busque a conta pelo usuário ou domínio no combobox.
3. Selecione a conta e escolha a ação — o relatório inclui comparativo antes/depois, owner aplicado e método usado.

## Desinstalação

```bash
bash /root/pluginscpanel/usertools/uninstall.sh
```

Remove os arquivos instalados, desregistra os AppConfigs e limpa caches.

## Segurança

- **Sanitização de usuário**: regex `^[a-z0-9_\-]{1,32}$` com captura para *untaint* explícito antes de qualquer `system()` / `exec()`. Aplicado a todo `REMOTE_USER` e ao `user` enviado pelo front-end WHM.
- **Validação de sessão**: `$ENV{REMOTE_USER}` obrigatório; sem ele → 403.
- **Escopo de revendedor**: a cada ação WHM, o script relê `/var/cpanel/users/<alvo>` e compara `OWNER` com `$ENV{REMOTE_USER}` — nunca confia apenas no ID enviado pelo front-end.
- **Proteção contra path traversal**: `fix_perms` usa `$home` de `getpwnam()`, não input do usuário. Bloqueia `/`, `/root` e paths inexistentes.
- **XSS**: as mensagens usam `innerHTML` para renderizar relatórios estruturados, mas os únicos valores interpolados (`$user`, `$count`, `$before`, `$after`) são validados por regex ASCII-only. Campos vindos de arquivos externos (`domain`) são renderizados via `textContent`.
- **CSRF**: protegido nativamente pelo cpsession token do cpsrvd/whostmgr. Toda ação destrutiva pede confirmação em modal HTML5.
- **Mensagens de erro genéricas**: stack traces e detalhes técnicos vão para `/usr/local/cpanel/logs/error_log` via `warn`; o usuário final recebe mensagens orientando o próximo passo sem expor estrutura interna.
- **Fork destacado para pkill (lado cPanel)**: o Perl imprime o JSON, fecha STDOUT/STDERR e então `fork()` + `setsid()` + `exec pkill -9 -ceiu`. Isso garante que:
  - A resposta HTTP é entregue ao browser antes do kill,
  - O `pkill` em session group separado sobrevive mesmo se o Perl pai for morto (que seria o caso, já que `-u $user` inclui o próprio UID),
  - O SIGKILL é imediato (sem sleep artificial).

## Padrão de permissões (alinhado com `/scripts/unsuspendacct`)

| Alvo | Com `fileprotect` | Sem `fileprotect` | Aplicado por |
|------|-------------------|-------------------|--------------|
| `$HOME` | 711 | 711 | cPanel + WHM |
| Diretórios gerais | 755 | 755 | cPanel + WHM |
| Arquivos gerais | 644 | 644 | cPanel + WHM |
| `.cgi` / `.pl` / `.sh` | 755 | 755 | cPanel + WHM |
| `public_html` | **750 user:nobody** | 755 user:user | WHM aplica `nobody`; cPanel só aplica modo |
| `.htpasswds` | **750 user:nobody** | 755 user:user | WHM aplica `nobody`; cPanel só aplica modo |
| `public_ftp` (com `noanonftp`) | 750 user:user | 755 user:user | cPanel + WHM |
| `.ssh` | 700 | 700 | cPanel + WHM |
| `.ssh/*` (arquivos) | 600 | 600 | cPanel + WHM |
| `mail/` | 751 | 751 | cPanel + WHM |
| `etc/` | 750 user:mail | 750 user:mail | cPanel + WHM |

## Solução de problemas

| Sintoma | Causa provável | Correção |
|---------|----------------|----------|
| Ícone não aparece no cPanel do usuário | Cache do browser ou feature não habilitada no plano | Ctrl+Shift+F5 e verificar `whmapi1 get_featurelist_data featurelist=<plano do user> \| grep usertools` |
| Ícone não aparece mesmo após instalação | `sprite_generator` não rodou — o PNG está na pasta mas não foi consolidado no spritemap | Rodar `/usr/local/cpanel/bin/sprite_generator` manualmente e limpar cache do browser |
| Plugin não aparece no Feature Manager | Falta a entrada em `addonfeatures.txt` | Reinstalar (idempotente) |
| "Desabilitado" forçado no Feature Manager | Chave `usertools=` presente em `/var/cpanel/features/disabled` | `sed -i '/^usertools=/d' /var/cpanel/features/disabled && /usr/local/cpanel/scripts/restartsrv_cpsrvd` |
| 403 "features missing for url" | `feature=` singular em vez de `features=` plural no AppConfig | Reinstalar (já corrigido no `.conf`) |
| 404 ao sair do plugin | Faltando `/frontend/jupiter/3rdparty/index.html` | Reinstalar (criado pelo `install.sh`) |
| 500 para revendedor no WHM | `Whostmgr::ACLS::hasreseller()` não existe no cPanel atual | Reinstalar (já corrigido) |
| Mensagem com HTML literal em vez de formatado | Template Toolkit com cache antigo | `find /var/cpanel/template_compiles -name "*usertools*" -delete && /usr/local/cpanel/scripts/restartsrv_cpsrvd` |
| Caracteres `?` em vez de acentos | Versão antiga sem `Encode::encode_utf8` | Reinstalar (já corrigido) |

## Requisitos

- cPanel/WHM 11.90+ com tema **Jupiter** (tema cPanel moderno)
- Perl 5 do cPanel (`/usr/local/cpanel/3rdparty/bin/perl`) — já incluso
- Acesso root para instalação
- Módulos Perl (todos nativos do cPanel): `Cpanel::LiveAPI`, `CGI`, `JSON::XS`, `Encode`, `POSIX`, `Cpanel::Template`, `Whostmgr::ACLS`, `Cpanel::AcctUtils::Account`
