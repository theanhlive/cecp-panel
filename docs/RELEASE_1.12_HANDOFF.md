# Bàn giao 1.12.0-beta — kiểm tra đầy đủ rồi đưa vào `main`

## Trạng thái (cập nhật 2026-10-07): ĐÃ PHÁT HÀNH

- **Phân phối 1.12.1-beta:** cài/cập nhật panel chỉ từ GitHub `theanhlive/cecp-panel` (`raw.githubusercontent.com/.../main`); `dist/` trong repo thay mirror isharevn.net.
- Test Docker: **339 passed, 0 failed** (sau khi sửa lỗi ACL docroot khiến mọi trang WordPress trả 404 và một test sai — xem CHANGELOG 1.12.0-beta). Lint sạch.
- Đã merge `claude/epic-fermat-85l79i` vào `main`, build `dist/` và upload mirror (`SHA256SUMS` có `1.12.0-beta`).
- Đã nâng cấp 3 VPS lên 1.12.0-beta (1 VPS canary trước, rồi 2 VPS còn lại): `apply-production`, `site rebuild-vhost --all`, `security harden-docroot --all`. Mọi site trả 200, `security check` 0 FAIL.
- **Còn lại:** (1) 2 cảnh báo `security check`: `PasswordAuthentication yes` (`security ssh-key-only`) và OPcache chưa cô lập (`security php-isolation`); (2) các tuỳ chọn chủ VPS quyết định: `notify setup`, `security scan-schedule on`, `backup prune-dry-run` rồi `backup prune`, `media enable`, `security cf-only`; (3) mục 4 (thử trên VPS lab: Ubuntu 22.04, thông báo Telegram/Zalo thật, HEIC/AVIF, cf-only, nâng cấp từ 1.11) chưa chạy; (4) scan sau nâng cấp vẫn báo "indicators found" (plugin stub, file thừa WP, checksum lệch) — đã được chủ VPS chấp nhận là không phải mã độc; một tài khoản admin WordPress tạo 2026-09-14 trên một VPS nên được chủ VPS xác nhận.
- Lưu ý quy trình: 2 VPS sau được nâng cấp trước khi quét bảo mật (quét chạy sau). Lần sau quét **trước**, dừng nếu có dấu hiệu lạ.
- Tag Git `v1.12.0-beta` (annotated, commit merge `b469ce6`) đã tạo và đẩy lên GitHub.

---

## Lưu trữ — hướng dẫn bàn giao gốc (lịch sử, phát hành hoàn tất 2026-10-07)

Phần dưới giữ nguyên nội dung hướng dẫn trước khi merge/phát hành; **không** còn là checklist
đang làm — chỉ tham chiếu. Mục **« 6. Cập nhật các VPS đang dùng »** vẫn là runbook nâng cấp chung.

**Dành cho Claude Code (hoặc người) chạy trên máy local có Docker.** Mọi thay đổi 1.12 đang ở nhánh
`claude/epic-fermat-85l79i`, chưa vào `main`. Chúng đã được lint và thử từng phần trong môi trường
cloud (không có Docker), **nhưng bộ test tích hợp đầy đủ chưa từng chạy**. Nhiệm vụ: tải về, chạy
toàn bộ kiểm tra, sửa lỗi phát sinh, rồi merge vào `main`. Làm theo thứ tự; dừng lại ở các bước
**[HỎI NGƯỜI]**.

Đọc trước: [AGENTS.md](../AGENTS.md) (quy ước code, quy tắc vận hành) và mục `1.12.0-beta` trong
[CHANGELOG.md](../CHANGELOG.md) (mô tả đầy đủ mọi thay đổi).

---

## 0. Quy tắc

- **Không bao giờ** bỏ qua, tắt hay xoá một test (`check`) để cho qua. Test đỏ ⇒ tìm nguyên nhân
  gốc, sửa code (hoặc sửa test nếu chính test viết sai — ghi rõ lý do trong commit).
- Không force-push, không rebase nhánh đã push; sửa bằng commit mới trên cùng nhánh.
- `bash tests/lint.sh` phải sạch trước **mỗi** commit.
- **Không** đụng vào VPS thật (đặc biệt VPS đang bị hack) ở bất kỳ bước nào của tài liệu này.
- Mọi thay đổi hành vi thêm vào `CHANGELOG.md` (tiếng Việt), mục `1.12.0-beta`.

## 1. Tải về

```bash
git clone <repo> cecp-panel && cd cecp-panel        # thư mục PHẢI tên cecp-panel (build-release.sh kiểm tra)
git fetch origin
git switch claude/epic-fermat-85l79i
git log --oneline origin/main..HEAD                 # 7+ commit, xem bảng mục 6
```

## 2. Kiểm tra tĩnh

