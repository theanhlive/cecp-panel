# CECP Panel — cài một lệnh cho khách

Nguồn chính thức: repo GitHub công khai `theanhlive/cecp-panel` (raw `main`).

## Khách chạy trên VPS mới (root, Alma 9 / Ubuntu 22)

### Cài panel

```bash
curl -fsSL https://raw.githubusercontent.com/theanhlive/cecp-panel/main/install-cecp-panel.sh | sudo bash
```

Script tự tải `dist/cecp-panel-<phiên-bản>.tar.gz` (hoặc `cecp-panel-latest.tar.gz`) và **xác minh SHA256** với `dist/SHA256SUMS` trên cùng nguồn GitHub.

**Cài ghim phiên bản / checksum (tin cậy hơn):**

```bash
curl -fsSL https://raw.githubusercontent.com/theanhlive/cecp-panel/main/install-cecp-panel.sh | sudo bash -s -- \
  --version 1.12.1-beta \
  --sha256 <64-ký-tự-hex-từ-SHA256SUMS>
```

Mirror tùy chọn (ghi đè nguồn mặc định): thêm `--raw-base https://HOST/path`.

### Hardening + tối ưu (khuyến nghị, 1–2 phút)

```bash
cecp-panel security apply-production
cecp-panel optimize stack
```

### Wizard DNS/backup (tự chạy nếu có TTY)

```bash
cecp-panel onboard
```

- Cloudflare API token (Zone DNS Edit) — thêm subdomain trỏ VPS
- Google Drive service account JSON + Shared Drive ID — backup

### Thêm site WordPress

```bash
cecp-panel dns point test1.theanhlive.com
cecp-panel site add test1.theanhlive.com --wordpress
cecp-panel optimize redis-wp test1.theanhlive.com
cecp-panel ssl issue test1.theanhlive.com
cecp-panel backup run test1.theanhlive.com
cecp-panel security check
```

## Nâng cấp panel trên VPS đã cài

```bash
cecp-panel update panel latest
```

VPS cài **trước 1.12.1** và còn URL mirror cũ trong `/etc/cecp-panel/panel.env` — chạy **một lần**:

```bash
cecp-panel update mirror https://raw.githubusercontent.com/theanhlive/cecp-panel/main
cecp-panel update panel latest
```

**Tin cậy:** mọi bản tải đều đối chiếu `dist/SHA256SUMS` trên GitHub; để chặt hơn, ghim `--sha256` khi cài hoặc `cecp-panel update panel latest --sha256 <hash>`.

## Không cần wizard (env)

```bash
export CECP_CF_TOKEN="..."
export CECP_CF_ZONE="theanhlive.com"
export CECP_GDRIVE_SA_JSON="/root/gdrive-sa.json"
export CECP_GDRIVE_TEAM_ID="..."
cecp-panel onboard
```

## Agency (phát hành / lab)

```bash
./build-release.sh   # lint + dist/ (commit dist/ lên main cùng code)
SSH_KEY=~/.ssh/cecp_vultr ./deploy-safe.sh root@VPS_IP --with-check
```
