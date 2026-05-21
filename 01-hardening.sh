#!/bin/bash
set -euo pipefail

SSH_PORT="${1:-22}"

echo "==> [01] SSH Hardening + Fail2ban"
echo "    Puerto SSH: ${SSH_PORT}"

# --- Dry-run mode ---
if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "    [DRY-RUN] No se ejecutaran cambios reales"
    apt-get --dry-run install -y fail2ban 2>&1 | grep -E "^Inst|^Conf"
    echo "    [DRY-RUN] sshd_config: PasswordAuthentication no"
    echo "    [DRY-RUN] fail2ban jail.local creado"
    echo "    [DRY-RUN] systemctl restart sshd"
    exit 0
fi

echo "    Instalando fail2ban..."
apt-get update -qq
apt-get install -y fail2ban

echo "    Configurando SSH (key-only)..."
sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication no/" /etc/ssh/sshd_config
sed -i "s/^#*PermitEmptyPasswords.*/PermitEmptyPasswords no/" /etc/ssh/sshd_config
sed -i "s/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/" /etc/ssh/sshd_config
sed -i "s/^#*UsePAM.*/UsePAM no/" /etc/ssh/sshd_config

if [[ "${SSH_PORT}" != "22" ]]; then
    sed -i "s/^#*Port .*/Port ${SSH_PORT}/" /etc/ssh/sshd_config
fi

echo "    Configurando fail2ban..."
cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ${SSH_PORT}
EOF

echo "    Reiniciando servicios..."
systemctl restart sshd
systemctl restart fail2ban
systemctl enable fail2ban

echo "==> [01] COMPLETADO - SSH key-only | fail2ban activo"
echo "    ADVERTENCIA: mantenga esta sesion abierta y pruebe"
echo "    una NUEVA sesion SSH antes de cerrar esta."
