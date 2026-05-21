#!/bin/bash
set -euo pipefail

WG_PORT="${1:-51820}"
WG_SUBNET="${2:-10.8.0.0/24}"
WG_SERVER_IP="${3:-10.8.0.1}"

echo "==> [06] Configurar wg0 - Servidor de clientes"
echo "    Puerto:${WG_PORT} Red:${WG_SUBNET} Server:${WG_SERVER_IP}"

WIREGUARD_DIR="/etc/wireguard"

# --- Dry-run mode ---
if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "    [DRY-RUN] wg0.conf creado con:"
    echo "      Address = ${WG_SERVER_IP}/24"
    echo "      ListenPort = ${WG_PORT}"
    echo "      Table = off"
    echo "      PostUp: ip rule from ${WG_SUBNET} table wg_clients"
    echo "      PostUp: ip route default dev wg1 table wg_clients"
    echo "      PostUp: iptables FORWARD + MASQUERADE"
    echo "    [DRY-RUN] wg-quick up wg0"
    exit 0
fi

if [[ ! -f "${WIREGUARD_DIR}/vps_private.key" ]]; then
    echo "    ERROR: Ejecute primero 04-wireguard.sh para generar claves"
    exit 1
fi

VPS_PRIVATE=$(cat "${WIREGUARD_DIR}/vps_private.key")

echo "    Creando wg0.conf..."
cat > "${WIREGUARD_DIR}/wg0.conf" << EOF
[Interface]
Address = ${WG_SERVER_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${VPS_PRIVATE}
MTU = 1420
Table = off

# --- Enrutar clientes hacia wg1 (Surfshark) ---
PostUp = ip rule add from ${WG_SUBNET} table wg_clients priority 200 2>/dev/null
PostUp = ip route add default dev wg1 table wg_clients 2>/dev/null
PostUp = ip route add ${WG_SUBNET} dev wg0 table wg_clients 2>/dev/null
PostUp = ip route add blackhole 0.0.0.0/0 table wg_clients metric 999 2>/dev/null
PostUp = iptables -A FORWARD -i wg0 -o wg1 -j ACCEPT 2>/dev/null
PostUp = iptables -A FORWARD -i wg1 -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
PostUp = iptables -t nat -A POSTROUTING -o wg1 -j MASQUERADE 2>/dev/null

PostDown = ip rule del from ${WG_SUBNET} table wg_clients 2>/dev/null
PostDown = ip route flush table wg_clients 2>/dev/null
PostDown = iptables -D FORWARD -i wg0 -o wg1 -j ACCEPT 2>/dev/null
PostDown = iptables -D FORWARD -i wg1 -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
PostDown = iptables -t nat -D POSTROUTING -o wg1 -j MASQUERADE 2>/dev/null

# Los clientes se agregan dinamicamente con add-client.sh
EOF

chmod 600 "${WIREGUARD_DIR}/wg0.conf"

echo "    Levantando wg0..."
wg-quick up wg0

echo ""
echo "==> [06] COMPLETADO - wg0 activo en ${WG_SERVER_IP}/24"
echo "    wg show:"
wg show wg0 2>/dev/null || echo "    (wg0 no responde aun)"
