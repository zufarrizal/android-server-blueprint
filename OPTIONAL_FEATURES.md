# Optional Production Features — Step-by-Step Build Tutorial

This hands-on tutorial shows you how to build and layer each optional production module onto the base **Android Server Blueprint** (`Termux + Ubuntu 24.04 PRoot + Nginx :8080 + Cloudflare Named Tunnel`). Every section includes exact commands, copy-pasteable code/configs, and verification steps.

---

## Module 1: Golang SSR Engine, Hardware Telemetry & SQLite (WAL)

### Step 1.1: Install Go inside Termux
```bash
pkg install -y golang sqlite
mkdir -p ~/relay/data && cd ~/relay
go mod init myserver-relay
go get github.com/mattn/go-sqlite3
```

### Step 1.2: Create the Go Server (`~/relay/main.go`)
```go
package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

func getSoCTempC() float64 {
	zones, _ := filepath.Glob("/sys/class/thermal/thermal_zone*/temp")
	for _, z := range zones {
		if b, err := os.ReadFile(z); err == nil {
			if v, err := strconv.ParseFloat(strings.TrimSpace(string(b)), 64); err == nil && v > 0 {
				if v > 1000 {
					v /= 1000.0
				}
				return v
			}
		}
	}
	return 0
}

func initDB() *sql.DB {
	db, err := sql.Open("sqlite3", "./data/store.db?_journal_mode=WAL&_synchronous=NORMAL&_busy_timeout=5000")
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
		fmt.Fprintf(w, "<!DOCTYPE html><html lang='en'><body><h1>Android Node Online</h1><p>SoC Temp: %.1f C</p></body></html>", getSoCTempC())
	})

	log.Println("Go SSR listening on 127.0.0.1:8081")
	log.Fatal(http.ListenAndServe("127.0.0.1:8081", mux))
}
```

### Step 1.3: Build, Run in `tmux`, and Proxy via Nginx
```bash
cd ~/relay && go build -o relay-service .
tmux new-session -d -s relay "~/relay/relay-service"
```
Update Nginx (`/etc/nginx/sites-available/default`) inside Ubuntu PRoot:
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
Reload and verify:
```bash
proot-distro login --isolated ubuntu -- nginx -t && proot-distro login --isolated ubuntu -- nginx -s reload
curl -s http://127.0.0.1:8080/api/telemetry
```

---

## Module 2: Rate Limiter Middleware, IP Reputation & OWASP Headers

### Step 2.1: Add Per-IP Token-Bucket Middleware (`~/relay/guard.go`)
```go
package main

import (
	"net/http"
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

### Step 2.2: Add OWASP & Origin Isolation Headers in Nginx
Add inside the `server { ... }` block of `/etc/nginx/sites-available/default`:
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
Verify headers:
```bash
curl -sI https://yourdomain.com/ | grep -iE "strict-transport|cross-origin|x-ratelimit"
```

---

## Module 3: PageSpeed 100/100/100/100 Frontend & `/llms.txt`

### Step 3.1: Compile & Purge Tailwind + DaisyUI at Build Time
Avoid runtime `tailwind.js` and unpurged `daisyui.min.css`. Install the build CLI once in Termux:
```bash
pkg install -y nodejs
mkdir -p ~/relay/css-build && cd ~/relay/css-build
npm init -y && npm install -D tailwindcss@3 daisyui@4
```
Create `~/relay/css-build/tailwind.config.js`:
```js
module.exports = {
  content: ["../views/**/*.html", "../*.go"],
  plugins: [require("daisyui")],
  daisyui: { themes: ["night"], logs: false }
};
```
Create `~/relay/css-build/input.css`:
```css
@tailwind base;
@tailwind components;
@tailwind utilities;
```
Build the purged stylesheet (~20 KB gzipped):
```bash
node ./node_modules/tailwindcss/lib/cli.js -i ./input.css -o /data/data/com.termux/files/usr/var/lib/proot-distro/containers/ubuntu/rootfs/var/www/html/assets/app.min.css --minify
```

### Step 3.2: Inline Purged CSS & Async Fonts in Your Layout `<head>`
Load `app.min.css` once in Go (`sync.Once` + `os.ReadFile`) and render `<style>{{.InlineCSS}}</style>` so there are **0 render-blocking CSS requests**. Load Google Fonts (`display=optional` for 0 CLS) and icons asynchronously:
```html
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;600;700&display=optional" rel="stylesheet" media="print" onload="this.media='all'">
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css" media="print" onload="this.media='all'">
<script src="/assets/htmx.min.js" defer></script>
```

### Step 3.3: Add `/llms.txt` for AI Agent Discoverability
Create `/var/www/html/llms.txt` inside Ubuntu PRoot:
```markdown
# My Android Server Node

> 24/7 self-hosted server running on ARM64 Android + Ubuntu 24.04 PRoot + Golang SSR.

