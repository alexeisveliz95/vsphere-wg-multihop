#!/bin/bash
set -euo pipefail

# =============================================================================
# wg-multihop.sh — WireGuard Multihop Toolbox (light version)
#
# Un solo archivo. Llevátelo a cualquier VPS y listo.
#
# Modos:
#   install            Setup interactivo completo (WG + firewall + routing + multihop)
#   add-client <name>  Agrega un peer a wg0, genera .conf + QR
#   remove-client <n>  Elimina peer de wg0, borra .conf
#   list-clients       Muestra peers activos en wg0
#   multihog [on|off]  Activa/desactiva salida por wg1 (Surfshark)
#   status             Dashboard
#   watchdog           Auto-reparación (correr via cron)
#   uninstall          Revierte TODO
#   test               Auto-test en namespaces aislados
#
# Uso:
#   DRY_RUN=1 bash wg-multihop.sh install   # simular sin cambios
#   bash wg-multihop.sh add-client pepe     # agregar cliente
# =============================================================================

# --- Config defaults (env vars sobrescriben) ---
WG_PORT="${WG_PORT:-51820}"
WG_DIR="${WG_DIR:-/etc/wireguard}"
CLIENT_DIR="${CLIENT_DIR:-/root/client-configs}"
SURFSHARK_CONF="${SURFSHARK_CONF:-$(cd "$(dirname "$0")" && pwd)/surfshark.conf}"
MULTIHOP_STATE="${WG_DIR}/.multihop_state"
DRY_RUN="${DRY_RUN:-0}"
BATCH="${BATCH:-0}"  # 1 = no interactivo (usa defaults o env vars)

# --- Colores ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ============================================================================
# Utilerías
# ============================================================================
log()  { echo -e "  ${GREEN}[+]${NC} $*"; }
warn() { echo -e "  ${YELLOW}[!]${NC} $*"; }
err()  { echo -e "  ${RED}[x]${NC} $*"; }
info() { echo -e "  ${CYAN}[i]${NC} $*"; }
title(){ echo -e "\n${BOLD}$*${NC}\n"; }

dry() {
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "    [DRY-RUN] $*" >&2
        return 0
    fi
    "$@"
}

check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        err "Requiere root. Ejecute: sudo bash $0 $*"
        exit 1
    fi
}

prompt() {
    local var="$1" msg="$2" default="$3"
    if [[ "$BATCH" == "1" ]]; then
        # En BATCH: no sobrescribir si ya seteado en entorno
        if [[ -n "$(eval echo "\${${var}-}")" ]]; then
            return 0
        fi
        printf -v "$var" "%s" "${default}"
        return 0
    fi
    local input
    if [[ -n "$default" ]]; then
        read -r -p "? ${msg} [${default}]: " input
        printf -v "$var" "%s" "${input:-$default}"
    else
        read -r -p "? ${msg}: " input
        printf -v "$var" "%s" "${input}"
    fi
}

confirm() {
    local msg="$1" default="${2:-Y}"
    if [[ "$BATCH" == "1" ]]; then
        [[ "$default" =~ ^[Yy] ]] && return 0 || return 1
    fi
    local input
    read -r -p "? ${msg} [${default}]: " input
    input="${input:-$default}"
    [[ "$input" =~ ^[Yy] ]]
}

run_wg_quick() {
    local conf="$1" action="$2"
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "    [DRY-RUN] wg-quick ${action} ${conf}" >&2
        return 0
    fi
    wg-quick "$action" "$conf" 2>&1 | grep -v "Warning:" || true
    return 0
}

# ============================================================================
# Internas — instalación
# ============================================================================

__detect_wan() {
    ip route get 8.8.8.8 2>/dev/null | grep -oP 'dev \K\S+' | head -1 || echo "eth0"
}

__detect_ip() {
    local iface="$1"
    ip addr show "$iface" 2>/dev/null | grep -oP 'inet \K[0-9.]+/[0-9]+' | head -1 || echo "0.0.0.0/24"
}

__install_wireguard() {
    title "[1/6] Instalando WireGuard"
    log "Instalando paquetes..."
    dry DEBIAN_FRONTEND=noninteractive apt update -qq 2>/dev/null || true
    dry DEBIAN_FRONTEND=noninteractive apt install -y -qq wireguard qrencode iptables-persistent 2>/dev/null || true
    dry mkdir -p "$WG_DIR"
    if [[ ! -f "${WG_DIR}/vps_private.key" ]]; then
        log "Generando claves del servidor..."
        dry bash -c "wg genkey | tee ${WG_DIR}/vps_private.key | wg pubkey > ${WG_DIR}/vps_public.key" || true
        dry chmod 600 "${WG_DIR}/vps_private.key" 2>/dev/null || true
    else
        info "Claves ya existen, reutilizando"
    fi
    log "Habilitando IP forwarding..."
    dry bash -c "sysctl -w net.ipv4.ip_forward=1 >/dev/null && sed -i 's/^#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf 2>/dev/null || true"
}

__install_firewall() {
    local wan="$1"
    title "[2/6] Configurando firewall"
    log "Aplicando reglas iptables base..."
    dry iptables -P INPUT DROP 2>/dev/null || true
    dry iptables -P FORWARD DROP 2>/dev/null || true
    dry iptables -P OUTPUT ACCEPT 2>/dev/null || true
    dry iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    dry iptables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
    dry iptables -A INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
    dry iptables -A INPUT -p udp --dport "${WG_PORT}" -j ACCEPT 2>/dev/null || true
    dry iptables -A INPUT -p icmp -m limit --limit 10/second -j ACCEPT 2>/dev/null || true
    dry iptables -A FORWARD -i wg0 -o wg1 -j ACCEPT 2>/dev/null || true
    dry iptables -A FORWARD -i wg1 -o wg0 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    dry iptables -A FORWARD -i wg0 -o "${wan}" -j ACCEPT 2>/dev/null || true
    dry iptables -A FORWARD -i "${wan}" -o wg0 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    dry iptables -t nat -A POSTROUTING -o wg1 -j MASQUERADE 2>/dev/null || true
    log "Guardando reglas iptables..."
    dry netfilter-persistent save 2>/dev/null || mkdir -p /etc/iptables 2>/dev/null; dry iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
}

