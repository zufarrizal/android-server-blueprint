# Optional Production Features & Full Architecture Blueprint

This guide documents all optional production-grade modules you can layer on top of the core **Android Server Blueprint** (`Termux + Ubuntu 24.04 PRoot + Nginx :8080 + Cloudflare Named Tunnel`). Every module is designed for ARM64 efficiency, zero open inbound firewall ports, and autonomous 24/7 operation.

---

## Table of Contents
1. [Golang SSR Engine & SQLite (WAL) Persistence (`:8081`)](#1-golang-ssr-engine--sqlite-wal-persistence-8081)
2. [Security Hardening, Rate Limiter & IP Reputation](#2-security-hardening-rate-limiter--ip-reputation)
3. [PageSpeed 100/100/100/100 Frontend & AI Discoverability (`/llms.txt`)](#3-pagespeed-100100100100-frontend--ai-discoverability-llmstxt)
4. [Cloudflare Edge Worker, KV Mirror & D1 (`3-Tier Routing`)](#4-cloudflare-edge-worker-kv-mirror--d1-3-tier-routing)
5. [Full-Stack Storefront, Admin CMS, PDF Invoices & WebP Pipeline](#5-full-stack-storefront-admin-cms-pdf-invoices--webp-pipeline)
6. [Telegram Control Plane, Multi-Provider AI Core & Voice/Call Alerts](#6-telegram-control-plane-multi-provider-ai-core--voicecall-alerts)
7. [Self-Hosted Media Downloader (`yt-dlp` + OAuth)](#7-self-hosted-media-downloader-yt-dlp--oauth)
8. [Built-In Load Tester (`/benchmark`) & Visitor Radar](#8-built-in-load-tester-benchmark--visitor-radar)
9. [Live Market Data & Adaptive Order Block Radar (`/trading`)](#9-live-market-data--adaptive-order-block-radar-trading)
10. [Overwatch Dual-Tier Watchdog & CLI Tooling](#10-overwatch-dual-tier-watchdog--cli-tooling)

---

## 1. Golang SSR Engine & SQLite (WAL) Persistence (`:8081`)

Instead of serving only static HTML from Nginx, run a single compiled Go binary behind Nginx on `127.0.0.1:8081` for Server-Side Rendering (SSR), dynamic APIs, and hardware telemetry.

### Nginx Reverse Proxy Configuration (`/etc/nginx/sites-available/default`)
```nginx
upstream relay_backend {
    server 127.0.0.1:8081;
    keepalive 64;
}

location / {
    proxy_pass http://relay_backend;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header CF-Connecting-IP $http_cf_connecting_ip;
    proxy_set_header CF-IPCountry $http_cf_ipcountry;
}
```

### Android Hardware Telemetry & Storage Tuning
- **SoC Thermal:** Read `/sys/class/thermal/thermal_zone*/temp` (divide millidegrees by `1000.0`).
- **RAM & Uptime:** Parse `/proc/meminfo` and `/proc/uptime`.
- **SQLite WAL Mode:** Configure `PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=5000;` to support concurrent reads/writes while minimizing flash wear on smartphone eMMC/UFS storage.

---

## 2. Security Hardening, Rate Limiter & IP Reputation

Protect the smartphone origin from scanners, brute-force attacks, and abusive scrapers before requests reach business logic:

1. **Token-Bucket Rate Limiter Middleware:**
   - Per-IP rate limiting keyed off `CF-Connecting-IP` (with fallback to `X-Real-IP`).
   - Emits standard `X-RateLimit-Limit` and `X-RateLimit-Remaining` headers (e.g., `90 req/min` on public routes, stricter caps on `/api/*` and `/admin/auth`).
2. **IP Reputation & Threat Lookup (`/api/security/ip-check`):**
   - Inspects incoming visitor IP, Cloudflare country code (`CF-IPCountry`), ASN/ISP metadata, and flags known abusive/datacenter ranges.
3. **Honeypot & Admin Auth Protection:**
   - Hidden honeypot form fields (`tabindex="-1"`, `aria-hidden="true"`) on public contact modals silently drop bot submissions.
   - Admin routes (`/admin`, `/admin/products/*`, `/admin/invoices/*`) are protected by HMAC-signed `HttpOnly; Secure; SameSite=Strict` session cookies.
4. **Nginx Path Denials & OWASP Headers:**
   ```nginx
   location ~ /\. { deny all; access_log off; log_not_found off; }
   add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
   add_header Cross-Origin-Opener-Policy "same-origin" always;
   add_header X-Frame-Options "SAMEORIGIN" always;
   add_header X-Content-Type-Options "nosniff" always;
   add_header Referrer-Policy "strict-origin-when-cross-origin" always;
   add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
   ```

---

## 3. PageSpeed 100/100/100/100 Frontend & AI Discoverability (`/llms.txt`)

Achieve **100** across Performance, Accessibility, Best Practices, SEO, and **3/3** Agentic Browsing on both Mobile and Desktop:

1. **Zero Render-Blocking CSS:**
   - Compile and purge Tailwind CSS + DaisyUI 4 at build time (`tailwindcss -i input.css -o app.min.css --minify`) instead of loading runtime `tailwind.js` or unpurged `daisyui.min.css`.
   - Load `app.min.css` once into Go memory via `sync.Once` and inline it into `<style>` in your base layout, eliminating render-blocking stylesheet round-trips.
2. **Non-Blocking Fonts & Icons:**
   - Trim Google Fonts to required weights only (`400;600;700`), use `display=optional` (0 CLS), and load external stylesheets asynchronously:
     ```html
     <link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;600;700&display=optional" rel="stylesheet" media="print" onload="this.media='all'">
     ```
   - Defer HTMX (`<script src="/assets/htmx.min.js" defer></script>`) and defer post-load telemetry beacons until `2000ms` after `window.load`.
3. **Accessibility (WCAG 2.1 AA):**
   - Use semantic `<button type="button">` (never `<label aria-label="...">`) for interactive dropdown triggers.
   - Maintain strict sequential heading order (`<h1>` -> `<h2>` -> `<h3>`) and explicit `width`/`height` on all `<img>` tags.
4. **Dynamic SEO & AI Agent Endpoints:**
   - Dynamic `/sitemap.xml` generated from SQLite products and static routes.
   - W3C `<script type="speculationrules">` for instant `moderate` prerendering of navigation targets.
   - Serve `/llms.txt` (`default_type text/markdown`) with an `# H1` title, summary, and Markdown links for LLM crawlers.

---

## 4. Cloudflare Edge Worker, KV Mirror & D1 (`3-Tier Routing`)

Pair your origin tunnel with a **Cloudflare Worker** + **KV (`ADMIN_KV`)** + **D1** for `<20ms` global reads and zero-downtime failover:

| Mode | Condition | Behavior |
| :--- | :--- | :--- |
| **DIRECT NODE** | Origin healthy (`200 OK`) | Live stream from smartphone Go SSR; Worker asynchronously snapshots HTML into `ADMIN_KV`. |
| **EDGE MIRROR** | Optional read-replica flag | Serves globally cached HTML snapshot directly from Cloudflare KV (`<20ms` worldwide) to save phone CPU. |
| **FLIGHT MODE** | Origin offline (`502/503/504` / timeout) | Automatically fails over to the latest `ADMIN_KV` snapshot so the site stays 100% online during phone reboots or Wi-Fi drops. |

- **Bypass Prefixes:** Always bypass KV caching for `/admin`, `/api/send-message`, `/api/webhook`, `/yt`, and `/ws`.

---

## 5. Full-Stack Storefront, Admin CMS, PDF Invoices & WebP Pipeline

1. **Dynamic Catalog & Admin CMS:**
   - Manage products, categories, global FAQs, and site settings via `/admin` backed by SQLite.
   - Replicate/backup critical state to Cloudflare D1 / KV via `CF_API_TOKEN`.
2. **Server-Side PDF Invoice Engine (`/invoice`, `/invoice/pdf`):**
   - Generate crisp, printable PDF invoices directly in Go (`gofpdf`) with unique invoice IDs, line items, and status tracking (`/admin/invoices`).
   - Support automated payment/order webhook callbacks (`/api/webhook/yappink`).
3. **Automated `cwebp` Image Pipeline:**
   - On product image upload, sniff MIME headers (15 MB max), resize to `1200px` width, strip EXIF metadata, and convert to `.webp` (`cwebp -q 82 -resize 1200 0 -m 4 -metadata none`).
4. **Nginx WebP Content Negotiation & Social OG Banner:**
   - `/etc/nginx/conf.d/webp.conf`:
     ```nginx
     map $http_accept $webp_suffix {
         default "";
         "~*webp" ".webp";
     }
     ```
   - Dedicated `1200x630` OpenGraph banner (`/assets/og-banner.png`) with `Cache-Control "public, max-age=3600"` so social previews refresh quickly across Telegram, WhatsApp, and X.

---

## 6. Telegram Control Plane, Multi-Provider AI Core & Voice/Call Alerts

Turn your server into an interactive assistant via outbound Telegram long-polling (no open webhook port required):

1. **Multi-Provider AI Gateway:**
   - Unified interface supporting primary + fallback AI providers with session continuity, token/latency tracking (`/api/ai/usage`), and persistent JSON memory (`ghost_memory.json`).
   - Includes structured image-design reasoning (5-layer minimalist prompt framework) and automatic `[PHOTO: <path>]` / `[SCREENSHOT: <url>]` dispatching using headless screenshots.
2. **Voice Message Synthesis & Transcription (`voice_service.py`):**
   - Converts incoming Telegram voice notes and synthesizes `.ogg` (Opus) voice responses.
3. **Hardware Thermal & Critical Call Escalation:**
   - Background monitor checks SoC temperature every 30s and dispatches Telegram alerts if `SoC >= 65°C`.
   - Optional Telethon emergency voice-call script (`emergency_caller.py`) for critical downtime escalation.
4. **Environment Variables (`.env`, never commit to Git):**
   ```env
   TELEGRAM_BOT_TOKEN="your_bot_token"
   TELEGRAM_CHAT_ID="your_numeric_chat_id"
   ```

---

## 7. Self-Hosted Media Downloader (`yt-dlp` + OAuth)

Run a private/public media extraction utility (`/dl`) powered by `yt-dlp` and `ffmpeg` inside the isolated environment:
- **OAuth / Cookie Auth (`/api/yt/auth/*`):** Supports device-code OAuth polling or cookie upload for authenticated extraction without exposing host credentials.
- **Streamed File Delivery (`/api/yt/info`, `/api/yt/download`, `/api/yt/file/`):** Fetches format metadata and streams processed media cleanly with temporary file cleanup.

---

## 8. Built-In Load Tester (`/benchmark`) & Visitor Radar

1. **Concurrent Load-Test Harness (`/benchmark`, `/api/loadtest`):**
   - Dispatch controlled concurrent HTTP bursts against local endpoints from the web UI and record Requests/sec, P50/P95/P99 latency, error rate, and real-time smartphone SoC temperature delta.
2. **Privacy-First Visitor Radar (`/api/visitor-ping`):**
   - Lightweight post-load beacon recording visited path, viewport size, effective network type, and Cloudflare country headers without invasive third-party trackers.

---

## 9. Live Market Data & Adaptive Order Block Radar (`/trading`)

Run a lightweight Python WebSocket worker (`tv_sunflow_sync.py`) to stream public candle data (e.g., `FX:XAUUSD`) and compute multi-timeframe Order Blocks (`5M`, `15M`, `30M`) into `trading_cache.json`:
- **Adaptive Lookback Expansion:** Automatically steps candle history (`800 -> 2000 -> 5000` bars) per timeframe until at least 3 valid unbroken Order Blocks are found.
- **Webhook & SSR Dashboard (`/trading`, `/api/trading/radar`, `/api/trading/webhook`):** Renders compact 3-column mobile-friendly tables (`Zona`, `Rentang`, `Jarak / Rej`) with live JSON refresh.

---

## 10. Overwatch Dual-Tier Watchdog & CLI Tooling

Keep all daemons resilient against Android's background process killer:
- **Dual-Tier Watchdog:**
  - **Fast-Heal (5s):** Checks Nginx `:8080`, Go Relay `:8081`, and Cloudflared tunnel; respawns any dead process immediately.
  - **Full-Audit (60s):** Verifies public HTTPS health (`https://yourdomain.com`), acquires CPU wake-lock, and logs heartbeats.
- **Unified Service Controller (`masjup-service` / `server-ctl`):** Single CLI to `start`, `stop`, `restart`, and inspect `status` across all 5 daemons.
- **Lightweight Headless Screenshots (`obscura-shot`):** Uses the Rust-based `obscura` engine inside isolated PRoot Ubuntu instead of heavy Chromium for fast mobile/desktop visual verification.
