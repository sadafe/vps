#!/bin/bash
set -euo pipefail

# --- НАСТРОЙКИ ---
SMTP_HOST="smtp.mail.ru"            # или smtp.gmail.com
SMTP_PORT="587"                     # 587 = STARTTLS; для 465 starttls выключится сам
SCRIPT_PATH="/usr/local/bin/ssh-login-notify.sh"
CONF_PATH="/etc/ssh-login-notify.conf"
MSMTP_CONF="/etc/msmtprc"
MSMTP_PASS="/etc/msmtp.password"
PAM_FILE="/etc/pam.d/sshd"

[[ $EUID -eq 0 ]] || { echo "ОШИБКА: запустите от root."; exit 1; }
command -v apt-get >/dev/null 2>&1 || { echo "ОШИБКА: нужен Debian/Ubuntu."; exit 1; }

read -rp "Адрес электронной почты: " SMTP_USER
read -rsp "Пароль для внешнего приложения (ввод скрыт): " SMTP_PASS; echo
[[ "$SMTP_USER" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] || { echo "ОШИБКА: некорректный email."; exit 1; }
[[ -n "$SMTP_PASS" ]] || { echo "ОШИБКА: пустой пароль."; exit 1; }

echo "=== Шаг 1: Пакеты (без apt upgrade) ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends msmtp ca-certificates geoip-bin geoip-database

echo "=== Шаг 2: msmtp ==="
( umask 077; printf '%s\n' "$SMTP_PASS" > "$MSMTP_PASS" )   # без окна world-readable
chown root:root "$MSMTP_PASS"; chmod 600 "$MSMTP_PASS"

if [[ "$SMTP_PORT" == "465" ]]; then STARTTLS="off"; else STARTTLS="on"; fi
cat > "$MSMTP_CONF" <<EOF
defaults
auth           on
tls            on
tls_starttls   $STARTTLS
tls_trust_file /etc/ssl/certs/ca-certificates.crt
timeout        10
syslog         on

account default
host           $SMTP_HOST
port           $SMTP_PORT
from           $SMTP_USER
user           $SMTP_USER
passwordeval   cat $MSMTP_PASS
EOF
chown root:root "$MSMTP_CONF"; chmod 600 "$MSMTP_CONF"

echo "=== Шаг 3: Тестовое письмо (PAM ещё не тронут) ==="
if ! printf 'From: %s\nTo: %s\nSubject: ssh-notify: SMTP test\n\nТест SMTP с %s.\n' \
        "$SMTP_USER" "$SMTP_USER" "$(hostname)" \
        | msmtp -C "$MSMTP_CONF" -a default "$SMTP_USER"; then
    echo "ОШИБКА: письмо не ушло (проверьте пароль приложения). PAM не изменён."
    exit 1
fi
echo "Письмо отправлено — проверьте ящик и папку Спам."

echo "=== Шаг 4: Скрипт уведомления (адрес — в конфиге, без sed) ==="
printf 'RECIPIENT=%q\n' "$SMTP_USER" > "$CONF_PATH"
chown root:root "$CONF_PATH"; chmod 644 "$CONF_PATH"

cat > "$SCRIPT_PATH" <<'EOF'
#!/bin/bash
# Уведомление о входе по SSH. Вызывается PAM от root:
#   session optional pam_exec.so quiet /usr/local/bin/ssh-login-notify.sh
# Отправка выносится в фон, чтобы медленный SMTP не задерживал вход.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

TAG="ssh-login-notify"
MSMTP_CONF="/etc/msmtprc"
CONF="/etc/ssh-login-notify.conf"

if [[ "${1:-}" != "--send" ]]; then
    # Вызов из PAM: только open_session, работу передаём в фон и сразу выходим.
    [[ "${PAM_TYPE:-}" == "open_session" ]] || exit 0
    u="${PAM_USER:-unknown}"; ip="${PAM_RHOST:-unknown}"; tty="${PAM_TTY:-unknown}"
    if command -v systemd-run >/dev/null 2>&1 &&
       systemd-run --quiet --no-block --collect \
           /bin/bash "$0" --send "$u" "$ip" "$tty" 2>/dev/null; then
        :
    else
        nohup /bin/bash "$0" --send "$u" "$ip" "$tty" >/dev/null 2>&1 &
    fi
    exit 0
fi

# Фоновая часть: формируем и отправляем письмо.
USER_NAME="$2"; IP="$3"; TTY="$4"
RECIPIENT="root@localhost"
[[ -r "$CONF" ]] && . "$CONF"
SENDER="$RECIPIENT"                     # должен совпадать с from в msmtprc

HOST="$(hostname -f 2>/dev/null || hostname)"
DATE="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
logger -t "$TAG" "login: user=$USER_NAME ip=$IP tty=$TTY"

LOCATION="Location unknown"
if command -v geoiplookup >/dev/null 2>&1; then
    geo="$(geoiplookup "$IP" 2>/dev/null || true)"
    [[ -n "$geo" && "$geo" != *"not found"* ]] && LOCATION="$geo"
fi

if err="$(
    {
        printf 'From: %s\n' "$SENDER"
        printf 'To: %s\n' "$RECIPIENT"
        printf 'Subject: SSH login: %s@%s from %s\n' "$USER_NAME" "$HOST" "$IP"
        printf 'Date: %s\n' "$(date -R)"
        printf 'Message-ID: <%s.%s@%s>\n' "$(date +%s)" "$$" "$HOST"
        printf 'Auto-Submitted: auto-generated\n'
        printf 'Content-Type: text/plain; charset=utf-8\n'
        printf '\n'
        printf 'Server: %s\nUser: %s\nFrom IP: %s\n%s\nDate: %s\nTTY: %s\n' \
            "$HOST" "$USER_NAME" "$IP" "$LOCATION" "$DATE" "$TTY"
    } | msmtp -C "$MSMTP_CONF" -a default "$RECIPIENT" 2>&1
)"; then
    logger -t "$TAG" "mail: delivered to $RECIPIENT"
else
    rc=$?
    logger -t "$TAG" -p mail.err "mail: FAILED rc=$rc: $err"
fi
exit 0
EOF
chown root:root "$SCRIPT_PATH"
chmod 700 "$SCRIPT_PATH"                # выполняется только root

echo "=== Шаг 5: PAM (без seteuid, без рестарта sshd) ==="
BACKUP="$PAM_FILE.bak.$(date +%F-%H%M%S)"
cp -a "$PAM_FILE" "$BACKUP"
if grep -Eq '^[^#]*pam_exec\.so.*ssh-login-notify\.sh' "$PAM_FILE"; then
    echo "Правило уже есть — пропускаю."
else
    printf '\n# Email-уведомление о входе по SSH\nsession optional pam_exec.so quiet %s\n' \
        "$SCRIPT_PATH" >> "$PAM_FILE"
fi

echo
echo "=== Готово ==="
echo "Перезапуск sshd НЕ нужен: PAM читается при каждом входе."
echo "Ручной тест отправки: $SCRIPT_PATH --send test 8.8.8.8 test"
echo "Лог:                  journalctl -t ssh-login-notify -n 20"
echo "Откат PAM:            cp -a $BACKUP $PAM_FILE"
echo "Проверка: откройте НОВУЮ SSH-сессию, текущую не закрывайте."