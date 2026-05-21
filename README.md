# vSphere WG Multihop

Servidor WireGuard multihop para VPS en vSphere. Clientes se conectan via wg0 y su trafico sale por wg1 (Surfshark USA). SSH y DNS nunca pasan por WireGuard.

## Arquitectura

```
[Cliente] ──wg0──▶ [VPS] ──wg1──▶ [Surfshark USA] ──▶ Internet
10.8.0.2/24     10.8.0.1/24    10.2.0.x/32       IP USA
```

## Uso rapido

```bash
./01-hardening.sh [puerto_ssh]         # SSH key-only + fail2ban
./02-firewall.sh [ssh_port] [wg_port]  # Firewall base
./03-mgmt-routing.sh                   # Tabla mgmt anti-lockout
./04-wireguard.sh [wg_port]            # Instalar WG + claves VPS
./05-wg1.sh                            # Configurar Surfshark
./06-wg0.sh [wg_port]                  # Servidor clientes
./07-dns.sh                            # DNS local con unbound
./08-watchdog.sh                       # Watchdog + scripts
```

## Scripts de gestion

```bash
add-client.sh <nombre>        # Agregar cliente (IP auto + .conf + QR)
remove-client.sh <nombre>     # Eliminar cliente
list-clients.sh               # Listar clientes activos
toggle-multihop.sh on|off     # Multihop VPS (ON/OFF persistente)
status.sh                     # Dashboard general
backup.sh                     # Backup completo
restore.sh <archivo>          # Restaurar desde backup
```

## Entorno de pruebas

```bash
./test-lab.sh up     # Crear entorno aislado (ip netns)
./test-lab.sh test   # Ejecutar 11 tests automatizados
./test-lab.sh down   # Destruir entorno
DRY_RUN=1 ./test-lab.sh up   # Simular sin cambios
```

## Seguridad

- SSH key-only (sin passwords)
- Tabla mgmt (100): trafico del VPS nunca pasa por WG
- Firewall: solo puertos SSH + WG abiertos
- Kill switch: blackhole en tabla wg_clients si wg1 cae
- Watchdog: monitoreo cada 2 minutos, auto-recuperacion
- iptables persistentes post-reboot
- Servicio systemd mgmt-routing para reglas de ruteo
