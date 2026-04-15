# pluginscpanel

Coleção de plugins próprios para cPanel/WHM.

## Plugins disponíveis

- **[usertools](usertools/)** — finaliza processos (`pkill -9 -u $user`) e corrige owner/permissões (`/scripts/fixhomedirperms`). Aparece no cPanel do cliente (para si mesmo), no WHM do revendedor (só para seus clientes) e no WHM do root (para qualquer conta).

## Instalação

No servidor cPanel/WHM, como `root`:

```bash
wget -qO- https://github.com/guigallina27/pluginscpanel/archive/refs/heads/main.tar.gz | tar -xz -C /opt/
rm -rf /opt/pluginscpanel && mv /opt/pluginscpanel-main /opt/pluginscpanel
bash /opt/pluginscpanel/usertools/install.sh
```

Rode `install.sh` de cada plugin que quiser ativar.

## Atualização

Mesmo comando da instalação — ele baixa a versão mais nova, sobrescreve e reinstala:

```bash
wget -qO- https://github.com/guigallina27/pluginscpanel/archive/refs/heads/main.tar.gz | tar -xz -C /opt/
rm -rf /opt/pluginscpanel && mv /opt/pluginscpanel-main /opt/pluginscpanel
bash /opt/pluginscpanel/usertools/install.sh
```

## Desinstalação

```bash
bash /opt/pluginscpanel/usertools/uninstall.sh
```

Detalhes específicos no README de cada plugin.
