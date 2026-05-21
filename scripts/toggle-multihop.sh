#!/bin/bash
set -euo pipefail

ACTION="${1:-}"
STATE_FILE="/etc/wireguard/.multihop_state"
IPT=$(command -v iptables)
WG_TABLE="wg_clients"

echo "==> Multihop Toggle - VPS mismo sale por USA"

# --- Dry-run mode ---
if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "    [DRY-RUN] toggle-multihop.sh on|off"
    if [[ "${ACTION}" == "on" ]]; then
        echo "    [DRY-RUN] Reglas a aplicar en mangle OUTPUT:"
        echo "      -p udp --dport 53 -j RETURN       (DNS fuera)"
        echo "      -p tcp --dport 22 -j RETURN       (SSH fuera)"
        echo "      -p udp --dport 51820 -j RETURN    (WG fuera)"
        echo "      -j MARK --set-mark 200            (resto -> Surfshark)"
        echo "    [DRY-RUN] ip rule add fwmark 200 table ${WG_TABLE}"
        echo "    [DRY-RUN] Persistente hasta toggle off"
    else
        echo "    [DRY-RUN] iptables -t mangle -F OUTPUT"
        echo "    [DRY-RUN] ip rule del fwmark 200 table ${WG_TABLE}"
    fi
    exit 0
fi

if [[ "${ACTION}" != "on" ]] && [[ "${ACTION}" != "off" ]]; then
    echo "Uso: $0 on|off"
    echo ""
    if [[ -f "${STATE_FILE}" ]]; then
        echo "Estado actual: $(cat ${STATE_FILE})"
    else
        echo "Estado actual: OFF (por defecto)"
    fi
    exit 1
fi

if [[ "${ACTION}" == "on" ]]; then
    echo "    Activando multihop para el VPS..."

    # DNS no va por WG
    ${IPT} -t mangle -A OUTPUT -p udp --dport 53 -j RETURN
    ${IPT} -t mangle -A OUTPUT -p tcp --dport 53 -j RETURN

    # SSH no va por WG
    ${IPT} -t mangle -A OUTPUT -p tcp --dport 22 -j RETURN

    # WireGuard propio no va por WG (evita loop)
    ${IPT} -t mangle -A OUTPUT -p udp --dport 51820 -j RETURN

    # TODO lo demas → marca para tabla wg_clients (Surfshark)
    ${IPT} -t mangle -A OUTPUT -j MARK --set-mark 200

    # Asegurar regla de ruteo
    ip rule add fwmark 200 table "${WG_TABLE}" priority 200 2>/dev/null || true

    # Guardar estado
    echo "ON" > "${STATE_FILE}"
    echo "    Multihop activado - VPS sale por Surfshark USA"

else
    echo "    Desactivando multihop..."

    # Limpiar todas las reglas de mangle OUTPUT
    ${IPT} -t mangle -F OUTPUT

    # Eliminar regla de ruteo
    ip rule del fwmark 200 table "${WG_TABLE}" 2>/dev/null || true

    # Guardar estado
    echo "OFF" > "${STATE_FILE}"
    echo "    Multihop desactivado - VPS sale directo"
fi

# Persistir reglas iptables
netfilter-persistent save 2>/dev/null || true

echo "==> Estado: $(cat ${STATE_FILE})"
