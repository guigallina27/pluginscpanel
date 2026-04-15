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

echo "==> Inicializando a instalação de ${PLUGIN_NAME}..."

# Sanitize - Finais de linha do Windows corrompem o parser/AppConfig do cPanel
echo "  - Normalizando quebras de linha Windows (CRLF -> LF)..."
for f in "${SRC_DIR}/whm/usertools.conf" "${SRC_DIR}/bin/usertools.conf" "${SRC_DIR}/whm/addon_usertools.cgi" "${SRC_DIR}/cpanel/usertools.live.pl" "${SRC_DIR}/bin/usertools"; do
    if [[ -f "$f" ]]; then
        perl -pi -e 's/\r//g' "$f" 2>/dev/null || true
    fi
done

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
install -o root -g root -m 0755 \
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
echo "  - Removendo registros antigos de AppConfig e Plugin (limpeza)..."
/usr/local/cpanel/bin/unregister_appconfig usertools >/dev/null 2>&1 || true
/usr/local/cpanel/bin/unregister_appconfig whm_usertools >/dev/null 2>&1 || true
/usr/local/cpanel/scripts/uninstall_plugin "${SRC_DIR}/cpanel" --theme jupiter >/dev/null 2>&1 || true

# --- Feature Manager ---------------------------------------------------------
# IMPORTANTE: a feature precisa existir em addonfeatures ANTES do
# register_appconfig do cPanel, caso contrario o cpanel valida a feature
# declarada no .conf (feature=usertools), nao encontra e ignora o registro
# da feature - resultado: nunca aparece no Feature Manager nem ao usuario.
ADDON_FEATURES_DIR="/usr/local/cpanel/whostmgr/addonfeatures"
if [[ -d "${ADDON_FEATURES_DIR}" ]]; then
    echo "Ferramentas do Usuário" > "${ADDON_FEATURES_DIR}/${PLUGIN_NAME}"
    chown root:root "${ADDON_FEATURES_DIR}/${PLUGIN_NAME}"
    chmod 0644 "${ADDON_FEATURES_DIR}/${PLUGIN_NAME}"
    echo "  - Feature '${PLUGIN_NAME}' registrada no Feature Manager"
fi

echo "  - Registrando AppConfig (WHM)"
/usr/local/cpanel/bin/register_appconfig "${SRC_DIR}/whm/usertools.conf"

echo "  - Registrando AppConfig (cPanel)"
/usr/local/cpanel/bin/register_appconfig "${SRC_DIR}/cpanel/usertools.conf"

# Habilita a feature em todas as feature lists em disco.
FEATURES_DIR="/var/cpanel/features"
if [[ -d "${FEATURES_DIR}" ]]; then
    shopt -s nullglob
    for flist in "${FEATURES_DIR}"/*; do
        [[ -f "$flist" ]] || continue
        case "$(basename "$flist")" in
            *.lock|*.cache|*.swp) continue ;;
        esac
        if ! grep -q "^${PLUGIN_NAME}=" "$flist" 2>/dev/null; then
            echo "${PLUGIN_NAME}=1" >> "$flist"
        fi
    done
    shopt -u nullglob
    echo "  - Feature 'usertools' confirmada ativa em todas as listas de planos em disco"
fi

# A feature list 'default' e compilada e nao fica em /var/cpanel/features/,
# entao injetamos via whmapi1 para garantir que o plano padrao (usado pela
# maioria dos usuarios de teste) enxergue o icone.
if command -v whmapi1 >/dev/null 2>&1; then
    whmapi1 update_featurelist featurelist=default "features.${PLUGIN_NAME}=1" >/dev/null 2>&1 || true
    echo "  - Feature '${PLUGIN_NAME}' habilitada na feature list 'default' via whmapi1"
fi

# Limpa caches dynamicui por usuario para forcar recomputacao do chrome do cPanel.
for userhome in /home/*/; do
    [[ -d "${userhome}.cpanel/caches" ]] || continue
    rm -f "${userhome}.cpanel/caches/dynamicui"* 2>/dev/null || true
done

# --- Limpeza de cache + reload -----------------------------------------------
echo "  - Limpando caches e recarregando cpsrvd"
/usr/local/cpanel/scripts/rebuild_sprites 2>/dev/null || true

# Força recarga do Feature Manager, AppConfigs compiladas e do chrome do WHM/cPanel.
# cpsrvd serve tanto WHM quanto cPanel; o restart é quase instantâneo.
if [[ -x /usr/local/cpanel/bin/build_dynamicui ]]; then
    /usr/local/cpanel/bin/build_dynamicui >/dev/null 2>&1 || true
fi
if [[ -x /usr/local/cpanel/scripts/restartsrv_cpsrvd ]]; then
    /usr/local/cpanel/scripts/restartsrv_cpsrvd >/dev/null 2>&1 || true
fi

echo ""
echo "==> Instalação concluída."
echo ""
echo "Próximos passos:"
echo "  1. WHM → Home → Feature Manager → adicione 'usertools' aos planos desejados"
echo "     para que os clientes vejam o ícone no cPanel."
echo "  2. WHM → Home → Plugins → 'Ferramentas do Usuário' (root/revendedores)."
echo "  3. cPanel do cliente → seção 'Ferramentas'."
