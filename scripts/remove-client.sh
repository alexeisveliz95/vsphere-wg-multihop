#!/bin/bash
set -euo pipefail

CLIENT_NAME="${1:-}"
WG_CONF="/etc/wireguard/wg0.conf"
CLIENT_DIR="/root/client-configs"

# --- Dry-run mode ---
if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "    [DRY-RUN] remove-client.sh <nombre>"
    echo "      - Elimina peer de wg0.conf"
    echo "      - Recarga wg0"
    echo "      - Borra configuracion del cliente"
    exit 0
fi

if [[ -z "${CLIENT_NAME}" ]]; then
    echo "Uso: $0 <nombre_del_cliente>"
    echo "Ej:  $0 laptop-andy"
    echo ""
    echo "Clientes disponibles:"
    grep -B1 "AllowedIPs" "${WG_CONF}" 2>/dev/null | grep "# Cliente:" || \
        echo "  (ningun cliente configurado)"
    exit 1
fi

# Sanitizar
CLIENT_NAME=$(echo "${CLIENT_NAME}" | sed 's/[^a-zA-Z0-9-]/_/g')

echo "    Eliminando cliente ${CLIENT_NAME}..."

# Extraer PublicKey del cliente antes de borrar
CLIENT_PUBKEY=$(grep -A2 "# Cliente: ${CLIENT_NAME}\$" "${WG_CONF}" 2>/dev/null | grep "PublicKey" | awk '{print $3}')
if [[ -n "${CLIENT_PUBKEY}" ]]; then
    wg set wg0 peer "${CLIENT_PUBKEY}" remove 2>/dev/null || \
        echo "    (wg0 no activo, peer eliminado solo del archivo)"
fi

# Eliminar bloque del archivo de config
sed -i "/^# Cliente: ${CLIENT_NAME}/,+3d" "${WG_CONF}" 2>/dev/null

# Eliminar directorio del cliente
if [[ -d "${CLIENT_DIR}/${CLIENT_NAME}" ]]; then
    rm -rf "${CLIENT_DIR:?}/${CLIENT_NAME}"
    echo "    Config de cliente eliminada: ${CLIENT_DIR}/${CLIENT_NAME}"
fi

echo "    Cliente ${CLIENT_NAME} eliminado"
