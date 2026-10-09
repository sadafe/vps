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
if [ -z "$USERNAME" ]; then
    echo "Ошибка: имя пользователя не может быть пустым."
    exit 1
fi

read -p "Введите желаемый порт SSH (например, 2244): " SSH_PORT
# Простая проверка, что порт — число
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]]; then
    echo "Ошибка: порт должен быть числом."
    exit 1
fi

echo "Вставьте ваш публичный SSH-ключ (формат ssh-ed25519/rsa ...) и нажмите Ctrl+D после вставки:"
# Читаем ключ многострочно до EOF (Ctrl+D)
SSH_KEY=$(cat)
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

# Обновляем систему
apt update && apt upgrade -y
# Устанавливаем необходимые пакеты
apt install -y ufw fail2ban rkhunter lynis unattended-upgrades sudo

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
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

# Настраиваем конфиг ssh
sed -i "/^#\?Port /c\Port $SSH_PORT" /etc/ssh/sshd_config
sed -i "/^#\?PermitRootLogin /c\PermitRootLogin prohibit-password" /etc/ssh/sshd_config
sed -i "/^#\?PasswordAuthentication /c\PasswordAuthentication no" /etc/ssh/sshd_config
sed -i "/^#\?PubkeyAuthentication  /c\PubkeyAuthentication yes" /etc/ssh/sshd_config

grep -q "^AllowUsers" /etc/ssh/sshd_config || echo "AllowUsers $USERNAME" >> /etc/ssh/sshd_config
sed -i "/^AllowUsers /c\AllowUsers $USERNAME" /etc/ssh/sshd_config

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
    echo "Ошибка в SSH-конфигурации! Проверь /etc/ssh/sshd_config"
    exit 1
fi

# Перезапускаем SSH (учитываем разные имена юнитов)
systemctl restart ssh 2>/dev/null || systemctl restart sshd

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
echo 'Unattended-Upgrade::Automatic-Reboot "false";' >> /etc/apt/apt.conf.d/50unattended-upgrades
dpkg-reconfigure -fnoninteractive unattended-upgrades

# Устанавливаем периодичность 
# Ежедневное обновление списка пакетов и установка обновлений безопасности,
# очистка устаревших пакетов раз в неделю.
cat <<EOF > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

echo
echo " Настройка завершена успешно "
echo "SSH теперь работает на порту $SSH_PORT"
echo "Вход разрешён только по ключу для пользователя: $USERNAME"
echo "Root-вход отключён."