# Changelog

## 1.12.0-beta — rà soát bảo mật, tốc độ, dữ liệu backup và thao tác

### Cách ly giữa các site — vá đường lây chéo (sau sự cố: một site bị hack kéo theo mọi site)
- **Leo thang lên root qua symlink (nghiêm trọng)**: panel (root) tạo/`chown`/ghi file bên trong docroot — `mu-plugins`, `wp-config.php` — và đi theo symlink. Code độc của site A đặt `wp-content/mu-plugins → /etc` thì `media enable` chuyển quyền sở hữu `/etc` cho site A (chiếm root → mọi site). `wp-config.php → wp-config của site B` thì restore/duplicate/staging/redis ghi thông tin DB của A vào B (B chạy trên database do kẻ tấn công kiểm soát). Đã tái hiện cả hai. Giờ **root không bao giờ ghi trong docroot**: mọi thao tác chạy bằng user của site (`site_write_file`, `site_run_as`); mu-plugin của panel thuộc user site (root-owned trước đây không bảo vệ gì — site vẫn xoá/tạo lại được).
- **nginx `disable_symlinks if_not_owner`**: site A tạo symlink tới file của site B (hoặc `/etc/passwd`) rồi tải về qua web — đã tái hiện (HTTP 200 kèm dữ liệu của B), giờ bị chặn.
- **wp-cron chạy qua PHP-FPM của chính site** (loopback HTTP, 5 phút/lần) thay vì `wp cron event run` (PHP CLI không có `open_basedir`/`disable_functions` → plugin độc có shell đầy đủ mỗi 15 phút). `wp-cron.php` chỉ nhận loopback (chặn spam wp-cron từ ngoài).
- **User site bị cấm `crontab`/`at`** (`/etc/cron.deny`, `/etc/at.deny`) — chặn cửa hậu tự cài lại.
- **OPcache cô lập** (`security php-isolation`, nằm trong `apply-production`): `validate_permission`, `validate_root`, khoá API — trước đây mọi site dùng chung một OPcache: liệt kê/xoá/đầu độc code của nhau.
- `site rebuild-vhost` giờ tự áp: ACL docroot (trước đây site cũ chưa chạy `harden-docroot` vẫn đọc chéo được `wp-config.php`), cấm crontab, dòng wp-cron mới. `security check` báo FAIL/WARN khi VPS chưa áp.
- **`security scan [DOMAIN|--all] [--days N]`** (mới, chỉ đọc): PHP trong uploads, mẫu web shell/loader, file của user khác trong docroot (ghi chéo), symlink ra ngoài, mu-plugin lạ, `wp-config.php` trỏ database khác, checksum core/plugin wordpress.org, admin mới tạo; cấp server: UID 0 lạ, `ld.so.preload`, crontab/at của site, tiến trình lạ của site, file site trong /tmp, cron/systemd/SSH key đổi gần đây. Lệnh WordPress chạy với `--skip-plugins --skip-themes` (code độc không chạy).
- **`security rotate-secrets DOMAIN|--all [--admins]`** (mới): mật khẩu DB (ghi lại wp-config), salts WordPress (đăng xuất mọi phiên), Redis ACL, khoá mật khẩu SFTP, mật khẩu mới cho mọi admin (chỉ in ra màn hình).
- Runbook [docs/INCIDENT_RESPONSE.md](docs/INCIDENT_RESPONSE.md): khoanh vùng → dựng VPS mới hay làm sạch tại chỗ → làm sạch WordPress → đổi bí mật → ngăn tái nhiễm.

