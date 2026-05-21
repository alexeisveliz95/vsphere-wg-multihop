#!/bin/bash
set -euo pipefail

# =============================================================================
# test-lab.sh - Entorno de pruebas aislado para vsphere-wg-multihop
#
# Simula 3 nodos en network namespaces separados:
#   [cliente] ──veth──▶ [vps] ──veth──▶ [surfshark]
#
# Todo es 100% aislado del sistema real. WireGuard dentro de namespaces.
# Uso:
#   test-lab.sh up          # Crear entorno
#   test-lab.sh test        # Ejecutar tests
#   test-lab.sh down        # Destruir entorno
#   test-lab.sh status      # Mostrar estado
#   DRY_RUN=1 test-lab.sh   # Modo simulacion
# =============================================================================

LAB_PREFIX="wgtest"
VETH_CS="veth-c"    # client side
VETH_VS="veth-v"    # vps side (to client)
VETH_VS2="veth-v2"  # vps side (to surfshark)
VETH_SS="veth-s"    # surfshark side

NS_CLIENT="${LAB_PREFIX}-client"
NS_VPS="${LAB_PREFIX}-vps"
NS_SS="${LAB_PREFIX}-surfshark"  # surfshark simulado

# IPs de enlace entre namespaces (red fisica virtual)
CLIENT_VETH_IP="10.99.0.2/24"
VPS_VETH_IP="10.99.0.1/24"
VPS_VETH2_IP="10.99.1.1/24"
SS_VETH_IP="10.99.1.2/24"

# WireGuard IPs
WG0_CLIENT_IP="10.8.0.2/24"
WG0_SERVER_IP="10.8.0.1/24"
WG1_VPS_IP="10.2.0.2/32"
WG1_SS_IP="10.2.0.1/32"

WG_PORT="51820"

TMPDIR="/tmp/wg-test-lab"

# --- Dry-run ---
dry_run() {
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "    [DRY-RUN] $*" >&2
        return 0
    fi
    "$@"
}

dry_run_bg() {
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "    [DRY-RUN] $* (background)" >&2
        return 0
    fi
    "$@" &
}

run_in_ns() {
    local ns="$1"; shift
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "    [DRY-RUN] ip netns exec ${ns} $*" >&2
        return 0
    fi
    ip netns exec "${ns}" "$@"
}

ns_add()    { dry_run ip netns add "$1"; }
ns_del()    { dry_run ip netns del "$1"; }
link_add()  { dry_run ip link add "$@"; }
link_set()  { dry_run ip link set "$@"; }
addr_add()  { dry_run ip addr add "$@"; }
route_add() { dry_run ip route add "$@"; }
sysctl_set(){ dry_run sysctl -w "$@"; }
wg_quick_up(){ dry_run wg-quick up "$@"; }
wg_genkey(){ 
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "    [DRY-RUN] wg genkey | tee ... | wg pubkey > ..." >&2
        echo "dry-run-simulated-key"
    else
        wg genkey
    fi
}

check_deps() {
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        return 0
    fi
    local missing=()
    for cmd in ip wg iptables; do
        if ! command -v "${cmd}" &>/dev/null; then
            missing+=("${cmd}")
        fi
    done
    if [[ ! -d /sys/module/wireguard ]] && ! lsmod 2>/dev/null | grep -q "^wireguard"; then
        missing+=("modulo wireguard (wireguard-dkms)")
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Faltan dependencias: ${missing[*]}"
        echo "Instale con: apt install -y wireguard iptables"
        exit 1
    fi
}

