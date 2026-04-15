# pluginscpanel

Coleção de plugins próprios para cPanel/WHM.

## Plugins disponíveis

- **[usertools](usertools/)** — finaliza processos (`pkill -9 -u $user`) e corrige owner/permissões (`/scripts/fixhomedirperms`). Aparece no cPanel do cliente (para si mesmo), no WHM do revendedor (só para seus clientes) e no WHM do root (para qualquer conta).

## Instalação

Logue como `root` no servidor cPanel/WHM e rode:

```bash
cd /root
rm -rf pluginscpanel pluginscpanel-main
wget -qO- https://github.com/guigallina27/pluginscpanel/archive/refs/heads/main.tar.gz | tar -xz
mv pluginscpanel-main pluginscpanel
bash /root/pluginscpanel/usertools/install.sh
```

O `install.sh` faz **todo o trabalho** — você não precisa executar mais nada depois dele:

1. Copia o CGI do WHM para `/usr/local/cpanel/whostmgr/docroot/cgi/addons/usertools/` (owner `root`, modo `0755`).
2. Copia o `.live.pl` do cPanel para `/usr/local/cpanel/base/frontend/jupiter/usertools/` (owner `cpanel`).
3. Instala o AdminBin em `/usr/local/cpanel/bin/admin/Cpanel/usertools` (modo `0700`, só root).
4. Registra os dois AppConfigs via `/usr/local/cpanel/bin/register_appconfig` (WHM + cPanel).
5. Limpa o cache de sprites de ícones.

Para reinstalar/atualizar, rode o mesmo bloco — ele baixa a versão atual do `main`, sobrescreve os arquivos e refaz os registros.

## Pós-instalação

Apenas uma ação manual no WHM para liberar a feature nos clientes:

- **WHM → Home → Feature Manager** → adicione `usertools` aos planos que devem enxergar o ícone no cPanel.
- **WHM → Plugins → Ferramentas do Usuário** já aparece para root e revendedores sem mais nada.

## Desinstalação

```bash
bash /root/pluginscpanel/usertools/uninstall.sh
```

Detalhes específicos no README de cada plugin.