__install_mgmt_routing() {
    title "[3/6] Anti-lockout (tabla mgmt 100)"
    # Crear tabla si no existe
    if ! grep -qxF "100 mgmt" /etc/iproute2/rt_tables 2>/dev/null; then
        dry bash -c "echo '100 mgmt' >> /etc/iproute2/rt_tables"
    fi
    local wan_ip
    wan_ip=$(__detect_ip "$(__detect_wan)" | cut -d/ -f1)
    local gw
    gw=$(ip route show default 2>/dev/null | grep -oP 'via \K\S+' | head -1 || echo "")
    if [[ -n "$gw" && "$wan_ip" != "0.0.0.0" ]]; then
        dry ip route add default via "$gw" dev "$(__detect_wan)" table mgmt 2>/dev/null || true
        dry ip rule add from "$wan_ip" table mgmt priority 100 2>/dev/null || true
        log "Regla mgmt agregada: ${wan_ip} → tabla 100"
    else
        warn "No se detectó gateway, saltando mgmt routing (puede configurarse manual)"
    fi
}

__install_wg0() {
    title "[4/6] Configurando wg0 (clientes)"
    local priv
    priv=$(cat "${WG_DIR}/vps_private.key" 2>/dev/null || wg genkey)
    local pub
    pub=$(echo "$priv" | wg pubkey)
    echo "$priv" > "${WG_DIR}/vps_private.key"
    echo "$pub" > "${WG_DIR}/vps_public.key"

    cat > "${WG_DIR}/wg0.conf" << EOF
[Interface]
PrivateKey = ${priv}
Address = 10.8.0.1/24
ListenPort = ${WG_PORT}
MTU = 1420
Table = off

PostUp = ip rule add from 10.8.0.0/24 table wg_clients priority 200 2>/dev/null
PostUp = ip route add default dev wg1 table wg_clients 2>/dev/null
PostUp = ip route add 10.8.0.0/24 dev wg0 table wg_clients 2>/dev/null
PostUp = ip route add blackhole 0.0.0.0/0 table wg_clients metric 999 2>/dev/null
PostUp = iptables -A FORWARD -i wg0 -o wg1 -j ACCEPT 2>/dev/null
PostUp = iptables -A FORWARD -i wg1 -o wg0 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
PostUp = iptables -t nat -A POSTROUTING -o wg1 -j MASQUERADE 2>/dev/null

PostDown = ip rule del from 10.8.0.0/24 table wg_clients 2>/dev/null
PostDown = ip route flush table wg_clients 2>/dev/null
PostDown = iptables -D FORWARD -i wg0 -o wg1 -j ACCEPT 2>/dev/null
PostDown = iptables -D FORWARD -i wg1 -o wg0 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
PostDown = iptables -t nat -D POSTROUTING -o wg1 -j MASQUERADE 2>/dev/null
EOF
    dry chmod 600 "${WG_DIR}/wg0.conf"
    if ! grep -qxF "200 wg_clients" /etc/iproute2/rt_tables 2>/dev/null; then
        dry bash -c "echo '200 wg_clients' >> /etc/iproute2/rt_tables"
    fi
    log "Levantando wg0..."
    run_wg_quick "${WG_DIR}/wg0.conf" up
    dry mkdir -p "$CLIENT_DIR"
}