# ============================================================================
# up
# ============================================================================
cmd_up() {
    echo "==> Creando entorno de pruebas aislado..."

    check_deps

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo ""
        echo "  Resumen de lo que se creara:"
        echo "  - 3 namespaces: ${NS_CLIENT}, ${NS_VPS}, ${NS_SS}"
        echo "  - 2 veth pairs: client<->vps, vps<->surfshark"
        echo "  - WireGuard interfaces:"
        echo "      cliente: wg0 (10.8.0.2 -> VPS 10.99.0.1:${WG_PORT})"
        echo "      VPS:     wg0 (10.8.0.1 listen), wg1 (10.2.0.2 -> SS 10.99.1.2:${WG_PORT})"
        echo "      SS:      wg1 (10.2.0.1 listen)"
        echo "  - Routing: cliente -> wg0 -> VPS -> wg1 -> Surfshark"
        echo "  - iptables: FORWARD + NAT en VPS"
        echo ""
        return 0
    fi

    sleep 1  # Esperar a que el kernel libere recursos

    # 0. Limpieza forzada de cualquier residuo anterior
    for ns_file in /run/netns/${LAB_PREFIX}-*; do
        if [[ -f "${ns_file}" ]]; then
            umount "${ns_file}" 2>/dev/null || true
            rm -f "${ns_file}" 2>/dev/null || true
        fi
    done
    for ns_try in ${LAB_PREFIX}-client ${LAB_PREFIX}-vps ${LAB_PREFIX}-surfshark; do
        if [[ -f "/run/netns/${ns_try}" ]]; then
            umount "/run/netns/${ns_try}" 2>/dev/null || true
            rm -f "/run/netns/${ns_try}" 2>/dev/null || true
        fi
        ip netns del "${ns_try}" 2>/dev/null || true
    done
    for veth_file in veth-c veth-v veth-v2 veth-s wg0 wg1; do
        ip link del "${veth_file}" 2>/dev/null || true
    done
    rm -rf "${TMPDIR}"
    mkdir -p "${TMPDIR}"

    # 1. Crear namespaces
    echo "    Creando namespaces..."
    ns_add "${NS_CLIENT}"
    ns_add "${NS_VPS}"
    ns_add "${NS_SS}"

    # 2. Veth: client <-> vps
    echo "    Creando enlaces veth..."
    link_add "${VETH_CS}" type veth peer name "${VETH_VS}"
    link_set "${VETH_CS}" netns "${NS_CLIENT}"
    link_set "${VETH_VS}" netns "${NS_VPS}"

    # 3. Veth: vps <-> surfshark
    link_add "${VETH_VS2}" type veth peer name "${VETH_SS}"
    link_set "${VETH_VS2}" netns "${NS_VPS}"
    link_set "${VETH_SS}" netns "${NS_SS}"

    # 4. Asignar IPs y levantar interfaces
    run_in_ns "${NS_CLIENT}" ip addr add "${CLIENT_VETH_IP}" dev "${VETH_CS}"
    run_in_ns "${NS_CLIENT}" ip link set "${VETH_CS}" up
    run_in_ns "${NS_CLIENT}" ip link set lo up

    run_in_ns "${NS_VPS}" ip addr add "${VPS_VETH_IP}" dev "${VETH_VS}"
    run_in_ns "${NS_VPS}" ip link set "${VETH_VS}" up
    run_in_ns "${NS_VPS}" ip addr add "${VPS_VETH2_IP}" dev "${VETH_VS2}"
    run_in_ns "${NS_VPS}" ip link set "${VETH_VS2}" up
    run_in_ns "${NS_VPS}" ip link set lo up

    run_in_ns "${NS_SS}" ip addr add "${SS_VETH_IP}" dev "${VETH_SS}"
    run_in_ns "${NS_SS}" ip link set "${VETH_SS}" up
    run_in_ns "${NS_SS}" ip link set lo up

    # 5. Agregar rutas entre namespaces (replace para evitar "File exists")
    run_in_ns "${NS_CLIENT}" ip route replace 10.99.1.0/24 via 10.99.0.1
    run_in_ns "${NS_VPS}" ip route replace 10.99.0.0/24 dev "${VETH_VS}"
    run_in_ns "${NS_VPS}" ip route replace 10.99.1.0/24 dev "${VETH_VS2}"
    run_in_ns "${NS_SS}" ip route replace 10.99.0.0/24 via 10.99.1.1

    # 6. Habilitar IP forwarding en VPS
    run_in_ns "${NS_VPS}" sysctl -w net.ipv4.ip_forward=1 >/dev/null

    # 7. Generar claves
    echo "    Generando claves..."
    wg genkey | tee "${TMPDIR}/vps_private.key" | wg pubkey > "${TMPDIR}/vps_public.key"
    wg genkey | tee "${TMPDIR}/client_private.key" | wg pubkey > "${TMPDIR}/client_public.key"
    wg genkey | tee "${TMPDIR}/ss_private.key" | wg pubkey > "${TMPDIR}/ss_public.key"

    VPS_PRIV=$(cat "${TMPDIR}/vps_private.key")
    VPS_PUB=$(cat "${TMPDIR}/vps_public.key")
    CLIENT_PRIV=$(cat "${TMPDIR}/client_private.key")
    CLIENT_PUB=$(cat "${TMPDIR}/client_public.key")
    SS_PRIV=$(cat "${TMPDIR}/ss_private.key")
    SS_PUB=$(cat "${TMPDIR}/ss_public.key")

    # 8. Configurar archivos de configuracion
    run_in_ns "${NS_VPS}" wg genkey > /dev/null  # carga modulo si no existe
    mkdir -p "${TMPDIR}/vps"
    cat > "${TMPDIR}/vps/wg1.conf" << EOF
[Interface]
PrivateKey = ${VPS_PRIV}
Address = ${WG1_VPS_IP}
MTU = 1320
Table = off

[Peer]
PublicKey = ${SS_PUB}
Endpoint = 10.99.1.2:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 5
EOF

    mkdir -p "${TMPDIR}/ss"
    cat > "${TMPDIR}/ss/wg1.conf" << EOF
[Interface]
PrivateKey = ${SS_PRIV}
Address = ${WG1_SS_IP}
ListenPort = ${WG_PORT}
MTU = 1320

[Peer]
PublicKey = ${VPS_PUB}
AllowedIPs = 0.0.0.0/0
EOF

    # 9. Levantar Surfshark wg1 PRIMERO (para que VPS encuentre el peer al conectar)
    echo "    Configurando Surfshark simulado..."
    run_in_ns "${NS_SS}" wg-quick up "${TMPDIR}/ss/wg1.conf" 2>&1

    # 10. Levantar VPS wg1 (Surfshark ya esta escuchando)
    echo "    Configurando wg1 (VPS -> Surfshark)..."
    run_in_ns "${NS_VPS}" wg-quick up "${TMPDIR}/vps/wg1.conf" 2>&1

    # 11. Configurar wg0 (VPS server) - incluye peer del cliente
    echo "    Configurando wg0 (VPS server)..."
    cat > "${TMPDIR}/vps/wg0.conf" << EOF
[Interface]
PrivateKey = ${VPS_PRIV}
Address = ${WG0_SERVER_IP}
ListenPort = ${WG_PORT}
MTU = 1420
Table = off

PostUp = ip rule add from 10.8.0.0/24 table wg_clients priority 200 2>/dev/null
PostUp = ip route add default dev wg1 table wg_clients 2>/dev/null
PostUp = ip route add 10.8.0.0/24 dev wg0 table wg_clients 2>/dev/null
PostUp = ip route add blackhole 0.0.0.0/0 table wg_clients metric 999
PostUp = iptables -A FORWARD -i wg0 -o wg1 -j ACCEPT 2>/dev/null
PostUp = iptables -A FORWARD -i wg1 -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
PostUp = iptables -t nat -A POSTROUTING -o wg1 -j MASQUERADE 2>/dev/null

PostDown = ip rule del from 10.8.0.0/24 table wg_clients 2>/dev/null
PostDown = ip route flush table wg_clients 2>/dev/null
PostDown = iptables -D FORWARD -i wg0 -o wg1 -j ACCEPT 2>/dev/null
PostDown = iptables -D FORWARD -i wg1 -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
PostDown = iptables -t nat -D POSTROUTING -o wg1 -j MASQUERADE 2>/dev/null

# Cliente de prueba
[Peer]
PublicKey = ${CLIENT_PUB}
AllowedIPs = 10.8.0.2/32
EOF

    # Crear tabla de ruteo auxiliar dentro del VPS (ANTES de wg-quick up, PostUp la necesita)
    run_in_ns "${NS_VPS}" bash -c 'grep -qxF "200 wg_clients" /etc/iproute2/rt_tables 2>/dev/null || echo "200 wg_clients" >> /etc/iproute2/rt_tables'

    run_in_ns "${NS_VPS}" wg-quick up "${TMPDIR}/vps/wg0.conf" 2>&1

    # 12. Configurar wg0 cliente
    echo "    Configurando cliente WireGuard..."
    mkdir -p "${TMPDIR}/client"
    cat > "${TMPDIR}/client/wg0.conf" << EOF
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address = ${WG0_CLIENT_IP}
MTU = 1380

[Peer]
PublicKey = ${VPS_PUB}
Endpoint = 10.99.0.1:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 5
EOF

    run_in_ns "${NS_CLIENT}" wg-quick up "${TMPDIR}/client/wg0.conf" 2>&1

    # Esperar handshakes WireGuard
    sleep 3

    echo ""
    echo "==> Entorno de pruebas creado exitosamente"
    echo ""
    echo "  Nodos:"
    echo "    ${NS_CLIENT}   (cliente)"
    echo "    ${NS_VPS}      (servidor)"
    echo "    ${NS_SS}       (Surfshark simulado)"
    echo ""
    echo "  Para probar: ./test-lab.sh test"
    echo "  Para destruir: ./test-lab.sh down"
}

