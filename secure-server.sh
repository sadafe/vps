#!/bin/bash
set -euo pipefail

# === Цвета для вывода ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="/etc/ssh/ssh-config-backup-${BACKUP_TIMESTAMP}.tar.gz"
USE_SOCKET=0

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }
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

# Создаем tar-архив с полной конфигурацией SSH
backup_ssh_config() {
    # Создаем архив с основным конфигом и директорией sshd_config.d (если есть)
    tar -czf "$BACKUP_FILE" \
        -C / \
        etc/ssh/sshd_config \
        $( [ -d /etc/ssh/sshd_config.d ] && echo etc/ssh/sshd_config.d ) \
        $( [ -d /etc/systemd/system/ssh.socket.d ] && echo etc/systemd/system/ssh.socket.d ) \
        $( [ -f /etc/systemd/system/ssh.service.d/override.conf ] && echo etc/systemd/system/ssh.service.d/override.conf ) \
        2>/dev/null || true

    # Проверяем, что архив валиден
    if ! tar -tzf "$BACKUP_FILE" > /dev/null 2>&1; then
        echo "Ошибка: архив $BACKUP_FILE невалиден" >&2
        rm -f "$BACKUP_FILE"
        exit 1
    fi

    chmod 600 "$BACKUP_FILE"
    log "Создан tar-архив резервной копии: $BACKUP_FILE"
}

# Восстанавливаем из tar-архива
unbackup_ssh_config() {
    if [ -f "$BACKUP_FILE" ]; then
        # Удаляем текущие файлы перед восстановлением
        rm -f /etc/ssh/sshd_config
        rm -rf /etc/ssh/sshd_config.d
        if [[ $USE_SOCKET -eq 1 ]]; then
            rm -rf "$OVERRIDE_DIR"
        fi
        # Распаковываем архив
        tar -xzf "$BACKUP_FILE" -C /
        
        # Восстанавливаем права доступа
        chmod 644 /etc/ssh/sshd_config
        if [ -d /etc/ssh/sshd_config.d ]; then
            chmod 755 /etc/ssh/sshd_config.d
            find /etc/ssh/sshd_config.d -type f -exec chmod 644 {} \;
        fi
        
        log "Конфигурация восстановлена из архива: $BACKUP_FILE"
        err "Откат выполнен. Проверьте конфигурацию вручную."
    else
        err "КРИТИЧЕСКАЯ ОШИБКА: Файл бэкапа $BACKUP_FILE не найден!"
        err "Невозможно выполнить откат. Восстановите конфигурацию вручную."
    fi
}

reload_socket() {
    if [[ $USE_SOCKET -eq 1 ]]; then
        systemctl daemon-reload
        systemctl restart ssh.socket
        log "ssh.socket перезапущен"
    else
        systemctl restart sshd 2>/dev/null || systemctl restart ssh
    fi
}

log "Автоматическая настройка безопасности VDS"

# 1. Проверяем, что скрипт запущен от root
if [ "$EUID" -ne 0 ]; then
    err "Ошибка: Запустите скрипт от root (используйте sudo или зайдите под root)"
    exit 1
fi

# 2. Проверка ОС (скрипт заточен под Debian/Ubuntu)
if ! command -v apt >/dev/null 2>&1; then
    err "Ошибка: Этот скрипт предназначен только для Debian/Ubuntu."
    exit 1
fi

