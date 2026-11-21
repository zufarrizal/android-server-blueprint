#!/data/data/com.termux/files/usr/bin/bash
while true; do
    sleep 5
    # Health check Nginx (:8080)
    if ! curl -s -m 2 -I http://127.0.0.1:8080/ >/dev/null 2>&1; then
        echo "[$(date)] Reviving Nginx daemon..."
        proot-distro login --isolated -d ubuntu -- nginx -g "daemon off;" >/dev/null 2>&1
        sleep 1
    fi
done
