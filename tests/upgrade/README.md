# Test nâng cấp (T3)

```bash
bash tests/upgrade/run.sh                    # FROM=1.12.1-beta (mặc định)
FROM=1.13.0-beta bash tests/upgrade/run.sh   # baseline khác
KEEP=1 bash tests/upgrade/run.sh             # giữ container cecp-panel-up để debug
```

Cần Docker + mạng (AlmaLinux/EPEL mirror, wordpress.org, raw.githubusercontent.com). Dùng lại image
`cecp-panel-it:alma9` của `tests/integration` (`SKIP_BUILD=1` = không build lại). Mã thoát = số check FAIL.

Các bước:
1. **Baseline** — bundle phát hành của `FROM`, ưu tiên theo thứ tự: `tests/baseline/cecp-panel-$FROM.tar.gz`
   (đối chiếu `tests/baseline/SHA256SUMS`) → `dist/cecp-panel-$FROM.tar.gz` ở tag `v$FROM` (đối chiếu
   `SHA256SUMS` của tag) → `git archive v$FROM`. Chạy `install.sh` của baseline, `security apply-production`,
   `site add upgrade.test --wp`, seed 1 bài viết + 1 option + 1 file upload ngẫu nhiên, chụp snapshot.
2. **Nâng cấp** — bundle khách từ checkout (không có `tests/`) đặt trên mirror `file://` có `SHA256SUMS`;
   `update mirror` trỏ vào đó thay cho GitHub raw, rồi chạy đúng các lệnh của mục "Nâng cấp từ …" trong
   `CHANGELOG.md` (bảng `upgrade_steps` trong `scenario.sh`; `FROM` chưa có trong bảng ⇒ FAIL).
3. **Sau nâng cấp** — CLI/`lib/common.sh` là phiên bản checkout, bản panel cũ được giữ làm backup;
   trang chủ, `/wp-login.php`, trang không cache trả 200; `site probe --all` thoát 0;
   `security check` 0 FAIL; `status` và `status --json` (nginx/mariadb/PHP-FPM active); `nginx -t`;
   file site (sha256), quyền/owner, bài viết, option, user, meta site, file env của panel không đổi; `wp db check`.

Thêm baseline mới: khi phát hành bản X, thêm nhánh `X)` vào `upgrade_steps` theo mục "Nâng cấp từ X" của
bản kế tiếp. Không cần chép tarball: tag `vX` đã có `dist/`.

Ghi chú: `update panel` chạy bằng code CŨ, nên từ baseline < 1.13.1 `panel.json` ghi `"version": "latest"`
(CHANGELOG 1.13.1: tự sửa ở lần cập nhật sau) — test chấp nhận và in `INFO`.
