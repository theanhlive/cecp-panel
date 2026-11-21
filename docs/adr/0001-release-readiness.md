# ADR-0001: Kiến trúc kiểm thử & phát hành cho bản chính thức 2.0.0

**Trạng thái:** Đề xuất · **Ngày:** 2026-11-21 · **Người duyệt:** chủ repo

## Bối cảnh
- CECP Panel 1.13.1-beta: ~12.900 dòng bash + vài file Python, chạy bằng root trên VPS của khách.
- Kiểm thử hiện có: `tests/lint.sh` (bash -n, shellcheck), 2 test đơn vị nhỏ, test tích hợp Docker
  **chỉ AlmaLinux 9** (400 `check`). **Không có CI** — mọi kiểm tra chạy tay.
- Chưa kiểm chứng: Ubuntu 22.04/24.04, nâng cấp từ bản cũ, Zalo Bot thật, HEIC/AVIF, `cf-only` + ufw.
- Bảo mật phân phối: `update panel` tải `SHA256SUMS` **cùng nguồn** với tarball ⇒ chỉ chống hỏng
  file, không chống nguồn bị chiếm (tài khoản GitHub, token). Cài bằng `curl | bash`.
- Chỉ có một kênh (`main` = beta). Khách không có lựa chọn "ổn định".

## Quyết định
1. **Giữ bash** (không viết lại Rust/Go). Rủi ro nằm ở tương tác hệ thống, không ở ngôn ngữ.
2. **Kim tự tháp kiểm thử 4 tầng**, chạy trên GitHub Actions:
   | Tầng | Công cụ | Khi chạy |
   |---|---|---|
   | T0 tĩnh | `tests/lint.sh` | mọi push |
   | T1 đơn vị | `bats` cho hàm thuần (`validate_*`, `secure_source`, tính `pm.max_children`, phân loại probe) | mọi push |
   | T2 tích hợp | Docker systemd, ma trận OS: alma9, ubuntu22.04, ubuntu24.04 | PR vào `main`, trước tag |
   | T3 nâng cấp | cài baseline cũ → `update` lên checkout → scenario rút gọn | PR vào `main`, trước tag |
   | T4 lab | checklist thủ công trên VPS lab (`docs/LAB_CHECKLIST.md`) | trước RC |
3. **Hai kênh phát hành**: `stable` và `beta`, chọn bằng `cecp-panel update channel stable|beta`;
   tarball/SUMS theo kênh trong `dist/`. Mặc định cài mới = `stable` từ 2.0.0.
4. **Ký bản phát hành bằng minisign** (ed25519, khoá công khai nhúng trong panel). `update` từ chối
   `SHA256SUMS` không có chữ ký hợp lệ; khoá bí mật giữ ngoại tuyến, ký thủ công lúc phát hành.
5. **Semver + RC**: `2.0.0-rc.N` chạy canary ≥ 7 ngày trước `2.0.0`. Giữ bản trước để rollback.

## Phương án đã cân nhắc
| | A. Giữ nguyên (chạy tay) | B. CI + ma trận + ký (chọn) | C. Viết lại Rust |
|---|---|---|---|
| Độ phức tạp | Thấp | Trung bình | Rất cao |
| Chi phí | 0 | GitHub Actions free (repo public) / vài giờ CI/tháng | Hàng tháng công |
| Giảm rủi ro thật | Không | Cao (đa OS, nâng cấp, chuỗi cung ứng) | Thấp với loại lỗi hiện tại |
| Quen thuộc | Cao | Cao | Thấp |

Chữ ký: **minisign** thay cosign/GPG — 1 binary nhỏ, không cần OIDC/hạ tầng, dễ xác minh trong bash.
Đánh đổi: ký thủ công (không tự động trong CI) — chấp nhận để khoá không nằm trên GitHub.

## Hệ quả
- Dễ hơn: phát hiện lỗi Ubuntu/nâng cấp trước khi tới khách; khách chọn được kênh ổn định.
- Khó hơn: CI tích hợp chậm (~20–30 phút/OS); phải quản lý khoá ký; thêm `minisign` vào phụ thuộc.
- Xem lại: nếu GitHub runner không chạy được systemd-in-Docker ổn định ⇒ chuyển T2 sang self-hosted
  runner trên 1 VPS lab.

## Việc cần làm
Xem [docs/PLAN_2.0.md](../PLAN_2.0.md).