### Bảo mật
- **Media optimize không còn chạy bằng root trên thư mục `uploads/`** (của site): trước đây một WordPress bị hack có thể đặt symlink (vd. `anh.webp -> /etc/shadow`) và job tối ưu ảnh hằng đêm (root) sẽ ghi đè file hệ thống qua symlink đó. Giờ script chạy bằng user của chính site (`runuser`), file cũ do root tạo được chuyển quyền trước (`chown -h`, không đi theo symlink).
- **Chặn tải file backup qua web**: `wp-content/ai1wm-backups`, `updraft`, `backups-dup-*`, `backwpup-*`, `wpvividbackups`, `backuply`, `wp-migrate-db`, `wp-staging` và các đuôi `.wpress .wpstg .sql.gz .sql.zip .dump .orig .old .save ~`. Các plugin này chỉ tự bảo vệ bằng `.htaccess` — nginx bỏ qua `.htaccess`, nên ai đoán được tên file là tải được toàn bộ site + database.
- **HTTPS catch-all** (`00-cecp-default-ssl.conf`, nginx ≥ 1.19.4): hostname lạ hoặc truy cập thẳng bằng IP trên cổng 443 bị từ chối bắt tay TLS, thay vì nhận chứng chỉ + nội dung của site đầu tiên. Chặn việc quét chứng chỉ để tìm ra IP gốc sau Cloudflare. Tự bỏ qua nếu nginx cũ hoặc đã có `default_server` 443 khác.
- `system.env` được nạp qua `secure_source` (như mọi file env khác); `optimize redis` nhận ra Redis có sẵn trên Ubuntu (`redis-server`) để không cấu hình đè.

- **`cecp-panel security cf-only on|off|status`** (mới, tự chọn bật): cổng 80/443 chỉ nhận kết nối từ dải IP Cloudflare (firewalld ipset / ufw), SSH không đổi. Kẻ tấn công biết IP gốc không còn vượt qua được WAF/chống DDoS của Cloudflare. Trước khi bật, panel kiểm tra mọi site đều đã proxy qua Cloudflare (mây cam) — site nào chưa sẽ bị liệt kê và lệnh dừng lại (`--force` để bỏ qua). Danh sách IP tự cập nhật theo cron `cf realip` hằng tuần.
- **Chặn `putenv`** trong PHP (`disable_functions`): cặp `putenv("LD_PRELOAD=…")` + `mail()` là cách phổ biến để chạy lệnh hệ thống dù `exec/system` đã bị cấm. Plugin nào cần: `cecp-panel php config DOMAIN allow_putenv=on`.
- **Restore/verify backup không import database bằng root nữa**: restore dùng user DB của chính site (như `db import`), verify dùng một user tạm chỉ có quyền trên database tạm rồi xoá ngay. Trước đây một bản dump bị sửa độc (`CREATE USER … GRANT ALL ON *.*`) chạy với quyền root MariaDB.

### RAM
- `pm.max_children` tự động giờ tính trên **RAM còn lại** sau buffer pool MariaDB + `maxmemory` Redis + ~300 MB cho hệ điều hành (tối thiểu ¼ RAM), chia cho số site, 2..32. Trước đây PHP được cấp 50% RAM (tối thiểu 4 tiến trình/site) *cộng thêm* MariaDB 30% + Redis 10% → VPS 1 GB nhiều site dễ hết RAM, OOM killer tắt MariaDB. Ví dụ VPS 1 GB, 1 site: 8 → 5 tiến trình.
- `security check` cảnh báo khi tổng tiến trình PHP tối đa (kể cả giá trị đặt tay) vượt ngân sách RAM; `system info` hiện ngân sách này.

### DNS Cloudflare
- `dns point` / `dns add` tìm **đúng zone** của domain (dò từ tên đầy đủ lên dần, mọi zone token quản lý). Trước đây `dns point shop.khachhang.vn` tạo nhầm `shop.<CF_DEFAULT_ZONE>`, còn domain gốc `khachhang.vn` bị hiểu zone là `vn`. `dns ssl-mode MODE DOMAIN` nhận cả subdomain.
- Tài liệu mới [docs/CLOUDFLARE_DNS.md](docs/CLOUDFLARE_DNS.md): quy trình chuẩn trỏ domain qua Cloudflare (token, thứ tự cấp SSL → trỏ DNS → SSL mode strict, subdomain/www, khoá IP gốc, kiểm tra, bảng lỗi 521/522/525/526); `AGENTS.md` + `CLAUDE.md` để AI Agent tự đọc.

### WordPress + SSL
- `FORCE_SSL_ADMIN` chỉ bật khi site **đã có chứng chỉ**: trước đây site mới (`site add --wp`, chưa `ssl issue`) bị chuyển wp-admin sang `https://` không tồn tại → không vào được trang quản trị.
- `ssl issue` giờ chuyển `home`/`siteurl` của WordPress sang `https://` (và `ssl remove` chuyển về `http://`) — chỉ khi URL đúng là `http(s)://DOMAIN`, không đụng URL tuỳ chỉnh/thư mục con. Trước đây mọi link nội bộ đều phải đi qua redirect 301.
- Site con dùng wildcard của domain cha được cài WordPress với `https://` ngay từ đầu.

