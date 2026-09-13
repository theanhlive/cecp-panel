# Changelog

## 1.9.0-beta — vận hành agency (đợt 3)

### Staging 1 lệnh (B1)
- `site staging DOMAIN [--name staging.DOMAIN] [--no-auth]` tạo bản sao đầy đủ (file + DB). Staging có user/pool/DB/Redis ACL riêng.
- Tự đổi URL trong DB, kể cả URL dạng JSON của page builder. Scheme http/https theo cert của staging, và site con một cấp tự dùng cert wildcard nếu có.
- Mặc định staging:
  - có basic auth và header `X-Robots-Tag: noindex`;
  - `WP_ENVIRONMENT_TYPE=staging`;
  - có mu-plugin chặn gửi e-mail và job nền (Action Scheduler) để khách thật không nhận mail đơn hàng từ bản sao;
  - không chạy wp-cron.
- `site staging-push DOMAIN [--files-only|--db-only] [--dry-run] [--yes]`:
  - lưu bản an toàn của site thật trước khi đẩy;
  - giữ `wp-config.php` và trạng thái hiển thị với Google của site thật, đổi URL staging về domain thật, gỡ mu-plugin staging, bật lại auto-purge;
  - site không lên thì **tự rollback**;
  - khi đẩy DB, CLI cảnh báo rõ rằng đơn hàng/bình luận phát sinh sau khi tạo staging sẽ mất.
- `site remove staging.DOMAIN` xóa staging và gỡ liên kết với site gốc.
- `site auth DOMAIN on|off|reset-password`: basic auth cho toàn site (preview cho khách). Challenge ACME vẫn mở, monitor và health check vẫn qua được.

### Cập nhật WordPress an toàn (A6)
- `wp update DOMAIN [--exclude a,b] [--no-major] [--dry-run]`:
  - lập kế hoạch (core/plugin/theme), kiểm tra site khỏe **trước** khi cập nhật, rồi tạo bản an toàn (file + DB);
  - cập nhật bằng user của site;
  - kiểm tra lại: WordPress phải load được với mọi plugin (`wp eval`) và trang chủ phải trả 2xx/3xx khi bỏ qua cache;
  - lỗi thì **tự rollback** và gửi sự kiện `wp_update_rolled_back` kèm lý do.
- `wp auto-update DOMAIN on [--exclude …] [--no-major] | off | status`: cập nhật tự động lúc 03:40 hằng ngày, có rollback.
- `wp rollback DOMAIN [--yes]`: hoàn tác lần cập nhật gần nhất.
- Mỗi site chỉ khóa một thao tác nguy hiểm tại một thời điểm (restore / update / staging-push).

### Giới hạn tài nguyên từng site (B4)
- `site limits DOMAIN --cpu 100 --mem 1G [--tasks 256] | off | show`:
  - PHP của site chạy trong PHP-FPM master riêng (`cecp-php-fpm@SLUG`, thuộc `cecp-sites.slice`) với `CPUQuota`/`MemoryMax`/`TasksMax` của systemd;
  - site bị hack hoặc plugin lỗi chỉ dùng hết phần của nó, không kéo sập cả VPS;
  - socket nằm ngoài `/run/php-fpm`, nên restart PHP-FPM chung (mỗi lần thêm site) không làm site giới hạn bị 502;
  - áp dụng lỗi thì tự hoàn nguyên. Monitor theo dõi cả các service này.

### Cấu hình PHP từng site (A9)
- `php config DOMAIN memory_limit=512M upload_max_filesize=128M max_execution_time=300 max_input_vars=5000 pm_max_children=8`. Có `--reset`.
- Chỉ nhận các key trong danh sách cho phép, có kiểm tra khoảng giá trị. `post_max_size` tự nâng cho ≥ `upload_max_filesize`.
- **Sửa lỗi upload:** nginx chưa từng đặt `client_max_body_size`, nên mặc định 1 MB làm mọi upload > 1 MB báo lỗi 413. Nay giá trị này theo `post_max_size`, và `fastcgi_read_timeout` theo `max_execution_time`.
- `php install 83|84`: cài thêm intl/zip/bcmath/imagick/redis (từng gói, thiếu gói nào thì bỏ qua gói đó).

### `status --json` + heartbeat (A10)
- `cecp-panel status --json` cho CECP Core/n8n: service; và theo từng site:
  - dung lượng đĩa (cache 6 h), kích thước DB;
  - tỉ lệ cache HIT, TTL/auto-purge/edge;
  - số ngày SSL còn lại;
  - backup (last_ok/verify), uptime;
  - cập nhật WP, limits, liên kết staging.
- Heartbeat của agent dùng chung tài liệu này (giữ các key cũ). Chạy lại `agent install` để cập nhật script.

### Công cụ DB (B6)
- `db export DOMAIN [FILE]`: gzip, quyền 600, không cho ghi vào `/home` (thư mục web tải được).
- `db import DOMAIN FILE [--replace-url OLD] [--yes]`:
  - dump bản hiện tại trước khi import;
  - import bằng **user DB của site**, nên dump có `USE`/`DROP` DB khác sẽ thất bại thay vì phá site khác; bỏ `DEFINER`;
  - site không lên thì tự khôi phục DB cũ.
- `db shell|info DOMAIN` (mật khẩu không nằm trên argv; `db info` hướng dẫn SSH tunnel cho TablePlus/DBeaver), `db size`, `db slow-log on [GIÂY]|off|status`, `db slow-report [TOP]`.
- **Không làm Adminer web:** tải PHP bên thứ ba khi chưa pin được checksum và mở giao diện DB ra Internet là rủi ro. Dùng `db shell` hoặc SSH tunnel thay thế.

