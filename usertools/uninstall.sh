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

# --- AppConfigs -------------------------------------------------------------
/usr/local/cpanel/bin/unregister_appconfig "${PLUGIN_NAME}"     >/dev/null 2>&1 || true
/usr/local/cpanel/bin/unregister_appconfig "whm_${PLUGIN_NAME}" >/dev/null 2>&1 || true

# --- Arquivos do plugin -----------------------------------------------------
rm -rf "/usr/local/cpanel/whostmgr/docroot/cgi/addons/${PLUGIN_NAME}"
rm -rf "/usr/local/cpanel/base/frontend/jupiter/3rdparty/${PLUGIN_NAME}"
rm -rf "/var/cpanel/addons/${PLUGIN_NAME}"

# AdminBin de versoes antigas (nao usado na versao atual, mas pode haver residuo)
rm -f "/usr/local/cpanel/bin/admin/Cpanel/${PLUGIN_NAME}"
rm -f "/usr/local/cpanel/bin/admin/Cpanel/${PLUGIN_NAME}.conf"

# --- Icone + dynamicui ------------------------------------------------------
rm -f "/usr/local/cpanel/base/frontend/jupiter/assets/application_icons/${PLUGIN_NAME}.png"
rm -f "/usr/local/cpanel/base/frontend/jupiter/assets/application_icons/${PLUGIN_NAME}.svg"
rm -f "/usr/local/cpanel/base/frontend/jupiter/dynamicui/dynamicui_${PLUGIN_NAME}.conf"

# --- Feature Manager --------------------------------------------------------
rm -f "/usr/local/cpanel/whostmgr/addonfeatures/${PLUGIN_NAME}"

ADDON_INDEX="/usr/local/cpanel/whostmgr/addonfeatures/addonfeatures.txt"
if [[ -f "${ADDON_INDEX}" ]]; then
    sed -i "/^${PLUGIN_NAME}$/d" "${ADDON_INDEX}" 2>/dev/null || true
fi

# Remove a feature de todas as feature lists em disco
FEATURES_DIR="/var/cpanel/features"
if [[ -d "${FEATURES_DIR}" ]]; then
    shopt -s nullglob
    for flist in "${FEATURES_DIR}"/*; do
        [[ -f "$flist" ]] || continue
        sed -i "/^${PLUGIN_NAME}=/d" "$flist" 2>/dev/null || true
    done
    shopt -u nullglob
fi

# Remove da feature list 'default' compilada via whmapi1
if command -v whmapi1 >/dev/null 2>&1; then
    whmapi1 update_featurelist featurelist=default "${PLUGIN_NAME}=0" >/dev/null 2>&1 || true
fi

# --- Cache ------------------------------------------------------------------
rm -rf /var/cpanel/features.cache/* 2>/dev/null || true

for userhome in /home/*/; do
    cache_dir="${userhome}.cpanel/caches/dynamicui"
    [[ -d "${cache_dir}" ]] || continue
    rm -rf "${cache_dir}"/* 2>/dev/null || true
done

# Cache de template toolkit da UI WHM
find /var/cpanel/template_compiles -name "*${PLUGIN_NAME}*" -delete 2>/dev/null || true

# --- Spritemap (regenera sem nosso icone) -----------------------------------
if [[ -x /usr/local/cpanel/bin/sprite_generator ]]; then
    /usr/local/cpanel/bin/sprite_generator >/dev/null 2>&1 || true
fi

# --- Reload cpsrvd ----------------------------------------------------------
if [[ -x /usr/local/cpanel/scripts/restartsrv_cpsrvd ]]; then
    /usr/local/cpanel/scripts/restartsrv_cpsrvd >/dev/null 2>&1 || true
fi

echo "==> ${PLUGIN_NAME} desinstalado."
