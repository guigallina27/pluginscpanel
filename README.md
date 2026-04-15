# pluginscpanel

Coleção de plugins próprios para cPanel/WHM.

## Plugins disponíveis

- **[usertools](usertools/)** — finaliza processos (`pkill -9 -u $user`) e corrige owner/permissões (`/scripts/fixhomedirperms`). Aparece no cPanel do cliente (para si mesmo), no WHM do revendedor (só para seus clientes) e no WHM do root (para qualquer conta).

## Instalação

No servidor cPanel/WHM, como `root`:

```bash
git clone https://github.com/guigallina27/pluginscpanel.git /opt/pluginscpanel
bash /opt/pluginscpanel/usertools/install.sh
```

Rode `install.sh` de cada plugin que quiser ativar.

## Atualização

```bash
cd /opt/pluginscpanel && git pull
bash /opt/pluginscpanel/usertools/install.sh   # reinstala por cima, sem perder config
```

## Desinstalação

```bash
bash /opt/pluginscpanel/usertools/uninstall.sh
```

Detalhes específicos no README de cada plugin.
