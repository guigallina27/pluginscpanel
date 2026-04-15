#!/bin/bash
# Desinstalador do plugin UserTools (cPanel/WHM)
# Uso: bash uninstall.sh

set -e

PLUGIN_NAME="usertools"

if [[ $EUID -ne 0 ]]; then
    echo "[ERRO] Precisa rodar como root."
    exit 1
fi

echo "==> Desinstalando ${PLUGIN_NAME}..."

/usr/local/cpanel/bin/unregister_appconfig "${PLUGIN_NAME}" 2>/dev/null || true

rm -rf "/usr/local/cpanel/whostmgr/docroot/cgi/addons/${PLUGIN_NAME}"
rm -rf "/usr/local/cpanel/base/frontend/jupiter/${PLUGIN_NAME}"
rm -rf "/var/cpanel/addons/${PLUGIN_NAME}"
rm -f  "/usr/local/cpanel/bin/admin/Cpanel/${PLUGIN_NAME}"
rm -f  "/usr/local/cpanel/bin/admin/Cpanel/${PLUGIN_NAME}.conf"

/usr/local/cpanel/scripts/rebuild_sprites 2>/dev/null || true

echo "==> ${PLUGIN_NAME} desinstalado."
