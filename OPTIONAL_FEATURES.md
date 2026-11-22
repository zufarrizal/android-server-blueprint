# Optional Production Features & Extensions

This guide documents optional modular extensions you can layer on top of the core **Android Server Blueprint** (`Termux + Ubuntu 24.04 PRoot + Nginx :8080 + Cloudflare Tunnel`). All modules are designed for low-overhead ARM64 execution and zero open inbound ports.

---

## 1. Golang SSR & Telemetry Backend (`:8081`)

Instead of serving only static files from Nginx, you can run a single compiled Go binary behind Nginx on `127.0.0.1:8081` for Server-Side Rendering (SSR), SQLite (WAL mode) persistence, and live hardware telemetry.

### Nginx Reverse Proxy Snippet (`/etc/nginx/sites-available/default`)
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
}
```

### Hardware Telemetry Sources (Android Termux / PRoot)
- **SoC Thermal:** Read `/sys/class/thermal/thermal_zone*/temp` (divide millidegrees by `1000.0`).
- **Memory & Uptime:** Read `/proc/meminfo` and `/proc/uptime`.
- **SQLite Optimization:** Enable Write-Ahead Logging (`PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;`) to minimize flash wear on smartphone eMMC/UFS storage.

---

## 2. PageSpeed 100/100/100/100 Frontend Stack

To achieve maximum Lighthouse scores on both mobile and desktop without heavy Node runtimes in production:

1. **Compile & Purge CSS at Build Time:**
   Avoid runtime CSS compilers (`tailwind.js`) and multi-megabyte unpurged stylesheets in `<head>`. Compile Tailwind + DaisyUI once into a single minified stylesheet (`app.min.css`, ~20 KB gzipped) and inline it into `<style>` in your base layout to eliminate render-blocking CSS requests.
2. **Non-Blocking Fonts & Icons:**
   Load Google Fonts (`display=optional` for zero CLS) and icon stylesheets asynchronously:
   ```html
   <link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;600;700&display=optional" rel="stylesheet" media="print" onload="this.media='all'">
   ```
3. **Security & Isolation Headers (Best Practices 100):**
   ```nginx
   add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
   add_header Cross-Origin-Opener-Policy "same-origin" always;
   add_header X-Frame-Options "SAMEORIGIN" always;
   add_header X-Content-Type-Options "nosniff" always;
   add_header Referrer-Policy "strict-origin-when-cross-origin" always;
   ```
4. **AI Agent Discoverability (`/llms.txt`):**
   Serve a clean Markdown `/llms.txt` at the web root with an H1 title, summary, and links to your core routes:
   ```nginx
   location = /llms.txt {
       default_type text/markdown;
       try_files /llms.txt =404;
   }
   ```

---

## 3. Cloudflare Edge Worker & KV Zero-Downtime Failover (`Flight Mode`)

If your physical smartphone reboots, loses Wi-Fi, or enters airplane mode, a **Cloudflare Worker** paired with **Cloudflare KV** keeps your site online with `<20ms` global latency:

1. **Normal Operation (`DIRECT`):** The Worker fetches fresh HTML from your Cloudflare Tunnel origin, strips any temporary headers, and asynchronously caches a snapshot into `ADMIN_KV` (`snapshot:/<path>`).
2. **Origin Offline (`502/503/504` or Timeout):** The Worker automatically catches the origin failure and serves the latest HTML snapshot from `ADMIN_KV` with an optional `FLIGHT MODE` status badge—delivering **100% uptime** even when the phone is offline.

---

## 4. Telegram Bot Control Plane & Thermal Alerts

Connect your Go relay to the Telegram Bot API (outbound HTTPS long-polling—no webhook port needed) to manage the phone server remotely:

- **Environment Variables (`.env`, never commit to Git):**
  ```env
  TELEGRAM_BOT_TOKEN="your_bot_token"
  TELEGRAM_CHAT_ID="your_numeric_chat_id"
  ```
- **Recommended Capabilities:**
  - Background thermal monitor polling every 30s (alerts Telegram if SoC `>= 65°C`).
  - Remote status commands (`/status`, `/ping`, `/logs`).
  - Automatic SITREP notifications on service restarts or deployments.

---

## 5. WebP Content Negotiation & Social Link Previews

1. **Automatic WebP Serving in Nginx:**
   Create `/etc/nginx/conf.d/webp.conf`:
   ```nginx
   map $http_accept $webp_suffix {
       default "";
       "~*webp" ".webp";
   }
   ```
   Serve `.webp` automatically when supported:
   ```nginx
   location ~* ^/assets/.+\.(?:jpe?g|png)$ {
       add_header Vary Accept;
       add_header Cache-Control "public, max-age=2592000, immutable";
       try_files $uri$webp_suffix $uri =404;
   }
   ```
2. **OpenGraph & Twitter Card Previews (`/assets/og-banner.png`):**
   Use a dedicated `1200x630` PNG/JPEG banner with a shorter cache TTL (`max-age=3600` instead of `immutable`) so banner updates propagate quickly across Telegram, WhatsApp, and X:
   ```html
   <meta property="og:image" content="https://yourdomain.com/assets/og-banner.png">
   <meta property="og:image:secure_url" content="https://yourdomain.com/assets/og-banner.png">
   <meta property="og:image:type" content="image/png">
   <meta property="og:image:width" content="1200">
   <meta property="og:image:height" content="630">
   <meta name="twitter:card" content="summary_large_image">
   ```

---

## 6. Real-Time Market Data & Adaptive Multi-Timeframe Sync (Optional)

You can run lightweight Python background workers via `cron` or `tmux` to pull public WebSocket market feeds (e.g., TradingView anonymous socket streams) into a local JSON cache (`trading_cache.json`) for your Go backend to render:

- Use **adaptive lookback expansion** (`800 -> 2000 -> 5000` bars) when scanning higher timeframes (such as 30M) so each timeframe consistently surfaces at least 3 valid, unbroken structural zones.
- Keep dashboard tables compact (3 columns on mobile: Zone, Range, Distance/Rejections) so data fits cleanly without horizontal overflow.
