# CECP Panel — cài một lệnh cho khách

## Khách chạy trên VPS mới (root, Alma 9 / Ubuntu 22)

### Bước 1 — Bạn host 2 file (GitHub raw hoặc CDN)

Sau mỗi bản release, chạy trên máy dev:

```bash
cd scripts/cecp-panel && ./build-release.sh
# Upload dist/cecp-panel-latest.tar.gz + install-cecp-panel.sh lên CDN/GitHub
```

### Bước 2 — Khách cài (mirror công khai)

```bash
curl -fsSL https://isharevn.net/downloads/cecp-panel/install-cecp-panel.sh | sudo bash
```

Script tự tải `dist/cecp-panel-1.5.1-beta.tar.gz` (hoặc `cecp-panel-latest.tar.gz`) — **không cần** tải `.tar.gz` thủ công.

Mirror tùy chọn (GitHub raw):

```bash
curl -fsSL https://raw.githubusercontent.com/ORG/REPO/main/scripts/cecp-panel/install-cecp-panel.sh | sudo bash -s -- \
  --raw-base https://raw.githubusercontent.com/ORG/REPO/main/scripts/cecp-panel
```

### Bước 3 — Hardening + tối ưu (khuyến nghị, 1–2 phút)

```bash
cecp-panel security apply-production
cecp-panel optimize stack
```

### Bước 4 — Wizard DNS/backup (tự chạy nếu có TTY)

```bash
cecp-panel onboard
```

- Cloudflare API token (Zone DNS Edit) — thêm subdomain trỏ VPS
- Google Drive service account JSON + Shared Drive ID — backup

### Bước 5 — Thêm site WordPress

```bash
cecp-panel dns point test1.theanhlive.com
cecp-panel site add test1.theanhlive.com --wordpress
cecp-panel optimize redis-wp test1.theanhlive.com
cecp-panel ssl issue test1.theanhlive.com
cecp-panel backup run test1.theanhlive.com
cecp-panel security check
```

## Không cần wizard (env)

```bash
export CECP_CF_TOKEN="..."
export CECP_CF_ZONE="theanhlive.com"
export CECP_GDRIVE_SA_JSON="/root/gdrive-sa.json"
export CECP_GDRIVE_TEAM_ID="..."
cecp-panel onboard
```

## Agency (từ Mac, lab)

```bash
chmod +x scripts/cecp-panel/finish-lab.sh
SSH_KEY=~/.ssh/cecp_vultr ./scripts/cecp-panel/finish-lab.sh root@207.148.65.70

# Khi có file Google SA:
CECP_GDRIVE_SA_JSON=~/gdrive-sa.json CECP_GDRIVE_TEAM_ID=xxx ./scripts/cecp-panel/finish-lab.sh root@207.148.65.70
```