### Sửa lỗi
- `site duplicate`:
  - bản sao giữ nguyên `wp-config.php` của site nguồn, nên **ghi thẳng vào DB của site nguồn** (và dùng chung Redis của nó); nay dùng DB và Redis ACL riêng;
  - bản sao WordPress không được đánh dấu là WordPress, nên không đổi URL;
  - luôn ép `https://` kể cả khi chưa có cert.
- Header bảo mật: `security check` chấp nhận snippet noindex của staging.
- `system maintain` dọn bản an toàn của staging-push/wp-update/db-import sau 14 ngày.

### Nâng cấp từ 1.8
```bash
cecp-panel site rebuild-vhost --all     # client_max_body_size, timeout, snippet noindex, pool mới
cecp-panel agent install                # heartbeat dùng status --json (nếu có agent)
cecp-panel wp auto-update example.com on --exclude woocommerce   # tùy chọn, từng site
cecp-panel site limits example.com --cpu 100 --mem 1G            # tùy chọn: site nặng/rủi ro
```

## 1.8.0-beta — tăng tốc website (đợt 2)

### Tự purge cache khi sửa nội dung (A4)
- `cache auto-purge DOMAIN on|off` (WordPress): mu-plugin ghi lại các URL bị ảnh hưởng khi đăng/sửa/xóa bài, có bình luận, đổi tồn kho WooCommerce (bài, trang chủ, feed, chuyên mục/thẻ, tác giả, archive). Đổi theme/menu/widget/plugin/tùy biến thì purge cả site.
- Việc purge chạy bằng root qua systemd path unit `cecp-purge@SLUG.path` (gần như tức thì), có cron 2 phút dự phòng. Hàng đợi nằm trong `tmp` riêng của site. Panel chỉ nhận URL `http(s)` đúng domain của site, không đi theo symlink và giới hạn kích thước, nên site không thể purge site khác hay ghi đè file hệ thống.
- Slug có dấu/Unicode (WordPress ghi `%xx` chữ thường, trình duyệt gửi chữ HOA) được purge cả hai dạng. `optimize purge-url` purge cả `http` và `https`.
- `cache ttl DOMAIN 5m|30m|1h|6h|1d`: TTL cache trang theo từng site. Khi đã bật auto-purge, có thể đặt 1h–1d để gần như mọi lượt xem đều HIT.
- `cache status DOMAIN` hiển thị TTL, auto-purge, edge cache và hàng đợi.

### Cache HTML ở edge Cloudflare (B3)
- `cf edge-cache DOMAIN on [--ttl 1h] | off | status`: tạo 1 Cache Rule cho site (host = domain). Bỏ qua `/wp-admin`, `/wp-json`, `wp-login`, giỏ hàng/thanh toán/tài khoản, tìm kiếm/preview, cookie đăng nhập/giỏ hàng/bình luận. Các rule khác trong zone được giữ nguyên. Nếu không đọc được ruleset hiện tại thì từ chối ghi, để không làm mất rule của người khác.
- Khi bật cùng auto-purge: sửa bài → purge đúng các URL đó ở edge (30 URL/lần gọi); purge cả site → purge theo **hostname**, không purge toàn zone.
- Token cần quyền **Zone → Cache Rules → Edit** và **Zone → Cache Purge**.

### WebP/AVIF tự động (A5)
- nginx trả `photo.webp` / `photo.avif` (nằm cạnh `photo.jpg`) cho trình duyệt hỗ trợ; nếu thiếu thì trả file gốc; header `Vary: Accept`.
- `media enable DOMAIN --avif`: tạo AVIF (PHP ≥ 8.1 với `imageavif`, Pillow ≥ 11.2 hoặc ImageMagick có libheif; chỉ giữ bản nhỏ hơn file gốc). AVIF là tùy chọn vì Cloudflare gói thường bỏ qua `Vary`, nên có thể trả AVIF cho trình duyệt cũ. WebP luôn được bật.
- Kiểm tra tham số `media enable` (chất lượng, kích thước).

### SSL qua DNS Cloudflare + wildcard (A8)
- `ssl issue DOMAIN --dns`: DNS-01 qua API Cloudflare. Chạy được khi bản ghi đang proxied hoặc cổng 80 bị chặn.
- `ssl issue DOMAIN --wildcard`: cert `DOMAIN` + `*.DOMAIN`. Site con một cấp (vd. `shop.DOMAIN`) tự dùng cert này khi thêm site hoặc khi cấp wildcard; gỡ cert thì các site đó tự quay về HTTP, nginx không lỗi.
- Gia hạn giữ nguyên DNS-01, chỉ bỏ `installer`. Token nằm trong `/etc/letsencrypt/cecp-cloudflare.ini` (600), không đưa lên dòng lệnh. Cảnh báo khi zone đang ở SSL `flexible`.
- `ssl remove` dựng lại vhost HTTP (trước đây vhost HTTPS vẫn trỏ tới cert đã xóa, làm lần reload nginx sau bị lỗi).

### Khác
- `fastcgi_cache_path inactive=12h` (TTL dài không bị xóa sớm).
- `site duplicate` không sao chép cấu hình auto-purge của site nguồn; `site remove` tắt watcher purge.
- Menu: SSL DNS/wildcard, edge cache, cache TTL/auto-purge.

### Nâng cấp từ 1.7
```bash
cecp-panel site rebuild-vhost --all          # WebP/AVIF, TTL cache, template SSL mới
cecp-panel cache auto-purge example.com on   # từng site WordPress
cecp-panel cache ttl example.com 1h
# Cloudflare (token: Cache Rules Edit + Cache Purge + DNS Edit):
cecp-panel cf edge-cache example.com on --ttl 1h
cecp-panel ssl issue example.com --wildcard  # tùy chọn
```

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
