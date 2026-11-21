# Kế hoạch triển khai 2.0.0 (theo ADR-0001)

Các luồng song song được tách theo **file không chồng nhau** để merge không xung đột.
Mỗi luồng = 1 nhánh `claude/2.0-<luồng>` → PR vào `main`. Không luồng nào bump phiên bản
(việc bump làm 1 lần ở bước phát hành).

| Luồng | Phạm vi file | Tiêu chí xong | Phụ thuộc |
|---|---|---|---|
| **W1 CI** | `.github/workflows/ci.yml` | lint + bats chạy mọi push; job tích hợp gọi `tests/integration/run.sh` (đọc `OS=` nếu có) khi PR vào `main` | — (W2/W3 chỉ cần thêm OS vào matrix) |
| **W2 Ubuntu IT** | `tests/integration/Dockerfile.ubuntu*`, `run.sh` (tham số `OS`), sửa `lib/*` nếu lộ lỗi Ubuntu | `OS=ubuntu22.04` và `ubuntu24.04` chạy hết scenario; check theo OS được gắn điều kiện rõ ràng | — |
| **W3 Upgrade test** | `tests/upgrade/` (mới), `tests/baseline/` | cài baseline (1.12.1 lấy từ tag) → nâng cấp lên checkout → site 200, `security check` 0 FAIL | — |
| **W4 Unit bats** | `tests/unit/` (mới) | ≥ 40 test cho hàm thuần trong `lib/common.sh`, `lib/probe.sh`, `lib/optimize.sh`; `bash tests/unit/run.sh` | — |
| **W5 Kênh + ký** | `lib/update.sh`, `build-release.sh`, `install-cecp-panel.sh`, `docs/RELEASING.md` | `update channel`, xác minh minisign (bắt buộc khi có khoá), test trong scenario; CHANGELOG mục "Chưa phát hành" | — |
| **W6 Tài liệu + lab** | `docs/LAB_CHECKLIST.md`, `docs/archive/RELEASE_1.12_HANDOFF.md` (lưu trữ), `README.md`, `CUSTOMER_INSTALL.md` | checklist T4 đủ mục; bỏ nhắc mirror isharevn đã ngừng | — |

## Thứ tự merge đề xuất
W6 → W4 → W1 → W2 → W3 → W5 (W5 sửa code sản phẩm, merge cuối sau khi CI đã có).

## Sau khi merge (người + agent)
1. Chạy T4 trên VPS lab theo [docs/LAB_CHECKLIST.md](LAB_CHECKLIST.md), ghi kết quả.
2. Tạo khoá minisign ngoại tuyến **[CHỦ REPO]**, nhúng khoá công khai.
3. `2.0.0-rc.1` → canary 1 VPS ≥ 7 ngày (quét `security scan --all` TRƯỚC khi nâng cấp).
4. `2.0.0` → kênh `stable`; các VPS còn lại nâng cấp lần lượt.

## Việc vận hành không chờ phát hành
- Xác nhận tài khoản admin WordPress tạo 2026-09-14 trên một VPS **[CHỦ VPS]**.
- `security ssh-key-only`, `security php-isolation` trên các VPS còn cảnh báo.