__install_wg1() {
    local vps_ip="$1"
    title "[5/6] Configurando wg1 — Surfshark"

    if [[ -z "${WG1_ENDPOINT:-}" || -z "${SS_PUB:-}" ]]; then
        err "Faltan datos de Surfshark (WG1_ENDPOINT o SS_PUB)"
        err "Configure surfshark.conf o pase las variables de entorno"
        return 1
    fi

    local priv
    priv=$(cat "${WG_DIR}/vps_private.key")

    cat > "${WG_DIR}/wg1.conf" << EOF
[Interface]
PrivateKey = ${priv}
Address = ${vps_ip}/32
MTU = 1320
Table = off

[Peer]
PublicKey = ${SS_PUB}
Endpoint = ${WG1_ENDPOINT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 5
EOF
    dry chmod 600 "${WG_DIR}/wg1.conf"
    log "Levantando wg1..."
    run_wg_quick "${WG_DIR}/wg1.conf" up
    # Forzar handshake inicial
    local peer
    peer=$(wg show wg1 peers 2>/dev/null | head -1)
    [[ -n "$peer" ]] && dry wg set wg1 peer "$peer" endpoint "${WG1_ENDPOINT}" 2>/dev/null || true
    echo "ON" > "$MULTIHOP_STATE"
}

__install_watchdog() {
    title "[6/6] Watchdog + Cron"
    local script_path
    script_path=$(readlink -f "$0")
    # Usar /etc/cron.d (formato correcto: incluye usuario root)
    dry mkdir -p /etc/cron.d
    dry bash -c "echo '*/5 * * * * root bash ${script_path} watchdog >/dev/null 2>&1' > /etc/cron.d/wg-multihop" 2>/dev/null || {
        # Fallback: crontab de root (SIN columna usuario)
        dry bash -c "(crontab -l 2>/dev/null; echo '*/5 * * * * bash ${script_path} watchdog >/dev/null 2>&1') | crontab -" 2>/dev/null || true
    }
    log "Watchdog instalado cada 5 minutos"
}

# ============================================================================
# Internas — clientes
# ============================================================================

__get_next_ip() {
    local base="10.8.0"
    local last=2
    if [[ -f "${WG_DIR}/wg0.conf" ]]; then
        last=$(grep -oP 'AllowedIPs = \K10\.8\.0\.\d+' "${WG_DIR}/wg0.conf" 2>/dev/null | \
               grep -oP '\d+$' | sort -n | tail -1 || echo "2")
    fi
    echo "${base}.$((last + 1))/32"
}

__add_peer_to_wg0() {
    local name="$1" pub="$2" ip="$3"
    # Remover peer existente del mismo nombre
    __remove_peer_from_wg0 "$name" 2>/dev/null || true
    cat >> "${WG_DIR}/wg0.conf" << EOF

# ${name}
[Peer]
PublicKey = ${pub}
AllowedIPs = ${ip}
EOF
    dry wg syncconf wg0 <(wg-quick strip "${WG_DIR}/wg0.conf" 2>/dev/null) 2>/dev/null || \
        dry wg addconf wg0 <(echo "[Peer]" ; echo "PublicKey = ${pub}" ; echo "AllowedIPs = ${ip}") 2>/dev/null || \
        log "wg0 recargado"
}

__remove_peer_from_wg0() {
    local name="$1"
    if [[ -f "${WG_DIR}/wg0.conf" ]]; then
        dry sed -i "/^# ${name}$/,/^$/d" "${WG_DIR}/wg0.conf" 2>/dev/null || true
    fi
    # También intentar remover por IP si la tenemos
    dry wg set wg0 peer "$name" remove 2>/dev/null || true
}

# ============================================================================
# Modos de comando
# ============================================================================

cmd_install() {
    check_root
    echo ""
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║   WireGuard Multihop Installer      ║"
    echo "  ╚══════════════════════════════════════╝"
    echo ""

    local WAN_IFACE
    local MULTIHOP_ENABLE="${MULTIHOP_ENABLE:-n}"
    local WD_ENABLE="${WD_ENABLE:-y}"
    local SS_CITY WG1_ENDPOINT SS_PUB WG1_VPS_IP

    # Detectar WAN
    WAN_IFACE="${WAN_IFACE:-$(__detect_wan)}"
    prompt WAN_IFACE "Interfaz WAN (detectada: ${WAN_IFACE})" "$WAN_IFACE"

    prompt WG_PORT "Puerto WireGuard" "$WG_PORT"

    prompt MULTIHOP_ENABLE "Habilitar multihop (salida por Surfshark)" "n"
    [[ "$MULTIHOP_ENABLE" =~ ^[Yy] ]] && MULTIHOP_ENABLE=1 || MULTIHOP_ENABLE=0

    if [[ "$MULTIHOP_ENABLE" == "1" ]]; then
        if [[ -f "$SURFSHARK_CONF" ]]; then
            info "Leyendo ${SURFSHARK_CONF}..."
            source "$SURFSHARK_CONF"
            WG1_VPS_IP="${WG1_VPS_IP:-10.2.0.2/32}"
        else
            [[ -z "${SS_CITY:-}" ]] && prompt SS_CITY "Ciudad Surfshark (usa-atl, usa-ny, usa-la)" "usa-atl"
            [[ -z "${WG1_ENDPOINT:-}" ]] && prompt WG1_ENDPOINT "Endpoint wg1 (IP:puerto)" ""
            [[ -z "${SS_PUB:-}" ]] && prompt SS_PUB "Public key del peer Surfshark" ""
            [[ -z "${WG1_VPS_IP:-}" ]] && prompt WG1_VPS_IP "IP interna wg1 (VPS)" "10.2.0.2/32"
        fi
    fi

    prompt WD_ENABLE "Configurar watchdog (auto-reparación cada 5 min)" "y"
    [[ "$WD_ENABLE" =~ ^[Yy] ]] && WD_ENABLE=1 || WD_ENABLE=0

    # Resumen
    echo ""
    log "Resumen de cambios:"
    log "  • WireGuard: wg0 en puerto ${WG_PORT}"
    log "  • Firewall: SSH + WG + ICMP, resto DROP"
    log "  • Multihop: $([ "$MULTIHOP_ENABLE" == "1" ] && echo "ON → Surfshark" || echo "OFF")"
    log "  • Anti-lockout: tabla mgmt (100)"
    log "  • Watchdog: $([ "$WD_ENABLE" == "1" ] && echo "cada 5 min via cron" || echo "OFF")"
    echo ""

    [[ "$BATCH" == "0" ]] && confirm "Aplicar cambios" "Y" || true

    # Ejecutar (wg1 ANTES que wg0, porque wg0 PostUp referencia wg1)
    __install_wireguard
    __install_firewall "$WAN_IFACE"
    __install_mgmt_routing
    if [[ "$MULTIHOP_ENABLE" == "1" ]]; then
        WG1_VPS_IP="${WG1_VPS_IP:-10.2.0.2/32}"
        __install_wg1 "${WG1_VPS_IP%/*}"
    fi
    __install_wg0
    [[ "$WD_ENABLE" == "1" ]] && __install_watchdog

    echo ""
    log "  Listo. Tu VPS es servidor WireGuard."
    log "  Para agregar clientes: bash $(basename "$0") add-client <nombre>"
    echo ""
}

cmd_add_client() {
    check_root
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        err "Uso: $0 add-client <nombre>"
        exit 1
    fi
    if [[ ! -f "${WG_DIR}/wg0.conf" ]]; then
        err "wg0.conf no existe. Ejecute 'install' primero."
        exit 1
    fi

    log "Generando claves para ${name}..."
    local priv pub ip
    priv=$(wg genkey)
    pub=$(echo "$priv" | wg pubkey)
    ip=$(__get_next_ip)

    log "IP asignada: ${ip%/*}"
    __add_peer_to_wg0 "$name" "$pub" "$ip"

    # Generar .conf
    local server_pub wan_endpoint
    server_pub=$(cat "${WG_DIR}/vps_public.key")
    wan_endpoint=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+' | head -1 || echo "0.0.0.0")

    dry mkdir -p "$CLIENT_DIR"
    cat > "${CLIENT_DIR}/${name}.conf" << EOF
[Interface]
PrivateKey = ${priv}
Address = ${ip}
DNS = 8.8.8.8, 1.1.1.1
MTU = 1380

[Peer]
PublicKey = ${server_pub}
Endpoint = ${wan_endpoint}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    log "Configuración: ${CLIENT_DIR}/${name}.conf"
    if command -v qrencode &>/dev/null; then
        log "QR Code (escanea con la app WireGuard):"
        dry qrencode -t ansiutf8 < "${CLIENT_DIR}/${name}.conf" 2>/dev/null || true
    fi
}

cmd_remove_client() {
    check_root
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        err "Uso: $0 remove-client <nombre>"
        exit 1
    fi
    log "Eliminando cliente ${name}..."
    __remove_peer_from_wg0 "$name"
    dry rm -f "${CLIENT_DIR}/${name}.conf"
    log "Cliente ${name} eliminado"
}

cmd_list_clients() {
    if [[ ! -f "${WG_DIR}/wg0.conf" ]]; then
        err "wg0.conf no existe"
        exit 1
    fi
    echo ""
    title "Clientes configurados"
    grep -B1 "^AllowedIPs" "${WG_DIR}/wg0.conf" 2>/dev/null | grep -v "^--" | \
        sed 's/# //' | sed 's/AllowedIPs = //' | paste - - | \
        awk '{ printf "  %-20s %s\n", $1, $2 }' || echo "  (ninguno)"
    echo ""

    if command -v wg &>/dev/null && wg show wg0 &>/dev/null 2>&1; then
        title "Peers activos (handshake)"
        wg show wg0 latest-handshakes | awk '{
            if ($2 > 0) printf "  %s → %d s ago\n", $1, systime() - $2
            else printf "  %s → sin handshake\n", $1
        }' 2>/dev/null || echo "  (no se pudo leer)"
    fi
}

