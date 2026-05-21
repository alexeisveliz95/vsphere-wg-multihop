#!/bin/bash
set -euo pipefail

WG_PORT="${1:-51820}"

echo "==> [04] Instalar WireGuard + claves VPS"
echo "    Puerto WG: ${WG_PORT}"

# --- Dry-run mode ---
if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "    [DRY-RUN] apt install -y wireguard"
    echo "    [DRY-RUN] sysctl net.ipv4.ip_forward=1"
    echo "    [DRY-RUN] wg genkey | tee vps_private.key | wg pubkey > vps_public.key"
    echo "    [DRY-RUN] Clave publica: (simulada)"
    exit 0
fi

echo "    Instalando WireGuard..."
apt-get update -qq
apt-get install -y wireguard

echo "    Activando IP forwarding..."
grep -qxF 'net.ipv4.ip_forward=1' /etc/sysctl.conf || \
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
sysctl -p

echo "    Generando claves del VPS..."
cd /etc/wireguard
umask 077
if [[ ! -f vps_private.key ]]; then
    wg genkey | tee vps_private.key | wg pubkey > vps_public.key
else
    echo "    Claves ya existen, omitiendo generacion"
fi

echo ""
echo "=== CLAVE PUBLICA DEL VPS ==="
cat /etc/wireguard/vps_public.key
echo "=== GUARDE ESTA CLAVE ==="
echo ""
echo "==> [04] COMPLETADO - WireGuard instalado"
