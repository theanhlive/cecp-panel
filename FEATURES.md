# CECP Panel v1.8 — tính năng

**Ưu tiên:** Bảo mật → WordPress → Tốc độ → UX → Cloudflare edge → Advanced optional

## v1.8 (tăng tốc website) — chi tiết: [CHANGELOG.md](CHANGELOG.md)

- `cache auto-purge DOMAIN on`: sửa/đăng bài → purge đúng các trang liên quan (origin + edge Cloudflare), gần như tức thì
- `cache ttl DOMAIN 1h`: TTL cache trang theo site; `cache status DOMAIN`
- `cf edge-cache DOMAIN on --ttl 1h`: cache HTML ở edge Cloudflare (bỏ qua admin, đăng nhập, giỏ hàng); giữ nguyên rule khác của zone
- WebP/AVIF tự động theo `Accept`; `media enable DOMAIN --avif`
- `ssl issue DOMAIN --dns | --wildcard`: SSL qua DNS Cloudflare (không cần cổng 80, chạy được khi proxied); site con dùng chung wildcard

## v1.7 (độ tin cậy + bảo vệ khách) — chi tiết: [CHANGELOG.md](CHANGELOG.md)

- Backup báo lỗi thật, trạng thái từng site, snapshot kèm cấu hình site; `backup verify DOMAIN|--all` (hằng tuần)
- `backup restore DOMAIN SNAP --live [--dry-run] [--yes]`: restore thẳng vào site đang chạy, tự rollback nếu hỏng
- `monitor enable|status|run`: giám sát 5 phút/lần, tự restart service, tự sửa socket PHP-FPM, chỉ báo khi đổi trạng thái
- `notify webhook URL`: sự kiện JSON ký HMAC → n8n ([docs/WEBHOOK_N8N.md](docs/WEBHOOK_N8N.md)); `events.log`
- Rate-limit `wp-login.php`; `site protect-admin DOMAIN on [--ip …]` (basic auth / allowlist IP)
- Logrotate cho log panel; menu đầy đủ lệnh mới

## v1.6 (bảo mật + tốc độ) — chi tiết: [CHANGELOG.md](CHANGELOG.md)

### Bảo mật
- Vhost template mới: chặn PHP trong uploads, header bảo mật trên mọi response; `site rebuild-vhost DOMAIN|--all`
- HTTPS panel tự quản (webroot + HTTP/2 + HSTS): `ssl issue`, `ssl hsts DOMAIN on|off|subdomains`
- IP thật sau Cloudflare: `cf realip`; fail2ban không ban Cloudflare, ban tăng dần, chặn cả ở nginx
- Validate input + không lộ secret (argv/log); `.env` chỉ nạp khi an toàn
- Cách ly site: tmp/session riêng, Redis ACL riêng (`optimize redis-acl --all`)
- Cài/cập nhật bắt buộc khớp `SHA256SUMS`; `security check` PASS/WARN/FAIL; `security fix-perms`

### Tốc độ
- HTTP/2; cache key bỏ `fbclid`/`gclid`/`utm_*`; background update
- `optimize purge DOMAIN`, `optimize purge-url URL`, `optimize report DOMAIN`
- PHP-FPM sizing theo RAM, BBR nạp lúc boot, MariaDB table cache theo số site

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
- `cf purge` / `purge-url` / `realip` / `brotli` / `cache-level` / `status` / `recommend` (Auto Minify đã bị Cloudflare ngừng 08/2024)
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
- Media: keep-original, queue Redis