cmd_multihop() {
    check_root
    local action="${1:-toggle}"
    local current=""
    [[ -f "$MULTIHOP_STATE" ]] && current=$(cat "$MULTIHOP_STATE")

    if [[ "$action" == "on" ]]; then
        [[ "$current" == "ON" ]] && { info "Multihop ya está ON"; exit 0; }
        log "Activando multihop..."
        local peer
        peer=$(wg show wg1 peers 2>/dev/null | head -1)
        if [[ -z "$peer" ]]; then
            err "wg1 no está configurado. Ejecute 'install' primero."
            exit 1
        fi
        # Quitar ruta directa por WAN (si existe)
        local wan gw
        wan=$(__detect_wan)
        gw=$(ip route show default 2>/dev/null | grep -oP 'via \K\S+' | head -1 || echo "")
        if [[ -n "$gw" ]]; then
            dry ip route del default via "$gw" dev "$wan" table wg_clients 2>/dev/null || true
            dry iptables -t nat -D POSTROUTING -o "$wan" -j MASQUERADE 2>/dev/null || true
        fi
        # Activar wg1 + MASQUERADE
        dry wg-quick up "${WG_DIR}/wg1.conf" 2>/dev/null || true
        dry wg set wg1 peer "$peer" endpoint "$(grep -oP 'Endpoint = \K\S+' "${WG_DIR}/wg1.conf" 2>/dev/null)" 2>/dev/null || true
        dry ip route add default dev wg1 table wg_clients 2>/dev/null || true
        dry iptables -t nat -A POSTROUTING -o wg1 -j MASQUERADE 2>/dev/null || true
        echo "ON" > "$MULTIHOP_STATE"
        log "Multihop activado — tráfico de clientes sale por Surfshark"
    elif [[ "$action" == "off" ]]; then
        [[ "$current" == "OFF" ]] && { info "Multihop ya está OFF"; exit 0; }
        log "Desactivando multihop..."
        local wan gw
        wan=$(__detect_wan)
        gw=$(ip route show default 2>/dev/null | grep -oP 'via \K\S+' | head -1 || echo "")
        # Quitar MASQUERADE de wg1 + cambiar ruta a WAN directa
        dry iptables -t nat -D POSTROUTING -o wg1 -j MASQUERADE 2>/dev/null || true
        dry wg-quick down "${WG_DIR}/wg1.conf" 2>/dev/null || true
        if [[ -n "$gw" ]]; then
            dry ip route replace default via "$gw" dev "$wan" table wg_clients 2>/dev/null || \
                dry ip route add default via "$gw" dev "$wan" table wg_clients 2>/dev/null || true
            dry iptables -t nat -A POSTROUTING -o "$wan" -j MASQUERADE 2>/dev/null || true
            echo "OFF" > "$MULTIHOP_STATE"
            log "Multihop desactivado — tráfico de clientes sale por IP directa del VPS (${wan})"
        else
            warn "No se detectó gateway WAN — clientes sin internet"
            echo "OFF" > "$MULTIHOP_STATE"
        fi
    else
        # toggle
        if [[ "$current" == "ON" ]]; then
            cmd_multihop off
        else
            cmd_multihop on
        fi
    fi
}

cmd_status() {
    echo ""
    title "WireGuard Multihop — Dashboard"
    # Multihop state
    local mh="OFF"
    [[ -f "$MULTIHOP_STATE" ]] && mh=$(cat "$MULTIHOP_STATE")
    echo -e "  Multihop:     $([ "$mh" == "ON" ] && echo -e "${GREEN}ON${NC}" || echo -e "${YELLOW}OFF${NC}")"
    echo ""

    # WG interfaces
    for iface in wg0 wg1; do
        if wg show "$iface" &>/dev/null 2>&1; then
            title "${iface}"
            wg show "$iface" 2>/dev/null | head -6 | sed 's/^/  /'
        fi
    done

    # Firewall
    title "Firewall (FORWARD)"
    iptables -L FORWARD -v -n 2>/dev/null | head -5 | sed 's/^/  /'

    title "NAT (MASQUERADE)"
    iptables -t nat -L POSTROUTING -v -n 2>/dev/null | head -5 | sed 's/^/  /'

    # Sistema
    local mem mem_total
    mem=$(free -m | awk '/Mem:/{print $4}')
    mem_total=$(free -m | awk '/Mem:/{print $2}')
    echo ""
    info "RAM libre: ${mem}/${mem_total} MB"
    info "Disk: $(df -h / | awk 'NR==2{print $4}') libre de $(df -h / | awk 'NR==2{print $2}')"
    echo ""
}

