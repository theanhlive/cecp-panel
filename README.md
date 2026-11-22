# CECP Panel v2.0.0

Standalone VPS panel (LarVPS-style). **One install** = full stack + menu.

**Hệ điều hành:** AlmaLinux / Rocky 8–9 (kiểm thử chính: AlmaLinux 9), Ubuntu 22.04. Ubuntu 24.04 được `install.sh` chấp nhận nhưng chưa kiểm chứng ([docs/LAB_CHECKLIST.md](docs/LAB_CHECKLIST.md)).  
**Tính năng chi tiết:** [FEATURES.md](FEATURES.md) · **Thay đổi + runbook nâng cấp:** [CHANGELOG.md](CHANGELOG.md)

## Cài một lệnh (khách hàng)

Xem **[CUSTOMER_INSTALL.md](CUSTOMER_INSTALL.md)** — khách chỉ cần:

```bash
curl -fsSL https://raw.githubusercontent.com/theanhlive/cecp-panel/main/install-cecp-panel.sh | sudo bash
```

Sau cài (khuyến nghị):

```bash
cecp-panel security apply-production
cecp-panel optimize stack
cecp-panel onboard   # Cloudflare + Google Drive (tuỳ chọn)
```

Gõ lệnh nhanh: phím **Tab** gợi ý lệnh, cờ và domain (`cecp-panel ssl issue <Tab>`), có hiệu lực ở phiên SSH mới.

## Agency (từ Mac/Windows CECP)

```bash
./build-release.sh          # lint gate + dist/*.tar.gz + dist/SHA256SUMS (commit dist/ lên main)
SSH_KEY=~/.ssh/KEY ./deploy-safe.sh root@VPS_IP --with-check
```

Kiểm thử (cần Docker):

```bash
bash tests/lint.sh                  # bash -n + shellcheck + check_truncation.py
bash tests/integration/run.sh       # AlmaLinux 9 + systemd, cài panel và chạy scenario.sh
```

Trước bản RC/chính thức: kiểm thử thủ công trên VPS lab theo [docs/LAB_CHECKLIST.md](docs/LAB_CHECKLIST.md).

## Features

| Menu | Commands |
|------|----------|
| Domains | `site add/remove/list/duplicate`, SFTP per site, `protect-admin` (basic auth / IP allowlist), `site auth` (whole site) |
| Agency | `site staging` + `staging-push` (rollback), safe `wp update` / `auto-update` / `rollback`, `site limits` (CPU/RAM per site), `php config`, `db export/import/shell/slow-report`, `status --json` |
| Updates | `update all` (OS + wp-cli + every WordPress site + panel, with rollback) + `update enable-cron`; new `site add --wp` turns on cache auto-purge + WordPress auto-update by default |
| SSL | Let's Encrypt webroot or Cloudflare DNS-01 (`--dns`, `--wildcard`, subdomain sites reuse the wildcard), HTTPS + HTTP/2 template, `ssl hsts` |
| DNS | Cloudflare A records (`/etc/cecp-panel/credentials.env`) |
| Backup | restic → Google Drive / local / sftp, tiered retention (`backup prune-dry-run` → `backup prune`), `verify`, `restore --live` with rollback |
| Security | vhost hardening, Cloudflare real IP, fail2ban (+nginx deny), SSH harden/port/key-only/repair, MariaDB bind, Redis ACL, `apply-production`, `check`, `fix-perms`, `harden-docroot`, `php-isolation`, `cf-only on\|off\|status` (80/443 chỉ nhận Cloudflare) |
| Incident | `security scan [DOMAIN\|--all]`, `scan-schedule on [--every 14\|30] [--auto-restore]`, `scan-ack`, `restore-clean`, `rotate-secrets` ([docs/INCIDENT_RESPONSE.md](docs/INCIDENT_RESPONSE.md)) |
| Performance | FastCGI cache (tracking-param-free key, per-site TTL, auto-purge on content change, per-site/URL purge), Cloudflare HTML edge cache (`cf edge-cache`), HTTP/2, Redis+WP, OPcache JIT, BBR, MariaDB tune, brotli, bench, report |
| Media | Per-site opt-in (`media enable DOMAIN [--format webp\|avif\|original]`): upload mọi định dạng → một file WebP (hoặc AVIF) đã thu nhỏ, không giữ gốc; `media run` cho thư viện cũ, `media prune-originals`; nginx serves WebP/AVIF by `Accept` |
| System | auto swap, disk/log cleanup, logrotate, weekly maintain cron |
| Monitor | services/sites/SSL/disk/backup every 5 min, auto-restart, alerts on change (`monitor enable`) |
| Notify | Telegram, Zalo Bot, Discord, signed JSON webhook → n8n; chọn loại theo kênh (`notify events`) ([docs/NOTIFICATIONS.md](docs/NOTIFICATIONS.md), [docs/WEBHOOK_N8N.md](docs/WEBHOOK_N8N.md)) |
| Agent | heartbeat → CECP API (`agent install\|status`) |

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
cecp-panel update panel latest
# rồi làm mục "Nâng cấp từ …" trong CHANGELOG.md cho từng phiên bản đã bỏ qua, và: cecp-panel site probe --all
```

VPS cài trước 1.12.1 vẫn trỏ nguồn cũ (mirror isharevn đã ngừng phân phối) — `cecp-panel update check` hiện
dòng `Update mirror:`; nếu không phải GitHub, chạy một lần:

```bash
cecp-panel update mirror https://raw.githubusercontent.com/theanhlive/cecp-panel/main
```

## Docs

- [NOTIFICATIONS.md](docs/NOTIFICATIONS.md) — cảnh báo qua Telegram / Zalo Bot / Discord / n8n, chọn loại thông báo
- [INCIDENT_RESPONSE.md](docs/INCIDENT_RESPONSE.md) — website bị hack: quét, làm sạch, đổi bí mật, ngăn lây chéo
- [CLOUDFLARE_DNS.md](docs/CLOUDFLARE_DNS.md) — trỏ domain qua Cloudflare (DNS, SSL, khoá IP gốc) — runbook cho người & AI Agent ([AGENTS.md](AGENTS.md))
- [MEDIA_OPTIMIZE.md](docs/MEDIA_OPTIMIZE.md) — per-site image optimize (opt-in)
- [SITE_TUNING.md](docs/SITE_TUNING.md) — tune và loadtest theo domain (audit → capacity → một thay đổi → verify → rollback)
- [CLOUDFLARE_AGENT_TOKEN.md](docs/CLOUDFLARE_AGENT_TOKEN.md) — token Cloudflare cho `tools/cf-agent.sh` (máy vận hành)
- [WEBHOOK_N8N.md](docs/WEBHOOK_N8N.md) — webhook JSON ký HMAC
- [LAB_CHECKLIST.md](docs/LAB_CHECKLIST.md) — kiểm thử thủ công trên VPS lab trước RC
- [PLAN_2.0.md](docs/PLAN_2.0.md) · [ADR-0001](docs/adr/0001-release-readiness.md) — lộ trình 2.0 (CI, ma trận OS, kênh stable/beta, ký bản phát hành)
- [archive/](docs/archive/) — tài liệu lịch sử (bàn giao 1.12)
