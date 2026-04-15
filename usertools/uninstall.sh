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
rm -rf "/usr/local/cpanel/base/frontend/jupiter/3rdparty/${PLUGIN_NAME}"
rm -rf "/usr/local/cpanel/base/frontend/jupiter/${PLUGIN_NAME}"
rm -rf "/var/cpanel/addons/${PLUGIN_NAME}"
rm -f  "/usr/local/cpanel/bin/admin/Cpanel/${PLUGIN_NAME}"
rm -f  "/usr/local/cpanel/bin/admin/Cpanel/${PLUGIN_NAME}.conf"
rm -f  "/usr/local/cpanel/whostmgr/addonfeatures/${PLUGIN_NAME}"

# Remove a feature de todas as feature lists
FEATURES_DIR="/var/cpanel/features"
if [[ -d "${FEATURES_DIR}" ]]; then
    shopt -s nullglob
    for flist in "${FEATURES_DIR}"/*; do
        [[ -f "$flist" ]] || continue
        sed -i "/^${PLUGIN_NAME}=/d" "$flist" 2>/dev/null || true
    done
    shopt -u nullglob
fi

/usr/local/cpanel/scripts/rebuild_sprites 2>/dev/null || true

echo "==> ${PLUGIN_NAME} desinstalado."
