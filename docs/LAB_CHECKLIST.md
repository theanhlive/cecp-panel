# Checklist T4 — kiểm thử thủ công trên VPS lab (trước mỗi RC)

Tầng **T4** trong [ADR-0001](adr/0001-release-readiness.md): những gì Docker test (`tests/integration/run.sh`)
không kiểm được — OS thật, mạng thật, bot thông báo thật, firewall thật, nâng cấp từ bản cũ.
Chạy **trước** khi gắn tag `X.Y.Z-rc.N`. Mục nào không làm được: ghi `SKIP` + lý do, không để trống.

## Quy tắc

- Chỉ dùng **VPS lab** (không có site/khách thật). Không chạy trên VPS production.
- Domain lab trỏ về VPS lab (ví dụ `lab.example.com`); thay `DOMAIN`, `IP_VPS` bên dưới.
- Không dán token/mật khẩu (Telegram, Zalo, Discord, Cloudflare, restic) vào ô kết quả, PR hay commit.
- Sau mỗi nhóm mục: `cecp-panel security check` (0 FAIL) và `cecp-panel status`.
- Ký hiệu ô kết quả: `PASS` / `FAIL` / `SKIP (lý do)` + ghi chú ngắn (phiên bản nginx, lỗi gặp…).

## Thông tin lần chạy

| Trường | Giá trị |
|---|---|
| Phiên bản / commit đang thử | |
| Người chạy / ngày | |
| VPS lab (nhà cung cấp, RAM, OS) | |
| Kết quả `bash tests/integration/run.sh` cùng commit | `RESULT: … passed, … failed` |

## 0. Chuẩn bị VPS lab (mỗi OS)

Cài từ checkout của nhánh/commit cần thử (không qua GitHub `main`):

```bash
git clone https://github.com/theanhlive/cecp-panel.git && cd cecp-panel && git checkout <commit>
sudo bash install.sh
cecp-panel security apply-production
cecp-panel optimize stack
cecp-panel site add DOMAIN --wp
cecp-panel ssl issue DOMAIN
cecp-panel site probe DOMAIN
```

Kỳ vọng: cài không lỗi; `site probe` thoát 0 (mọi đường dẫn `PASS`); `security check` 0 FAIL.

| OS | Kết quả | Ghi chú |
|---|---|---|
| AlmaLinux 9 | | |
| Ubuntu 22.04 | | |
| Ubuntu 24.04 | | |

## 1. Ubuntu 22.04 / 24.04

| # | Lệnh | Kết quả mong đợi | 22.04 | 24.04 |
|---|---|---|---|---|
| 1.1 | `nginx -v; cecp-panel site rebuild-vhost --all; nginx -t` | `nginx -t` OK sau khi render lại vhost | | |
| 1.2 | `ls /etc/nginx/conf.d/00-cecp-default-ssl.conf` | Chỉ có khi nginx ≥ 1.19.4 (22.04 gốc là 1.18 ⇒ **không** có file; 24.04 ⇒ có) | | |
| 1.3 | `grep disable_symlinks /etc/nginx/conf.d/cecp-*.conf` + `cecp-panel security check` | Có `disable_symlinks if_not_owner`; check PASS "nginx ignores symlinks…" | | |
| 1.4 | `systemctl status php*-fpm` + `cecp-panel site probe --all` | Pool PHP-FPM chạy (tên unit Debian `php8.x-fpm`); probe thoát 0 | | |
| 1.5 | `cecp-panel optimize opcache` rồi `cecp-panel optimize rollback latest` | Reload PHP-FPM thành công cả hai chiều, không lỗi `php-fpm -t` | | |
| 1.6 | `cecp-panel security unattended` | Bật `unattended-upgrades` (không phải dnf-automatic) | | |

## 2. HTTPS catch-all (nginx ≥ 1.19.4: AlmaLinux 9, Ubuntu 24.04)

| # | Lệnh | Kết quả mong đợi | Kết quả |
|---|---|---|---|
| 2.1 | `curl -vk https://IP_VPS/` (từ máy khác) | Bắt tay TLS bị từ chối (không lộ chứng chỉ site nào) | |
| 2.2 | `curl -sI https://DOMAIN/` | HTTP 200/301 với chứng chỉ đúng của DOMAIN | |
| 2.3 | `curl -sI http://IP_VPS/` | Không trả nội dung của site thật | |

## 3. Thông báo thật (Telegram / Zalo Bot / Discord)

Chi tiết: [NOTIFICATIONS.md](NOTIFICATIONS.md). Token nhập qua prompt (có TTY), không qua argv.