# ============================================================================
# down
# ============================================================================
cmd_down() {
    echo "==> Destruyendo entorno de pruebas..."

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "    [DRY-RUN] Se eliminarian: 3 namespaces, 4 veths, ${TMPDIR}"
        return 0
    fi

    # Bajar interfaces WG dentro de namespaces
    for ns in "${NS_VPS}" "${NS_CLIENT}" "${NS_SS}"; do
        if ip netns list | grep -q "${ns}"; then
            ip netns exec "${ns}" wg-quick down wg0 2>/dev/null || true
            ip netns exec "${ns}" wg-quick down wg1 2>/dev/null || true
            ip netns exec "${ns}" wg-quick down "${TMPDIR}/vps/wg0.conf" 2>/dev/null || true
            ip netns exec "${ns}" wg-quick down "${TMPDIR}/vps/wg1.conf" 2>/dev/null || true
            ip netns exec "${ns}" wg-quick down "${TMPDIR}/client/wg0.conf" 2>/dev/null || true
            ip netns exec "${ns}" wg-quick down "${TMPDIR}/ss/wg1.conf" 2>/dev/null || true
        fi
    done

    # Eliminar namespaces
    for ns in "${NS_CLIENT}" "${NS_VPS}" "${NS_SS}"; do
        if ip netns list | grep -q "${ns}"; then
            ns_del "${ns}"
        fi
    done

    # Limpiar veths sueltos
    for v in "${VETH_CS}" "${VETH_VS}" "${VETH_VS2}" "${VETH_SS}"; do
        ip link del "${v}" 2>/dev/null || true
    done

    rm -rf "${TMPDIR}"

    echo "==> Entorno destruido"
}