## Core Pages
- [Home](https://yourdomain.com/): Live telemetry and overview.
- [Products](https://yourdomain.com/products): Services and packages.
```
Expose it in Nginx:
```nginx
location = /llms.txt {
    default_type text/markdown;
    try_files /llms.txt =404;
}
```
Verify:
```bash
curl -sI https://yourdomain.com/llms.txt
```

---

## Module 4: Cloudflare Edge Worker + KV Zero-Downtime Failover

### Step 4.1: Create KV Namespace & Configure Wrangler
```bash
npm install -g wrangler
wrangler login
wrangler kv namespace create ADMIN_KV
```
Create `~/edge-worker/wrangler.toml`:
```toml
name = "android-edge-failover"
main = "index.js"
compatibility_date = "2024-01-01"

routes = [
  { pattern = "yourdomain.com/*", zone_name = "yourdomain.com" }
]

[[kv_namespaces]]
binding = "ADMIN_KV"
id = "<YOUR_KV_NAMESPACE_ID>"
```

### Step 4.2: Create `~/edge-worker/index.js`
```javascript
const ORIGIN_URL = "https://yourdomain.com";
const BYPASS_PREFIXES = ["/admin", "/api/send-message", "/api/webhook"];

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (request.headers.get("X-Edge-Bypass") === "1") {
      return fetch(request);
    }

    const bypass = BYPASS_PREFIXES.some(p => url.pathname.startsWith(p));
    const snapKey = `snapshot:${url.pathname}`;

    try {
      const headers = new Headers(request.headers);
      headers.set("X-Edge-Bypass", "1");
      const res = await fetch(new Request(ORIGIN_URL + url.pathname + url.search, {
        method: request.method, headers,
        body: (request.method !== "GET" && request.method !== "HEAD") ? request.body : undefined
      }));

      if (res.ok) {
        const ct = res.headers.get("Content-Type") || "";
        if (!bypass && request.method === "GET" && ct.includes("text/html") && env.ADMIN_KV) {
          ctx.waitUntil(res.clone().text().then(body => env.ADMIN_KV.put(snapKey, body)));
        }
        const out = new Headers(res.headers);
        out.set("X-Node-Mode", "DIRECT");
        return new Response(res.body, { status: res.status, headers: out });
      }
    } catch (_) {}

    // Origin unreachable -> Flight Mode KV Failover
    if (env.ADMIN_KV) {
      const snap = await env.ADMIN_KV.get(snapKey);
      if (snap) {
        return new Response(snap, {
          status: 200,
          headers: { "Content-Type": "text/html; charset=utf-8", "X-Node-Mode": "FLIGHT" }
        });
      }
    }
    return new Response("Origin temporarily offline", { status: 503 });
  }
};
```
Deploy:
```bash
cd ~/edge-worker && wrangler deploy
```

---

## Module 5: WebP Auto-Negotiation, `cwebp` Pipeline & OpenGraph Banner

### Step 5.1: Install `cwebp` & Configure Nginx WebP Negotiation
```bash
pkg install -y libwebp
```
Inside Ubuntu PRoot, create `/etc/nginx/conf.d/webp.conf`:
```nginx
map $http_accept $webp_suffix {
    default "";
    "~*webp" ".webp";
}
```
Add these blocks to `/etc/nginx/sites-available/default`:
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

### Step 5.2: Convert Uploaded Images Automatically
```bash
cwebp -q 82 -resize 1200 0 -m 4 -metadata none input.png -o /var/www/html/assets/products/item-cover.webp
```

### Step 5.3: Add Full OpenGraph & Twitter Card Tags (`<head>`)
```html
<meta property="og:title" content="My Android Server Node">
<meta property="og:description" content="24/7 ARM64 self-hosted server.">
<meta property="og:url" content="https://yourdomain.com/">
<meta property="og:type" content="website">
<meta property="og:image" content="https://yourdomain.com/assets/og-banner.png">
<meta property="og:image:secure_url" content="https://yourdomain.com/assets/og-banner.png">
<meta property="og:image:type" content="image/png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="My Android Server Node">
<meta name="twitter:description" content="24/7 ARM64 self-hosted server.">
<meta name="twitter:image" content="https://yourdomain.com/assets/og-banner.png">
```

---

## Module 6: PDF Invoice Generator & Webhook Integration

### Step 6.1: Install `gofpdf`
```bash
cd ~/relay && go get github.com/jung-kurt/gofpdf
```

### Step 6.2: Render Invoice PDFs Directly in Go (`~/relay/pdf_invoice.go`)
```go
package main

import (
	"net/http"
	"github.com/jung-kurt/gofpdf"
)

