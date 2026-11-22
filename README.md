# Android Server Blueprint

A minimal, production-grade guide to turning an idle physical Android smartphone into a 24/7 Linux server running Ubuntu 24.04 LTS via Termux, isolated PRoot, Nginx, and Cloudflare Named Tunnels.

```
+-------------------------------------------------------------------+
|               PHYSICAL ANDROID HARDWARE (ARM64)                   |
|  - Battery acts as zero-cost Hardware UPS (blackout immune)       |
|  - Android CPU Wake-Lock active                                   |
+-------------------------------------------------------------------+
                                 |
                                 v
+-------------------------------------------------------------------+
|                        TERMUX BASE LAYER                          |
|  - Host management, OpenSSH (:8022), tmux daemons                 |
|  - Cloudflare Named Tunnel (outbound QUIC, 0 open ports)          |
|  - Sentinel Watchdog (auto-recovers dead processes in seconds)     |
+-------------------------------------------------------------------+
                                 |
                                 v
+-------------------------------------------------------------------+
|               UBUNTU 24.04 PRoot ISOLATED CONTAINER               |
|  - Runs securely without Android root                             |
|  - Nginx 1.24 web server (:8080)                                  |
|  - Application web root: /var/www/html/                           |
+-------------------------------------------------------------------+
```

---

## 1. Prerequisites

1. **Hardware:** Any physical Android smartphone (ARM64 / aarch64, 3GB+ RAM recommended).
2. **Terminal:** Install **Termux** from [F-Droid](https://f-droid.org/packages/com.termux/) (do not use the obsolete Google Play version).
3. **Power:** Plug the phone into a charger and keep it connected to Wi-Fi.

---

## 2. Android Host Preparation

To prevent Android OS from putting the CPU or Wi-Fi to sleep:

1. **Acquire Termux Wake-Lock:**
   Run inside Termux:
   ```bash
   termux-wake-lock
   ```
2. **Disable Android Battery Optimization:**
   Go to phone **Settings -> Apps -> Termux -> Battery** and set to **Unrestricted** (or "Don't Optimize").
3. **Prevent App Killing (Android 12+ Phantom Process Killer):**
   If on Android 12+, enable Developer Options and disable phantom process limits, or execute via ADB:
   ```bash
   adb shell "/system/bin/device_config put activity_manager max_phantom_processes 2147483647"
   ```

---

## 3. Step-by-Step Installation

### Step 3.1: Update Termux and Install Core Tools
Inside Termux, update packages and install core utilities:
```bash
pkg update -y && pkg upgrade -y
pkg install -y proot-distro tmux git curl openssh
```

### Step 3.2: Install Ubuntu 24.04 LTS via PRoot
Use `proot-distro` to install an isolated Ubuntu userland without rooting:
```bash
proot-distro install ubuntu
```

Verify you can log into Ubuntu:
```bash
proot-distro login --isolated ubuntu
```
*(Type `exit` to return to Termux)*.

### Step 3.3: Install and Configure Nginx inside Ubuntu
Log into Ubuntu and install Nginx 1.24:
```bash
proot-distro login --isolated ubuntu -- bash -c "apt update && apt install -y nginx && apt clean"
```

Configure Nginx to listen on non-privileged port `8080`:
```bash
proot-distro login --isolated ubuntu -- bash -c "sed -i 's/listen 80 default_server;/listen 8080 default_server;/g' /etc/nginx/sites-available/default && sed -i 's/listen \[::\]:80 default_server;/listen \[::\]:8080 default_server;/g' /etc/nginx/sites-available/default"
```

Start Nginx inside Ubuntu as a background daemon:
```bash
proot-distro login --isolated -d ubuntu -- nginx -g "daemon off;"
```

Test local connectivity from Termux:
```bash
curl -I http://127.0.0.1:8080/
```
You should receive `HTTP/1.1 200 OK`.

---

## 4. Public Domain Setup (Cloudflare Named Tunnel)

This server requires **zero router port forwarding**, **no public static IP**, and **0 open inbound firewall ports**. Traffic enters securely via an outbound encrypted tunnel.

1. **Install cloudflared in Termux:**
   ```bash
   pkg install -y cloudflared
   ```
2. **Authenticate with Cloudflare:**
   ```bash
   cloudflared tunnel login
   ```
   *(Open the displayed URL in your browser and select your domain)*.
3. **Create Named Tunnel:**
   ```bash
   cloudflared tunnel create my-phone-server
   ```
4. **Route Your Domain to the Tunnel:**
   ```bash
   cloudflared tunnel route dns my-phone-server yourdomain.com
   ```
5. **Configure Ingress (`~/.cloudflared/config.yml`):**
   ```yaml
   tunnel: <TUNNEL_UUID>
   credentials-file: /data/data/com.termux/files/home/.cloudflared/<TUNNEL_UUID>.json

   ingress:
     - hostname: yourdomain.com
       service: http://127.0.0.1:8080
     - service: http_status:404
   ```
6. **Run the Tunnel in tmux:**
   ```bash
   tmux new-session -d -s tunnel "cloudflared tunnel run my-phone-server"
   ```

Your website is now live at `https://yourdomain.com` with automatic HTTPS!

---

## 5. 24/7 Resilience & Watchdog

To prevent Android process killer from keeping your server down, run the included sentinel watchdog script in a tmux session:

```bash
chmod +x scripts/server-ctl.sh scripts/watchdog.sh
tmux new-session -d -s watchdog "./scripts/watchdog.sh"
```

If Nginx or the tunnel crashes, the watchdog revives it within 5 seconds.

---

## 6. Service Controller Reference

Use `scripts/server-ctl.sh` to manage all services in one command:
```bash
./scripts/server-ctl.sh start    # Start Wake-lock, Nginx, Tunnel, and Watchdog
./scripts/server-ctl.sh status   # Inspect real-time status of all daemons
./scripts/server-ctl.sh restart  # Cleanly cycle all services
./scripts/server-ctl.sh stop     # Gracefully stop everything and release wake-lock
```

---

## 7. Optional Production Extensions

Looking to go beyond the minimal setup? See **[OPTIONAL_FEATURES.md](OPTIONAL_FEATURES.md)** for modular guides on:
- **Golang SSR & Hardware Telemetry Backend (`:8081`)**
- **PageSpeed 100/100/100/100 Optimization & `llms.txt`**
- **Cloudflare Edge Worker + KV Zero-Downtime Failover (`Flight Mode`)**
- **Telegram Bot Control Plane & SoC Thermal Alerts**
- **WebP Content Negotiation & OpenGraph Social Previews**
- **Real-Time Market Data & Adaptive Multi-Timeframe Sync**

---

## License

MIT License. Free to use, modify, and distribute.