```bash
bash tests/lint.sh                                   # bash -n + shellcheck + check_truncation (cần shellcheck hoặc Docker)
for f in templates/mu-plugins/*.php; do php -l "$f"; done
grep -h 'CECP_PANEL_VERSION:-\|^VERSION=' cecp-panel lib/common.sh install.sh install-cecp-panel.sh remote-code-only-install.sh
#   ⇒ cả 5 chỗ đều là 1.12.0-beta
```

## 3. Test tích hợp (bắt buộc — chưa từng chạy)

```bash
bash tests/integration/run.sh 2>&1 | tee /tmp/it.log        # AlmaLinux 9 + systemd trong Docker, ~15-30 phút
KEEP=1 bash tests/integration/run.sh                          # giữ container để gỡ lỗi: docker exec -it cecp-panel-it bash
```

Kết quả cuối: `RESULT: N passed, 0 failed`. Các nhóm test **mới/đổi ở 1.12**, dễ lỗi nhất — kiểm tra kỹ:

| Nhóm trong `scenario.sh` | Rủi ro cần để ý |
|---|---|
| `=== WordPress system cron ===` | wp-cron giờ gọi `curl http://DOMAIN/wp-cron.php` qua loopback (không còn `wp cron event run`), test đổi `\%`→`%` như cron; cần HTTP 200 trong log. `wp-cron.php` từ IP không phải loopback phải 403 |
| cache auto-purge `mu-plugin written as the site user` | mu-plugin giờ thuộc **user của site** (không còn root) |
| `=== On-upload: any format in, one right-sized WebP out ===` | `media enable` mặc định `--format webp`; import JPG 3000px / BMP ⇒ chỉ còn `.webp` ≤1920px, không có file gốc/`-scaled`. Cần `php-gd` có WebP trên Alma 9 |
| `staging guard mu-plugin (written as the staging user)` | tương tự, thuộc user staging |
| `=== Isolation … ===` | đọc/ghi chéo bị chặn, nginx `disable_symlinks`, panel không chown/ghi qua symlink (`/root/decoy`), `crontab` bị cấm (`/etc/cron.deny`), `security php-isolation`, `security scan` bắt web shell, `rotate-secrets` |
| `=== Periodic security scan ===` | `scan-schedule on`, `scan-cron --force`, retention bị đóng băng khi nhiễm, `scan-ack` |
| notify `events` / `telegram` không có terminal | bộ lọc theo kênh; token chỉ nhận qua biến môi trường khi không có TTY |
| `pm.max_children sized (2..32)` | công thức RAM mới |
| `putenv disabled by default`, `allow_putenv=on` | `disable_functions` có `putenv` |
| SSL wildcard / remove | `ssl issue` giờ đổi `home/siteurl` WordPress sang https và `ssl remove` đổi lại http — các test staging sau đó mong `http://$D` |

## 4. Kiểm tra thêm ngoài `scenario.sh` (không có trong Docker test)

Làm trên **một VPS lab** (không có site thật) cài từ nhánh này (`bash install.sh` từ checkout, rồi
`security apply-production`, `optimize stack`, `site add lab.example.com --wp`). Ghi kết quả vào PR.

1. **Ubuntu 22.04** (nginx 1.18): `site rebuild-vhost --all` ⇒ `nginx -t` OK; file
   `00-cecp-default-ssl.conf` **không** được tạo (cần nginx ≥ 1.19.4); `disable_symlinks` chạy được.
2. **HTTPS catch-all** (AlmaLinux 9): `curl -vk https://IP_VPS/` ⇒ bị từ chối bắt tay TLS; site thật vẫn HTTPS bình thường.
3. **Thông báo thật**: `notify setup` với bot Telegram thật và **Zalo Bot thật** (bot.zapps.vn,
   API `https://bot-api.zapps.me/bot<TOKEN>/…` — chỉ được xác minh qua SDK python-zalo-bot, chưa gọi
   thật). Kiểm tra: getMe, tự tìm chat id sau khi nhắn bot, tin thử tới nơi, tiếng Việt/emoji hiển thị đúng.
   Nếu Zalo khác tài liệu (host, định dạng `getUpdates`, giới hạn độ dài) ⇒ sửa `lib/notify.sh`.
4. **Media**: có PHP Imagick (`media enable` thử cài `php-pecl-imagick(-im7)`/`php-imagick`) ⇒ upload
   ảnh **HEIC iPhone** và **TIFF** ⇒ thành WebP; WordPress ≥ 6.5 ⇒ `--format avif` ra AVIF. `media status DOMAIN` liệt kê đúng.
   `media prune-originals DOMAIN` (dry run rồi `--yes`) trên thư viện có ảnh `-scaled`.
5. **`security cf-only on`** với firewalld **và** ufw: 80/443 chỉ nhận IP Cloudflare, SSH còn vào được,
   `cf-only off` trả lại như cũ; `cf realip` (cron tuần) đồng bộ lại ipset.
