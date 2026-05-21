#!/bin/bash
set -euo pipefail

echo "==> [08] Watchdog + persistencia + scripts de gestion"

# --- Dry-run mode ---
if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "    [DRY-RUN] Instalar scripts en /usr/local/bin/"
    echo "    [DRY-RUN]   scripts/add-client.sh"
    echo "    [DRY-RUN]   scripts/remove-client.sh"
    echo "    [DRY-RUN]   scripts/list-clients.sh"
    echo "    [DRY-RUN]   scripts/toggle-multihop.sh"
    echo "    [DRY-RUN]   scripts/status.sh"
    echo "    [DRY-RUN]   scripts/watchdog.sh"
    echo "    [DRY-RUN]   scripts/backup.sh"
    echo "    [DRY-RUN]   scripts/restore.sh"
    echo "    [DRY-RUN] Cron: */2 * * * * root /usr/local/bin/watchdog.sh"
    echo "    [DRY-RUN] qrencode: apt install -y qrencode"
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")/scripts" && pwd)"

echo "    Instalando scripts en /usr/local/bin/..."

for script in add-client.sh remove-client.sh list-clients.sh \
              toggle-multihop.sh status.sh watchdog.sh backup.sh restore.sh; do
    if [[ -f "${SCRIPT_DIR}/${script}" ]]; then
        cp "${SCRIPT_DIR}/${script}" "/usr/local/bin/${script}"
        chmod +x "/usr/local/bin/${script}"
        echo "      ${script}"
    fi
done

echo "    Instalando qrencode (para QR en add-client)..."
apt-get install -y qrencode

echo "    Configurando cron (watchdog cada 2 min)..."
cat > /etc/cron.d/wg-watchdog << EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
*/2 * * * * root /usr/local/bin/watchdog.sh >/dev/null 2>&1
EOF
chmod 644 /etc/cron.d/wg-watchdog

echo "    Estado inicial multihop..."
mkdir -p /etc/wireguard
echo "OFF" > /etc/wireguard/.multihop_state

echo "    Respaldo inicial de iptables..."
netfilter-persistent save 2>/dev/null || \
    mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

echo ""
echo "==> [08] COMPLETADO"
echo "    Scripts instalados en /usr/local/bin/"
echo "    Watchdog cada 2 min via cron"
echo "    qrencode disponible para QR"
echo ""
echo "    Para agregar cliente:  add-client.sh <nombre>"
echo "    MultiHop VPS:          toggle-multihop.sh on|off"
echo "    Dashboard:             status.sh"
echo "    Backup:                backup.sh"
