#!/bin/bash
set -e

echo "Автоматическая настройка безопасности VDS"

# 1. Проверяем, что скрипт запущен от root
if [ "$EUID" -ne 0 ]; then
    echo "Ошибка: Запустите скрипт от root (используйте sudo или зайдите под root)"
    exit 1
fi

# 2. Проверка ОС (скрипт заточен под Debian/Ubuntu)
if ! command -v apt >/dev/null 2>&1; then
    echo "Ошибка: Этот скрипт предназначен только для Debian/Ubuntu."
    exit 1
fi

# 3. Интерактивный ввод данных
read -p "Введите имя пользователя для создания: " USERNAME
if [ -z "$USERNAME" ] || [[ ! "$USERNAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Ошибка: Имя пользователя не может быть пустым и должно содержать только буквы, цифры, _ и -"
    exit 1
fi

read -p "Введите желаемый порт SSH (например, 2244): " SSH_PORT
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
    echo "Ошибка: Порт должен быть числом от 1 до 65535."
    exit 1
fi

echo "Вставьте ваш публичный SSH-ключ (одной строкой) и нажмите Enter:"
read -r SSH_KEY
if [ -z "$SSH_KEY" ]; then
    echo "Ошибка: SSH-ключ не может быть пустым."
    exit 1
fi

# Базовая проверка формата SSH-ключа
if [[ ! "$SSH_KEY" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|sk-ssh-ed25519@openssh.com) ]]; then
    echo "Ошибка: Неверный формат SSH-ключа. Он должен начинаться с ssh-rsa, ssh-ed25519 и т.д."
    exit 1
fi

echo ""
echo "--- Введённые данные ---"
echo "Пользователь: $USERNAME"
echo "Порт SSH: $SSH_PORT"
echo "SSH-ключ (первые 20 символов): ${SSH_KEY:0:20}..."
echo "------------------------"
read -p "Продолжить? (y/n): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Отменено пользователем."
    exit 0
fi

# 4. Обновление системы и установка пакетов
export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y
apt install -y ufw fail2ban unattended-upgrades sudo

# 5. Создание пользователя и настройка SSH-ключа
if ! id "$USERNAME" &>/dev/null; then
    adduser --disabled-password --gecos "" "$USERNAME"
    usermod -aG sudo "$USERNAME"
    echo "Создан пользователь $USERNAME"

    mkdir -p "/home/$USERNAME/.ssh"
    echo "$SSH_KEY" > "/home/$USERNAME/.ssh/authorized_keys"
    chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh"
    chmod 700 "/home/$USERNAME/.ssh"
    chmod 600 "/home/$USERNAME/.ssh/authorized_keys"
    echo "Добавлен SSH-ключ для $USERNAME"
else
    echo "Пользователь $USERNAME уже существует, пропускаем создание."
fi

# 6. Резервное копирование и настройка sshd_config
if [ ! -f /etc/ssh/sshd_config ]; then
    echo "КРИТИЧЕСКАЯ ОШИБКА: /etc/ssh/sshd_config не найден"
    exit 1
fi
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

# Функция для безопасного и идемпотентного обновления параметров sshd_config
update_sshd_config() {
    local param="$1"
    local value="$2"
    if grep -qE "^[[:space:]]*#?[[:space:]]*${param}[[:space:]]" /etc/ssh/sshd_config; then
        sed -i -E "s/^[[:space:]]*#?[[:space:]]*${param}[[:space:]].*/${param} ${value}/" /etc/ssh/sshd_config
    else
        echo "${param} ${value}" >> /etc/ssh/sshd_config
    fi
}

update_sshd_config "Port" "$SSH_PORT"
update_sshd_config "PermitRootLogin" "prohibit-password"
update_sshd_config "PasswordAuthentication" "no"
update_sshd_config "PubkeyAuthentication" "yes"
update_sshd_config "MaxAuthTries" "3"
update_sshd_config "MaxSessions" "2"
update_sshd_config "ClientAliveInterval" "300"
update_sshd_config "ClientAliveCountMax" "2"

# Обработка AllowUsers (идемпотентная: добавляет, только если пользователя ещё нет)
if grep -qE "^AllowUsers[[:space:]]" /etc/ssh/sshd_config; then
    if ! grep -qE "^AllowUsers[[:space:]].*\b${USERNAME}\b" /etc/ssh/sshd_config; then
        sed -i -E "s/^(AllowUsers[[:space:]].*)/\1 ${USERNAME}/" /etc/ssh/sshd_config
    fi
else
    echo "AllowUsers $USERNAME" >> /etc/ssh/sshd_config
fi

# 7. Проверка и перезапуск SSH
if sshd -t 2>/dev/null; then
    echo "SSH конфигурация проверена — OK"
else
    echo "КРИТИЧЕСКАЯ ОШИБКА в SSH-конфигурации! Выполняется откат изменений..."
    cp /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
    exit 1
fi

systemctl disable --now ssh.socket 2>/dev/null
systemctl restart ssh 2>/dev/null || systemctl restart sshd

# Проверяем, что SSH действительно слушает новый порт
if ! ss -tlnp 2>/dev/null | grep -qE ":${SSH_PORT}\b"; then
    echo "КРИТИЧЕСКАЯ ОШИБКА: SSH не слушает порт $SSH_PORT! Откат UFW не выполнен, проверьте конфиг."
    exit 1
fi

# 8. Настройка UFW (ВНИМАНИЕ: сбрасывает предыдущие правила)
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# 9. Настройка Fail2Ban (создаем чистый конфиг вместо копирования jail.conf)
cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3

[sshd]
enabled = true
port = ${SSH_PORT}
EOF

systemctl enable fail2ban
systemctl restart fail2ban

# 10. Автоматические обновления безопасности
if [ -f /etc/apt/apt.conf.d/50unattended-upgrades ]; then
    sed -i 's|^//\?Unattended-Upgrade::Automatic-Reboot .*|Unattended-Upgrade::Automatic-Reboot "false";|' /etc/apt/apt.conf.d/50unattended-upgrades
    if ! grep -q 'Automatic-Reboot' /etc/apt/apt.conf.d/50unattended-upgrades; then
        echo 'Unattended-Upgrade::Automatic-Reboot "false";' >> /etc/apt/apt.conf.d/50unattended-upgrades
    fi
fi

cat <<EOF > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# 11. Создание скрипта проверки безопасности
# Используем 'EOF' в кавычках, чтобы переменные раскрылись при выполнении скрипта, а не при его создании
cat <<'EOF' > /usr/local/bin/security-check.sh
#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "Starting security check..."

# 1. Неудачные попытки входа по SSH за последние 24 часа
FAILED_ATTEMPTS=$(journalctl --since "24 hours ago" 2>/dev/null | grep -c "Failed password") || FAILED_ATTEMPTS=0
log "Failed SSH attempts in last 24h: $FAILED_ATTEMPTS"

# 2. Статус Fail2Ban для SSH
if command -v fail2ban-client >/dev/null 2>&1; then
  fail2ban-client status sshd 2>/dev/null || log "Fail2Ban status: command failed"
else
  log "Fail2Ban status: fail2ban-client not found"
fi

# 3. Активные соединения на порту SSH (исправлено: используем state established)
SSH_PORT_CHECK=$(grep -E "^[[:space:]]*Port " /etc/ssh/sshd_config | awk '{print $2}')
SSH_PORT_CHECK=${SSH_PORT_CHECK:-22}
ACTIVE_CONN=$(ss -tn state established 2>/dev/null | grep -cE ":${SSH_PORT_CHECK}\b") || ACTIVE_CONN=0
log "Active established connections on port $SSH_PORT_CHECK: $ACTIVE_CONN"

# 4. Доступные обновления
UPDATES_COUNT=$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)
log "Available updates (apt): $UPDATES_COUNT"

