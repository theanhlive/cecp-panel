# CECP Panel — tính năng (đến 1.13.1-beta)

**Ưu tiên:** Bảo mật → WordPress → Tốc độ → UX → Cloudflare edge → Advanced optional

Các mục bên dưới xếp theo phiên bản ra mắt; hành vi hiện tại và cờ đầy đủ: `cecp-panel help`,
lỗi "Usage:" của từng lệnh, và [CHANGELOG.md](CHANGELOG.md). Khi một mục cũ bị thay đổi ở bản sau,
bản sau được ghi ở đây.

## v1.13 (tune theo domain + chẩn đoán sau nâng cấp) — chi tiết: [CHANGELOG.md](CHANGELOG.md)

- `site probe [DOMAIN|--all]`: gọi `/wp-login.php`, `/wp-json/`, URL bỏ qua cache qua loopback; PASS/WARN/FAIL, chỉ ra nguyên nhân từ log của chính site. Chạy sau mỗi lần nâng cấp panel/WordPress
- `optimize audit DOMAIN [--json]` (chỉ đọc), `optimize capacity`, `optimize loadtest`, `optimize rollback list|ID|latest` — runbook [docs/SITE_TUNING.md](docs/SITE_TUNING.md)
- `security check` báo file PHP mà pool không đọc được, lỗi PHP fatal 24 giờ theo site
- `tools/cf-agent.sh` (máy vận hành): audit/snapshot/apply/rollback Cloudflare — [docs/CLOUDFLARE_AGENT_TOKEN.md](docs/CLOUDFLARE_AGENT_TOKEN.md)

## v1.12 (cách ly site, sự cố, thông báo) — chi tiết: [CHANGELOG.md](CHANGELOG.md)

- Cài/cập nhật **chỉ từ GitHub** (`dist/` trong repo, đối chiếu `SHA256SUMS`); mirror isharevn cũ đã ngừng
- Cách ly giữa các site: root không ghi trong docroot, `disable_symlinks`, wp-cron qua loopback, cấm `crontab` user site, `security php-isolation` (OPcache riêng), `putenv` tắt mặc định (`php config DOMAIN allow_putenv=on` nếu plugin cần)
- `security scan [DOMAIN|--all] [--days N]`, `security rotate-secrets`, `security restore-clean DOMAIN|--all [--dry-run] [--yes]` — [docs/INCIDENT_RESPONSE.md](docs/INCIDENT_RESPONSE.md)
- `security scan-schedule on [--every 14|30] [--hour H] [--auto-restore]`: quét định kỳ giờ rảnh, gắn tag `scan-clean` cho backup sạch, đóng băng retention khi nhiễm, `security scan-ack` để gỡ
- `security cf-only on [--force]|off|status`: 80/443 chỉ nhận IP Cloudflare (firewalld hoặc ufw), `cf realip` đồng bộ lại
- Thông báo **Telegram / Zalo Bot / Discord**: `notify setup|telegram|zalo|discord|test [KÊNH]|off KÊNH`, chọn loại theo kênh `notify events set CATS --channel KÊNH --min warning` — [docs/NOTIFICATIONS.md](docs/NOTIFICATIONS.md)
- Backup: sửa retention (trước đây không bao giờ xoá snapshot); `backup prune-dry-run` rồi xác nhận một lần `backup prune`
- Media: upload mọi định dạng → **một** file WebP (mặc định `--format webp`, hoặc `avif`/`original`) đã thu nhỏ, không giữ gốc; `media prune-originals DOMAIN [--yes]`
- HTTPS catch-all (nginx ≥ 1.19.4) từ chối bắt tay TLS khi truy cập bằng IP; `ssl issue` đổi URL WordPress sang https
- Menu không thoát khi nhập sai; phím Tab gợi ý lệnh, cờ và domain

## v1.11 (vá đọc chéo giữa các site)

- `security harden-docroot [DOMAIN|--all]`: bỏ quyền đọc "other" trên docroot, nginx chỉ đọc file tĩnh qua ACL; tự chạy khi `site add`, `site duplicate`, `backup restore`, `wp update`, `security apply-production`

## v1.10 (mặc định thông minh + cập nhật toàn diện) — chi tiết: [CHANGELOG.md](CHANGELOG.md)

- `site add DOMAIN --wp` tự bật cache auto-purge + TTL 1h, WordPress auto-update (minor); `--minimal` để giữ hành vi cũ
- `cecp-panel update all`: cập nhật OS + wp-cli + WordPress mọi site + panel trong một lệnh, có rollback từng phần; `update enable-cron` để chạy hằng tuần
- `update wp-cli`: cập nhật wp-cli.phar ngay cả khi đã cài (trước đây chỉ cài khi thiếu)

## v1.9 (vận hành agency) — chi tiết: [CHANGELOG.md](CHANGELOG.md)

- `site staging DOMAIN` / `site staging-push DOMAIN`: staging 1 lệnh (có mật khẩu, noindex, chặn mail), đẩy lên site thật có rollback
- `wp update DOMAIN` / `wp auto-update DOMAIN on` / `wp rollback DOMAIN`: cập nhật WordPress có bản an toàn, kiểm tra sức khỏe, tự rollback
- `site limits DOMAIN --cpu 100 --mem 1G`: PHP-FPM riêng giới hạn CPU/RAM
- `php config DOMAIN memory_limit=512M …`: cấu hình PHP từng site; upload lớn không còn lỗi 413
- `site auth DOMAIN on`: basic auth toàn site (preview cho khách)
- `status --json`: trạng thái chi tiết cho CECP Core / n8n (heartbeat dùng chung)
- `db export|import|shell|info|size|slow-log|slow-report`

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
- Runbook tune/loadtest theo domain: [docs/SITE_TUNING.md](docs/SITE_TUNING.md) + profile mẫu [docs/sites/_TEMPLATE.md](docs/sites/_TEMPLATE.md)
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
- On-upload: mu-plugin resize + nén + WebP sidecar (từ 1.12: một file WebP, không giữ gốc — xem mục v1.12)
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
cecp-panel site probe --all
cecp-panel security scan --all
cecp-panel security scan-schedule on --every 14
cecp-panel backup prune-dry-run
cecp-panel log nginx example.com
# advanced (cẩn thận):
# cecp-panel modsec install && cecp-panel modsec enable
```

## Chưa có (roadmap)

- 2.0 ([docs/PLAN_2.0.md](docs/PLAN_2.0.md)): CI GitHub Actions, test tích hợp Ubuntu 22.04/24.04, test nâng cấp, kênh `stable`/`beta`, ký bản phát hành minisign
- OpenLiteSpeed dual-stack
- File Manager
- SMTP cho WordPress, quota đĩa từng site
- WebUI agency (CECP control plane)
- HTTP/3 QUIC (phụ thuộc build nginx)
- Media: queue Redis
