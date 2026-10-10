# Profile tuning theo domain

Thư mục này chứa **hồ sơ vận hành** (markdown) cho từng domain agency quản lý trên VPS CECP. Hồ sơ giúp AI Agent và người vận hành biết loại site, baseline, thay đổi đã được duyệt và kết quả loadtest gần nhất — **không** thay thế runbook kỹ thuật [SITE_TUNING.md](../SITE_TUNING.md).

## Cách dùng

1. Sao chép [`_TEMPLATE.md`](_TEMPLATE.md) thành `<domain>.md` (vd. `shop.khachhang.vn.md`) trên máy làm việc của agency.
2. Điền stack thật (PHP version, Redis, Cloudflare zone) từ `cecp-panel status` / audit — **không** dán mật khẩu, token, hay connection string DB.
3. Mỗi lần tune: cập nhật *Approved changes*, *Current values*, *Rollback ID*, *Last loadtest result*.
4. Agent đọc profile **trước** vòng `optimize audit` trong SITE_TUNING.md.

## Git

- Trong repo chỉ commit `README.md` và `_TEMPLATE.md`.
- File `*.md` theo domain thật nằm trong `.gitignore` (tránh lộ tên khách hàng / cấu hình nội bộ).

## Quy tắc nội dung

| Được ghi | Không được ghi |
|---|---|
| Domain, loại site, PHP 8.x, có/không Redis | Mật khẩu WP/DB/SFTP, `CF_API_TOKEN`, private key |
| Zone Cloudflare, SSL mode (Full strict) | Giá trị token, webhook secret |
| Số `pm.max_children`, TTL cache, snapshot rollback id | Dump SQL, backup path có credential |

Nếu cần lưu số nhạy cảm, dùng kho riêng của agency (password manager), không profile markdown.
