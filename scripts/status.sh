#!/bin/bash
# vSphere WG Multihop - Dashboard de estado

VPS_IP="152.206.85.17"
STATE_FILE="/etc/wireguard/.multihop_state"

MULTIHOP_STATE="OFF"
if [[ -f "${STATE_FILE}" ]]; then
    MULTIHOP_STATE=$(cat "${STATE_FILE}")
fi

# Obtener informacion de wg0
WG0_PEERS=0
WG0_PEERS_ONLINE=0
if command -v wg &>/dev/null && wg show wg0 &>/dev/null 2>&1; then
    WG0_PEERS=$(wg show wg0 peers 2>/dev/null | wc -l)
    wg show wg0 latest-handshakes 2>/dev/null | while read -r _ ts; do
        if [[ "${ts}" -gt 0 ]]; then
            NOW=$(date +%s)
            AGE=$((NOW - ts))
            if [[ ${AGE} -lt 180 ]]; then
                WG0_PEERS_ONLINE=$((WG0_PEERS_ONLINE + 1))
            fi
        fi
    done
fi

# Obtener informacion de wg1
WG1_HANDSHAKE="N/A"
WG1_AGE="N/A"
if command -v wg &>/dev/null && wg show wg1 &>/dev/null 2>&1; then
    wg show wg1 latest-handshakes 2>/dev/null | while read -r _ ts; do
        if [[ "${ts}" -gt 0 ]]; then
            NOW=$(date +%s)
            AGE=$((NOW - ts))
            if [[ ${AGE} -lt 60 ]]; then
                WG1_AGE="hace ${AGE}s"
            elif [[ ${AGE} -lt 3600 ]]; then
                WG1_AGE="hace $((AGE / 60))min"
            else
                WG1_AGE="hace $((AGE / 3600))h"
            fi
            WG1_HANDSHAKE="OK"
        fi
    done
    WG1_HANDSHAKE=$(wg show wg1 2>/dev/null | grep -c "peer:" || echo 0)
    if [[ "${WG1_HANDSHAKE}" -gt 0 ]]; then
        WG1_HANDSHAKE="activo"
    else
        WG1_HANDSHAKE="sin peer"
    fi
fi

# Memoria
MEM_TOTAL=$(free -h | awk '/^Mem:/ {print $2}')
MEM_USED=$(free -h | awk '/^Mem:/ {print $3}')
MEM_AVAIL=$(free -h | awk '/^Mem:/ {print $7}')
SWAP_USED=$(free -h | awk '/^Swap:/ {print $3}')

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║   vSphere WG Multihop - Dashboard    ║"
echo "  ╠══════════════════════════════════════╣"
echo "  ║  VPS IP:    ${VPS_IP}"
echo "  ║  Multihop:  ${MULTIHOP_STATE}"
echo "  ║  wg0:       10.8.0.1/24 (${WG0_PEERS} peers, ${WG0_PEERS_ONLINE} online)"
echo "  ║  wg1:       Surfshark (${WG1_HANDSHAKE})"
echo "  ║  Memoria:   ${MEM_USED} / ${MEM_TOTAL} (disp: ${MEM_AVAIL})"
echo "  ║  Swap:      ${SWAP_USED}"
echo "  ╚══════════════════════════════════════╝"
echo ""

# Tests rapidos
echo "  --- Tests rapidos ---"
echo -n "  DNS (google.com): "
if command -v dig &>/dev/null; then
    dig +short google.com @127.0.0.1 2>/dev/null | head -1 || echo "fallo"
else
    echo "dig no instalado"
fi

echo -n "  Ping a gateway: "
if ping -c 1 -W 2 152.206.85.1 &>/dev/null; then
    echo "OK"
else
    echo "fallo"
fi

echo -n "  Tabla mgmt: "
if ip rule show | grep -q "mgmt"; then
    echo "OK"
else
    echo "FALTA (watchdog deberia restaurar)"
fi

echo -n "  Tabla wg_clients: "
if ip rule show | grep -q "wg_clients"; then
    echo "OK"
else
    echo "solo necesaria con clientes conectados"
fi
echo ""

echo "  --- Comandos utiles ---"
echo "  add-client.sh <nombre>      Agregar cliente"
echo "  remove-client.sh <nombre>   Eliminar cliente"
echo "  list-clients.sh             Listar clientes"
echo "  toggle-multihop.sh on|off   Multihop VPS"
echo "  backup.sh                   Backup config"
echo ""
