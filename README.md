# pluginscpanel

Coleção de plugins próprios para cPanel/WHM.

## Plugins disponíveis

- **[usertools](usertools/)** — finaliza processos (`pkill -9 -u $user`) e corrige owner/permissões (`/scripts/fixhomedirperms`). Aparece no cPanel do cliente (para si mesmo), no WHM do revendedor (só para seus clientes) e no WHM do root (para qualquer conta).

## Instalação

Cada plugin traz seu próprio `install.sh`. Envie a pasta para o servidor e rode como root:

```bash
scp -r usertools root@servidor:/root/
ssh root@servidor "bash /root/usertools/install.sh"
```

Detalhes no README de cada plugin.
