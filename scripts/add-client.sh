#!/bin/bash
set -euo pipefail

CLIENT_NAME="${1:-}"
WG_CONF="/etc/wireguard/wg0.conf"
WG_SUBNET="10.8.0.0/24"
WG_SERVER_IP="10.8.0.1"
WG_PORT="${WG_PORT:-51820}"
VPS_PUBLIC_IP="${VPS_PUBLIC_IP:-152.206.85.17}"
CLIENT_DIR="/root/client-configs"

# --- Dry-run mode ---
if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "    [DRY-RUN] add-client.sh <nombre>"
    echo "      - Genera par de llaves para el cliente"
    echo "      - Asigna proxima IP disponible en ${WG_SUBNET}"
    echo "      - Agrega [Peer] a wg0.conf"
    echo "      - Recarga wg0 con wg syncconf"
    echo "      - Genera .conf y QR para el cliente"
    exit 0
fi

if [[ -z "${CLIENT_NAME}" ]]; then
    echo "Uso: $0 <nombre_del_cliente>"
    echo "Ej:  $0 laptop-andy"
    echo ""
    echo "Variables de entorno:"
    echo "  WG_PORT=51820       Puerto WireGuard"
    echo "  VPS_PUBLIC_IP=...   IP publica del VPS"
    echo "  DRY_RUN=1           Modo simulacion"
    exit 1
fi

# Sanitizar nombre (solo alfanumerico + guiones)
CLIENT_NAME=$(echo "${CLIENT_NAME}" | sed 's/[^a-zA-Z0-9-]/_/g')

mkdir -p "${CLIENT_DIR}"
CLIENT_DIR="${CLIENT_DIR}/${CLIENT_NAME}"
mkdir -p "${CLIENT_DIR}"

# --- Generar llaves del cliente ---
echo "    Generando llaves para ${CLIENT_NAME}..."
wg genkey | tee "${CLIENT_DIR}/private.key" | wg pubkey > "${CLIENT_DIR}/public.key"
CLIENT_PRIVATE=$(cat "${CLIENT_DIR}/private.key")
CLIENT_PUBLIC=$(cat "${CLIENT_DIR}/public.key")

# --- Asignar IP (siguiente disponible) ---
CURRENT_IPS=$(grep -E "^\s*#?\s*AllowedIPs" "${WG_CONF}" 2>/dev/null | grep -oP '10\.8\.0\.\d+' || true)
NEXT_IP=2
for ip in $(seq 2 254); do
    if ! echo "${CURRENT_IPS}" | grep -q "10.8.0.${ip}"; then
        NEXT_IP=${ip}
        break
    fi
done
CLIENT_IP="10.8.0.${NEXT_IP}"

echo "    IP asignada: ${CLIENT_IP}/24"

# --- Agregar peer a wg0.conf ---
cat >> "${WG_CONF}" << EOF

# Cliente: ${CLIENT_NAME} (${CLIENT_IP})
[Peer]
PublicKey = ${CLIENT_PUBLIC}
AllowedIPs = ${CLIENT_IP}/32
EOF

# --- Recargar wg0 sin cortar conexiones ---
wg syncconf wg0 <(wg-quick strip wg0) 2>/dev/null || \
    wg addconf wg0 <(wg-quick strip wg0) 2>/dev/null || \
    echo "    (wg0 no activo, se aplicara al levantar)"

# --- Generar archivo .conf para el cliente ---
cat > "${CLIENT_DIR}/${CLIENT_NAME}.conf" << EOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE}
Address = ${CLIENT_IP}/24
DNS = ${WG_SERVER_IP}
MTU = 1380

[Peer]
PublicKey = $(cat /etc/wireguard/vps_public.key 2>/dev/null || echo "VPS_PUBKEY_AQUI")
Endpoint = ${VPS_PUBLIC_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

chmod 600 "${CLIENT_DIR}/${CLIENT_NAME}.conf"

echo ""
echo "=== CLIENTE: ${CLIENT_NAME} ==="
echo "  IP:       ${CLIENT_IP}/24"
echo "  Llaves:   ${CLIENT_DIR}/"
echo ""
echo "=== CONFIGURACION (copia en el cliente) ==="
cat "${CLIENT_DIR}/${CLIENT_NAME}.conf"
echo ""

# --- QR ---
if command -v qrencode &>/dev/null; then
    echo "=== CODIGO QR ==="
    qrencode -t ansiutf8 < "${CLIENT_DIR}/${CLIENT_NAME}.conf" 2>/dev/null || \
        echo "  (qrencode fallo, el .conf esta en ${CLIENT_DIR})"
else
    echo "  (qrencode no instalado. apt install qrencode para QR)"
    echo "  Configuracion disponible en: ${CLIENT_DIR}/${CLIENT_NAME}.conf"
fi

echo ""
echo "=== CLIENTE AGREGADO EXITOSAMENTE ==="
