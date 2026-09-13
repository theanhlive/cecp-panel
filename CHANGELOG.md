# Changelog

## 1.7.0-beta — độ tin cậy + bảo vệ khách (đợt 1)

### Backup (A1)
- **Lỗi backup không còn bị nuốt**: mysqldump, tar, restic, prune đều được kiểm tra; lỗi → exit ≠ 0, ghi trạng thái, gửi sự kiện `backup_failed` (và `backup_recovered` khi chạy lại được). Trước đây restic lỗi vẫn báo "done".
- `mysqldump --single-transaction --routines --triggers` (bản dump nhất quán, không khóa bảng).
- Snapshot có thêm `config/config.tar.gz`: vhost, pool PHP, cron, SFTP, htpasswd, cert Let's Encrypt — để dựng lại trên VPS mới.
- `backup verify DOMAIN|--all`: `restic check` + restore bản mới nhất vào thư mục tạm + import thử DB vào DB tạm. Cron chạy hằng tuần (CN 05:30).
- `backup status` hiển thị trạng thái từng site (last_ok, verified, lỗi gần nhất).
- `RESTIC_REPOSITORY` có thể là thư mục cục bộ hoặc `sftp:` (bản sao thứ hai / không dùng Google Drive).

### Restore 1 lệnh (A2)
- `backup restore DOMAIN SNAPSHOT|latest --live [--dry-run] [--yes]`: lưu bản hiện tại → tráo thư mục site → import lại DB → cập nhật thông tin DB/Redis trong `wp-config.php` → purge cache → kiểm tra HTTP; nếu site không lên thì **tự rollback** về bản trước. Không có `--yes` thì phải gõ lại tên domain để xác nhận.
- Cú pháp cũ `backup restore DOMAIN SNAP [TARGET_DIR]` (chỉ giải nén) vẫn dùng được.

### Giám sát + tự phục hồi (A3)
- `monitor enable|disable|run|status`: cron 5 phút/lần kiểm tra service, trang chủ từng site (bỏ qua cache), SSL, dung lượng đĩa, độ tươi của backup.
- Service bị dừng → tự khởi động lại và báo; systemd `Restart=on-failure` cho nginx/php-fpm/mariadb/redis/fail2ban.
- Tự sửa socket PHP-FPM sai quyền (lỗi 502).
- Chỉ báo khi trạng thái **thay đổi** (có báo "đã khôi phục sau X phút"); lỗi kéo dài thì nhắc lại mỗi 6 h / 24 h.

### Webhook sự kiện → n8n (B5)
- `notify webhook URL|off`: mọi sự kiện gửi JSON có chữ ký HMAC-SHA256 (`X-CECP-Signature`), thử lại 3 lần. Xem [docs/WEBHOOK_N8N.md](docs/WEBHOOK_N8N.md).
- Mọi sự kiện được ghi vào `/var/log/cecp-panel/events.log` (JSON lines, cho CECP Core).

### Bảo vệ đăng nhập WordPress (A7 + B2)
- `wp-login.php` có rate-limit riêng (10 request/phút/IP, burst 10) → bot nhận 429 rồi bị fail2ban ban.
- `site protect-admin DOMAIN on [--ip CIDR,...] [--no-auth] | off | status | reset-password`: basic auth và/hoặc allowlist IP cho `wp-login.php` + `/wp-admin/`; `admin-ajax.php`/`admin-post.php` vẫn công khai để front-end không hỏng.

### Vận hành (A11)
- Logrotate cho log của panel (`/etc/logrotate.d/cecp-panel`); dọn bản sao pre-restore > 7 ngày trong `system maintain`.
- Menu tương tác có đủ các lệnh của 1.6/1.7.

### Nâng cấp từ 1.6
```bash
cecp-panel security apply-production     # logrotate
cecp-panel site rebuild-vhost --all      # rate-limit wp-login (template mới)
cecp-panel monitor enable
cecp-panel notify webhook https://n8n.example.com/webhook/...   # tùy chọn
cecp-panel backup enable-cron            # thêm lịch verify hằng tuần
cecp-panel backup verify --all
```

## 1.6.0-beta — bảo mật + tốc độ