### Tốc độ / dữ liệu
- **Backup không nén `public_html` trước khi đưa cho restic** (`public_html.tar` thay cho `.tar.gz`): restic khử trùng lặp theo nội dung (và tự nén với repository v2), còn gzip làm thay đổi toàn bộ luồng dữ liệu → trước đây **mỗi ngày upload lại gần như toàn bộ site lên Google Drive**. Giờ chỉ phần thay đổi được upload. Restore/verify đọc được cả snapshot cũ (`.tar.gz`). Lưu ý: thư mục staging tạm thời cần dung lượng bằng kích thước site (không nén). Repository tạo bằng restic < 0.14 (v1, không nén): `restic migrate upgrade_repo_v2`.
- Bảo trì hằng tuần (`system maintain`) **không còn xoá sạch page cache nginx và cache của restic** mỗi lần chạy (site chậm cho tới khi cache đầy lại; backup kế tiếp phải tải lại index từ Google Drive) — chỉ xoá khi ổ đĩa vượt ngưỡng `DISK_CLEAN_MIN_USE_PCT`; bình thường chỉ `restic cache --cleanup`.
- `cache purge DOMAIN` đọc 4 KB đầu mỗi file cache (dòng `KEY:`) thay vì `grep` toàn bộ nội dung (tới 1 GB) — nhanh hơn nhiều khi auto-purge "xoá hết" chạy thường xuyên.
- wp-cron của mỗi site chạy ở một phút riêng trong chu kỳ 15 phút (trước đây mọi site cùng khởi động WordPress lúc :00/:15/:30/:45 → đỉnh CPU/RAM). Áp dụng cho site cũ: `cecp-panel wp cron DOMAIN`.
- gzip thêm font (`ttf/otf/eot`) và favicon.

### Tối ưu ảnh
- **Upload bất kỳ định dạng → một file WebP tối ưu, không giữ file gốc** (`media enable DOMAIN`, mặc định `--format webp`): JPG/PNG/WebP/BMP (HEIC/HEIF iPhone, TIFF khi có PHP Imagick) được xoay đúng chiều, thu về tối đa 1920px (không phóng to), lưu **một** file WebP; file upload bị xoá, WordPress không còn giữ cặp `-scaled` + bản gốc, thumbnail cũng là WebP. Ảnh PNG (chữ/logo) nén chất lượng cao hơn; ảnh đã tối ưu sẵn giữ nguyên. Thử thực tế: ảnh điện thoại 819 KB → 72 KB, BMP 5,7 MB → 61 KB. `--format avif` (WordPress ≥ 6.5) hoặc `--format original` (hành vi cũ). Site bật trước đây giữ chế độ cũ cho tới khi chạy lại `media enable`.
- `media prune-originals DOMAIN [--yes]` (mới): xoá bản gốc full-size WordPress đã giữ cho thư viện cũ (chạy thử mặc định, báo dung lượng giải phóng). Có trong menu Media.
- `media status DOMAIN` liệt kê định dạng server đọc/chuyển được; `media enable` cài PHP Imagick (nếu có gói) và cảnh báo khi RAM PHP không đủ cho ảnh rất lớn.
- Ảnh PNG trong suốt (logo, dạng palette) **không còn bị nền đen** trong bản WebP/AVIF.
- Giữ ICC color profile khi nén lại JPEG/WebP (ảnh chụp từ điện thoại không bị nhạt màu).
- Không ghi đè ảnh gốc nếu bản nén lại không nhỏ hơn (trừ khi resize); xoá sidecar WebP/AVIF nếu nó **lớn hơn** ảnh gốc (nginx ưu tiên sidecar → trước đây có thể phục vụ file to hơn).
- mu-plugin: ảnh vừa upload không bị nén lossy lần thứ hai ở bước tạo metadata.

### Thao tác
- **Menu tương tác không còn bị thoát ra shell khi một thao tác lỗi** (gõ sai domain, bước nào đó thất bại) — báo lỗi rồi quay lại menu.
- **Tự động gợi ý bằng phím Tab** (`/etc/bash_completion.d/cecp-panel`): lệnh, lệnh con, cờ (`--wp`, `--dns`…) và domain của các site trên VPS. Có hiệu lực ở phiên SSH mới.
- Cài thêm `bash-completion` và `acl` ngay khi cài panel.

