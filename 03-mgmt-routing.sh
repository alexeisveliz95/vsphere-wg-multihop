#!/bin/bash
set -euo pipefail

MGMT_IFACE="${1:-ens192}"
MGMT_GW="${2:-152.206.85.1}"
VPS_IP="${3:-152.206.85.17}"
MGMT_TABLE="100"

echo "==> [03] Management routing (anti-lockout)"
echo "    IFACE:${MGMT_IFACE} GW:${MGMT_GW} VPS:${VPS_IP}"

# --- Dry-run mode ---
if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "    [DRY-RUN] echo \"${MGMT_TABLE} mgmt\" >> /etc/iproute2/rt_tables"
    echo "    [DRY-RUN] ip rule add from ${VPS_IP} table mgmt priority 100"
    echo "    [DRY-RUN] ip route add default via ${MGMT_GW} dev ${MGMT_IFACE} table mgmt"
    echo "    [DRY-RUN] systemd service: /etc/systemd/system/mgmt-routing.service"
    echo "    [DRY-RUN] Script: /usr/local/bin/mgmt-routing.sh"
    exit 0
fi

echo "    Creando tabla mgmt (${MGMT_TABLE})..."
grep -qxF "${MGMT_TABLE} mgmt" /etc/iproute2/rt_tables || \
    echo "${MGMT_TABLE} mgmt" >> /etc/iproute2/rt_tables

echo "    Aplicando regla de ruteo..."
ip rule add from ${VPS_IP} table mgmt priority 100 2>/dev/null || \
    echo "    (regla ya existe, omitiendo)"
ip route replace default via ${MGMT_GW} dev ${MGMT_IFACE} table mgmt 2>/dev/null || \
    ip route add default via ${MGMT_GW} dev ${MGMT_IFACE} table mgmt

echo "    Creando script de persistencia..."
cat > /usr/local/bin/mgmt-routing.sh << 'SCRIPT'
#!/bin/bash
MGMT_IFACE="$1"
MGMT_GW="$2"
VPS_IP="$3"
MGMT_TABLE="mgmt"

grep -qxF "100 mgmt" /etc/iproute2/rt_tables || echo "100 mgmt" >> /etc/iproute2/rt_tables
ip rule add from "${VPS_IP}" table "${MGMT_TABLE}" priority 100 2>/dev/null || true
ip route replace default via "${MGMT_GW}" dev "${MGMT_IFACE}" table "${MGMT_TABLE}" 2>/dev/null || true
SCRIPT
chmod +x /usr/local/bin/mgmt-routing.sh

echo "    Creando servicio systemd..."
cat > /etc/systemd/system/mgmt-routing.service << EOF
[Unit]
Description=Policy routing for management traffic (anti-lockout)
After=network-online.target
Wants=network-online.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mgmt-routing.sh ${MGMT_IFACE} ${MGMT_GW} ${VPS_IP}
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mgmt-routing.service
systemctl start mgmt-routing.service

echo "==> [03] COMPLETADO - Tabla mgmt activa y persistente"
echo "    Todo trafico desde ${VPS_IP} usa gateway ${MGMT_GW}"
echo "    (SSH, DNS y demas servicios del VPS NO pasan por WG)"
