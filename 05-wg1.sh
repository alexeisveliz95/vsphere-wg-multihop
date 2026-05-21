#!/bin/bash
set -euo pipefail

echo "==> [05] Configurar wg1 - Surfshark (salida USA)"
echo ""
echo "    ATENCION: Este script NO incluye credenciales reales."
echo "    Debe editar /etc/wireguard/wg1.conf con sus datos."
echo ""

WG_TABLE="200"
grep -qxF "${WG_TABLE} wg_clients" /etc/iproute2/rt_tables || \
    echo "${WG_TABLE} wg_clients" >> /etc/iproute2/rt_tables

cat > /etc/wireguard/wg1.conf << 'WGEOF'
[Interface]
Address = 10.2.0.2/32
PrivateKey = <CAMBIAR_POR_PRIVATE_KEY_SURFSHARK>
MTU = 1320
Table = off

[Peer]
PublicKey = <CAMBIAR_POR_PUBLIC_KEY_SURFSHARK>
Endpoint = <CAMBIAR_POR_IP_SURFSHARK>:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
WGEOF

chmod 600 /etc/wireguard/wg1.conf

echo "==> [05] wg1.conf creado en /etc/wireguard/wg1.conf"
echo ""
echo "    Datos que debe reemplazar:"
echo "      - PrivateKey:  clave privada de Surfshark"
echo "      - PublicKey:   clave publica del peer Surfshark"
echo "      - Endpoint:    IP:puerto del servidor Surfshark"
echo "      - Address:     IP asignada por Surfshark"
echo ""
echo "    Luego ejecute:  wg-quick up wg1"
echo "    Verifique con:  wg show wg1"
