# CECP Panel v1.5.0-beta

Standalone VPS panel (LarVPS-style). **One install** = full stack + menu.

**Spec:** [docs/products/CECP_VPS_PANEL_V2.md](../../docs/products/CECP_VPS_PANEL_V2.md)  
**Tính năng chi tiết:** [FEATURES.md](FEATURES.md)

## Cài một lệnh (khách hàng)

Xem **[CUSTOMER_INSTALL.md](CUSTOMER_INSTALL.md)** — khách chỉ cần:

```bash
curl -fsSL https://YOUR-CDN/install-cecp-panel.sh | sudo bash
```

Sau cài (khuyến nghị):

```bash
cecp-panel security apply-production
cecp-panel optimize stack
cecp-panel onboard   # Cloudflare + Google Drive (tuỳ chọn)
```

## Agency (từ Mac/Windows CECP)

```bash
./scripts/cecp-panel/build-release.sh          # tạo dist/*.tar.gz
SSH_KEY=~/.ssh/KEY ./scripts/cecp-panel/finish-lab.sh root@VPS_IP
```

## Features

| Menu | Commands |
|------|----------|
| Domains | `site add/remove/list/duplicate`, SFTP per site |
| SSL | Let's Encrypt issue/renew/status/fix |
| DNS | Cloudflare A records (`/etc/cecp-panel/credentials.env`) |
| Backup | restic → Google Drive, tiered retention |
| Security | fail2ban full, firewall, SSH harden/port/key-only, MariaDB bind, `apply-production`, `check` |
| Performance | FastCGI cache+purge, Redis+WP, OPcache JIT, BBR, MariaDB RAM tune, brotli/webp, bench |
| Media | Per-site opt-in: on-upload resize/compress/WebP + daily cron batch (`media enable|disable|run`) |
| System | auto swap, disk/log cleanup, weekly maintain cron |
| Agent | heartbeat → CECP API (`docs/infrastructure/CECP_PANEL_AGENT_INTEGRATION.md`) |

## Quick start (lab)

```bash
cp templates/credentials.env.example /etc/cecp-panel/credentials.env
cecp-panel security apply-production
cecp-panel optimize stack
cecp-panel dns point test2.theanhlive.com
cecp-panel site add test2.theanhlive.com --wordpress
cecp-panel optimize redis-wp test2.theanhlive.com
cecp-panel ssl issue test2.theanhlive.com
cecp-panel backup setup
cecp-panel backup enable-cron
```

## Nâng cấp panel trên VPS đã cài

```bash
# Từ mirror / release mới
cecp-panel update panel
# hoặc rsync/scp scripts/cecp-panel → /opt/cecp-panel rồi:
cecp-panel security apply-production
cecp-panel optimize stack
```

## Docs

- [MEDIA_OPTIMIZE.md](docs/MEDIA_OPTIMIZE.md) — per-site image optimize (opt-in)
- [VPS_BACKUP_GDRIVE.md](../../docs/infrastructure/VPS_BACKUP_GDRIVE.md)
- [CECP_PANEL_PRODUCT_PRIORITIES.md](../../docs/products/CECP_PANEL_PRODUCT_PRIORITIES.md)
