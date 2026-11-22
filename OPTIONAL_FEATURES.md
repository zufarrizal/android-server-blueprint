# Optional Production Features — Ubuntu PRoot (Termux) Setup Guide

This guide explains how to install and wire each optional production feature when running your server inside **Ubuntu 24.04 LTS (PRoot)** on **Termux**.

---

## How Termux Host & Ubuntu PRoot Work Together

Because PRoot runs Ubuntu as an unprivileged userland container without `systemd`, keep this boundary in mind:

| Layer | What Runs Here | Why |
| :--- | :--- | :--- |
| **Termux Host** | `termux-wake-lock`, `cloudflared`, `tmux`, `watchdog.sh`, Android `/sys/class/thermal` | Direct access to Android wake-lock, hardware thermal sensors, and network tunnel daemon. |
| **Ubuntu 24.04 PRoot** (`--isolated`) | Nginx (`:8080`), Go SSR Relay (`:8081`), SQLite, Node.js/Tailwind build, `cwebp`, `yt-dlp`, `ffmpeg` | Standard Linux `apt` packages, `/var/www/html/`, `/etc/nginx/`, and glibc binaries work cleanly. |

> **Important PRoot Rules:**
> 1. **`systemctl` does not work in PRoot.** Always start background processes using `proot-distro login --isolated -d ubuntu -- <command>` or inside a Termux `tmux` session.
> 2. **Loopback (`127.0.0.1`) is shared.** `cloudflared` on Termux reaches Nginx on `127.0.0.1:8080`, and Nginx inside Ubuntu reaches your Go backend on `127.0.0.1:8081`.
> 3. **Use standard Ubuntu `apt` inside PRoot**, not Termux `pkg`, for server dependencies.

---

## Module 1: Golang SSR Engine, SQLite (WAL) & Telemetry (`:8081`)

### Step 1.1: Install Go, GCC & SQLite `[Ubuntu PRoot]`
Enter Ubuntu PRoot:
```bash
proot-distro login --isolated ubuntu
```
Inside Ubuntu, install Go, C compiler (needed by `go-sqlite3` CGO), and SQLite:
```bash
apt update && apt install -y golang-go build-essential sqlite3 libsqlite3-dev
mkdir -p /opt/myserver/data && cd /opt/myserver
go mod init myserver-relay
go get github.com/mattn/go-sqlite3
```

### Step 1.2: Create `/opt/myserver/main.go` `[Ubuntu PRoot]`
```go
package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

func getSoCTempC() float64 {
	// Termux host can write /tmp/soc_temp.txt into Ubuntu rootfs, or read /sys if exposed
	if b, err := os.ReadFile("/tmp/soc_temp.txt"); err == nil {
		if v, err := strconv.ParseFloat(strings.TrimSpace(string(b)), 64); err == nil {
			return v
		}
	}
	return 0
}

func initDB() *sql.DB {
	db, err := sql.Open("sqlite3", "/opt/myserver/data/store.db?_journal_mode=WAL&_synchronous=NORMAL&_busy_timeout=5000")
	if err != nil {
		log.Fatal(err)
	}
	_, _ = db.Exec(`CREATE TABLE IF NOT EXISTS products (id INTEGER PRIMARY KEY AUTOINCREMENT, slug TEXT UNIQUE, name TEXT, price TEXT);`)
	return db
}

func main() {
	db := initDB()
	defer db.Close()

	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":"online"}`))
	})
	mux.HandleFunc("/api/telemetry", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"temp_c": getSoCTempC(),
			"time":   time.Now().Format(time.RFC3339),
		})
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprintf(w, "<!DOCTYPE html><html lang='en'><body><h1>Ubuntu PRoot Go Node Online</h1><p>SoC Temp: %.1f C</p></body></html>", getSoCTempC())
	})

	log.Println("Go SSR listening on 127.0.0.1:8081")
	log.Fatal(http.ListenAndServe("127.0.0.1:8081", mux))
}
```
Compile inside Ubuntu PRoot:
```bash
cd /opt/myserver && go build -o /opt/myserver/relay-service .
exit
```

### Step 1.3: Bridge SoC Thermal from Termux Host (Optional) `[Termux Host]`
Because `--isolated` PRoot hides Android `/sys`, a 1-line cron/loop on Termux writes the thermal readout into Ubuntu's `/tmp/soc_temp.txt`:
```bash
UBUNTU_TMP="/data/data/com.termux/files/usr/var/lib/proot-distro/containers/ubuntu/rootfs/tmp/soc_temp.txt"
cat /sys/class/thermal/thermal_zone0/temp | awk '{printf "%.1f\n", $1/1000}' > "$UBUNTU_TMP"
```

### Step 1.4: Run Go Relay in `tmux` & Configure Nginx `[Termux Host + Ubuntu PRoot]`
Start the Ubuntu Go binary from Termux inside `tmux`:
```bash
tmux new-session -d -s relay "proot-distro login --isolated ubuntu -- /opt/myserver/relay-service"
```
Configure `/etc/nginx/sites-available/default` inside Ubuntu PRoot:
```nginx
upstream relay_backend {
    server 127.0.0.1:8081;
    keepalive 64;
}