### Nâng cấp từ 1.11
```bash
cecp-panel update panel                  # hoặc deploy-safe.sh từ máy agency
cecp-panel security apply-production     # gồm OPcache cô lập giữa các site
cecp-panel site rebuild-vhost --all      # rule chặn file backup, HTTPS catch-all, disable_symlinks, wp-cron qua PHP-FPM, cấm crontab site, ACL docroot
cecp-panel security scan --all           # quét dấu hiệu nhiễm (xem docs/INCIDENT_RESPONSE.md nếu có FAIL)
cecp-panel wp cron DOMAIN                # (từng site WordPress) rải lịch wp-cron
cecp-panel ssl issue DOMAIN              # (site đã có SSL) chuyển URL WordPress sang https nếu còn http
cecp-panel security check                # xem cảnh báo RAM; site rebuild-vhost --all ở trên đã áp số tiến trình mới + putenv
cecp-panel media enable DOMAIN            # (site đang bật media) chuyển sang lưu 1 file WebP, không giữ gốc
cecp-panel media prune-originals DOMAIN   # xem dung lượng bản gốc cũ có thể xoá (thêm --yes để xoá)
cecp-panel security cf-only status       # (tuỳ chọn) nếu mọi site qua Cloudflare: cecp-panel security cf-only on
```

## 1.11.0-beta — vá lỗ hổng đọc chéo giữa các site (world-readable docroot)

### Vấn đề
- Từ trước tới giờ, docroot mỗi site được tạo `755`/file `644` (world-readable) để nginx (không nằm trong group riêng của site nào) đọc được file tĩnh. Hệ quả: **user Linux của site A đọc thẳng được `wp-config.php` (mật khẩu DB, khóa salt) của site B** ở tầng hệ điều hành — không đi qua PHP nên `open_basedir`/`disable_functions` của pool PHP-FPM (vốn đã cô lập tốt ở tầng thực thi PHP) không chặn được đường này. Phát hiện và xác minh trực tiếp trên VPS production (theanh-lap-01) ngày 2026-09-14.
- Ghi chéo (1 site ghi/cấy file sang site khác) đã được chặn từ trước (docroot không có quyền ghi cho "other", thư mục `tmp` riêng đã là `700`) — lỗ hổng chỉ ở chiều đọc.

### Vá
- `cecp-panel security harden-docroot [DOMAIN|--all]` (mới): gỡ quyền đọc "other" khỏi docroot bằng `setfacl -m o::---`, rồi cấp lại cho riêng user `nginx` — nhưng **không cấp trên file `.php` (kể cả `wp-config.php`)**, chỉ trên file tĩnh (ảnh, css, js...) + quyền traverse (`--x`, không listing) trên thư mục. Lý do: nginx không bao giờ tự đọc nội dung file `.php` — request `.php` luôn được proxy sang PHP-FPM pool riêng của site đó qua `fastcgi_pass`, nginx chỉ cần biết file tồn tại (`stat`, cần `x` trên thư mục cha, không cần `r`). Bỏ hẳn quyền đọc `.php` khỏi ACL của nginx nghĩa là **cho dù có tiến trình nào đó (vô tình hay cố ý) chạy chung danh tính `nginx`** (ví dụ 1 site cấu hình tay ngoài panel có PHP-FPM pool set `user = nginx` thay vì user riêng của site), tiến trình đó vẫn không đọc được `wp-config.php` của bất kỳ site nào — không có gì để "thừa hưởng" qua ACL cả.
- Áp dụng ACL mặc định (`-d`) là `rx` đồng nhất cho file/thư mục mới tạo (để upload ảnh mới hoạt động ngay, không cần chờ) — riêng `.php` mới tạo sẽ tạm có ACL `nginx:rx` cho tới lần hardening kế tiếp thì bị gỡ; vì vậy hardening được chạy lại tự động sau **mọi thao tác WordPress core/plugin/theme update** (`cecp-panel wp update`), không chỉ lúc tạo site.
- Tự động áp dụng cho: site mới (`site add`, chạy 2 lần — trước và sau khi cài WordPress, vì lần đầu docroot còn rỗng), site nhân bản (`site duplicate` — rsync có thể phục hồi lại mode bit gốc), sau mọi lần `backup restore`, và sau mọi lần `wp update`.
- `cecp-panel security apply-production` giờ chạy `harden-docroot --all` cho toàn bộ site hiện có như một bước trong quy trình production hoá — **cần chạy lại lệnh này trên site đã tồn tại để áp bản vá** (site tạo mới sau 1.11.0-beta tự động có sẵn).
- `cecp-panel security check` báo `FAIL` nếu `wp-config.php` của site nào đó vẫn world-readable HOẶC vẫn còn ACL đọc cho `nginx`, kèm lệnh sửa.

