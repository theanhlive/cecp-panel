# Site profile — `<DOMAIN>`

> Sao chép file này thành `<domain>.md`, thay placeholder, xóa dòng hướng dẫn này. **Không commit** file domain thật (xem [README.md](README.md)).

## Identity

| Field | Value |
|---|---|
| **Domain** | `<DOMAIN>` |
| **Site type** | landing \| woocommerce \| membership \| api-heavy |
| **VPS / panel version** | (vd. AlmaLinux 9, panel 1.12.x) |

## Stack facts

| Component | Value |
|---|---|
| PHP | (vd. 8.2, pool riêng / shared) |
| WordPress | (có / staging URL) |
| Redis object cache | on / off |
| FastCGI page cache | TTL hiện tại |
| Cloudflare | proxied yes/no, zone apex |

## Cache bypass (must never cache)

- [ ] `wp-admin`, `wp-login.php`
- [ ] Cookie: `wordpress_logged_in_*` (và cookie plugin nếu có)
- [ ] Woo: cart, checkout, `my-account`, `woocommerce_items_in_cart`
- [ ] Authenticated `/wp-json/*`, mọi **POST**
- [ ] (custom) …

## Cloudflare

| Setting | Value | Approved by owner |
|---|---|---|
| SSL mode | Full (strict) | date / pending |
| Edge HTML cache | off / on + TTL | |
| Brotli / cache-level | | |
| Origin locked (`cf-only`) | off / on | |

## Approved changes (one at a time)

| Date | Change | Command / note | Rollback ID |
|---|---|---|---|
| | | | |

## Baseline numbers (before last tune)

- `optimize audit`: (PASS/WARN summary, no secrets)
- `optimize capacity`: sum_max_children, RAM verdict
- Typical p95 guest homepage: … ms (nếu đã đo)

## Current values

- `cache ttl`: …
- `pm.max_children`: …
- Last global tune: nginx / mariadb / opcache — (none / date)

## Rollback ID

- Latest snapshot to revert last change: `YYYYMMDDTHHMMSS.mmmZ-label` or `latest`

## Last loadtest result

| Date | Profile | max-vus | Verdict | CSV path on VPS |
|---|---|---|---|---|
| | cached / mixed / login-api | | PASS / FAIL | `/var/lib/cecp-panel/loadtest/...` |

## Open risks

- (WARN từ audit, RAM WARN, staging chưa sync, …)