cmd_watchdog() {
    # Silent — corre cada 5 min desde cron, solo logea si repara algo
    local logfile="/var/log/wg-watchdog.log"
    local fixed=0

    # 1. wg0
    if ! wg show wg0 &>/dev/null 2>&1; then
        echo "[$(date)] wg0 caído — reiniciando" >> "$logfile"
        wg-quick up "${WG_DIR}/wg0.conf" 2>/dev/null && fixed=1
    fi

    # 2. wg1 si multihop ON
    if [[ -f "$MULTIHOP_STATE" ]] && [[ "$(cat "$MULTIHOP_STATE")" == "ON" ]]; then
        if ! wg show wg1 &>/dev/null 2>&1; then
            echo "[$(date)] wg1 caído — reiniciando" >> "$logfile"
            wg-quick up "${WG_DIR}/wg1.conf" 2>/dev/null && fixed=1
        else
            local handshake
            handshake=$(wg show wg1 latest-handshakes | awk '{print $2}')
            if [[ -n "$handshake" ]] && [[ "$handshake" -gt 0 ]]; then
                local now
                now=$(date +%s)
                if [[ $((now - handshake)) -gt 180 ]]; then
                    echo "[$(date)] wg1 handshake >180s — reiniciando peer" >> "$logfile"
                    wg-quick down "${WG_DIR}/wg1.conf" 2>/dev/null
                    sleep 1
                    wg-quick up "${WG_DIR}/wg1.conf" 2>/dev/null && fixed=1
                fi
            fi
        fi
    fi

    # 3. Mgmt table
    local wan_ip gw
    wan_ip=$(__detect_ip "$(__detect_wan)" | cut -d/ -f1)
    gw=$(ip route show default 2>/dev/null | grep -oP 'via \K\S+' | head -1 || echo "")
    if [[ -n "$gw" && "$wan_ip" != "0.0.0.0" ]]; then
        if ! ip rule show 2>/dev/null | grep -q "from ${wan_ip}.*table mgmt"; then
            echo "[$(date)] mgmt rule faltante — restaurando" >> "$logfile"
            ip route add default via "$gw" dev "$(__detect_wan)" table mgmt 2>/dev/null || true
            ip rule add from "$wan_ip" table mgmt priority 100 2>/dev/null || true
            fixed=1
        fi
        if ! ip route show table mgmt 2>/dev/null | grep -q default; then
            echo "[$(date)] mgmt route faltante — restaurando" >> "$logfile"
            ip route add default via "$gw" dev "$(__detect_wan)" table mgmt 2>/dev/null || true
            fixed=1
        fi
    fi

    # 4. FORWARD rules
    if ! iptables -L FORWARD -v -n 2>/dev/null | grep -q "wg0.*wg1"; then
        echo "[$(date)] FORWARD wg0→wg1 faltante — restaurando" >> "$logfile"
        iptables -A FORWARD -i wg0 -o wg1 -j ACCEPT 2>/dev/null || true
        iptables -A FORWARD -i wg1 -o wg0 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
        iptables -t nat -A POSTROUTING -o wg1 -j MASQUERADE 2>/dev/null || true
        fixed=1
    fi

    # 5. RAM
    local mem
    mem=$(free -m | awk '/Mem:/{print $4}')
    if [[ "$mem" -lt 50 ]]; then
        echo "[$(date)] RAM baja: ${mem}MB — limpiando caché" >> "$logfile"
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
        fixed=1
    fi

    [[ "$fixed" == "1" ]] && echo "[$(date)] Watchdog: reparación aplicada" >> "$logfile"
}

cmd_uninstall() {
    check_root
    title "Desinstalando WireGuard Multihop"
    confirm "¿Está seguro? Esto eliminará toda la configuración de WG, reglas iptables, y rutas" "n" || { info "Cancelado"; exit 0; }

    log "Deteniendo WireGuard..."
    dry wg-quick down "${WG_DIR}/wg0.conf" 2>/dev/null || true
    dry wg-quick down "${WG_DIR}/wg1.conf" 2>/dev/null || true

    log "Limpiando reglas iptables..."
    dry iptables -P INPUT ACCEPT 2>/dev/null || true
    dry iptables -P FORWARD ACCEPT 2>/dev/null || true
    dry iptables -P OUTPUT ACCEPT 2>/dev/null || true
    dry iptables -F 2>/dev/null || true
    dry iptables -t nat -F 2>/dev/null || true
    dry iptables -t mangle -F 2>/dev/null || true

    log "Eliminando reglas de ruteo..."
    dry ip rule del from 10.8.0.0/24 table wg_clients 2>/dev/null || true
    dry ip rule del from "$(__detect_ip "$(__detect_wan)" | cut -d/ -f1)" table mgmt 2>/dev/null || true
    dry ip route flush table wg_clients 2>/dev/null || true
    dry ip route flush table mgmt 2>/dev/null || true

    log "Eliminando archivos..."
    dry rm -f "${WG_DIR}/wg0.conf" "${WG_DIR}/wg1.conf" 2>/dev/null || true
    dry rm -f "$MULTIHOP_STATE" 2>/dev/null || true

    log "Eliminando cron..."
    dry crontab -l 2>/dev/null | grep -v "wg-multihop.sh" | crontab - 2>/dev/null || true
    dry rm -f /etc/cron.d/wg-multihop 2>/dev/null || true

    log "WireGuard Multihop desinstalado"
}

# ============================================================================
# Test en namespaces aislados
# ============================================================================