| # | Lệnh | Kết quả mong đợi | Telegram | Zalo | Discord |
|---|---|---|---|---|---|
| 3.1 | `cecp-panel notify telegram` / `notify zalo` / `notify discord` | Bot: getMe OK, nhắn bot 1 tin ⇒ tự tìm được chat id; Discord: nhận webhook URL | | | |
| 3.2 | `cecp-panel notify test telegram` (tương tự `zalo`, `discord`) | Log `telegram: OK`; tin thử tới nơi, tiếng Việt + emoji hiển thị đúng | | | |
| 3.3 | `cecp-panel notify events set security,backup --channel zalo --min warning` rồi `notify events` | Bộ lọc riêng kênh được lưu và hiển thị đúng | | | |
| 3.4 | `cecp-panel notify status`; `grep -ri token /var/log/cecp-panel/` | Trạng thái đúng từng kênh; token **không** xuất hiện trong log | | | |
| 3.5 | `cecp-panel notify off zalo` | Kênh tắt; `notify test` không gửi tới Zalo | | | |

Zalo Bot (`https://bot-api.zapps.me/bot<TOKEN>/…`) mới chỉ đối chiếu qua SDK — nếu host, định dạng
`getUpdates` hoặc giới hạn độ dài khác thực tế, ghi FAIL kèm mô tả để sửa `lib/notify.sh`.

## 4. Media: HEIC / TIFF / AVIF

Chi tiết: [MEDIA_OPTIMIZE.md](MEDIA_OPTIMIZE.md).

| # | Lệnh | Kết quả mong đợi | Kết quả |
|---|---|---|---|
| 4.1 | `cecp-panel media enable DOMAIN`; `php -m \| grep -i imagick` | Panel thử cài Imagick (`php-pecl-imagick-im7`/`php-pecl-imagick` hoặc `php-imagick`); `format=webp` | |
| 4.2 | Upload ảnh **HEIC iPhone** qua wp-admin | Thư viện chỉ có 1 file `.webp` ≤ 1920px, không còn file gốc | |
| 4.3 | Upload ảnh **TIFF** | Như 4.2 | |
| 4.4 | `cecp-panel media enable DOMAIN --format avif` (WordPress ≥ 6.5), upload JPG | Ra file `.avif`; `curl -sI -H 'Accept: image/avif' …` trả AVIF | |
| 4.5 | `cecp-panel media status DOMAIN` | Liệt kê đúng cấu hình và số ảnh | |
| 4.6 | `cecp-panel media prune-originals DOMAIN` rồi `… --yes` (thư viện có ảnh `-scaled`) | Lần đầu chỉ báo dung lượng (dry run); `--yes` xoá bản gốc, site vẫn hiển thị ảnh | |

## 5. `security cf-only` với firewalld và ufw

Site phải đã proxied (đám mây cam) qua Cloudflare — xem [CLOUDFLARE_DNS.md](CLOUDFLARE_DNS.md).

| # | Lệnh | Kết quả mong đợi | firewalld (Alma) | ufw (Ubuntu) |
|---|---|---|---|---|
| 5.1 | `cecp-panel security cf-only status` | Liệt kê site chưa proxied (nếu có) | | |
| 5.2 | `cecp-panel security cf-only on` khi còn site chưa proxied | Từ chối, in danh sách site sẽ offline (không dùng `--force` trên lab có site thật) | | |
| 5.3 | `cecp-panel security cf-only on` (mọi site proxied) | `curl https://DOMAIN` qua Cloudflare OK; `curl --resolve DOMAIN:443:IP_VPS https://DOMAIN` từ IP ngoài Cloudflare bị chặn | | |
| 5.4 | Mở phiên SSH **mới** | SSH vẫn vào được | | |
| 5.5 | `cecp-panel cf realip` | Làm mới dải IP Cloudflare + đồng bộ lại ipset/ufw (không lỗi "cf-only firewall refresh failed"); `ls /etc/cron.d/cecp-cf-realip` | | |
| 5.6 | `cecp-panel security cf-only off` | 80/443 mở lại cho mọi IP như trước | | |

## 6. Backup retention / prune

Cần repo restic đã có nhiều snapshot cũ (vài ngày/tuần).

