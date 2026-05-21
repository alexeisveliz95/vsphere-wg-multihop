#!/bin/bash
set -euo pipefail

BACKUP_DIR="${1:-/root/wg-backups}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="${BACKUP_DIR}/backup_${TIMESTAMP}"

echo "==> Backup de configuracion WireGuard"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "    [DRY-RUN] Backup desde: /etc/wireguard/"
    echo "    [DRY-RUN] Backup hacia: ${BACKUP_PATH}"
    echo "    [DRY-RUN] Incluye: .conf, .key, .state, iptables"
    exit 0
fi

mkdir -p "${BACKUP_PATH}"

# Backup de configs WG
if [[ -d /etc/wireguard ]]; then
    cp -r /etc/wireguard "${BACKUP_PATH}/wireguard"
    echo "    /etc/wireguard/ guardado"
fi

# Backup de iptables
iptables-save > "${BACKUP_PATH}/iptables.rules" 2>/dev/null && \
    echo "    iptables guardado" || echo "    (sin iptables)"

# Backup de reglas de ruteo
ip rule show > "${BACKUP_PATH}/ip-rules.txt"
ip route show table all > "${BACKUP_PATH}/ip-routes.txt"
echo "    Reglas de ruteo guardadas"

# Backup de sysctl
sysctl net.ipv4.ip_forward > "${BACKUP_PATH}/sysctl.conf" 2>/dev/null || true
echo "    sysctl guardado"

# Backup de unbound
if [[ -f /etc/unbound/unbound.conf ]]; then
    cp /etc/unbound/unbound.conf "${BACKUP_PATH}/unbound.conf"
    echo "    unbound.conf guardado"
fi

# Backup del estado multihop
[[ -f /etc/wireguard/.multihop_state ]] && cp "/etc/wireguard/.multihop_state" "${BACKUP_PATH}/multihop_state"

# Comprimir
cd "${BACKUP_DIR}"
tar czf "backup_${TIMESTAMP}.tar.gz" "backup_${TIMESTAMP}" 2>/dev/null
rm -rf "backup_${TIMESTAMP}"

echo "    Backup comprimido: ${BACKUP_DIR}/backup_${TIMESTAMP}.tar.gz"
echo ""
echo "==> Backup completado"

# Mostrar resumen
echo ""
echo "  Resumen del backup:"
echo "    Fecha:  ${TIMESTAMP}"
echo "    Archivo: ${BACKUP_DIR}/backup_${TIMESTAMP}.tar.gz"
tar tzf "${BACKUP_DIR}/backup_${TIMESTAMP}.tar.gz" 2>/dev/null | sed 's/^/      /'
