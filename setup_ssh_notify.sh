#!/bin/bash
set -euo pipefail

# --- НАСТРОЙКИ (ИЗМЕНИТЕ ПОД СЕБЯ) ---
EMAIL_TO="krv_1973@mail.ru"
EMAIL_FROM="krv_1973@mail.ru"
SMTP_HOST="smtp.mail.ru"      # выбери один: smtp.mail.ru или smtp.gmail.com
SMTP_PORT="587"
SCRIPT_PATH="/usr/local/bin/ssh-login-notify.sh"
PAM_FILE="/etc/pam.d/sshd"
# POSTFIX_DIR="/etc/postfix"

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
# Уведомление о входе по SSH через внешний SMTP (msmtp).
# pam_exec: session optional pam_exec.so quiet /usr/local/bin/ssh-login-notify.sh

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

if [ "${PAM_TYPE:-}" = "close_session" ]; then
    exit 0
fi

RECIPIENT="__EMAIL_FROM__"          # ← реальный адрес
SENDER="__EMAIL_TO__"          # ← тот же, что в from в /etc/msmtprc

USER_NAME="${PAM_USER:-unknown}"
IP="${PAM_RHOST:-unknown}"
TTY="${PAM_TTY:-unknown}"
HOST="$(hostname -f 2>/dev/null || hostname)"
DATE="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

logger -t ssh-login-notify "login: user=$USER_NAME ip=$IP tty=$TTY host=$HOST"

LOCATION="Location unknown"
if command -v geoiplookup >/dev/null 2>&1; then
    geo_result="$(geoiplookup "$IP" 2>/dev/null || true)"
    [ -n "$geo_result" ] && LOCATION="$geo_result"
fi

SUBJECT="SSH Login Alert: $USER_NAME on $HOST"
MESSAGE="Server: $HOST
User: $USER_NAME
From IP: $IP
$LOCATION
Date: $DATE
SSH Client: $TTY"

# Собираем RFC-заголовки и отдаём msmtp. Он синхронный: возвращается
# только после ответа SMTP-сервера, код из sysexits.h при сбое.
if err="$(
    {
        printf 'From: %s\n' "$SENDER"
        printf 'To: %s\n' "$RECIPIENT"
        printf 'Subject: %s\n' "$SUBJECT"
        printf 'Content-Type: text/plain; charset=utf-8\n'
        printf 'Date: %s\n' "$(date -R)"
        printf '\n'
        printf '%s\n' "$MESSAGE"
    } | msmtp -a default -t 2>&1
)"; then
    logger -t ssh-login-notify "mail: delivered to $RECIPIENT"
else
    rc=$?
    logger -t ssh-login-notify -p err "mail: FAILED rc=$rc: $err"
fi

exit 0
EOF

sed -i "s/__EMAIL_TO__/$SMTP_USER/g" "$SCRIPT_PATH" 
sed -i "s/__EMAIL_FROM__/$SMTP_USER/g" "$SCRIPT_PATH"

chmod 655 "$SCRIPT_PATH"

echo "=== Шаг 3: Настройка Msmtp ==="
cat > /etc/msmtprc <<EOF
defaults
auth           on
tls            on
tls_starttls   on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
timeout        15
syslog         on

account default
host           $SMTP_HOST
port           587
from           $EMAIL_FROM
user           $SMTP_USER
password_file  /etc/msmtp.password
EOF

cat > /etc/msmtp.password <<EOF
$SMTP_PASS
EOF

chown root:root /etc/msmtp.password /etc/msmtprc
chmod 600 /etc/msmtp.password
chmod 644 /etc/msmtprc


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
echo ""
echo "Для теста выполните вход по SSH с другого хоста."
echo "Логи почты: tail -f /var/log/mail.log"
echo "Логи SSH: tail -f /var/log/auth.log"
