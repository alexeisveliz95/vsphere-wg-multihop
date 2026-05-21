#!/bin/bash
set -euo pipefail

echo "==> [07] DNS local con unbound"
echo "    Forwarders: Cloudflare + Google"

# --- Dry-run mode ---
if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "    [DRY-RUN] apt install -y unbound"
    echo "    [DRY-RUN] /etc/unbound/unbound.conf creado"
    echo "    [DRY-RUN] resolvectl dns ens192 127.0.0.1"
    echo "    [DRY-RUN] Resumen config:"
    echo "      interface: 127.0.0.1 (local) + 10.8.0.1 (clientes)"
    echo "      forwarders: 1.1.1.1, 8.8.8.8"
    echo "      cache min/max: 300s/86400s"
    exit 0
fi

echo "    Instalando unbound..."
apt-get install -y unbound

echo "    Configurando unbound..."
cat > /etc/unbound/unbound.conf << EOF
server:
    interface: 127.0.0.1
    interface: 10.8.0.1
    port: 53
    access-control: 127.0.0.0/8 allow
    access-control: 10.8.0.0/24 allow
    do-ip4: yes
    do-ip6: no
    do-udp: yes
    do-tcp: yes
    prefer: auto

    prefetch: yes
    prefetch-key: yes
    cache-min-ttl: 300
    cache-max-ttl: 86400
    msg-cache-slabs: 4
    rrset-cache-slabs: 4
    infra-cache-slabs: 4
    key-cache-slabs: 4
    rrset-cache-size: 64m
    msg-cache-size: 32m
    so-rcvbuf: 1m
    so-sndbuf: 1m

    hide-identity: yes
    hide-version: yes
    use-caps-for-id: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    unwanted-reply-threshold: 10000
    val-clean-additional: yes

    # Reducir uso de memoria en VPS limitado
    outgoing-range: 512
    num-queries-per-thread: 256
    outgoing-num-tcp: 64
    incoming-num-tcp: 64

forward-zone:
    name: "."
    forward-addr: 1.1.1.1
    forward-addr: 1.0.0.1
    forward-addr: 8.8.8.8
    forward-addr: 8.8.4.4
    forward-tls-upstream: yes
EOF

echo "    Iniciando unbound..."
systemctl restart unbound
systemctl enable unbound

echo "    Apuntando systemd-resolved a unbound local..."
resolvectl dns ens192 127.0.0.1
resolvectl domain ens192 ""

echo ""
echo "==> [07] COMPLETADO - DNS local: unbound activo"
echo "    Clientes WG usaran 10.8.0.1 como DNS"
echo "    Forwarders: Cloudflare + Google"
