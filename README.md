# vps

Добавлена информация из https://habr.com/ru/companies/lansoft_career/articles/956730/

## Внутренний аудит
''' sh
# Проверяем конфигурацию SSH
sudo sshd -T | grep -E "port|permitrootlogin|passwordauthentication"
# Ожидаемый результат:
# port 2245 (или ваш порт)
# permitrootlogin no
# passwordauthentication no
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
'''