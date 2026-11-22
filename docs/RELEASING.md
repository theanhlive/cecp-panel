# Quy trình phát hành (kênh stable/beta + chữ ký minisign)

Áp dụng từ luồng W5 ([ADR-0001](adr/0001-release-readiness.md)). GitHub raw `main` vẫn là nguồn
duy nhất; bản phát hành nằm trong `dist/` của repo.

## Bố cục `dist/`

```
dist/
  stable/  cecp-panel-X.Y.Z.tar.gz  cecp-panel-latest.tar.gz  SHA256SUMS  SHA256SUMS.minisig
  beta/    cecp-panel-X.Y.Z-beta.N.tar.gz  cecp-panel-latest.tar.gz  SHA256SUMS  SHA256SUMS.minisig
  cecp-panel-*.tar.gz  SHA256SUMS  SHA256SUMS.minisig      # "legacy" = bản sao của beta
```

- `cecp-panel update panel latest` đọc `dist/<kênh>/` (kênh trong `/etc/cecp-panel/panel.env`,
  biến `CECP_PANEL_CHANNEL`; đặt bằng `cecp-panel update channel stable|beta`). Chưa đặt kênh ⇒
  `beta` (mọi bản trước 2.0.0 đều là beta).
- Mirror chưa có `dist/<kênh>/SHA256SUMS` ⇒ panel dùng `dist/` cũ và in cảnh báo.
- Panel ≤ 1.13.x chỉ biết `dist/` ⇒ `build-release.sh --channel beta` luôn chép kênh beta ra
  `dist/`. **Không xoá `dist/` gốc** cho tới khi mọi VPS đã lên bản có kênh.
- Kênh `stable` không nhận phiên bản có hậu tố (`-beta`, `-rc.1`): script từ chối.

## Khoá ký (làm MỘT lần — chủ repo)

Khoá bí mật **không bao giờ** nằm trong repo, CI, VPS hay máy có token GitHub tự động.

1. Trên máy ngoại tuyến (hoặc máy cá nhân, ổ mã hoá): `minisign -G -p cecp-release.pub -s cecp-release.key`
   (đặt mật khẩu; **không** dùng `-W`). Sao lưu `cecp-release.key` + mật khẩu ở 2 nơi ngoại tuyến.
2. Chép **chỉ** `cecp-release.pub` đè lên `keys/cecp-release.pub` trong repo, commit.
   `.gitignore` đã chặn `keys/*.key`; `build-release.sh` từ chối tarball có file `.key`.
3. Kể từ bản đầu tiên chứa khoá thật, panel cài bản đó **bắt buộc** chữ ký cho mọi lần
   `update panel` sau: thiếu `SHA256SUMS.minisig` hoặc chữ ký sai ⇒ từ chối cập nhật.
   Vì vậy chính bản mang khoá thật cũng phải được ký (để các bản sau còn xác minh được).

Xác minh dùng khoá của **panel đang cài** (không phải khoá trong bundle tải về), nên mirror bị
chiếm không thay được khoá. Đổi khoá = phát hành một bản chứa khoá mới, ký bằng khoá **cũ**.

Mất khoá bí mật: không còn cách ký hợp lệ ⇒ trên từng VPS phải cập nhật bằng
`cecp-panel update panel X.Y.Z --sha256 <hash>` (hash lấy qua kênh tin cậy khác GitHub), với bundle
chứa khoá mới. `--sha256` bỏ qua chữ ký có chủ đích: người chạy lệnh tự bảo đảm hash.

## Các bước phát hành

1. `bash tests/lint.sh` sạch; `bash tests/integration/run.sh` → 0 failed.
2. Bump phiên bản ở 5 chỗ (`cecp-panel`, `lib/common.sh`, `install.sh`, `install-cecp-panel.sh`,
   `remote-code-only-install.sh`) + `CHANGELOG.md` (đổi "Chưa phát hành" thành số phiên bản).
3. Build:
   - beta / RC: `./build-release.sh` (tự chọn `beta` khi phiên bản có hậu tố) — cập nhật
     `dist/beta/` **và** `dist/`.
   - stable: `./build-release.sh --channel stable` — chỉ cập nhật `dist/stable/`. Kênh beta
     không tự nhận bản stable; nếu beta đang cũ hơn, phát hành sớm một beta mới hơn.
   Script xoá `SHA256SUMS.minisig` cũ của thư mục vừa build — quên ký thì panel có khoá sẽ từ chối
   (lỗi lộ ra ngay, không lặng lẽ cho qua).
4. **Ký thủ công** trên máy giữ khoá (script in sẵn lệnh đúng):
   ```
   minisign -Sm dist/<kênh>/SHA256SUMS -s /PATH/OFFLINE/cecp-release.key -t 'cecp-panel X.Y.Z channel=<kênh>'
   cp dist/beta/SHA256SUMS.minisig dist/SHA256SUMS.minisig      # chỉ với kênh beta
   minisign -Vm dist/<kênh>/SHA256SUMS -p keys/cecp-release.pub  # tự kiểm tra
   ```
   Nếu build trên máy khác: chỉ mang `SHA256SUMS` sang máy ký, mang `SHA256SUMS.minisig` về.
   Trusted comment (`-t`) được ký kèm; panel in nó ra log khi cập nhật để đối chiếu.
5. Commit code + `dist/` → push `main` → tag `vX.Y.Z[-beta]` trên commit cuối.
6. Kiểm tra raw URL: tải `dist/<kênh>/SHA256SUMS`, `.minisig`, tarball từ
   `https://raw.githubusercontent.com/theanhlive/cecp-panel/main/`, `sha256sum -c`, `minisign -Vm`.
7. Nâng cấp từng VPS một (canary trước; với RC ≥ 7 ngày). Sau nâng cấp: `cecp-panel update check`
   (dòng "Update channel" và "Release signature"), `cecp-panel site probe --all`,
   `cecp-panel security check`, `cecp-panel status`.

## Khi phát hành 2.0.0

- Đổi `CECP_PANEL_DEFAULT_CHANNEL` trong `lib/update.sh` sang `stable` (VPS đã chọn kênh giữ
  nguyên lựa chọn), và hướng dẫn cài mới dùng `install-cecp-panel.sh --channel stable`.
- `dist/stable/` phải có trước khi đổi mặc định, nếu không VPS kênh stable rơi về `dist/` (beta).

## Giới hạn đã biết

- Chữ ký chứng minh **nguồn gốc** `SHA256SUMS`, không chứng minh độ mới: mirror bị chiếm vẫn có
  thể phục vụ một bản cũ hơn đã ký hợp lệ (rollback). Trusted comment ghi phiên bản/kênh để người
  vận hành đối chiếu; chưa tự chặn.
- Lệnh cài đầu tiên (`curl … install-cecp-panel.sh | bash`) không xác minh chữ ký được (chưa có khoá
  tin cậy trên máy): đây là tin cậy lần đầu (TOFU) vào GitHub. Từ lần `update panel` đầu tiên trở
  đi, khoá đã cài mới có tác dụng.
- Xác minh dùng `minisign` nếu có (EPEL 9, Ubuntu 24.04+; `install.sh` tự cài nếu kho có), nếu
  không thì `openssl` ≥ 3.0 qua `lib/minisign_verify.py` (Ubuntu 22.04). Thiếu cả hai ⇒ từ chối.