server {
    listen 8080 default_server;
    root /var/www/html;

    location / {
        proxy_pass http://relay_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header CF-Connecting-IP $http_cf_connecting_ip;
        proxy_set_header CF-IPCountry $http_cf_ipcountry;
    }
}
```
Reload and test:
```bash
proot-distro login --isolated ubuntu -- nginx -t && proot-distro login --isolated ubuntu -- nginx -s reload
curl -s http://127.0.0.1:8080/api/telemetry
```

---

## Module 2: Rate Limiter Middleware & OWASP Security Headers

### Step 2.1: Add Per-IP Rate Limiter (`guard.go`) `[Ubuntu PRoot]`
Create `/opt/myserver/guard.go` inside Ubuntu and wrap `mux` with `rateLimitMiddleware(mux, 90)`:
```go
package main

import (
	"net/http"
	"strconv"
	"sync"
	"time"
)

type bucket struct {
	tokens float64
	last   time.Time
}

var (
	guardMu sync.Mutex
	buckets = map[string]*bucket{}
)

func rateLimitMiddleware(next http.Handler, limitPerMin float64) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ip := r.Header.Get("CF-Connecting-IP")
		if ip == "" {
			ip = r.RemoteAddr
		}
		guardMu.Lock()
		b, ok := buckets[ip]
		if !ok {
			b = &bucket{tokens: limitPerMin, last: time.Now()}
			buckets[ip] = b
		}
		elapsed := time.Since(b.last).Minutes()
		b.tokens = min(limitPerMin, b.tokens+elapsed*limitPerMin)
		b.last = time.Now()
		allowed := b.tokens >= 1
		if allowed {
			b.tokens -= 1
		}
		rem := int(b.tokens)
		guardMu.Unlock()

		w.Header().Set("X-RateLimit-Limit", "90")
		w.Header().Set("X-RateLimit-Remaining", strconv.Itoa(rem))
		if !allowed {
			http.Error(w, "Rate limit exceeded", http.StatusTooManyRequests)
			return
		}
		next.ServeHTTP(w, r)
	})
}
```

### Step 2.2: Add OWASP & COOP Headers in Nginx `[Ubuntu PRoot]`
Inside `/etc/nginx/sites-available/default` (`server { ... }`):
```nginx
server_tokens off;
location ~ /\. { deny all; access_log off; log_not_found off; }

add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
add_header Cross-Origin-Opener-Policy "same-origin" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
```

---

## Module 3: PageSpeed 100/100/100/100 Frontend & `/llms.txt`

### Step 3.1: Install Node.js & Build Purged CSS `[Ubuntu PRoot]`
Inside Ubuntu PRoot (`npx` and `/usr/bin/env` work natively without Termux shebang issues):
```bash
proot-distro login --isolated ubuntu -- bash -c "
  apt update && apt install -y nodejs npm
  mkdir -p /opt/myserver/css-build /var/www/html/assets
  cd /opt/myserver/css-build
  npm init -y && npm install -D tailwindcss@3 daisyui@4
"
```
Create `/opt/myserver/css-build/tailwind.config.js` and `input.css`, then compile:
```bash
proot-distro login --isolated ubuntu -- bash -c "
  cd /opt/myserver/css-build
  npx tailwindcss -i ./input.css -o /var/www/html/assets/app.min.css --minify
"
```
Inline `/var/www/html/assets/app.min.css` in your Go layout `<style>{{.InlineCSS}}</style>` (cached via `sync.Once`) and load Google Fonts (`display=optional`) + icons asynchronously (`media="print" onload="this.media='all'"`).

### Step 3.2: Add `/llms.txt` `[Ubuntu PRoot]`
```bash
cat <<'EOF' > /var/www/html/llms.txt
# My Android Server Node

> 24/7 self-hosted server running on ARM64 Android + Ubuntu 24.04 PRoot + Golang SSR.

