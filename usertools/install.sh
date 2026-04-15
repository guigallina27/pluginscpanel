#!/bin/bash
# Instalador do plugin UserTools (cPanel/WHM)
# Uso: bash install.sh
#
# Copia os arquivos para os diretórios oficiais do cPanel,
# registra os AppConfigs e ajusta permissões.

set -e

PLUGIN_NAME="usertools"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

WHM_ADDON_DIR="/usr/local/cpanel/whostmgr/docroot/cgi/addons/${PLUGIN_NAME}"
CPANEL_FRONTEND_DIR="/usr/local/cpanel/base/frontend/jupiter/3rdparty/${PLUGIN_NAME}"
ADMINBIN_DIR="/usr/local/cpanel/bin/admin/Cpanel"
TEMPLATES_DIR="/var/cpanel/addons/${PLUGIN_NAME}/templates"

if [[ $EUID -ne 0 ]]; then
    echo "[ERRO] Este instalador precisa rodar como root."
    exit 1
fi

if [[ ! -d /usr/local/cpanel ]]; then
    echo "[ERRO] /usr/local/cpanel não encontrado — este servidor não parece ter cPanel."
    exit 1
fi

echo "==> Instalando ${PLUGIN_NAME}..."

# --- WHM (addon) -------------------------------------------------------------
echo "  - WHM addon em ${WHM_ADDON_DIR}"
mkdir -p "${WHM_ADDON_DIR}"
install -o root -g root -m 0755 \
    "${SRC_DIR}/whm/addon_usertools.cgi" \
    "${WHM_ADDON_DIR}/addon_usertools.cgi"

# --- Template Toolkit (chrome nativo do WHM) ---------------------------------
echo "  - Template WHM em ${TEMPLATES_DIR}"
mkdir -p "${TEMPLATES_DIR}"
install -o root -g root -m 0644 \
    "${SRC_DIR}/whm/templates/main.tmpl" \
    "${TEMPLATES_DIR}/main.tmpl"

# --- cPanel (Jupiter theme, pasta /3rdparty/) --------------------------------
# Remove resíduos do path antigo (versões anteriores do plugin
# colocavam em /jupiter/usertools/, que o register_appconfig rejeita
# por não estar em /3rdparty/).
rm -rf "/usr/local/cpanel/base/frontend/jupiter/${PLUGIN_NAME}" 2>/dev/null || true

echo "  - cPanel frontend em ${CPANEL_FRONTEND_DIR}"
mkdir -p "${CPANEL_FRONTEND_DIR}"
install -o cpanel -g cpanel -m 0755 \
    "${SRC_DIR}/cpanel/usertools.live.pl" \
    "${CPANEL_FRONTEND_DIR}/usertools.live.pl"

# --- AdminBin ----------------------------------------------------------------
echo "  - AdminBin em ${ADMINBIN_DIR}/${PLUGIN_NAME}"
install -o root -g root -m 0700 \
    "${SRC_DIR}/bin/usertools" \
    "${ADMINBIN_DIR}/${PLUGIN_NAME}"
install -o root -g root -m 0644 \
    "${SRC_DIR}/bin/usertools.conf" \
    "${ADMINBIN_DIR}/${PLUGIN_NAME}.conf"

# --- AppConfig registro ------------------------------------------------------
echo "  - Registrando AppConfig (WHM)"
/usr/local/cpanel/bin/register_appconfig "${SRC_DIR}/whm/usertools.conf"

echo "  - Registrando AppConfig (cPanel)"
/usr/local/cpanel/bin/register_appconfig "${SRC_DIR}/cpanel/usertools.conf"

# --- Limpeza de cache --------------------------------------------------------
echo "  - Limpando caches"
/usr/local/cpanel/scripts/rebuild_sprites 2>/dev/null || true

echo ""
echo "==> Instalação concluída."
echo ""
echo "Próximos passos:"
echo "  1. WHM → Home → Feature Manager → adicione 'usertools' aos planos desejados"
echo "     para que os clientes vejam o ícone no cPanel."
echo "  2. WHM → Home → Plugins → 'Ferramentas do Usuário' (root/revendedores)."
echo "  3. cPanel do cliente → seção 'Ferramentas'."
