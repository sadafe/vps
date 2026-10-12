# vps

Добавлена информация из https://habr.com/ru/companies/lansoft_career/articles/956730/

Склонировать репозиторий на хостовую машину
``` shell
git clone https://github.com/sadafe/vps.git && cd vps
```

с рабочей машины создаем SSH ключ для доступа к серверу
``` shell
ssh-keygen -t ed25519 -C "комментарий" -f .ssh/имяключа
```

Открываем полученный SSH ключ

Linux
``` shell
nano ~/.ssh/имяключа.pub
```

Windows
``` shell
type "%USERPROFILE%\.ssh\имяключа.pub"
```
копируем полученный ключ от начала до конца

на хостовой машине запускаем 
``` shell
chmod +x secure-server.sh
./secure-server.sh
```



## Внутренний аудит
``` shell
# Проверяем конфигурацию SSH
sudo sshd -T | grep -E "port|permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication"
# Ожидаемый результат:
# port 2245 (или ваш порт)
# permitrootlogin prohibit-password
# passwordauthentication no
# PubkeyAuthentication yes
# KbdInteractiveAuthentication no
# Статус файрвола
sudo ufw status verbose
# Проверяем активные правила
sudo ufw status numbered
# Логи неудачных попыток входа за последние 24 часа
sudo journalctl --since "24 hours ago" | grep "Failed password" | wc -l
# Статус служб
systemctl status ufw fail2ban
# Проверяем, что службы включены при загрузке
systemctl is-enabled ufw fail2ban
# Статистика Fail2Ban
sudo fail2ban-client status sshd
# Список заблокированных IP
sudo fail2ban-client get sshd banip
# Анализ сетевой активности
# Проверка открытых портов (на каких портах система принимает входящие подключения)
sudo ss -tuln | grep LISTEN
# Проверка активных сетевых соединений (текущие установленные подключения)
sudo ss -tunap | grep ESTABLISHED
# Для идентификации незнакомых IP:
# whois <IP_адрес>
# Статистика бана за сутки
cat /var/log/security-check.log
# Посмотреть кто и когда последний раз авторизировался
grep "Accepted" /var/log/auth.log
```