log "Security check completed."
EOF

chown root:root /usr/local/bin/security-check.sh
chmod 755 /usr/local/bin/security-check.sh

# 12. Настройка sudoers (ИСПРАВЛЕНО: только для конкретного скрипта)
cat <<EOF > /etc/sudoers.d/security-check-"$USERNAME"
$USERNAME ALL=(ALL) NOPASSWD: /usr/local/bin/security-check.sh
EOF
chmod 440 "/etc/sudoers.d/security-check-$USERNAME"

# 13. Настройка cron-задачи
cat <<EOF > /etc/cron.d/security-check
# Ежедневная проверка безопасности в 01:00
0 1 * * * root /usr/local/bin/security-check.sh >> /var/log/security-check.log 2>&1
EOF
chmod 644 /etc/cron.d/security-check

echo ""
echo "=========================================="
echo " Настройка завершена успешно! "
echo "=========================================="
echo "SSH теперь работает на порту: $SSH_PORT"
echo "Вход разрешён только по ключу для пользователя: $USERNAME"
echo "Root-вход по паролю отключен."
echo ""
echo "  ВАЖНО: Перед тем как закрывать текущую сессию root,"
echo "ОБЯЗАТЕЛЬНО откройте новое окно терминала и проверьте вход"
echo "под пользователем $USERNAME на порт $SSH_PORT!"
echo "=========================================="