# 3. Интерактивный ввод данных
read -p "Введите имя пользователя для создания: " USERNAME
if [ -z "$USERNAME" ] || [[ ! "$USERNAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    err "Ошибка: Имя пользователя не может быть пустым и должно содержать только буквы, цифры, _ и -"
    exit 1
fi

read -p "Введите желаемый порт SSH 1-1024 — потребуются привилегии root для каждого подключения (например, 2244): " SSH_PORT
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
    err "Ошибка: Порт должен быть числом от 1 до 65535."
    exit 1
fi

# === Проверка, что порт свободен ===
if ss -tlnp | awk '{print $4}' | grep -qE ":${SSH_PORT}\$"; then
    err "Порт $SSH_PORT уже используется"
    exit 1
fi

echo "Вставьте ваш публичный SSH-ключ (одной строкой) и нажмите Enter:"
read -r SSH_KEY
if [ -z "$SSH_KEY" ]; then
    err "Ошибка: SSH-ключ не может быть пустым."
    exit 1
fi

# Базовая проверка формата SSH-ключа
if [[ ! "$SSH_KEY" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|sk-ssh-ed25519@openssh.com) ]]; then
    err "Ошибка: Неверный формат SSH-ключа. Он должен начинаться с ssh-rsa, ssh-ed25519 и т.д."
    exit 1
fi

log ""
log "--- Введённые данные ---"
log "Пользователь: $USERNAME"
log "Порт SSH: $SSH_PORT"
log "SSH-ключ (первые 20 символов): ${SSH_KEY:0:20}..."
log "------------------------"
read -p "Продолжить? (y/n): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    err "Отменено пользователем."
    exit 0
fi

# 4. Обновление системы и установка пакетов
export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y
apt install -y ufw fail2ban unattended-upgrades sudo openssh-server

if [ ! -f /etc/ssh/sshd_config ]; then
    err "КРИТИЧЕСКАЯ ОШИБКА: /etc/ssh/sshd_config не найден"
    exit 1
fi

# 5. Создание пользователя и настройка SSH-ключа
if ! id "$USERNAME" &>/dev/null; then
    adduser --disabled-password --gecos "" "$USERNAME"
    usermod -aG sudo "$USERNAME"
    log "Создан пользователь $USERNAME"

else
    echo "Пользователь $USERNAME уже существует, пропускаем создание."
fi

mkdir -p "/home/$USERNAME/.ssh"
echo "$SSH_KEY" > "/home/$USERNAME/.ssh/authorized_keys"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh"
chmod 700 "/home/$USERNAME/.ssh"
chmod 600 "/home/$USERNAME/.ssh/authorized_keys"
echo "Добавлен SSH-ключ для $USERNAME"

backup_ssh_config()

update_sshd_config "Port" "$SSH_PORT"
update_sshd_config "PermitRootLogin" "no"
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

# Обработка /etc/ssh/sshd_config.d/ (для современных систем)
SSHD_CONFIG_DIR="/etc/ssh/sshd_config.d"
if [ -d "$SSHD_CONFIG_DIR" ]; then
    log "Обнаружена директория $SSHD_CONFIG_DIR"
    
    # Создаем файл с нашими настройками безопасности (высокий приоритет)
    cat <<EOF > "$SSHD_CONFIG_DIR/99-secure.conf"
# Настройки безопасности от secure-server.sh
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
MaxSessions 2
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers ${USERNAME}
EOF

    chmod 644 "$SSHD_CONFIG_DIR/99-secure.conf"
    log "Создан файл $SSHD_CONFIG_DIR/99-secure.conf"
    
    # Проверяем и удаляем конфликтующие настройки из других файлов
    for conf_file in "$SSHD_CONFIG_DIR"/*.conf; do
        if [ -f "$conf_file" ] && [ "$conf_file" != "$SSHD_CONFIG_DIR/99-secure.conf" ]; then
            log "Проверяем $conf_file на конфликтующие настройки..."
            
            # Удаляем дублирующиеся параметры
            sed -i -E '/^[[:space:]]*(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|MaxAuthTries|MaxSessions|ClientAliveInterval|ClientAliveCountMax|AllowUsers)[[:space:]]/d' "$conf_file"
            
            # Если файл стал пустым или содержит только комментарии, удаляем его
            if ! grep -qE '^[^#]' "$conf_file" 2>/dev/null; then
                rm "$conf_file"
                log "Удален пустой файл $conf_file"
            fi
        fi
    done
    
    # Убеждаемся, что Include директива есть в основном конфиге и стоит в начале
    if ! grep -qE "^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf" /etc/ssh/sshd_config; then
        # Добавляем Include в начало файла, если его нет
        sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
        log "Добавлена директива Include в начало sshd_config"
    fi
else
    log "Директория $SSHD_CONFIG_DIR не найдена, используем только основной конфиг"
fi

# === Определяем режим работы SSH ===
if systemctl list-unit-files ssh.socket &>/dev/null && \
   systemctl is-enabled ssh.socket 2>/dev/null | grep -qE 'enabled|static'; then
    USE_SOCKET=1
    log "Обнаружена socket-активация (ssh.socket)"
    # === Настройка ssh.socket  ===
    OVERRIDE_DIR="/etc/systemd/system/ssh.socket.d"
    OVERRIDE_FILE="$OVERRIDE_DIR/override.conf"

    mkdir -p "$OVERRIDE_DIR"
    cat > "$OVERRIDE_FILE" <<EOF
[Socket]
ListenStream=
BindIPv6Only=no
ListenStream=0.0.0.0:${SSH_PORT}
EOF

#    if ip -6 route show default >/dev/null 2>&1; then
#        echo "ListenStream=[::]:${SSH_PORT}" >> "$OVERRIDE_FILE"
#    fi

    log "Создан override для ssh.socket: $OVERRIDE_FILE"
else
    warn "Socket-активация не найдена, будет использоваться классический режим"
fi

# 7. Проверка и перезапуск SSH
if sshd -t 2>/dev/null; then
    log "SSH конфигурация проверена — OK"
else
    err "КРИТИЧЕСКАЯ ОШИБКА в SSH-конфигурации! Выполняется откат изменений..."

    unbackup_ssh_config()

    exit 1
fi


reload_socket()

log "Сервис SSH перезапущен"

# Проверяем, что SSH действительно слушает новый порт
if ! ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "(^0\.0\.0\.0:|^\*:)${SSH_PORT}\b"; then
    err "КРИТИЧЕСКАЯ ОШИБКА: SSH не слушает порт $SSH_PORT на IPv4 (0.0.0.0)! Откат, UFW не выполнен. Проверьте логи: journalctl -u ssh.socket -u ssh."
    unbackup_ssh_config()
    reload_socket()
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
backend = systemd

[sshd]
enabled = true
port = ${SSH_PORT}

[recidive]
enabled   = true
filter = recidive
logpath   = /var/log/fail2ban.log
banaction = %(banaction_allports)s
findtime  = 1d
maxretry  = 5
bantime   = 1w
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

cat <<EOF > /etc/sudoers.d/sudo-"$USERNAME"
$USERNAME ALL=(ALL) NOPASSWD: ALL
EOF
chmod 440 "/etc/sudoers.d/sudo-$USERNAME"

# 13. Настройка cron-задачи
cat <<EOF > /etc/cron.d/security-check
# Ежедневная проверка безопасности в 01:00
0 1 * * * root /usr/local/bin/security-check.sh >> /var/log/security-check.log 2>&1
EOF
chmod 644 /etc/cron.d/security-check

# 14. Настройка ротации логов для security-check
cat <<EOF > /etc/logrotate.d/security-check
/var/log/security-check.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF
chmod 644 /etc/logrotate.d/security-check

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