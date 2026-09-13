# CECP Panel v1.5 — tính năng

**Ưu tiên:** Bảo mật → WordPress → Tốc độ → UX → Cloudflare edge → Advanced optional

## v1.5 (Performance sâu + UX + Cloud edge + Advanced)

### UX
- Menu màu + load average + uptime
- `status` giàu: version stack, service dots, SSL days left, site list
- `log panel|nginx|php|mysql|fail2ban|audit|notify [DOMAIN]`
- Site 1 dòng: `site add d.com --wp --php 82 --ssl --redis`

### Notify
- Telegram + Discord webhook (`/etc/cecp-panel/notify.env`)
- `notify setup|test|health|enable-cron`
- Cảnh báo SSL sắp hết hạn + disk đầy (cron daily)

### Cloudflare edge
- `cf purge` / `purge-url` / `brotli` / `cache-level` / `minify` / `status` / `recommend`
- Dùng chung CF_API_TOKEN với DNS

### Security polish
- `security unattended` — dnf-automatic / unattended-upgrades
- Fail2Ban full, SSH harden, MariaDB bind (v1.4)

### Performance (v1.4+)
- FastCGI cache + purge + Woo bypass
- Redis secure + `redis-wp`
- OPcache JIT, BBR, MariaDB theo RAM
- `optimize stack` one-shot

### Media optimize (per-site opt-in)
- **Mặc định OFF** — chỉ bật site upload ảnh nhiều
- On-upload: mu-plugin resize + nén + WebP sidecar
- Cron daily 03:20: batch backlog (chỉ site `enabled` + `cron`)
- State trong `/var/lib/cecp-panel/sites/<domain>.json` → `media_optimize`
- Lệnh: `media enable|disable|status|run|run-all|enable-cron|disable-cron`

### Advanced optional
- **ModSecurity** off-by-default: `modsec install|enable|disable|blocking`
- DetectionOnly trước; blocking chỉ khi operator xác nhận

## Lệnh nhanh

```bash
cecp-panel status
cecp-panel site add example.com --wp --php 82 --ssl --redis
cecp-panel optimize stack
cecp-panel media enable shop.example.com --max-width 1920 --quality 80
cecp-panel media run shop.example.com --dry-run
cecp-panel media status
cecp-panel cf purge example.com
cecp-panel notify setup && cecp-panel notify enable-cron
cecp-panel security unattended
cecp-panel log nginx example.com
# advanced (cẩn thận):
# cecp-panel modsec install && cecp-panel modsec enable
```

## Chưa có (roadmap 1.6+)

- OpenLiteSpeed dual-stack
- File Manager / staging
- WebUI agency (CECP control plane)
- HTTP/3 QUIC (phụ thuộc build nginx)
- Media: AVIF, keep-original, queue Redis