| # | Lệnh | Kết quả mong đợi | Kết quả |
|---|---|---|---|
| 6.1 | `cecp-panel backup policy`; `cecp-panel backup list` | Chính sách daily=7/weekly=6/monthly=12 (hoặc đã cấu hình); thấy snapshot cũ | |
| 6.2 | `cecp-panel backup run --all` (trước khi xác nhận prune) | Retention tự động chỉ chạy thử + cảnh báo "run once: cecp-panel backup prune" (kèm thông báo) | |
| 6.3 | `cecp-panel backup prune-dry-run` | Danh sách snapshot sẽ xoá hợp lý theo chính sách | |
| 6.4 | `cecp-panel backup prune` | Xoá đúng như 6.3; snapshot tag `scan-clean` / `scan-suspect` được giữ | |
| 6.5 | `cecp-panel backup verify --all` | Không lỗi | |

## 7. Quét định kỳ + tự khôi phục

Chi tiết: [INCIDENT_RESPONSE.md](INCIDENT_RESPONSE.md). Mục này **cố ý** cài file giả nhiễm — chỉ trên lab.

| # | Lệnh | Kết quả mong đợi | Kết quả |
|---|---|---|---|
| 7.1 | `cecp-panel backup run DOMAIN` rồi `cecp-panel security scan-cron --force` (site sạch) | Kết quả "clean"; bản backup mới nhất được tag `scan-clean` | |
| 7.2 | `cecp-panel security scan-schedule on --every 14 --auto-restore`; `… scan-schedule status` | Giờ quét được chọn theo giờ ít truy cập trong log nginx; trạng thái hiện auto-restore | |
| 7.3 | Tạo `wp-content/uploads/x.php` (bằng user của site), rồi `cecp-panel security scan-cron --force` | Phát hiện web shell; có backup hiện trường; retention bị đóng băng; site được khôi phục từ bản `scan-clean`; cảnh báo tới Telegram/Zalo | |
| 7.4 | `cecp-panel backup run DOMAIN` khi đang đóng băng | Log "retention paused — security scan found indicators" | |
| 7.5 | `cecp-panel security scan --all`; `cecp-panel security scan-ack` | Quét lại sạch; `scan-ack` gỡ đóng băng retention | |
| 7.6 | `cecp-panel security restore-clean DOMAIN --dry-run` | In kế hoạch khôi phục, không thay đổi gì | |

## 8. Nâng cấp từ bản cũ

Cài baseline cũ trên VPS lab có site WordPress, rồi nâng cấp lên commit cần thử bằng `deploy-safe.sh`
từ máy agency (`SSH_KEY=~/.ssh/KEY ./deploy-safe.sh root@IP_VPS --with-check`). Sau đó làm **đúng**
các mục "Nâng cấp từ …" trong [CHANGELOG.md](../CHANGELOG.md) từ bản cũ tới bản mới.

| # | Baseline | Bước | Kết quả mong đợi | Kết quả |
|---|---|---|---|---|
| 8.1 | 1.11.x | `deploy-safe.sh … --with-check` + runbook "Nâng cấp từ 1.11", "1.12.0-beta", "1.12", "1.12.1" | Site vẫn 200; `site probe --all` thoát 0; `security check` 0 FAIL | |
| 8.2 | 1.12.1-beta | `cecp-panel update panel latest` (hoặc deploy-safe) + runbook "Nâng cấp từ 1.12.1" trở đi | Như 8.1; `/etc/cecp-panel/panel.json` ghi số phiên bản thật (không phải `latest`) | |
| 8.3 | VPS còn mirror cũ trong `panel.env` | `cecp-panel update check` rồi `cecp-panel update mirror https://raw.githubusercontent.com/theanhlive/cecp-panel/main` | Nguồn cập nhật là GitHub raw `main` | |

## 9. Menu và Tab completion

| # | Lệnh | Kết quả mong đợi | Kết quả |
|---|---|---|---|
| 9.1 | `cecp-panel` (không tham số) → vào vài mục cần domain, nhập domain sai | Báo lỗi và quay lại menu, không thoát ra shell | |
| 9.2 | Phiên SSH **mới**: `cecp-panel ssl issue <Tab>` | Gợi ý danh sách domain (`/etc/bash_completion.d/cecp-panel`) | |
| 9.3 | `cecp-panel security <Tab><Tab>`; `cecp-panel site add x.com --<Tab>` | Gợi ý lệnh con và cờ | |

## Kết luận

| Nhóm | PASS | FAIL | SKIP |
|---|---|---|---|
| 0–9 | | | |

Có FAIL ⇒ mở issue/sửa trên nhánh, chạy lại mục đó và `tests/integration/run.sh` trước khi gắn RC.
Dán bảng này (không kèm bí mật) vào PR phát hành.