# ============================================================================
# status
# ============================================================================
cmd_status() {
    echo "==> Estado del laboratorio"

    for ns in "${NS_CLIENT}" "${NS_VPS}" "${NS_SS}"; do
        if ip netns list | grep -q "${ns}"; then
            echo ""
            echo "--- ${ns} ---"
            echo -n "  Interfaces: "
            ip netns exec "${ns}" ip -br addr 2>/dev/null | grep -v "^lo" || echo "(solo lo)"
            if ip netns exec "${ns}" command -v wg &>/dev/null; then
                ip netns exec "${ns}" wg show 2>/dev/null || echo "  WG: no activo"
            fi
            echo -n "  Rutas: "
            ip netns exec "${ns}" ip route show default 2>/dev/null || echo "(sin default)"
        else
            echo "  ${ns}: NO EXISTE"
        fi
    done
}

# ============================================================================
# test
# ============================================================================
cmd_test() {
    local failures=0
    local passed=0

    echo "==> Ejecutando tests..."

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo ""
        echo "  Tests que se ejecutarian:"
        echo "    T1  - wg0 handshake (cliente -> VPS)"
        echo "    T2  - wg1 handshake (VPS -> Surfshark)"
        echo "    T3  - Ping cliente -> VPS (via wg0)"
        echo "    T4  - Ping cliente -> Surfshark (via wg0 + wg1)"
        echo "    T5  - Tabla wg_clients en VPS"
        echo "    T6  - Aislamiento VPS (trafico local no pasa por WG)"
        echo "    T7  - Ruteo entre namespaces"
        echo "    T8  - NAT (MASQUERADE) en VPS"
        echo "    T9  - FORWARD wg0 -> wg1"
        echo "    T10 - Tabla 200 (wg_clients)"
        echo "    T11 - kill switch (blackhole en tabla wg_clients)"
        echo ""
        return 0
    fi

    # Verificar que el entorno esta activo
    for ns in "${NS_CLIENT}" "${NS_VPS}" "${NS_SS}"; do
        if ! ip netns list | grep -q "${ns}"; then
            echo "  FAIL: namespace ${ns} no existe"
            echo "  Ejecute: ./test-lab.sh up"
            return 1
        fi
    done

    # --- TEST 1: wg0 handshake (cliente -> VPS) ---
    echo ""
    echo -n "  TEST 1 - wg0 handshake (cliente -> VPS): "
    HANDSHAKE=$(ip netns exec "${NS_CLIENT}" wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}')
    if [[ -n "${HANDSHAKE}" && "${HANDSHAKE}" -gt 0 ]]; then
        echo "OK (handshake en ${HANDSHAKE})"
        passed=$((passed + 1))
    else
        echo "FAIL - sin handshake"
        echo "    Debug:"
        echo "      Cliente WG:"
        ip netns exec "${NS_CLIENT}" wg show wg0 2>/dev/null | sed 's/^/      /'
        echo "      VPS WG:"
        ip netns exec "${NS_VPS}" wg show wg0 2>/dev/null | sed 's/^/      /'
        failures=$((failures + 1))
    fi

    # --- TEST 2: wg1 handshake (VPS -> Surfshark) ---
    echo -n "  TEST 2 - wg1 handshake (VPS -> Surfshark): "
    HANDSHAKE=$(ip netns exec "${NS_VPS}" wg show wg1 latest-handshakes 2>/dev/null | awk '{print $2}')
    if [[ -n "${HANDSHAKE}" && "${HANDSHAKE}" -gt 0 ]]; then
        echo "OK (handshake en ${HANDSHAKE})"
        passed=$((passed + 1))
    else
        echo "FAIL - sin handshake"
        echo "    Debug:"
        echo "      VPS wg1:"
        ip netns exec "${NS_VPS}" wg show wg1 2>/dev/null | sed 's/^/      /'
        echo "      Surfshark simulado:"
        ip netns exec "${NS_SS}" wg show 2>/dev/null | sed 's/^/      /'
        failures=$((failures + 1))
    fi

    # --- TEST 3: Ping cliente -> VPS (por wg0) ---
    echo -n "  TEST 3 - Ping cliente -> VPS (wg0): "
    if ip netns exec "${NS_CLIENT}" ping -c 2 -W 3 "${WG0_SERVER_IP%/*}" &>/dev/null; then
        echo "OK"
        passed=$((passed + 1))
    else
        echo "FAIL"
        failures=$((failures + 1))
    fi

    # --- TEST 4: Ping cliente -> Surfshark (por wg0 + wg1) ---
    echo -n "  TEST 4 - Ping cliente -> Surfshark (wg0 + wg1): "
    if ip netns exec "${NS_CLIENT}" ping -c 2 -W 5 "${WG1_SS_IP%/*}" &>/dev/null; then
        echo "OK"
        passed=$((passed + 1))
    else
        echo "FAIL"
        ip netns exec "${NS_VPS}" iptables -L FORWARD -v -n 2>/dev/null | head -10 | sed 's/^/    /'
        ip netns exec "${NS_VPS}" ip route show table wg_clients 2>/dev/null | sed 's/^/    /'
        failures=$((failures + 1))
    fi

    # --- TEST 5: Verificar tabla wg_clients existe ---
    echo -n "  TEST 5 - Tabla wg_clients en VPS: "
    if ip netns exec "${NS_VPS}" ip route show table wg_clients 2>/dev/null | grep -q "default"; then
        echo "OK"
        passed=$((passed + 1))
    else
        echo "FAIL"
        ip netns exec "${NS_VPS}" ip route show table wg_clients 2>/dev/null | sed 's/^/    /'
        failures=$((failures + 1))
    fi

    # --- TEST 6: Verificar que tráfico del VPS NO pasa por WG (simula mgmt) ---
    echo -n "  TEST 6 - Aislamiento VPS (trafico local): "
    # En el test, el VPS no tiene ruta default que pase por WG
    VPS_DEFAULT=$(ip netns exec "${NS_VPS}" ip route show table main 2>/dev/null | grep "default" || true)
    if echo "${VPS_DEFAULT}" | grep -q "wg"; then
        echo "FAIL - default usa WG! ${VPS_DEFAULT}"
        failures=$((failures + 1))
    else
        echo "OK (default: ${VPS_DEFAULT:-ninguna})"
        passed=$((passed + 1))
    fi

    # --- TEST 7: Forward entre namespaces ---
    echo -n "  TEST 7 - Ruteo entre namespaces: "
    if ip netns exec "${NS_VPS}" ping -c 1 -W 2 "10.99.0.2" &>/dev/null && \
       ip netns exec "${NS_VPS}" ping -c 1 -W 2 "10.99.1.2" &>/dev/null; then
        echo "OK"
        passed=$((passed + 1))
    else
        echo "FAIL"
        failures=$((failures + 1))
    fi

    # --- TEST 8: MASQUERADE (NAT) ---
    echo -n "  TEST 8 - NAT (MASQUERADE) en VPS: "
    if ip netns exec "${NS_VPS}" iptables -t nat -L POSTROUTING 2>/dev/null | grep -q "MASQUERADE"; then
        echo "OK"
        passed=$((passed + 1))
    else
        echo "FAIL"
        failures=$((failures + 1))
    fi

    # --- TEST 9: FORWARD permitido ---
    echo -n "  TEST 9 - FORWARD wg0 -> wg1: "
    if ip netns exec "${NS_VPS}" iptables -L FORWARD -v -n 2>/dev/null | grep -q "wg0.*wg1"; then
        echo "OK"
        passed=$((passed + 1))
    else
        echo "FAIL"
        failures=$((failures + 1))
    fi

    # --- TEST 11: Kill switch (blackhole) ---
    echo -n "  TEST 11 - Kill switch (blackhole en wg_clients): "
    if ip netns exec "${NS_VPS}" ip route show table wg_clients 2>/dev/null | grep -q "blackhole"; then
        echo "OK"
        passed=$((passed + 1))
    else
        echo "FAIL - sin blackhole, riesgo de leak si wg1 cae"
        failures=$((failures + 1))
    fi

    # --- TEST 10: Tabla 200 existe ---
    echo -n "  TEST 10 - Tabla 200 (wg_clients): "
    if ip netns exec "${NS_VPS}" grep -q "200 wg_clients" /etc/iproute2/rt_tables 2>/dev/null; then
        echo "OK"
        passed=$((passed + 1))
    else
        echo "FAIL"
        failures=$((failures + 1))
    fi

    # --- Resumen ---
    echo ""
    echo "========================================="
    if [[ "${failures}" -eq 0 ]]; then
        echo "  TODOS LOS TESTS PASARON (${passed}/11)"
    else
        echo "  ${failures} FALLOS - ${passed}/11 PASADOS"
    fi
    echo "========================================="

    return ${failures}
}

# ============================================================================
# Main
# ============================================================================
case "${1:-}" in
    up)
        cmd_up
        ;;
    down)
        cmd_down
        ;;
    test)
        cmd_test
        ;;
    status)
        cmd_status
        ;;
    *)
        echo "Uso: $0 up|down|test|status"
        echo ""
        echo "  up       Crear entorno de pruebas aislado"
        echo "  down     Destruir entorno"
        echo "  test     Ejecutar tests automatizados"
        echo "  status   Mostrar estado del laboratorio"
        echo ""
        echo "Con DRY_RUN=1:  DRY_RUN=1 $0 up"
        exit 1
        ;;
esac
