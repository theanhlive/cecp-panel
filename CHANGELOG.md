# Changelog

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