6. **Backup retention (sửa lỗi nghiêm trọng)**: trên repo restic đã có nhiều snapshot cũ:
   backup tự động ⇒ chỉ chạy thử + cảnh báo; `backup prune-dry-run` hợp lý; `backup prune` ⇒ xoá đúng
   theo chính sách, giữ các snapshot tag `scan-clean`/`scan-suspect`.
7. **Quét định kỳ**: `security scan-schedule on --auto-restore` ⇒ giờ được chọn hợp lý so với log nginx;
   cài một file `uploads/x.php` ⇒ `security scan-cron --force` ⇒ backup hiện trường, retention đóng
   băng, site được `restore-clean` từ bản `scan-clean`, cảnh báo tới Telegram/Zalo; `scan-ack`.
8. **Nâng cấp từ 1.11**: trên VPS lab đang chạy 1.11 có site WordPress, cài bản này qua
   `deploy-safe.sh` rồi làm đúng mục "Nâng cấp từ 1.11" trong CHANGELOG ⇒ site vẫn chạy, `security check` không FAIL.
9. **Menu** `cecp-panel`: nhập sai domain trong vài mục ⇒ báo lỗi và quay lại menu (không thoát ra shell).
   Phím Tab: `cecp-panel ssl issue <Tab>` gợi ý domain (phiên SSH mới).

## 5. Đưa vào `main`

Khi mục 2–3 xanh và mục 4 đã ghi kết quả (mục nào không làm được thì ghi rõ lý do):

1. Tạo **Pull Request** `claude/epic-fermat-85l79i` → `main`. Nội dung: tóm tắt từ CHANGELOG 1.12,
   kết quả `RESULT: … passed, 0 failed`, bảng kết quả mục 4, các lỗi đã sửa trong quá trình kiểm tra.
2. **[HỎI NGƯỜI]** chủ repo xem PR và đồng ý merge. Merge bằng merge commit (giữ lịch sử từng bước).
3. Sau merge, trên `main`:
   ```bash
   git switch main && git pull
   ./build-release.sh            # lint gate + dist/cecp-panel-1.12.0-beta.tar.gz + dist/cecp-panel-latest.tar.gz + dist/SHA256SUMS
   ```
4. **[HỎI NGƯỜI]** upload `dist/` (cả `SHA256SUMS`) lên mirror `https://isharevn.net/downloads/cecp-panel/dist/`.
   Kiểm tra: `curl -fsSL …/dist/SHA256SUMS | grep 1.12.0-beta`.

## 6. Cập nhật các VPS đang dùng (sau khi mirror có bản mới)

**[HỎI NGƯỜI]** trước từng VPS. Làm VPS ít quan trọng trước.

```bash
cecp-panel update panel latest     # BẮT BUỘC có "latest" (không có sẽ tải lại đúng bản đang chạy)
# hoặc từ máy agency: SSH_KEY=~/.ssh/KEY ./deploy-safe.sh root@IP --with-check
```
Rồi làm mục **"Nâng cấp từ 1.11"** trong CHANGELOG (apply-production, `site rebuild-vhost --all`,
`security check`, `notify setup`, `security scan-schedule on`…).

⚠ **VPS đang/nghi bị hack**: làm theo [docs/INCIDENT_RESPONSE.md](INCIDENT_RESPONSE.md), chạy
`security scan --all` và báo kết quả cho chủ VPS **trước** mọi thao tác khác; **không** chạy
`backup prune` cho tới khi đã khôi phục được bản sạch.

## Các commit trên nhánh (tham chiếu)

| Commit | Nội dung |
|---|---|
| `087c056` | Rà soát 1.12: media chạy bằng user site, chặn file backup qua web, HTTPS catch-all, FORCE_SSL_ADMIN, backup tar không nén (dedupe), cache/cron/ảnh, menu không thoát, Tab completion |
| `be5190d` | `security cf-only`, ngân sách RAM PHP, chặn `putenv`, restore/verify import bằng user DB không phải root |
| `fbbf525` | Runbook Cloudflare DNS, sửa tìm zone Cloudflare (`dns point`) |
| `4ccd6cc` | Upload mọi định dạng → một file WebP, không giữ gốc; `media prune-originals` |
| `10bfcc5` | Cách ly giữa các site (root không ghi trong docroot, disable_symlinks, wp-cron qua PHP-FPM, cấm crontab, OPcache), `security scan`, `rotate-secrets`, INCIDENT_RESPONSE |
| `54a95e5` | Quét định kỳ giờ rảnh, giữ backup sạch, **sửa retention không bao giờ xoá snapshot** |
| `3a9bd67` | Thông báo Telegram / Zalo Bot / Discord + chọn loại; `security restore-clean`, `--auto-restore` |
