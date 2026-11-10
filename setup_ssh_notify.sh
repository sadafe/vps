#!/bin/bash
set -euo pipefail

# --- НАСТРОЙКИ (ИЗМЕНИТЕ ПОД СЕБЯ) ---
EMAIL_TO="krv_1973@mail.ru"
EMAIL_FROM="krv_1973@mail.ru"
SMTP_HOST="smtp.mail.ru"      # выбери один: smtp.mail.ru или smtp.gmail.com
SMTP_PORT="587"
SCRIPT_PATH="/usr/local/bin/ssh-login-notify.sh"
PAM_FILE="/etc/pam.d/sshd"
POSTFIX_DIR="/etc/postfix"

# Пароли НЕ хранятся в скрипте! Их нужно ввести вручную после запуска
read -p "Введите адрес электронной почты: " SMTP_USER
read -p "Введите пароль для доступа к электронной почты: " SMTP_PASS
if [[ -z "${SMTP_USER:-}" || -z "${SMTP_PASS:-}" ]]; then
    echo "ОШИБКА: Переменные SMTP_USER и SMTP_PASS не заданы."
    exit 1
fi

echo "=== Шаг 1: Установка необходимых пакетов ==="
DEBIAN_FRONTEND=noninteractive 
apt update
apt upgrade 
apt install -y  geoip-bin msmtp msmtp-mta

echo "=== Шаг 2: Создание скрипта уведомления ==="
cat > "$SCRIPT_PATH" << 'EOF'
#!/bin/bash
# Уведомление о входе по SSH. Вызывается pam_exec; окружение там
# минимальное (только PAM_*), поэтому PATH/HOME задаём явно.

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

if [ "${PAM_TYPE:-}" = "close_session" ]; then
    exit 0
fi

HOST="$(hostname -f 2>/dev/null || hostname)"
USER_NAME="${PAM_USER:-unknown}"
IP="${PAM_RHOST:-unknown}"
TTY="${PAM_TTY:-unknown}"
DATE="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

# Аудит в системный журнал: без файлов и прав, ротация автоматом
logger -t ssh-login-notify "login: user=$USER_NAME ip=$IP tty=$TTY host=$HOST"

LOCATION="Location unknown"
if command -v geoiplookup >/dev/null 2>&1; then
    geo_result="$(geoiplookup "$IP" 2>/dev/null || true)"
    [ -n "$geo_result" ] && LOCATION="$geo_result"
fi

RECIPIENT="__EMAIL_TO__"   # ← замените на реальный адрес!
SENDER="__EMAIL_FROM__"    # ← и на этот

# mailx ищет ~/.mailrc — без HOME он может вести себя иначе
if [ -z "${HOME:-}" ]; then
    HOME="$(getent passwd "${PAM_USER:-root}" 2>/dev/null | cut -d: -f6)"
    [ -n "$HOME" ] || HOME=/tmp
    export HOME
fi

SUBJECT="SSH Login Alert: $USER_NAME on $HOST"
MESSAGE="Server: $HOST
User: $USER_NAME
From IP: $IP
$LOCATION
Date: $DATE
SSH Client: $TTY"

if command -v mail >/dev/null 2>&1; then
    if ! echo "$MESSAGE" | mail -s "$SUBJECT" -r "$SENDER" "$RECIPIENT" >/dev/null 2>&1; then
        logger -t ssh-login-notify -p warning "mail: failed to send message"
    fi
else
    logger -t ssh-login-notify -p warning "mail: command not found"
fi

exit 0
EOF

sed -i "s/__EMAIL_TO__/$SMTP_USER/g" "$SCRIPT_PATH" 
sed -i "s/__EMAIL_FROM__/$SMTP_USER/g" "$SCRIPT_PATH"

chmod +x "$SCRIPT_PATH"

echo "=== Шаг 3: Настройка Postfix ==="
# Бэкап текущей конфигурации
cp -p "$POSTFIX_DIR/main.cf" "$POSTFIX_DIR/main.cf.bak.$(date +%F-%H%M)"
cp -p "$POSTFIX_DIR/sasl_passwd" "$POSTFIX_DIR/sasl_passwd.bak.$(date +%F-%H%M)" 2>/dev/null || true

# Настройка relayhost
if ! grep -q "^relayhost" "$POSTFIX_DIR/main.cf"; then
    echo "relayhost = [$SMTP_HOST]:$SMTP_PORT" >> "$POSTFIX_DIR/main.cf"
else
    sed -i "s/^relayhost.*/relayhost = [$SMTP_HOST]:$SMTP_PORT/" "$POSTFIX_DIR/main.cf"
fi

# Дополнительные настройки TLS и SASL
cat >> "$POSTFIX_DIR/main.cf" <<EOF
smtp_use_tls = yes
smtp_sasl_auth_enable = yes
smtp_sasl_security_options = noanonymous
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt
EOF

# Файл паролей
cat > "$POSTFIX_DIR/sasl_passwd" <<EOF
[$SMTP_HOST]:$SMTP_PORT $SMTP_USER:$SMTP_PASS
EOF

chmod 600 "$POSTFIX_DIR/sasl_passwd"
postmap "$POSTFIX_DIR/sasl_passwd"

systemctl enable --now postfix
if ! systemctl is-active --quiet postfix; then
    echo "ОШИБКА: Postfix не запустился. Проверьте логи: journalctl -u postfix -n 50"
    exit 1
fi

echo "=== Шаг 4: Настройка PAM ==="
cp -p "$PAM_FILE" "$PAM_FILE.bak.$(date +%F-%H%M)"

if ! grep -q "pam_exec.so.*ssh-login-notify.sh" "$PAM_FILE"; then
    # Вставляем строку после pam_limits.so, если она есть, иначе — в конец секции session
    if grep -q "pam_limits.so" "$PAM_FILE"; then
        sed -i "/pam_limits.so/a session optional pam_exec.so seteuid \"$SCRIPT_PATH\"" "$PAM_FILE"
    else
        # Если шаблона нет, добавляем в конец файла
        echo "session optional pam_exec.so seteuid \"$SCRIPT_PATH\"" >> "$PAM_FILE"
    fi
fi

# Проверка, что строка добавлена
if ! grep -q "pam_exec.so.*ssh-login-notify.sh" "$PAM_FILE"; then
    echo "ОШИБКА: Не удалось добавить правило в PAM. Проверьте $PAM_FILE вручную."
    exit 1
fi

echo "=== Шаг 5: Перезапуск SSH и финальные проверки ==="
systemctl daemon-reload
systemctl restart ssh
if ! systemctl is-active --quiet ssh; then
    echo "ОШИБКА: Служба SSH не перезапустилась. Проверьте доступ по консоли."
    exit 1
fi

echo ""
echo "=== Готово ==="
echo "1. Скрипт уведомлений: $SCRIPT_PATH"
echo "2. Конфигурация PAM: $PAM_FILE (бэкап: ${PAM_FILE}.bak.*)"
echo "3. Конфигурация Postfix: $POSTFIX_DIR (бэкапы в той же директории)"
echo ""
echo "Для теста выполните вход по SSH с другого хоста."
echo "Логи почты: tail -f /var/log/mail.log"
echo "Логи SSH: tail -f /var/log/auth.log"