## Core Pages
- [Home](https://yourdomain.com/): Live telemetry and overview.
- [Products](https://yourdomain.com/products): Services and packages.
EOF
```
Add to `/etc/nginx/sites-available/default`:
```nginx
location = /llms.txt {
    default_type text/markdown;
    try_files /llms.txt =404;
}
```

---

## Module 4: Cloudflare Edge Worker + KV Zero-Downtime Failover

### Step 4.1: Deploy Wrangler from Ubuntu PRoot `[Ubuntu PRoot]`
```bash
proot-distro login --isolated ubuntu -- bash -c "
  npm install -g wrangler
  wrangler login
  wrangler kv namespace create ADMIN_KV
"
```
Create `/opt/edge-worker/wrangler.toml` and `index.js` (caching `200 OK` HTML into `ADMIN_KV` and serving `FLIGHT MODE` snapshots if your PRoot server is offline/rebooting), then run:
```bash
proot-distro login --isolated ubuntu -- bash -c "cd /opt/edge-worker && wrangler deploy"
```

---

## Module 5: WebP Auto-Negotiation, `cwebp` & OpenGraph Banner

### Step 5.1: Install `webp` Inside Ubuntu PRoot `[Ubuntu PRoot]`
```bash
proot-distro login --isolated ubuntu -- apt install -y webp
```
Create `/etc/nginx/conf.d/webp.conf`:
```nginx
map $http_accept $webp_suffix {
    default "";
    "~*webp" ".webp";
}
```
Add to `/etc/nginx/sites-available/default`:
```nginx
location = /assets/og-banner.png {
    add_header Cache-Control "public, max-age=3600";
    try_files $uri =404;
}

location ~* ^/assets/.+\.(?:jpe?g|png)$ {
    add_header Vary Accept;
    add_header Cache-Control "public, max-age=2592000, immutable";
    try_files $uri$webp_suffix $uri =404;
}
```
Convert images via Go (`exec.Command("cwebp", ...)`) or CLI inside Ubuntu:
```bash
cwebp -q 82 -resize 1200 0 -m 4 -metadata none input.png -o /var/www/html/assets/products/item-cover.webp
```

---

## Module 6: PDF Invoice Generator (`gofpdf`) `[Ubuntu PRoot]`

Inside `/opt/myserver` in Ubuntu PRoot:
```bash
go get github.com/jung-kurt/gofpdf
```
Register `/invoice/pdf` in Go to stream generated PDFs (`Content-Type: application/pdf`) directly from SQLite invoice records.

---

## Module 7: Telegram Bot Control Plane & Thermal Alerts

### Step 7.1: Configure `.env` Inside `/opt/myserver/.env` `[Ubuntu PRoot]`
```env
TELEGRAM_BOT_TOKEN="123456:ABC-DEF..."
TELEGRAM_CHAT_ID="your_numeric_chat_id"
```
Run an outbound long-polling goroutine in Go (no open inbound port needed) + a 30s ticker reading `/tmp/soc_temp.txt` (bridged from Termux) to fire alerts if `temp >= 65.0°C`.

---

## Module 8: Self-Hosted Media Downloader (`yt-dlp` + `ffmpeg`) `[Ubuntu PRoot]`

### Step 8.1: Install inside Ubuntu PRoot
```bash
proot-distro login --isolated ubuntu -- bash -c "
  apt update && apt install -y python3 python3-pip ffmpeg
  pip3 install --break-system-packages -U yt-dlp
"
```
Test extraction inside Ubuntu PRoot:
```bash
proot-distro login --isolated ubuntu -- yt-dlp --dump-json --skip-download "https://www.youtube.com/watch?v=dQw4w9WgXcQ" | head -c 300
```

---

## Module 9: Load Tester (`/benchmark`) & Live Market Radar (`/trading`)

### Step 9.1: Install Python WebSocket Client inside Ubuntu PRoot `[Ubuntu PRoot]`
```bash
proot-distro login --isolated ubuntu -- pip3 install --break-system-packages websocket-client
```
Run your TradingView WebSocket sync script (`tv_sunflow_sync.py`) inside PRoot via `tmux` or a Go ticker, writing `trading_cache.json` to `/opt/myserver/data/trading_cache.json` with adaptive bar expansion (`800 -> 2000 -> 5000` bars) so every timeframe maintains at least 3 valid Order Blocks.

---

## Module 10: Dual-Tier Watchdog for PRoot Daemons `[Termux Host]`

Because PRoot has no `systemd`, supervise **both** Ubuntu PRoot daemons (Nginx + Go Relay) and the Termux `cloudflared` tunnel from Termux `~/scripts/watchdog.sh`:

```bash
#!/data/data/com.termux/files/usr/bin/bash
UBUNTU_TMP="/data/data/com.termux/files/usr/var/lib/proot-distro/containers/ubuntu/rootfs/tmp/soc_temp.txt"

while true; do
  # 1. Bridge hardware SoC temp to Ubuntu PRoot
  if [ -r /sys/class/thermal/thermal_zone0/temp ]; then
    awk '{printf "%.1f\n", $1/1000}' /sys/class/thermal/thermal_zone0/temp > "$UBUNTU_TMP"
  fi

  # 2. Fast-Heal Nginx (:8080) inside Ubuntu PRoot
  curl -sf http://127.0.0.1:8080/ >/dev/null || \
    proot-distro login --isolated -d ubuntu -- nginx -g "daemon off;"

  # 3. Fast-Heal Go Relay (:8081) inside Ubuntu PRoot
  curl -sf http://127.0.0.1:8081/health >/dev/null || \
    tmux new-session -d -s relay "proot-distro login --isolated ubuntu -- /opt/myserver/relay-service"

  # 4. Fast-Heal Cloudflare Tunnel on Termux Host
  tmux has-session -t tunnel 2>/dev/null || \
    tmux new-session -d -s tunnel "cloudflared tunnel run my-phone-server"

  sleep 5
done
```
Start it on Termux:
```bash
chmod +x ~/scripts/watchdog.sh
tmux new-session -d -s watchdog "~/scripts/watchdog.sh"
```
