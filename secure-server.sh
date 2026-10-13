#!/bin/bash
set -e

echo "Автоматическая настройка безопасности VDS"

# Проверяем, что скрипт запущен от root
if [ "$EUID" -ne 0 ]; then
    echo "Запустите скрипт от root"
    exit 1
fi

# Интерактивный ввод данных
read -p "Введите имя пользователя для создания: " USERNAME
if [ -z "$USERNAME" ] || [[ "$USERNAME" =~ [^a-zA-Z0-9_-] ]]; then
    echo "Ошибка: Имя пользователя не может быть пустым и должно содержать только буквы, цифры, _ и -"
    exit 1
fi

read -p "Введите желаемый порт SSH (например, 2244): " SSH_PORT
# Простая проверка, что порт — число
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

# Дальше можно использовать переменные $USERNAME, $SSH_PORT, $SSH_KEY
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

# Обновляем систему
export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y
# Устанавливаем необходимые пакеты
apt install -y ufw fail2ban unattended-upgrades sudo

# Создаём пользователя (если не существует)
if ! id "$USERNAME" &>/dev/null; then
    adduser --disabled-password --gecos "" "$USERNAME"
    usermod -aG sudo "$USERNAME"
    echo "Создан пользователь $USERNAME"

    # Добавляем SSH-ключ
    mkdir -p /home/$USERNAME/.ssh
    echo "$SSH_KEY" > /home/$USERNAME/.ssh/authorized_keys
    chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh
    chmod 700 /home/$USERNAME/.ssh
    chmod 600 /home/$USERNAME/.ssh/authorized_keys
    echo "Добавлен SSH-ключ для $USERNAME"
fi

# Делаем бэкап текущего конфига
[ -f /etc/ssh/sshd_config ] || { echo "sshd_config не найден"; exit 1; }
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

# Настраиваем конфиг ssh
if grep -qE "^#?Port " /etc/ssh/sshd_config; then
    sed -i -E "s/^#?Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
else
    echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
fi
sed -i "/^#\?PermitRootLogin /c\PermitRootLogin prohibit-password" /etc/ssh/sshd_config
sed -i "/^#\?PasswordAuthentication /c\PasswordAuthentication no" /etc/ssh/sshd_config
sed -i "/^#\?PubkeyAuthentication\b/c\PubkeyAuthentication yes" /etc/ssh/sshd_config

sed -i '/^AllowUsers /d' /etc/ssh/sshd_config
echo "AllowUsers $USERNAME" >> /etc/ssh/sshd_config

grep -q "^MaxAuthTries" /etc/ssh/sshd_config && \
  sed -i "s/^MaxAuthTries.*/MaxAuthTries 3/" /etc/ssh/sshd_config || \
  echo "MaxAuthTries 3" >> /etc/ssh/sshd_config

grep -q "^MaxSessions" /etc/ssh/sshd_config && \
  sed -i "s/^MaxSessions.*/MaxSessions 2/" /etc/ssh/sshd_config || \
  echo "MaxSessions 2" >> /etc/ssh/sshd_config

grep -q "^ClientAliveInterval" /etc/ssh/sshd_config && \
  sed -i "s/^ClientAliveInterval.*/ClientAliveInterval 300/" /etc/ssh/sshd_config || \
  echo "ClientAliveInterval 300" >> /etc/ssh/sshd_config

grep -q "^ClientAliveCountMax" /etc/ssh/sshd_config && \
  sed -i "s/^ClientAliveCountMax.*/ClientAliveCountMax 2/" /etc/ssh/sshd_config || \
  echo "ClientAliveCountMax 2" >> /etc/ssh/sshd_config

# Проверяем корректность конфига SSH перед перезапуском
if sshd -t 2>/dev/null; then
    echo "SSH конфигурация проверена — OK"
else
    echo "КРИТИЧЕСКАЯ ОШИБКА в SSH-конфигурации! Откат изменений..."
    cp /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
    exit 1
fi

# Перезапускаем SSH (учитываем разные имена юнитов)
systemctl restart ssh 2>/dev/null || systemctl restart sshd
if ! ss -tlnp | grep -q ":$SSH_PORT "; then
    echo "SSH не слушает порт $SSH_PORT! UFW не включаем."
    exit 1
fi
# Настраиваем UFW
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ${SSH_PORT}/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# Настраиваем Fail2Ban 
[ -f /etc/fail2ban/jail.local ] || cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local

systemctl enable fail2ban
systemctl restart fail2ban

# Настраиваем автоматические обновления безопасности 
sed -i 's|^//\?Unattended-Upgrade::Automatic-Reboot .*|Unattended-Upgrade::Automatic-Reboot "false";|' /etc/apt/apt.conf.d/50unattended-upgrades
grep -q 'Automatic-Reboot' /etc/apt/apt.conf.d/50unattended-upgrades || \
  echo 'Unattended-Upgrade::Automatic-Reboot "false";' >> /etc/apt/apt.conf.d/50unattended-upgrades
dpkg-reconfigure -f noninteractive unattended-upgrades

# Устанавливаем периодичность 
# Ежедневное обновление списка пакетов и установка обновлений безопасности,
# очистка устаревших пакетов раз в неделю.
cat <<EOF > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

cat <<EOF > /usr/local/bin/security-check.sh
#!/bin/bash

echo "=== Отчет по безопасности за $(date) ==="

# Проверяем количество неудачных попыток входа по SSH за последние 24 часа
echo "Failed SSH attempts in last 24h:"
journalctl --since "24 hours ago" | grep "Failed password" | wc -l

# Показываем статус Fail2Ban для службы SSH (показывает, есть ли заблокированные IP и т.д.)
echo "Fail2Ban status:"
fail2ban-client status sshd

# Отображаем активные сетевые соединения, фильтруем по порту 2244 (SSH)
echo "Active connections:"
ss -tuln | grep :$SSH_PORT

# Проверяем наличие доступных обновлений пакетов в системе
echo "Available updates:"
apt list --upgradable 2>/dev/null | wc -l
EOF

chown root:root /usr/local/bin/security-check.sh
chmod 755 /usr/local/bin/security-check.sh

# Создаем файл настроек 
cat <<EOF > /etc/sudoers.d/security-check-"$USERNAME"
$USERNAME ALL=(ALL) NOPASSWD:ALL
EOF

# Выставляем строгие права (sudoers требует 440, иначе sudo откажется работать)
chmod 440 /etc/sudoers.d/security-check-"$USERNAME"

# Создаем файл cron-задачи
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