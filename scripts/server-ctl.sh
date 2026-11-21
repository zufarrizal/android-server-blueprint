#!/data/data/com.termux/files/usr/bin/bash
ACTION="${1:-status}"

case "$ACTION" in
    start)
        termux-wake-lock 2>/dev/null || true
        proot-distro login --isolated -d ubuntu -- nginx -g "daemon off;" >/dev/null 2>&1 || true
        if [ -f "$HOME/.cloudflared/config.yml" ] && ! tmux has-session -t tunnel 2>/dev/null; then
            tmux new-session -d -s tunnel "cloudflared tunnel run"
        fi
        echo "[OK] Services started."
        ;;
    stop)
        tmux kill-session -t tunnel 2>/dev/null || true
        tmux kill-session -t watchdog 2>/dev/null || true
        proot-distro login --isolated ubuntu -- nginx -s stop >/dev/null 2>&1 || true
        termux-wake-unlock 2>/dev/null || true
        echo "[OK] Services stopped."
        ;;
    status)
        echo "=== Server Status ==="
        if curl -s -m 2 -I http://127.0.0.1:8080/ >/dev/null 2>&1; then
            echo "  Nginx (Ubuntu :8080):  ONLINE"
        else
            echo "  Nginx (Ubuntu :8080):  OFFLINE"
        fi
        tmux ls 2>/dev/null || echo "  No active tmux sessions."
        ;;
    restart)
        $0 stop
        sleep 1
        $0 start
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