### Nâng cấp từ 1.10
```bash
cecp-panel security apply-production      # vá lỗ hổng world-readable cho toàn bộ site hiện có
cecp-panel security check                 # xác nhận không còn cảnh báo wp-config.php world-readable
```

## 1.10.0-beta — mặc định thông minh + cập nhật toàn diện

### Mặc định cho site WordPress mới
- `site add DOMAIN --wp` giờ tự động bật thêm (không cần chạy tay từng lệnh):
  - `cache auto-purge on` + `cache ttl 1h` (đợt 2): trang được cache 1 giờ nhưng vẫn mới ngay khi sửa bài;
  - `wp auto-update on --no-major` (đợt 3): tự cập nhật plugin/theme và core (trừ bản major) hằng ngày, có rollback nếu lỗi.
- Cố ý **không** bật mặc định: Redis (tốn thêm RAM trên VPS 1GB), media optimize (tốn CPU mỗi lần upload), site limits/protect-admin (cần thông tin xác thực hoặc quyết định riêng của bạn).
- `site add DOMAIN --wp --minimal` để giữ hành vi cũ (không bật 2 mục trên). Tắt sau khi tạo: `cecp-panel cache auto-purge DOMAIN off` / `cecp-panel wp auto-update DOMAIN off`.
- Áp dụng cho site cũ: chạy tay `cecp-panel cache auto-purge DOMAIN on` và/hoặc `cecp-panel wp auto-update DOMAIN on` — không tự động áp cho site đã có sẵn, để không thay đổi hành vi ngoài ý muốn.

### `cecp-panel update all` — cập nhật toàn bộ trong một lệnh
- Gộp mọi phần cần cập nhật định kỳ: gói hệ thống (nginx, PHP mọi bản Remi, MariaDB, Redis, restic, rclone, certbot, fail2ban qua `dnf`/`apt`), `wp-cli`, **WordPress (core/plugin/theme) của mọi site** (dùng lại cơ chế an toàn của `wp update`: bản sao trước, kiểm tra sức khỏe, tự rollback nếu site không lên), rồi panel chính nó (nếu đã cấu hình mirror).
- Mỗi bước cách ly trong subshell: một bước lỗi không làm dừng các bước còn lại; cuối cùng in tổng kết (site nào cập nhật/rollback/lỗi) và gửi sự kiện `update_all_done` (n8n/webhook).
- Sau khi cập nhật gói hệ thống: tự reload nginx/PHP-FPM, restart ngắn MariaDB/Redis để dùng bản mới, chạy `monitor run` để tự sửa service nào bị tắt, và báo nếu cần **reboot** (kernel/glibc đổi) — panel không tự reboot.
- Bỏ qua từng phần khi cần: `update all --skip-os` (chỉv WordPress+wp-cli, an toàn hơn khi không muốn đụng gói hệ thống), `--skip-wp`, `--skip-panel`.
- `update enable-cron` / `disable-cron`: chạy `update all` tự động hằng tuần (CN 04:10 UTC). Site đang là bản staging (`staging_of`) được bỏ qua trong vòng lặp WordPress.
- `update wp-cli`: cập nhật wp-cli.phar (có kiểm sha512) ngay cả khi đã cài — trước đây `wp_ensure_cli` chỉ cài khi thiếu, không bao giờ cập nhật.

### Nâng cấp từ 1.9
```bash
cecp-panel update wp-cli                 # một lần
cecp-panel update enable-cron            # tuỳ chọn: tự cập nhật hằng tuần
# Site cũ muốn có mặc định mới (tuỳ chọn, từng site):
cecp-panel cache auto-purge example.com on
cecp-panel wp auto-update example.com on --no-major
```

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
