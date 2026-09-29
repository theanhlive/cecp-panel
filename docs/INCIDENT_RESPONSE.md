# Xử lý khi website bị hack — runbook (người & AI Agent)

Áp dụng khi một (hoặc nhiều) site trên VPS bị chèn mã độc, chuyển hướng lạ, spam SEO, tạo admin lạ,
Google báo "trang web bị xâm nhập"… Làm **theo thứ tự**. Bước có **[HỎI NGƯỜI]** là quyết định của
chủ VPS; AI Agent dừng lại và báo cáo.

> Nguyên tắc: một site bị hack là chuyện của site đó. **Nhiều site cùng bị** thì kẻ tấn công đã đi
> được giữa các site hoặc đã lên root, nên phải coi **cả VPS** là không còn tin được.

---

## 1. Khoanh vùng (5 phút đầu)

```bash
cecp-panel security scan --all --days 30 | tee /root/scan-$(date +%F).txt
```

Đọc mục `--- Server ---` trước:

| Kết quả | Ý nghĩa | Hướng xử lý |
|---|---|---|
| Có `FAIL` ở **Server** (UID 0 lạ, `/etc/ld.so.preload`, crontab của `site_*`, tiến trình lạ của `site_*`) hoặc file cron/systemd/SSH đổi mà bạn không làm | Có thể **đã mất root** | **Mục 2A — dựng VPS mới** |
| Chỉ `FAIL` ở một vài site, site khác sạch | Nhiễm trong phạm vi site | **Mục 2B — làm sạch tại chỗ** |
| `files not owned by site_x` chứa file của **user site khác** | Đã ghi chéo giữa các site (bản panel cũ) | Coi như 2A, hoặc tối thiểu 2B cho **mọi** site |

AI Agent: gửi nguyên file `scan-*.txt` cho chủ VPS, không tự xoá gì ở bước này. **[HỎI NGƯỜI]** chọn 2A hay 2B.

Chặn thiệt hại ngay trong lúc xử lý (không mất dữ liệu):

```bash
cecp-panel site protect-admin DOMAIN on          # khoá wp-admin bằng mật khẩu (mỗi site bị nhiễm)
cecp-panel site auth DOMAIN on                   # hoặc khoá CẢ site (khách thấy hộp mật khẩu) nếu đang phát tán mã độc
cecp-panel backup run --all                      # chụp lại hiện trạng để điều tra, KHÔNG dùng để restore
```

---

## 2A. Đã có thể mất root → dựng lại VPS (cách duy nhất đáng tin)

Khi kẻ tấn công đã lên root thì không có cách "dọn" nào chắc chắn, vì rootkit có thể giấu cả chính nó.

1. Tạo **VPS mới** và cài panel bản mới nhất (`CUSTOMER_INSTALL.md`), rồi:
   `cecp-panel security apply-production && cecp-panel optimize stack`.
2. Với mỗi site: `cecp-panel site add DOMAIN --wp`, rồi restore **snapshot trước thời điểm bị nhiễm**:
   ```bash
   cecp-panel backup list                         # chọn snapshot cũ hơn ngày bị hack
   cecp-panel backup restore DOMAIN SNAPSHOT_ID --live --yes
   ```
   Không nhớ ngày bị hack: restore vào thư mục riêng (`--target /root/check`) rồi chạy scan trên đó.
3. Làm **mục 3** (làm sạch WordPress) và **mục 4** (đổi mọi bí mật) trên VPS mới.
4. Trỏ DNS sang IP mới (docs/CLOUDFLARE_DNS.md), rồi mới tắt VPS cũ. Giữ ổ đĩa VPS cũ vài ngày để điều tra.

---

## 2B. Nhiễm trong phạm vi site → làm sạch tại chỗ

```bash
cecp-panel update panel                          # bản vá cách ly (1.12+)
cecp-panel security apply-production             # quyền docroot, OPcache cô lập, fail2ban...
cecp-panel site rebuild-vhost --all              # disable_symlinks, wp-cron qua PHP-FPM, cấm crontab của site
cecp-panel security check
```

Rồi với **từng site có FAIL**: nếu có backup sạch, cách nhanh nhất là restore:
`cecp-panel backup restore DOMAIN SNAPSHOT_ID --live`. Nếu không có: làm mục 3.

---

## 3. Làm sạch một site WordPress

Chạy lệnh WordPress **bằng user của site** và **không nạp plugin/theme** (code độc không được chạy):

```bash
D=domain.com
SU=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["site_user"])' /var/lib/cecp-panel/sites/$D.json)
DOC=/home/$SU/public_html
wpx() { runuser -u "$SU" -- php /usr/local/bin/wp --path="$DOC" --skip-plugins --skip-themes "$@"; }

wpx core download --force --skip-content --version="$(wpx core version)"   # thay toàn bộ core bằng bản gốc
wpx core verify-checksums                                                    # phải "Success"
for p in $(wpx plugin list --field=name); do wpx plugin install "$p" --force || echo "TỰ KIỂM TRA: $p"; done
wpx plugin verify-checksums --all
```

