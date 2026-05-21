#!/bin/bash
set -euo pipefail

SSH_PORT="${1:-22}"
WG_PORT="${2:-51820}"

echo "==> [02] Firewall base iptables"
echo "    SSH:${SSH_PORT} WG:${WG_PORT}"

# --- Dry-run mode ---
if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "    [DRY-RUN] Reglas iptables a aplicar:"
    echo "      -P INPUT DROP"
    echo "      -P FORWARD DROP"
    echo "      -P OUTPUT ACCEPT"
    echo "      -A INPUT -i lo -j ACCEPT"
    echo "      -A INPUT -p tcp --dport ${SSH_PORT} -j ACCEPT (SSH anti-lockout)"
    echo "      -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT"
    echo "      -A INPUT -p udp --dport ${WG_PORT} -j ACCEPT"
    echo "      -A INPUT -p icmp --icmp-type echo-request -m limit --limit 2/s -j ACCEPT"
    echo "      -A INPUT -j DROP"
    echo "      -A FORWARD -i wg0 -o wg1 -j ACCEPT"
    echo "      -A FORWARD -i wg1 -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT"
    echo "      -t nat -A POSTROUTING -o wg1 -j MASQUERADE"
    echo "    [DRY-RUN] apt install -y iptables-persistent"
    echo "    [DRY-RUN] netfilter-persistent save"
    exit 0
fi

IPT=$(command -v iptables)

echo "    Aplicando reglas base..."

# --- Politicas por defecto ---
${IPT} -P INPUT DROP
${IPT} -P FORWARD DROP
${IPT} -P OUTPUT ACCEPT

# --- Loopback ---
${IPT} -A INPUT -i lo -j ACCEPT

# --- SSH anti-lockout (primera regla, siempre permitido) ---
${IPT} -A INPUT -p tcp --dport ${SSH_PORT} -j ACCEPT

# --- Tráfico establecido/relacionado ---
${IPT} -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# --- WireGuard ---
${IPT} -A INPUT -p udp --dport ${WG_PORT} -j ACCEPT

# --- ICMP limitado ---
${IPT} -A INPUT -p icmp --icmp-type echo-request -m limit --limit 2/second -j ACCEPT

# --- Log + Drop resto ---
${IPT} -A INPUT -j LOG --log-prefix "FW-DROP: " --log-limit 5/min 2>/dev/null || true
${IPT} -A INPUT -j DROP

# --- Forwarding WireGuard (clientes → Surfshark) ---
${IPT} -A FORWARD -i wg0 -o wg1 -j ACCEPT
${IPT} -A FORWARD -i wg1 -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT

# --- NAT para clientes ---
${IPT} -t nat -A POSTROUTING -o wg1 -j MASQUERADE

echo "    Instalando persistencia..."
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
apt-get install -y iptables-persistent
netfilter-persistent save

echo "==> [02] COMPLETADO - Firewall base activo"
echo "    Regla anti-lockout SSH en puerto ${SSH_PORT}"
