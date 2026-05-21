#!/bin/bash
set -euo pipefail

BACKUP_FILE="${1:-}"
BACKUP_DIR="/root/wg-backups"

echo "==> Restaurar configuracion WireGuard"

if [[ -z "${BACKUP_FILE}" ]]; then
    echo "Uso: $0 <archivo_backup.tar.gz>"
    echo ""
    echo "Backups disponibles:"
    ls -1t "${BACKUP_DIR}"/*.tar.gz 2>/dev/null || echo "  (ninguno)"
    exit 1
fi

if [[ ! -f "${BACKUP_FILE}" ]]; then
    echo "ERROR: archivo no encontrado: ${BACKUP_FILE}"
    exit 1
fi

echo "    Backup a restaurar: ${BACKUP_FILE}"
echo ""
echo "    ATENCION: Esto sobreescribira:"
echo "      - /etc/wireguard/ (configs y claves)"
echo "      - Reglas de iptables"
echo "      - Config de unbound"
echo ""

# Preguntar confirmacion (si no es dry-run y hay terminal)
if [[ "${DRY_RUN:-0}" != "1" ]] && [[ -t 0 ]]; then
    read -rp "  Continuar? (s/N): " CONFIRM
    if [[ "${CONFIRM}" != "s" ]]; then
        echo "  Restauracion cancelada"
        exit 0
    fi
fi

RESTORE_DIR=$(mktemp -d)
tar xzf "${BACKUP_FILE}" -C "${RESTORE_DIR}"
BACKUP_CONTENT=$(find "${RESTORE_DIR}" -type d | head -1)

echo "    Restaurando..."

if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "    [DRY-RUN] Contenido del backup:"
    find "${RESTORE_DIR}" -type f | sed 's/^/      /'
    echo "    [DRY-RUN] No se aplicaron cambios"
    rm -rf "${RESTORE_DIR}"
    exit 0
fi

# Restaurar WireGuard
if [[ -d "${BACKUP_CONTENT}/wireguard" ]]; then
    cp -r "${BACKUP_CONTENT}/wireguard" /etc/
    echo "    /etc/wireguard/ restaurado"
    wg-quick down wg0 2>/dev/null || true
    wg-quick down wg1 2>/dev/null || true
    wg-quick up wg1 2>/dev/null || echo "    (wg1 pendiente de credenciales)"
    wg-quick up wg0 2>/dev/null || echo "    (wg0 pendiente de clientes)"
fi

# Restaurar iptables
if [[ -f "${BACKUP_CONTENT}/iptables.rules" ]]; then
    iptables-restore < "${BACKUP_CONTENT}/iptables.rules"
    netfilter-persistent save 2>/dev/null || true
    echo "    iptables restaurado"
fi

# Restaurar unbound
if [[ -f "${BACKUP_CONTENT}/unbound.conf" ]]; then
    cp "${BACKUP_CONTENT}/unbound.conf" /etc/unbound/unbound.conf
    systemctl restart unbound
    echo "    unbound restaurado"
fi

# Restaurar estado multihop
if [[ -f "${BACKUP_CONTENT}/multihop_state" ]]; then
    cp "${BACKUP_CONTENT}/multihop_state" /etc/wireguard/.multihop_state
    echo "    Estado multihop restaurado: $(cat /etc/wireguard/.multihop_state)"
fi

rm -rf "${RESTORE_DIR}"
echo ""
echo "==> Restauracion completada"
echo "    Verifique conectividad SSH antes de cerrar esta sesion"