Sau đó xử lý từng dòng `FAIL` còn lại của `cecp-panel security scan $D`:

- **PHP trong `uploads/`**: xoá (WordPress không bao giờ đặt code ở đó).
- **mu-plugins lạ**: xoá, trừ khi bạn biết rõ nó là gì. `cecp-*` là của panel.
- **Theme**: cài lại bản gốc từ nhà cung cấp. Plugin/theme trả phí thì tải lại từ trang của hãng
  (`wp plugin install` chỉ có với plugin trên wordpress.org).
- **Admin lạ**: `wpx user list --role=administrator`, rồi `wpx user delete ID --reassign=ID_CỦA_BẠN`.
- **Symlink ra ngoài docroot, file của user khác**: xoá.
- **`wp-config.php` trỏ sai database / include lạ**: sửa lại theo mục 4 (`rotate-secrets` ghi lại DB).
- **Database**: tìm script chèn vào bài viết/tuỳ chọn:
  `wpx db query "SELECT option_name FROM wp_options WHERE option_value LIKE '%<script%' OR option_value LIKE '%eval(%'"`
  và `wpx search-replace` / sửa tay những gì lạ **[HỎI NGƯỜI]** trước khi xoá dữ liệu.

Quét lại cho tới khi sạch: `cecp-panel security scan $D`.

---

## 4. Đổi toàn bộ bí mật (bắt buộc — kẻ tấn công đã đọc được chúng)

```bash
cecp-panel security rotate-secrets --all --admins
```

Lệnh này đổi, cho từng site: mật khẩu database (và ghi lại vào `wp-config.php`), salts WordPress
(mọi phiên đăng nhập bị đăng xuất), mật khẩu Redis ACL, **khoá** mật khẩu SFTP, và cấp mật khẩu mới
cho **mọi admin WordPress**. Mật khẩu mới chỉ in ra màn hình một lần, không ghi vào log: lưu lại ngay.

Tự làm thêm **[HỎI NGƯỜI]**:
- Mật khẩu root / SSH key của VPS: `cecp-panel security ssh-key-only` sau khi đã có key mới.
- Cloudflare API token: tạo token mới, thu hồi token cũ, nạp lại (docs/CLOUDFLARE_DNS.md mục 2).
- SFTP cho người cần: `cecp-panel site sftp-password DOMAIN`.
- Khoá API trong plugin (SMTP, cổng thanh toán, Google…), mật khẩu hosting/nhà đăng ký tên miền.

---

## 5. Ngăn tái nhiễm

```bash
cecp-panel update all                               # OS + WordPress + plugin + panel
cecp-panel wp auto-update DOMAIN on --no-major      # từng site
cecp-panel security cf-only status                  # nếu mọi site qua Cloudflare: security cf-only on
cecp-panel modsec install && cecp-panel modsec enable   # WAF (tuỳ chọn, xem trước ở chế độ DetectionOnly)
cecp-panel monitor enable
cecp-panel backup enable-cron                       # có snapshot sạch để quay về lần sau
```

Theo dõi trong 2 tuần sau: `cecp-panel security scan --all --days 1` mỗi ngày. Nếu file độc quay lại
thì vẫn còn cửa hậu (plugin/theme chưa thay, admin lạ, cron…), hoặc đã mất root: chuyển sang **2A**.

---

## Các lớp cách ly giữa các site (1.12+)

| Lớp | Chặn |
|---|---|
| Mỗi site một user Linux + PHP-FPM pool riêng, `open_basedir`, thư mục tmp/session riêng | PHP của site A đọc/ghi file site B |
| ACL docroot: bỏ quyền "other", nginx không đọc được `.php` | Đọc `wp-config.php` (mật khẩu DB) của site khác |
| Root không bao giờ ghi/chown trong docroot (thao tác bằng user của site) | Site bị hack đặt symlink để panel (root) trao quyền `/etc` hay ghi đè `wp-config.php` của site khác |
| nginx `disable_symlinks if_not_owner` | Site A tạo symlink tới file site B / hệ thống rồi tải về qua web |
| wp-cron chạy qua PHP-FPM của site (không qua PHP CLI) | Plugin độc có shell đầy đủ (`exec`, không `open_basedir`) mỗi lần cron chạy |
| `disable_functions` (exec, system, proc_open, putenv…) | Chạy lệnh hệ thống từ PHP |
| User site bị cấm `crontab`/`at` | Cửa hậu tự cài lại sau khi đã dọn |
| OPcache: `validate_permission`, API bị khoá | Liệt kê/đầu độc code đã cache của site khác |
| DB user riêng mỗi site; import/restore bằng user của site | Một dump độc sửa database site khác / tạo user MariaDB |
| Redis ACL riêng mỗi site | Đọc/xoá cache object của site khác |
