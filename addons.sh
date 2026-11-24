#!/bin/bash

# Остановка скрипта при возникновении ошибки
set -e

echo "🚀 === Начало установки Zsh и Oh My Zsh ==="

# 1. Установка зависимостей (zsh, git, curl) в зависимости от пакетного менеджера
echo "📦 Обновление списков пакетов и установка зависимостей..."
if command -v apt-get &> /dev/null; then
    sudo apt-get update
    sudo apt-get install -y zsh git curl tmux
elif command -v dnf &> /dev/null; then
    sudo dnf install -y zsh git curl tmux
elif command -v yum &> /dev/null; then
    sudo yum install -y zsh git curl tmux
elif command -v pacman &> /dev/null; then
    sudo pacman -Sy --noconfirm zsh git curl tmux
else
    echo "❌ Ошибка: Не найден поддерживаемый пакетный менеджер. Установите tmux, zsh, git и curl вручную."
    exit 1
fi

# Установка и настройка tmux
echo "Настроиваем tmux"

if [ -f ~/.tmux.conf ]; then 
rm ~/.tmux.conf
fi

git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm

# Копирование конфига TODO исправить под себя
cat <<'EOF' > ~/.tmux.conf 
set -g default-terminal "screen-256color"

bind s chose-tree -sZ -O name
set -g base-index 1
setw -g pane-base-index 1

# remap prefix from 'C-b' to 'C-a'
unbind C-b
set-option -g prefix C-a
bind-key C-a send-prefix

# reload config file (change file location to your the tmux.conf you want to use)
bind r source-file ~/.tmux.conf

# switch panes using Alt-arrow without prefix
bind -n M-Left select-pane -L
bind -n M-Right select-pane -R
bind -n M-Up select-pane -U
bind -n M-Down select-pane -D

# Enable mouse control (clickable windows, panes, resizable panes)
set -g mouse on

# don't rename windows automatically
set-option -g allow-rename off

# DESIGN TWEAKS

# don't do anything when a 'bell' rings
set -g visual-activity off
set -g visual-bell off
set -g visual-silence off
setw -g monitor-activity off
set -g bell-action none

# clock mode
setw -g clock-mode-colour yellow

# copy mode
setw -g mode-style 'fg=black bg=red bold'

# panes
set -g pane-border-style 'fg=red'
set -g pane-active-border-style 'fg=yellow'

# statusbar
set -g status-position bottom
set -g status-justify left
set -g status-style 'fg=red'

set -g status-left ''
set -g status-left-length 10

set -g status-right-style 'fg=black bg=yellow'
set -g status-right '%Y-%m-%d %H:%M '
set -g status-right-length 50

setw -g window-status-current-style 'fg=black bg=red'
setw -g window-status-current-format ' #I #W #F '

setw -g window-status-style 'fg=red bg=black'
setw -g window-status-format ' #I #[fg=white]#W #[fg=yellow]#F '

setw -g window-status-bell-style 'fg=yellow bg=red bold'

# messages
set -g message-style 'fg=yellow bg=red bold'

# List of plugins
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-sensible'
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'
set -g @plugin 'tmux-plugins/tmux-sessionist'

set -g @resurrect-capture-pane-contents 'on'
set -g @continuum-restore 'on'

# Initialize TMUX plugin manager (keep this line at the very bottom of tmux.conf)
run '~/.tmux/plugins/tpm/tpm'
EOF

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
if grep -q '^plugins=' ~/.zshrc; then
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