### Bảo mật
- **PHP trong uploads không còn chạy được**: trước đây `location ~ \.php$` đứng trước luật deny nên file `.php` upload lên vẫn được thực thi. Chặn thêm `wp-config.php`, `wp-includes/*.php`, `wp-admin/includes/`, dotfile, `.sql/.bak/.log/...`.
- **Header bảo mật trên mọi response** (trước đây bị mất ở trang PHP và file tĩnh do cơ chế kế thừa `add_header`).
- **HTTPS do panel quản lý**: `certbot certonly --webroot` + template HTTPS riêng (80→301, HTTP/2, TLS 1.2/1.3, HSTS 180 ngày). `ssl hsts DOMAIN on|off|subdomains`. Cert cũ được chuyển cấu hình gia hạn sang webroot + hook reload nginx.
- **IP thật sau Cloudflare** (`cf realip`, cron hàng tuần): rate-limit, log và fail2ban thấy IP khách; không thể giả header từ ngoài Cloudflare.
- **fail2ban**: không bao giờ ban dải Cloudflare, ban tăng dần (1h → 1 tuần), jail `recidive`, ban thêm ở tầng nginx (`deny`) để chặn cả traffic đi qua proxy.
- **Chống injection**: validate domain/IP/URL/mật khẩu/lịch cron ở mọi lệnh (kể cả từ menu); bỏ toàn bộ nội suy biến vào `python3 -c`; file `.env` ghi dạng `%q` và chỉ `source` khi thuộc root, không cho group/other ghi. Chặn `site sftp-password` đổi mật khẩu tài khoản khác (vd. root) qua ký tự xuống dòng. Chặn `backup configure` chèn dòng cron root.
- **Secret không còn trên argv/log**: token Cloudflare/agent/Telegram đi qua `curl -K`, mật khẩu DB qua file tạm 600, mật khẩu WP qua stdin; `panel.log` 640, không ghi mật khẩu; `notify status` không in token; `apply-production` xóa mật khẩu cũ khỏi log.
- **Cách ly giữa các site**: `tmp`/session riêng cho từng site (bỏ `/tmp` dùng chung trong `open_basedir`); Redis ACL riêng cho từng site (`optimize redis-acl --all` chuyển site cũ sang và đổi mật khẩu dùng chung); từ chối domain trùng user hệ thống (`a-b.com` và `a.b.com`); admin WP không còn tên `admin`.
- **SSH**: drop-in `00-cecp-*` để `ssh-key-only`/`ssh-harden` thực sự có hiệu lực (trước đây thua `50-cloud-init.conf` / `50-redhat.conf`).
- **Toàn vẹn khi cài/cập nhật**: installer và `update panel` bắt buộc khớp `SHA256SUMS` (hoặc `--sha256`), kiểm tra `bash -n`, tự rollback; kiểm tra sha512 của `wp-cli.phar`.
- `site remove` xóa luôn thư mục site (trước đây `userdel -r` bỏ sót, còn nguyên `wp-config.php`).
- `security check` in PASS/WARN/FAIL (cấu hình sshd thực tế, PHP trong uploads, header, real IP, quyền file, secret trong log, BBR…); trả mã lỗi khi có FAIL.

### Tốc độ
- **HTTP/2** cho mọi site HTTPS.
- **Cache key bỏ tham số tracking** (`fbclid`, `gclid`, `utm_*`…): mỗi click quảng cáo không còn là một cache MISS.
- `fastcgi_cache_background_update` + `revalidate`; sửa bypass tìm kiếm (`s=` từng khớp nhầm `ids=`).
- **Purge theo site** (`optimize purge DOMAIN`) và **theo URL** (`optimize purge-url URL`, `cf purge-url` xóa cả cache origin) thay vì xóa toàn bộ.
- PHP-FPM: `pm.max_children` theo RAM và số site; idle 60s (giảm cold start); bỏ cấu hình OPcache/JIT vô hiệu trong pool.
- BBR: nạp module `tcp_bbr` lúc boot; MariaDB `table_open_cache` theo số site.
- `optimize report DOMAIN`: tỉ lệ HIT/MISS/BYPASS, p50/p95.
- `cf minify` gỡ bỏ (Cloudflare đã ngừng Auto Minify từ 08/2024).

