#!/bin/bash
# wg-watchdog.sh - Protege contra perdida de acceso SSH/DNS
# Ejecutar cada 2 min via cron

set -euo pipefail

MGMT_IFACE="${MGMT_IFACE:-ens192}"
MGMT_GW="${MGMT_GW:-152.206.85.1}"
VPS_IP="${VPS_IP:-152.206.85.17}"
VPS_PUBLIC_IP="${VPS_PUBLIC_IP:-152.206.85.17}"
WG_PORT="${WG_PORT:-51820}"
LOG_TAG="wg-watchdog"

log() {
    logger -t "${LOG_TAG}" "$@"
}

echo "=== wg-watchdog $(date) ==="

# --- 1. Verificar / restaurar tabla mgmt ---
if ! ip rule show | grep -q "from ${VPS_IP} lookup mgmt"; then
    log "ALERTA: tabla mgmt perdida - restaurando"
    ip rule add from "${VPS_IP}" table mgmt priority 100 2>/dev/null || true
    ip route replace default via "${MGMT_GW}" dev "${MGMT_IFACE}" table mgmt 2>/dev/null || true
    log "tabla mgmt restaurada"
    echo "  [RECUPERADO] Tabla mgmt"
fi

# --- 2. Verificar SSH responde ---
if ! ss -tlnp 2>/dev/null | grep -q ':22 '; then
    log "CRITICO: SSH no responde - bajando WireGuard"
    wg-quick down wg0 2>/dev/null || true
    wg-quick down wg1 2>/dev/null || true
    iptables -F
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    log "WireGuard bajado, firewall abierto"
    echo "  [CRITICO] SSH caido - WG detenido, FW abierto"
    exit 1
fi

# --- 3. Verificar wg1 handshake ---
if wg show wg1 &>/dev/null; then
    HANDSHAKE_TS=$(wg show wg1 latest-handshakes 2>/dev/null | awk '{print $2}')
    if [[ -n "${HANDSHAKE_TS}" && "${HANDSHAKE_TS}" -gt 0 ]]; then
        NOW=$(date +%s)
        AGE=$((NOW - HANDSHAKE_TS))
        if [[ ${AGE} -gt 180 ]]; then
            log "wg1: handshake expirado (${AGE}s) - reintentando"
            wg-quick down wg1 2>/dev/null || true
            sleep 2
            wg-quick up wg1 2>/dev/null || log "wg1: fallo al re-subir"
            echo "  [RECONECTADO] wg1 restart por handshake expirado"
        else
            echo "  wg1 handshake: OK (${AGE}s)"
        fi
    else
        log "wg1: sin handshake - intentando subir"
        wg-quick up wg1 2>/dev/null || log "wg1: fallo al subir"
    fi
fi

# --- 4. Verificar wg0 ---
if wg show wg0 &>/dev/null; then
    # Verificar que la regla de ruteo para clientes existe
    if ! ip rule show | grep -q "from 10.8.0.0/24 lookup wg_clients"; then
        log "wg0: regla de ruteo perdida - restaurando PostUp"
        wg-quick down wg0 2>/dev/null || true
        sleep 1
        wg-quick up wg0 2>/dev/null || log "wg0: fallo al re-subir"
        echo "  [RECUPERADO] wg0 reiniciado por regla perdida"
    fi
fi

# --- 5. Verificar resolucion DNS ---
if command -v dig &>/dev/null; then
    if ! dig +short google.com @127.0.0.53 2>/dev/null | grep -qE '^[0-9]+\.[0-9]'; then
        log "DNS: resolucion fallando - reiniciando unbound"
        systemctl restart unbound 2>/dev/null || true
        echo "  [RECUPERADO] unbound reiniciado"
    fi
fi

# --- 6. Verificar memoria (alerta si critica) ---
MEM_AVAIL=$(free -m | awk '/^Mem:/ {print $7}')
if [[ "${MEM_AVAIL}" -lt 50 ]]; then
    log "MEMORIA BAJA: ${MEM_AVAIL}MB disponibles"
    echo "  [ALERTA] Memoria: ${MEM_AVAIL}MB libre"
    # Liberar cache si es necesario
    sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
fi

echo "=== wg-watchdog FINALIZADO (OK) ==="
