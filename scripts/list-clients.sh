#!/bin/bash

echo "=== CLIENTES WIREGUARD (wg0) ==="
echo ""

if command -v wg &>/dev/null && wg show wg0 &>/dev/null; then
    wg show wg0 | grep -A1 "peer:" | while read -r line; do
        if [[ "${line}" == peer:* ]]; then
            PUBKEY=$(echo "${line}" | awk '{print $2}')
            ENDPOINT=$(wg show wg0 endpoints 2>/dev/null | grep "${PUBKEY}" | awk '{print $2}')
            # Buscar IP asignada en wg0.conf
            CLIENT_IP=$(grep -B2 "${PUBKEY}" /etc/wireguard/wg0.conf 2>/dev/null | grep "AllowedIPs" | awk '{print $3}')
            CLIENT_NAME=$(grep -B3 "${PUBKEY}" /etc/wireguard/wg0.conf 2>/dev/null | grep "# Cliente:" | sed 's/.*# Cliente: //')
            LATEST_HANDSHAKE=$(wg show wg0 latest-handshakes 2>/dev/null | grep "${PUBKEY}" | awk '{print $2}')
            TRANSFER=$(wg show wg0 transfer 2>/dev/null | grep "${PUBKEY}" | awk '{print $2, $3}')

            if [[ -n "${LATEST_HANDSHAKE}" && "${LATEST_HANDSHAKE}" -gt 0 ]]; then
                NOW=$(date +%s)
                AGE=$((NOW - LATEST_HANDSHAKE))
                if [[ ${AGE} -lt 60 ]]; then
                    TIME_AGO="hace ${AGE}s"
                elif [[ ${AGE} -lt 3600 ]]; then
                    TIME_AGO="hace $((AGE / 60))min"
                else
                    TIME_AGO="hace $((AGE / 3600))h"
                fi
            else
                TIME_AGO="nunca"
            fi

            echo "  Cliente: ${CLIENT_NAME:-desconocido}"
            echo "    IP:      ${CLIENT_IP:-N/A}"
            echo "    Pubkey:  ${PUBKEY:0:20}..."
            echo "    Handshake: ${TIME_AGO}"
            echo "    Endpoint: ${ENDPOINT:-N/A}"
            echo "    Transfer: ${TRANSFER:-N/A}"
            echo ""
        fi
    done
else
    echo "  wg0 no activo o WireGuard no instalado"
    echo ""
    echo "  Clientes configurados en wg0.conf:"
    grep "# Cliente:" /etc/wireguard/wg0.conf 2>/dev/null | sed 's/.*# Cliente: //' || echo "  (ninguno)"
fi

echo "=== TOTAL: $(wg show wg0 peers 2>/dev/null || echo 0) peers ==="