cmd_test() {
    check_root
    local TMPDIR="/tmp/wg-multihop-test"
    local NS_VPS="wgtest-mh-vps"
    local NS_CLIENT="wgtest-mh-client"
    local NS_SS="wgtest-mh-ss"
    local VETH_V="mh-veth-v"
    local VETH_C="mh-veth-c"
    local VETH_V2="mh-veth-v2"
    local VETH_S="mh-veth-s"
    local WG_PORT="${WG_PORT:-51820}"
    local failed=0 passed=0

    echo ""
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║   wg-multihop.sh — Self Test        ║"
    echo "  ╚══════════════════════════════════════╝"
    echo ""

    # Limpiar cualquier residuo
    for ns in "$NS_CLIENT" "$NS_VPS" "$NS_SS"; do
        if ip netns list 2>/dev/null | grep -q "$ns"; then
            ip netns exec "$ns" wg-quick down wg0 2>/dev/null || true
            ip netns exec "$ns" wg-quick down wg1 2>/dev/null || true
            ip netns del "$ns" 2>/dev/null || true
        fi
    done
    for v in "$VETH_C" "$VETH_V" "$VETH_V2" "$VETH_S"; do
        ip link del "$v" 2>/dev/null || true
    done
    rm -rf "$TMPDIR"
    mkdir -p "$TMPDIR"

    # --- Crear namespaces ---
    echo "  [lab] Creando namespaces..."
    ip netns add "$NS_CLIENT"
    ip netns add "$NS_VPS"
    ip netns add "$NS_SS"

    # --- Veth pairs ---
    ip link add "$VETH_C" type veth peer name "$VETH_V"
    ip link set "$VETH_C" netns "$NS_CLIENT"
    ip link set "$VETH_V" netns "$NS_VPS"

    ip link add "$VETH_V2" type veth peer name "$VETH_S"
    ip link set "$VETH_V2" netns "$NS_VPS"
    ip link set "$VETH_S" netns "$NS_SS"

    # --- IPs ---
    ip netns exec "$NS_CLIENT" ip addr add "10.99.0.2/24" dev "$VETH_C"
    ip netns exec "$NS_CLIENT" ip link set "$VETH_C" up
    ip netns exec "$NS_CLIENT" ip link set lo up

    ip netns exec "$NS_VPS" ip addr add "10.99.0.1/24" dev "$VETH_V"
    ip netns exec "$NS_VPS" ip link set "$VETH_V" up
    ip netns exec "$NS_VPS" ip addr add "10.99.1.1/24" dev "$VETH_V2"
    ip netns exec "$NS_VPS" ip link set "$VETH_V2" up
    ip netns exec "$NS_VPS" ip link set lo up

    ip netns exec "$NS_SS" ip addr add "10.99.1.2/24" dev "$VETH_S"
    ip netns exec "$NS_SS" ip link set "$VETH_S" up
    ip netns exec "$NS_SS" ip link set lo up

    # --- Rutas entre namespaces ---
    ip netns exec "$NS_CLIENT" ip route replace 10.99.1.0/24 via 10.99.0.1
    ip netns exec "$NS_VPS" ip route replace 10.99.0.0/24 dev "$VETH_V"
    ip netns exec "$NS_VPS" ip route replace 10.99.1.0/24 dev "$VETH_V2"
    ip netns exec "$NS_SS" ip route replace 10.99.0.0/24 via 10.99.1.1

    # --- Generar claves Surfshark simulado ---
    echo "  [lab] Generando claves SS simuladas..."
    local ss_priv ss_pub vps_priv vps_pub
    ss_priv=$(wg genkey); ss_pub=$(echo "$ss_priv" | wg pubkey)

    # Generar VPS keys
    vps_priv=$(wg genkey); vps_pub=$(echo "$vps_priv" | wg pubkey)

    # Crear WG_DIR de prueba
    local WG_TEST_DIR="${TMPDIR}/vps-etc/wireguard"
    mkdir -p "$WG_TEST_DIR"
    echo "$vps_priv" > "$WG_TEST_DIR/vps_private.key"
    echo "$vps_pub" > "$WG_TEST_DIR/vps_public.key"

    # Iniciar Surfshark simulado (wg1 peer)
    echo "  [lab] Iniciando Surfshark simulado..."
    cat > "$TMPDIR/ss-wg1.conf" << EOF
[Interface]
PrivateKey = ${ss_priv}
Address = 10.2.0.1/32
ListenPort = ${WG_PORT}
MTU = 1320

[Peer]
PublicKey = ${vps_pub}
AllowedIPs = 0.0.0.0/0
EOF

    ip netns exec "$NS_SS" wg-quick up "$TMPDIR/ss-wg1.conf" 2>&1 | grep -v "Warning:" || true

    # --- Test 1: VPS reachability ---
    echo ""
    echo -n "  T1 - VPS → SS (veth): "
    if ip netns exec "$NS_VPS" ping -c 1 -W 2 10.99.1.2 &>/dev/null; then
        echo "OK"; passed=$((passed+1))
    else
        echo "FAIL"; failed=$((failed+1))
    fi

    echo -n "  T2 - Client → VPS (veth): "
    if ip netns exec "$NS_CLIENT" ping -c 1 -W 2 10.99.0.1 &>/dev/null; then
        echo "OK"; passed=$((passed+1))
    else
        echo "FAIL"; failed=$((failed+1))
    fi

    # --- Instalar wg-multihop dentro del VPS namespace ---
    echo ""
    echo "  [lab] Instalando wg-multihop en VPS namespace..."
    local SCRIPT_PATH
    SCRIPT_PATH=$(readlink -f "$0")
    cp "$SCRIPT_PATH" "$TMPDIR/wg-multihop.sh"
    chmod +x "$TMPDIR/wg-multihop.sh"

    # Preparar surfshark.conf para el VPS
    cat > "$TMPDIR/surfshark-test.conf" << EOF
WG1_ENDPOINT="10.99.1.2:${WG_PORT}"
SS_PUB="${ss_pub}"
WG1_VPS_IP="10.2.0.2/32"
EOF

    # Ejecutar install dentro del VPS namespace con variables de entorno
    local install_ok=1
    # Las variables de entorno fluyen al bash -c del ip netns exec
    export -p | grep -E "^(declare -x )?WG_" > /dev/null 2>&1 || true
    local install_out
    install_out=$(ip netns exec "$NS_VPS" env \
        BATCH=1 \
        WG_PORT="${WG_PORT}" \
        WG_DIR="${WG_TEST_DIR}" \
        CLIENT_DIR="${WG_TEST_DIR}/clients" \
        MULTIHOP_STATE="${WG_TEST_DIR}/.multihop_state" \
        SURFSHARK_CONF="${TMPDIR}/surfshark-test.conf" \
        WAN_IFACE="${VETH_V2}" \
        WG1_ENDPOINT="10.99.1.2:${WG_PORT}" \
        SS_PUB="${ss_pub}" \
        WG1_VPS_IP="10.2.0.2/32" \
        MULTIHOP_ENABLE="y" \
        WD_ENABLE="y" \
        bash "${TMPDIR}/wg-multihop.sh" install 2>&1) || install_ok=0
    echo "$install_out" | grep -E "(\[\+|\[!|\[x|\[i|error)" || true
    echo "$install_out" | grep "Listo" && { echo -n "  T3 - Install en VPS: "; echo "OK"; passed=$((passed+1)); } || { echo -n "  T3 - Install en VPS: "; echo "FAIL"; failed=$((failed+1)); }

    # --- Test 4: Handshake wg1 ---
    echo -n "  T4 - Handshake wg1 (VPS↔SS): "
    local peer_hs
    peer_hs=$(ip netns exec "$NS_VPS" wg show wg1 2>/dev/null | grep "latest handshake" | awk '{print $3, $4}' || echo "")
    if [[ -n "$peer_hs" ]]; then
        echo "OK (${peer_hs})"; passed=$((passed+1))
    else
        # Forzar handshake
        local p peer
        peer=$(ip netns exec "$NS_VPS" wg show wg1 peers 2>/dev/null | head -1)
        if [[ -n "$peer" ]]; then
            ip netns exec "$NS_VPS" wg set wg1 peer "$peer" endpoint "10.99.1.2:${WG_PORT}" 2>/dev/null || true
            sleep 2
            peer_hs=$(ip netns exec "$NS_VPS" wg show wg1 2>/dev/null | grep "latest handshake" | awk '{print $3, $4}' || echo "")
            if [[ -n "$peer_hs" ]]; then
                echo "OK (${peer_hs})"; passed=$((passed+1))
            else
                echo "FAIL"; failed=$((failed+1))
            fi
        else
            echo "FAIL (sin peer)"; failed=$((failed+1))
        fi
    fi

    # --- Test 5: Cliente en namespace puede llegar a SS vía wg0+wg1 ---
    echo -n "  T5 - Client→SS (wg0+wg1): "
    local client_priv client_pub server_pub
    client_priv=$(wg genkey); client_pub=$(echo "$client_priv" | wg pubkey)
    server_pub=$(cat "$WG_TEST_DIR/vps_public.key" 2>/dev/null || echo "")

    # Agregar peer al VPS wg0
    ip netns exec "$NS_VPS" wg set wg0 peer "${client_pub}" allowed-ips 10.8.0.2/32 2>/dev/null || true
    local client_wg0="${TMPDIR}/mh-client-wg0.conf"
    cat > "$client_wg0" << EOF
[Interface]
PrivateKey = ${client_priv}
Address = 10.8.0.2/24
MTU = 1380

[Peer]
PublicKey = ${server_pub}
Endpoint = 10.99.0.1:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 5
EOF
    ip netns exec "$NS_CLIENT" wg-quick up "$client_wg0" 2>&1 | grep -v "Warning:" || true
    sleep 2
    if ip netns exec "$NS_CLIENT" ping -c 1 -W 3 10.2.0.1 &>/dev/null; then
        echo "OK"; passed=$((passed+1))
    else
        echo "FAIL"; failed=$((failed+1))
    fi

    # --- Test 6: Tabla wg_clients ---
    echo -n "  T6 - Tabla wg_clients: "
    if ip netns exec "$NS_VPS" ip route show table wg_clients 2>/dev/null | grep -q "default"; then
        echo "OK"; passed=$((passed+1))
    else
        echo "FAIL"; failed=$((failed+1))
    fi

    # --- Test 7: Blackhole ---
    echo -n "  T7 - Kill switch (blackhole): "
    if ip netns exec "$NS_VPS" ip route show table wg_clients 2>/dev/null | grep -q "blackhole"; then
        echo "OK"; passed=$((passed+1))
    else
        echo "FAIL"; failed=$((failed+1))
    fi

    # --- Test 8: NAT MASQUERADE ---
    echo -n "  T8 - NAT MASQUERADE: "
    if ip netns exec "$NS_VPS" iptables -t nat -L POSTROUTING 2>/dev/null | grep -q "MASQUERADE"; then
        echo "OK"; passed=$((passed+1))
    else
        echo "FAIL"; failed=$((failed+1))
    fi

    # --- Test 9: Anti-lockout mgmt ---
    echo -n "  T9 - Anti-lockout (mgmt table): "
    if ip netns exec "$NS_VPS" grep -q "100 mgmt" /etc/iproute2/rt_tables 2>/dev/null; then
        echo "OK"; passed=$((passed+1))
    else
        echo "FAIL"; failed=$((failed+1))
    fi

    # --- Test 10: FORWARD rules ---
    echo -n "  T10 - FORWARD wg0→wg1: "
    if ip netns exec "$NS_VPS" iptables -L FORWARD -v -n 2>/dev/null | grep -q "wg0.*wg1"; then
        echo "OK"; passed=$((passed+1))
    else
        echo "FAIL"; failed=$((failed+1))
    fi

    # --- Test 11: add-client ---
    echo -n "  T11 - add-client test: "
    local add_out
    add_out=$(ip netns exec "$NS_VPS" env \
        WG_DIR="${WG_TEST_DIR}" \
        CLIENT_DIR="${WG_TEST_DIR}/clients" \
        bash "${TMPDIR}/wg-multihop.sh" add-client testclient 2>&1) || true
    if grep -q "testclient" "${WG_TEST_DIR}/wg0.conf" 2>/dev/null; then
        echo "OK"; passed=$((passed+1))
    else
        echo "FAIL"; failed=$((failed+1))
    fi

    # --- Test 12: remove-client ---
    echo -n "  T12 - remove-client test: "
    ip netns exec "$NS_VPS" env \
        WG_DIR="${WG_TEST_DIR}" \
        CLIENT_DIR="${WG_TEST_DIR}/clients" \
        bash "${TMPDIR}/wg-multihop.sh" remove-client testclient 2>&1 || true
    if ! grep -q "testclient" "${WG_TEST_DIR}/wg0.conf" 2>/dev/null; then
        echo "OK"; passed=$((passed+1))
    else
        echo "FAIL"; failed=$((failed+1))
    fi

    # --- Test 13: multihog toggle ---
    echo -n "  T13 - multihog toggle: "
    ip netns exec "$NS_VPS" env \
        WG_DIR="${WG_TEST_DIR}" \
        MULTIHOP_STATE="${WG_TEST_DIR}/.multihop_state" \
        bash "${TMPDIR}/wg-multihop.sh" multihog off 2>&1 || true
    local mh_state
    mh_state=$(cat "${WG_TEST_DIR}/.multihop_state" 2>/dev/null || echo "OFF")
    if [[ "$mh_state" == "OFF" ]]; then
        echo "OK"; passed=$((passed+1))
    else
        echo "FAIL"; failed=$((failed+1))
    fi

    # --- Test 14: status funciona ---
    echo -n "  T14 - status dashboard: "
    local t14_out
    t14_out=$(ip netns exec "$NS_VPS" env \
        WG_DIR="${WG_TEST_DIR}" \
        MULTIHOP_STATE="${WG_TEST_DIR}/.multihop_state" \
        bash "${TMPDIR}/wg-multihop.sh" status 2>&1) || true
    echo "$t14_out" | grep -q "Dashboard" && { echo "OK"; passed=$((passed+1)); } \
        || { echo "FAIL"; failed=$((failed+1)); }

    # --- Test 15: VPS traffic isolation (mgmt) ---
    echo -n "  T15 - Aislamiento VPS (sin default por WG): "
    local vps_default
    vps_default=$(ip netns exec "$NS_VPS" ip route show table main 2>/dev/null | grep "default" || echo "")
    if ! echo "$vps_default" | grep -q "wg"; then
        echo "OK${vps_default:+ (sin default)}"; passed=$((passed+1))
    else
        echo "FAIL"; failed=$((failed+1))
    fi

    # --- Cleanup ---
    echo ""
    echo "  [lab] Limpiando..."
    ip netns exec "$NS_CLIENT" wg-quick down "$client_wg0" 2>/dev/null || true
    ip netns exec "$NS_VPS" wg-quick down wg0 2>/dev/null || true
    ip netns exec "$NS_VPS" wg-quick down wg1 2>/dev/null || true
    ip netns exec "$NS_SS" wg-quick down wg1 2>/dev/null || true
    ip netns exec "$NS_SS" wg-quick down "$TMPDIR/ss-wg1.conf" 2>/dev/null || true
    for ns in "$NS_CLIENT" "$NS_VPS" "$NS_SS"; do
        ip netns del "$ns" 2>/dev/null || true
    done
    for v in "$VETH_C" "$VETH_V" "$VETH_V2" "$VETH_S"; do
        ip link del "$v" 2>/dev/null || true
    done
    rm -rf "$TMPDIR"

    # --- Results ---
    echo ""
    echo "  ═══════════════════════════════════════"
    if [[ "$failed" -eq 0 ]]; then
        echo "  ✅  TODOS LOS TESTS PASARON (${passed}/15)"
    else
        echo "  ❌  ${failed} FALLOS — ${passed}/15 PASADOS"
    fi
    echo "  ═══════════════════════════════════════"
    echo ""

    return $failed
}

