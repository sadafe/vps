#!/bin/bash

# Остановка скрипта при возникновении ошибки
set -e

echo "🚀 === Начало установки Zsh и Oh My Zsh ==="

# 1. Установка зависимостей (zsh, git, curl) в зависимости от пакетного менеджера
echo "📦 Обновление списков пакетов и установка зависимостей..."
if command -v apt-get &> /dev/null; then
    sudo apt-get update
    sudo apt-get install -y zsh git curl
elif command -v dnf &> /dev/null; then
    sudo dnf install -y zsh git curl
elif command -v yum &> /dev/null; then
    sudo yum install -y zsh git curl
elif command -v pacman &> /dev/null; then
    sudo pacman -Sy --noconfirm zsh git curl
else
    echo "❌ Ошибка: Не найден поддерживаемый пакетный менеджер. Установите zsh, git и curl вручную."
    exit 1
fi

# 2. Установка Oh My Zsh (в автоматическом режиме без вопросов)
echo "🛠 Установка Oh My Zsh..."
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
else
    echo "ℹ️ Oh My Zsh уже установлен. Пропускаем..."
fi

# 3. Клонирование плагинов
echo "🔌 Установка плагинов zsh-autosuggestions и zsh-syntax-highlighting..."
ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

if [ ! -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]; then
    git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM}/plugins/zsh-autosuggestions
else
    echo "ℹ️ zsh-autosuggestions уже установлен. Пропускаем..."
fi

if [ ! -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ]; then
    git clone https://github.com/zsh-users/zsh-syntax-highlighting ${ZSH_CUSTOM}/plugins/zsh-syntax-highlighting
else
    echo "ℹ️ zsh-syntax-highlighting уже установлен. Пропускаем..."
fi

# 4. Активация плагинов в .zshrc
echo "⚙️ Настройка конфигурационного файла ~/.zshrc..."
if grep -q "^plugins=" ~/.zshrc; then
    # Заменяем существующую строку plugins
    sed -i 's/^plugins=.*/plugins=(git zsh-autosuggestions zsh-syntax-highlighting sudo)/' ~/.zshrc
else
    # Если строки нет, добавляем в конец
    echo "plugins=(git zsh-autosuggestions zsh-syntax-highlighting sudo)" >> ~/.zshrc
fi

# Смена оболочки по умолчанию на zsh
ZSH_PATH=$(command -v zsh)

# 1. Убедимся, что zsh есть в /etc/shells
if ! grep -qx "$ZSH_PATH" /etc/shells 2>/dev/null; then
    echo "$ZSH_PATH" | sudo tee -a /etc/shells > /dev/null
fi

# 2. Меняем оболочку (с явным указанием пользователя)
if [ "$SHELL" != "$ZSH_PATH" ]; then
    sudo chsh -s "$ZSH_PATH" "$USER"
    echo "✅ Оболочка по умолчанию изменена на $ZSH_PATH"
else
    echo "ℹ️ Zsh уже является вашей оболочкой по умолчанию."
fi

echo "🎉 === Установка успешно завершена! ==="
echo "⚠️  Пожалуйста, перезапустите SSH-сессию (выйдите и зайдите снова) или выполните 'source ~/.zshrc', чтобы изменения вступили в силу."