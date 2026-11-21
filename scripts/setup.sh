#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

echo "[1/4] Acquiring Termux CPU wake-lock..."
termux-wake-lock

echo "[2/4] Installing host packages..."
pkg update -y && pkg install -y proot-distro tmux curl git openssh

echo "[3/4] Installing Ubuntu PRoot..."
if ! proot-distro list | grep -q "ubuntu.*installed"; then
    proot-distro install ubuntu
fi

echo "[4/4] Configuring Nginx inside Ubuntu on port 8080..."
proot-distro login --isolated ubuntu -- bash -c "
    apt update -y && apt install -y nginx && apt clean
    sed -i 's/listen 80 default_server;/listen 8080 default_server;/g' /etc/nginx/sites-available/default
    sed -i 's/listen \[::\]:80 default_server;/listen \[::\]:8080 default_server;/g' /etc/nginx/sites-available/default
"

proot-distro login --isolated -d ubuntu -- nginx -g "daemon off;"
sleep 2

if curl -sI http://127.0.0.1:8080/ >/dev/null 2>&1; then
    echo "[SUCCESS] Nginx is running inside Ubuntu PRoot on http://127.0.0.1:8080/"
fi
