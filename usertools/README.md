# UserTools — Plugin para cPanel/WHM

Plugin que oferece duas ações rápidas de manutenção por usuário do cPanel:

1. **Finalizar Processos** — executa `pkill -9 -u <usuário>` encerrando todos os processos daquele usuário.
2. **Corrigir Permissões & Owner** — executa `/scripts/fixhomedirperms <usuário>`, script nativo do cPanel que restaura owner/grupo e permissões padrão do diretório home.

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

No servidor cPanel/WHM, como `root`:

```bash
wget -qO- https://github.com/guigallina27/pluginscpanel/archive/refs/heads/main.tar.gz | tar -xz -C /opt/
rm -rf /opt/pluginscpanel && mv /opt/pluginscpanel-main /opt/pluginscpanel
bash /opt/pluginscpanel/usertools/install.sh
```

Para atualizar, rode o mesmo bloco — ele baixa a versão mais recente, sobrescreve e reinstala.

O instalador:
- Copia os arquivos para os diretórios oficiais do cPanel
- Registra os dois AppConfigs (WHM + cPanel)
- Define permissões e owners corretos
- Cria o AdminBin que permite ao usuário cPanel acionar o pkill/fixhomedirperms com privilégio de root de forma controlada

Depois da instalação:

1. **WHM → Home → Feature Manager** — adicione a feature `usertools` ao plano padrão (ou aos planos em que quiser liberar o ícone no cPanel).
2. **WHM → Home → Plugins → Ferramentas do Usuário** — root e revendedores já enxergam.
3. **cPanel do cliente** — se a feature estiver ativa no plano dele, aparece a seção "Ferramentas".

## Desinstalação

```bash
bash /opt/pluginscpanel/usertools/uninstall.sh
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