func handleInvoicePDF(w http.ResponseWriter, r *http.Request) {
	pdf := gofpdf.New("P", "mm", "A4", "")
	pdf.AddPage()
	pdf.SetFont("Arial", "B", 16)
	pdf.Cell(40, 10, "INVOICE #INV-001")
	pdf.Ln(12)
	pdf.SetFont("Arial", "", 12)
	pdf.Cell(40, 8, "Service: Full-Stack Server Deployment")

	w.Header().Set("Content-Type", "application/pdf")
	w.Header().Set("Content-Disposition", `inline; filename="invoice.pdf"`)
	_ = pdf.Output(w)
}
```

---

## Module 7: Telegram Control Plane, Thermal Alerts & AI Core

### Step 7.1: Create `.env` (Excluded from Git)
```bash
cat <<'EOF' > ~/relay/.env
TELEGRAM_BOT_TOKEN="123456:ABC-DEF..."
TELEGRAM_CHAT_ID="your_numeric_chat_id"
EOF
```

### Step 7.2: Outbound Long-Polling & Thermal Alert Worker (`~/relay/telegram.go`)
```go
package main

import (
	"fmt"
	"net/http"
	"net/url"
	"os"
	"time"
)

func sendTelegram(text string) {
	token := os.Getenv("TELEGRAM_BOT_TOKEN")
	chatID := os.Getenv("TELEGRAM_CHAT_ID")
	endpoint := fmt.Sprintf("https://api.telegram.org/bot%s/sendMessage", token)
	_, _ = http.PostForm(endpoint, url.Values{
		"chat_id": {chatID},
		"text":    {text},
	})
}

func startThermalMonitor() {
	for range time.Tick(30 * time.Second) {
		if temp := getSoCTempC(); temp >= 65.0 {
			sendTelegram(fmt.Sprintf("🔥 Thermal Alert: SoC Temp %.1f°C", temp))
		}
	}
}
```

### Step 7.3: CLI SITREP Helper (`~/bin/telegram-sitrep`)
```bash
#!/data/data/com.termux/files/usr/bin/bash
source ~/relay/.env
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=$1" >/dev/null
```
```bash
chmod +x ~/bin/telegram-sitrep
~/bin/telegram-sitrep "Server deployment verified!"
```

---

## Module 8: Self-Hosted Media Downloader (`yt-dlp` + `ffmpeg`)

### Step 8.1: Install Dependencies
```bash
pkg install -y python ffmpeg
pip install -U yt-dlp
```

### Step 8.2: Extract Metadata & Stream Downloads from Go
Invoke `yt-dlp` cleanly from a Go handler using `exec.CommandContext`:
```go
// Metadata endpoint (/api/yt/info?url=...)
cmd := exec.CommandContext(ctx, "yt-dlp", "--dump-json", "--no-playlist", targetURL)
out, err := cmd.Output()
```
Verify CLI extraction:
```bash
yt-dlp --dump-json --skip-download "https://www.youtube.com/watch?v=dQw4w9WgXcQ" | head -c 300
```

---

## Module 9: Built-In Load Tester (`/benchmark`) & Live Market Radar (`/trading`)

### Step 9.1: Concurrent HTTP Benchmark Handler in Go
Use a bounded goroutine pool (`sync.WaitGroup` + `chan struct{}`) to benchmark `http://127.0.0.1:8080/` and measure RPS, P95 latency, and SoC temperature before/after load.

### Step 9.2: Adaptive Multi-Timeframe TradingView WebSocket Sync
Install Python WebSocket client:
```bash
pip install websocket-client
```
Connect anonymously to `wss://data.tradingview.com/socket.io/websocket` and use adaptive bar lookback (`800 -> 2000 -> 5000` bars) so higher timeframes (like `30M`) always surface at least 3 valid unbroken Order Blocks into `~/relay/data/trading_cache.json`.

---

## Module 10: Dual-Tier Watchdog & Headless Screenshots (`obscura`)

### Step 10.1: Dual-Tier Watchdog Loop (`~/scripts/watchdog.sh`)
```bash
#!/data/data/com.termux/files/usr/bin/bash
while true; do
  # Fast-Heal (every 5s): check Nginx :8080 and Go Relay :8081
  curl -sf http://127.0.0.1:8080/ >/dev/null || proot-distro login --isolated -d ubuntu -- nginx -g "daemon off;"
  curl -sf http://127.0.0.1:8081/health >/dev/null || tmux new-session -d -s relay "~/relay/relay-service"
  tmux has-session -t tunnel 2>/dev/null || tmux new-session -d -s tunnel "cloudflared tunnel run my-phone-server"
  sleep 5
done
```

### Step 10.2: Lightweight Mobile Screenshots without Chromium
Run `obscura` inside Ubuntu PRoot for fast ARM64 visual verification:
```bash
proot-distro login --isolated ubuntu -- env OBSCURA_SHOT_W=390 OBSCURA_SHOT_H=844 \
  obscura fetch --allow-private-network "http://127.0.0.1:8080/" --screenshot /tmp/mobile.png
```
