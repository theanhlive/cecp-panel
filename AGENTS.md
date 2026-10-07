# Hướng dẫn cho AI Agent — CECP Panel

CECP Panel là bộ script bash (+ Python nhỏ) cài và quản lý VPS web (nginx, PHP-FPM, MariaDB,
Redis, WordPress, Let's Encrypt, backup restic → Google Drive). CLI: `cecp-panel`, chạy bằng root.

> **1.12.0-beta đã phát hành** (merge vào `main`, mirror, 3 VPS đã nâng cấp). Việc còn lại và lưu ý:
> [docs/RELEASE_1.12_HANDOFF.md](docs/RELEASE_1.12_HANDOFF.md).

## Triển khai trên VPS (vận hành)

| Việc | Tài liệu bắt buộc đọc trước |
|---|---|
| **Website bị hack** / nghi nhiễm mã độc (quét, làm sạch, đổi mật khẩu, ngăn tái nhiễm) | [docs/INCIDENT_RESPONSE.md](docs/INCIDENT_RESPONSE.md) |
| Trỏ domain qua **Cloudflare** (DNS, proxy, SSL mode, khoá IP gốc) | [docs/CLOUDFLARE_DNS.md](docs/CLOUDFLARE_DNS.md) |
| Cài panel cho khách | [CUSTOMER_INSTALL.md](CUSTOMER_INSTALL.md) |
| Nâng cấp panel trên VPS đang chạy | mục "Nâng cấp từ …" của phiên bản mới nhất trong [CHANGELOG.md](CHANGELOG.md) |
| Tối ưu ảnh theo site | [docs/MEDIA_OPTIMIZE.md](docs/MEDIA_OPTIMIZE.md) |
| Thông báo Telegram / Zalo / Discord, chọn loại thông báo | [docs/NOTIFICATIONS.md](docs/NOTIFICATIONS.md) |
| Webhook n8n (JSON ký HMAC) | [docs/WEBHOOK_N8N.md](docs/WEBHOOK_N8N.md) |

Quy tắc vận hành:
- Không in/log/commit bí mật (Cloudflare token, mật khẩu DB/WordPress/SFTP, restic password).
  Panel đã chỉ hiện mật khẩu ra terminal, không ghi `panel.log` — giữ nguyên như vậy.
- Sự cố bảo mật: chạy `cecp-panel security scan --all` và báo kết quả trước khi sửa/xoá bất cứ gì.
- Lệnh phá huỷ (`site remove`, `backup restore --live`, `db import`, `site staging-push`,
  `security cf-only on --force`, `dns ssl-mode` trên zone có subdomain khác) cần chủ VPS đồng ý.
- Sau mỗi thay đổi: `cecp-panel security check` và `cecp-panel status` để xác nhận.

## Sửa code (phát triển)

- Kiểm tra nhanh (bắt buộc trước khi commit): `bash tests/lint.sh` (bash -n + shellcheck + check_truncation).
- Test tích hợp (cần Docker, AlmaLinux 9 + systemd): `bash tests/integration/run.sh`; kịch bản trong
  `tests/integration/scenario.sh` — thêm `check` cho hành vi mới.
- Phiên bản nằm ở 5 chỗ, phải giống nhau (build-release.sh kiểm tra): `cecp-panel`, `lib/common.sh`,
  `install.sh`, `install-cecp-panel.sh`, `remote-code-only-install.sh`.
- Mỗi thay đổi hành vi ghi vào `CHANGELOG.md` (tiếng Việt), kèm mục "Nâng cấp từ …" nếu VPS cũ
  cần chạy lệnh để áp dụng.
- Quy ước code: `set -euo pipefail`; mọi input (domain, URL, số) qua `validate_*` trong
  `lib/common.sh`; file env chỉ nạp bằng `secure_source`; bí mật không nằm trong argv (dùng
  `curl -K <(...)`, `mysql --defaults-extra-file`, stdin); root không ghi vào thư mục của site
  (dùng `runuser -u SITE_USER`); nginx đổi cấu hình qua `nginx_test_and_reload` (tự rollback).
- Template nginx/PHP ở `templates/`; vhost được render lại bằng `cecp-panel site rebuild-vhost --all`.