### Nâng cấp từ 1.5.x
Trên máy agency: `bash build-release.sh`, upload **cả** `dist/SHA256SUMS` lên mirror, rồi `SSH_KEY=… ./deploy-safe.sh root@VPS_IP --with-check`.
Trên từng VPS, giờ thấp điểm, **giữ phiên SSH hiện tại**:
```bash
cecp-panel security check                  # ghi lại trạng thái trước
cecp-panel security apply-production       # quyền file + xóa secret cũ, real IP, fail2ban, headers, SSH harden
cecp-panel site rebuild-vhost --all        # template mới: chặn PHP uploads, headers, HTTPS/HTTP2, cache key, pool
cecp-panel optimize redis-acl --all        # nếu dùng Redis: ACL riêng từng site + đổi mật khẩu dùng chung
cecp-panel optimize stack
cecp-panel agent install                   # nếu dùng agent: tạo lại script heartbeat (token qua curl -K)
cecp-panel security check                  # kỳ vọng: không còn FAIL
```
Lưu ý:
- Zone Cloudflare phải ở chế độ **Full (strict)** trước khi site có HTTPS (`cecp-panel dns ssl-mode strict`), nếu không sẽ bị vòng lặp redirect.
- HSTS mặc định **không** có `includeSubDomains`; chỉ bật khi mọi subdomain đều đã có HTTPS.
- Nếu trước đó từng chạy `ssh-key-only`: từ 1.6 lệnh này mới thực sự có hiệu lực trên image cloud. Kiểm tra `sshd -T | grep passwordauthentication` và SSH bằng key trước khi chạy lại.

## 1.5.1-beta — hotfix

Bản 1.5.0-beta bị một công cụ chuyển CRLF→LF làm mất ký tự `r` ở cuối 27 dòng. Bản này chỉ sửa lỗi, không đổi hành vi.

### Sửa lỗi
- `optimize stack` chết ngay bước đầu (`optimize_kernel_bb`) → nginx/OPcache/MariaDB/Redis tuning chưa từng được áp dụng; sysctl ghi `tcp_congestion_control = bb` nên **BBR chưa bao giờ bật**.
- `site sftp-password` / `sftp-info` ghi `Match User ` rỗng vào `/etc/ssh/sshd_config.d/` → sshd lỗi config (nguy cơ khóa SSH khi restart).
- `update check` / `update panel` chết (`update_load_mirro`, `INSTALL_ROOT` chưa định nghĩa).
- `ssl fix`: câu trả lời Y/n bị bỏ qua.
- `site remove` luôn lỗi (Python inline thiếu `)`); nay dọn thêm pool Remi, cron wp-cron, drop-in SFTP.
- wp-cron hệ thống không chạy (user site không ghi được log vào `/var/log/cecp-panel`) trong khi `DISABLE_WP_CRON=true`.
- **Thêm site làm các site khác bị 502**: sau khi thêm pool, `reload` PHP-FPM (AlmaLinux 9, php-fpm 8.0) đổi chủ mọi socket cũ thành `root:root` → nginx bị từ chối. Nay `restart` khi thêm pool và kiểm tra lại quyền socket.
- `site add --wp` luôn dừng ở bước harden (`wp rewrite structure` thiếu tham số) → cron, reload và backup tự động cuối `site add` không chạy.
- `optimize stack` dừng ở bước nginx trên AlmaLinux (`keepalive_timeout` bị khai báo trùng).
- `site remove` âm thầm thoát với site chưa có SSL.
- Installer lỗi trên image có `curl-minimal`.

### An toàn
- Mọi thay đổi sshd đi qua `sshd -t`; lỗi thì hoàn tác, không reload.
- `security ssh-port`: gán nhãn SELinux `ssh_port_t` cho port mới; từ chối khi ssh chạy qua `ssh.socket`.
- Lệnh mới `security ssh-repair`: dọn drop-in SFTP bị 1.5.0 ghi hỏng.
- Release kèm `dist/SHA256SUMS`; build bắt buộc qua `tests/lint.sh`.

### Nâng cấp VPS đang chạy 1.5.0
Trên máy agency:
```bash
bash build-release.sh
SSH_KEY=~/.ssh/KEY ./deploy-safe.sh root@VPS_IP --with-check
```
Trên từng VPS (SSH vào, **giữ nguyên phiên hiện tại** cho tới khi xong):
```bash
sshd -t                                   # nếu lỗi: chạy lệnh dưới rồi kiểm tra lại
cecp-panel security ssh-repair            # dọn drop-in SFTP hỏng, tạo lại cho site còn tồn tại
sshd -t

# tạo lại cron wp-cron cho mọi site WordPress
for f in /var/lib/cecp-panel/sites/*.json; do
  d=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["domain"] if d.get("wordpress") else "")' "$f")
  [ -n "$d" ] && cecp-panel wp cron "$d"
done

cecp-panel optimize kernel
sysctl net.ipv4.tcp_congestion_control    # kỳ vọng: bbr

# giờ thấp điểm (restart MariaDB/Redis vài giây):
cecp-panel optimize stack
cecp-panel update check
```
Rollback: `deploy-safe.sh` đã sao lưu panel cũ tại `/var/lib/cecp-panel/backups/panel-<STAMP>/`.