# ============================================================================
# Main
# ============================================================================
main() {
    local mode="${1:-}"
    shift 2>/dev/null || true

    case "$mode" in
        install)
            cmd_install
            ;;
        add-client)
            cmd_add_client "${1:-}"
            ;;
        remove-client)
            cmd_remove_client "${1:-}"
            ;;
        list-clients)
            cmd_list_clients
            ;;
        multihog)
            cmd_multihop "${1:-toggle}"
            ;;
        status)
            check_root
            cmd_status
            ;;
        watchdog)
            check_root
            cmd_watchdog
            ;;
        uninstall)
            cmd_uninstall
            ;;
        test)
            cmd_test
            ;;
        *)
            echo ""
            echo "  WireGuard Multihop Toolbox"
            echo ""
            echo "  Uso: bash $0 <comando> [args]"
            echo ""
            echo "  Comandos:"
            echo "    install              Setup interactivo completo"
            echo "    add-client <nombre>  Agregar cliente"
            echo "    remove-client <nomb> Eliminar cliente"
            echo "    list-clients         Listar clientes"
            echo "    multihog [on|off]    Activar/desactivar salida por wg1"
            echo "    status               Dashboard de estado"
            echo "    watchdog             Auto-reparación (via cron)"
            echo "    uninstall            Revertir TODO"
            echo "    test                 Auto-test en namespaces"
            echo ""
            echo "  Variables de entorno:"
            echo "    DRY_RUN=1            Modo simulación (sin cambios reales)"
            echo "    BATCH=1              No interactivo (usa defaults)"
            echo "    WG_PORT=51820        Puerto WireGuard"
            echo ""
            ;;
    esac
}

main "$@"
