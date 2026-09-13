# CECP Panel v1.9.0-beta

Standalone VPS panel (LarVPS-style). **One install** = full stack + menu.

**Spec:** [docs/products/CECP_VPS_PANEL_V2.md](../../docs/products/CECP_VPS_PANEL_V2.md)  
**Tính năng chi tiết:** [FEATURES.md](FEATURES.md) · **Thay đổi + runbook nâng cấp:** [CHANGELOG.md](CHANGELOG.md)

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
./build-release.sh          # lint gate + dist/*.tar.gz + dist/SHA256SUMS (upload cả SHA256SUMS lên mirror)
SSH_KEY=~/.ssh/KEY ./deploy-safe.sh root@VPS_IP --with-check
```

Kiểm thử (cần Docker):

```bash
bash tests/lint.sh                  # bash -n + shellcheck + check_truncation.py
bash tests/integration/run.sh       # AlmaLinux 9 + systemd, cài panel và chạy scenario.sh
```

## Features

| Menu | Commands |
|------|----------|
| Domains | `site add/remove/list/duplicate`, SFTP per site, `protect-admin` (basic auth / IP allowlist), `site auth` (whole site) |
| Agency | `site staging` + `staging-push` (rollback), safe `wp update` / `auto-update` / `rollback`, `site limits` (CPU/RAM per site), `php config`, `db export/import/shell/slow-report`, `status --json` |
| SSL | Let's Encrypt webroot or Cloudflare DNS-01 (`--dns`, `--wildcard`, subdomain sites reuse the wildcard), HTTPS + HTTP/2 template, `ssl hsts` |
| DNS | Cloudflare A records (`/etc/cecp-panel/credentials.env`) |
| Backup | restic → Google Drive / local / sftp, tiered retention, `verify`, `restore --live` with rollback |
| Security | vhost hardening, Cloudflare real IP, fail2ban (+nginx deny), SSH harden/port/key-only/repair, MariaDB bind, Redis ACL, `apply-production`, `check`, `fix-perms` |
| Performance | FastCGI cache (tracking-param-free key, per-site TTL, auto-purge on content change, per-site/URL purge), Cloudflare HTML edge cache (`cf edge-cache`), HTTP/2, Redis+WP, OPcache JIT, BBR, MariaDB tune, brotli, bench, report |
| Media | Per-site opt-in: on-upload resize/compress/WebP (+ optional AVIF) + daily cron batch; nginx serves WebP/AVIF by `Accept` |
| System | auto swap, disk/log cleanup, logrotate, weekly maintain cron |
| Monitor | services/sites/SSL/disk/backup every 5 min, auto-restart, alerts on change (`monitor enable`) |
| Notify | Telegram, Discord, signed JSON webhook → n8n ([docs/WEBHOOK_N8N.md](docs/WEBHOOK_N8N.md)) |
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
# Từ mirror (bắt buộc có dist/SHA256SUMS) — hoặc deploy-safe.sh từ máy agency
cecp-panel update panel
# rồi làm theo runbook trong CHANGELOG.md (apply-production, site rebuild-vhost --all, ...)
```

## Docs

- [MEDIA_OPTIMIZE.md](docs/MEDIA_OPTIMIZE.md) — per-site image optimize (opt-in)
- [VPS_BACKUP_GDRIVE.md](../../docs/infrastructure/VPS_BACKUP_GDRIVE.md)
- [CECP_PANEL_PRODUCT_PRIORITIES.md](../../docs/products/CECP_PANEL_PRODUCT_PRIORITIES.md)
