# CECP Panel — Media optimize (per-site)

Tối ưu ảnh **tùy chọn theo website**. Site tĩnh / ít update: **không bật**. Site shop / blog upload nhiều: bật on-upload + cron.

## Mặc định

- **OFF** cho mọi site mới
- Không cài mu-plugin cho đến khi `media enable`
- Cron global chỉ xử lý site có `media_optimize.enabled=true` **và** `cron=true`

## Lệnh

```bash
# Bật (WordPress only)
cecp-panel media enable example.com
cecp-panel media enable example.com --max-width 1920 --quality 80
cecp-panel media enable example.com --no-cron          # chỉ on-upload
cecp-panel media enable example.com --no-upload        # chỉ cron batch
cecp-panel media enable example.com --no-webp

# Tắt (gỡ mu-plugin)
cecp-panel media disable example.com

# Xem trạng thái
cecp-panel media status
cecp-panel media status example.com

# Chạy backlog ngay (tối đa batch_limit file, mặc định 30)
cecp-panel media run example.com
cecp-panel media run example.com --dry-run
cecp-panel media run example.com --limit 10

# Cron global (03:20 mỗi ngày)
cecp-panel media enable-cron
cecp-panel media disable-cron
cecp-panel media run-all    # dùng bởi cron
```

## Cơ chế

| Lớp | Cách | Khi nào |
|-----|------|---------|
| On-upload | mu-plugin `wp-content/mu-plugins/cecp-media-optimize.php` | Ngay khi khách upload Media / product |
| Batch | `media run` / cron `run-all` | File cũ, FTP, import, sidecar `.webp` thiếu |
| Marker | `*.cecp-opt` cạnh file | Tránh nén lại file đã xử lý |

### On-upload (mu-plugin)

- Resize nếu vượt `max_width` / `max_height` (mặc định 1920)
- JPEG quality ~80, strip qua WP image editor
- Ghi WebP cạnh file nếu PHP GD có `imagewebp`
- Bỏ qua SVG/GIF

### Batch (CLI)

- Ưu tiên Pillow (`python3-pillow`), fallback ImageMagick
- Chỉ `wp-content/uploads/**/*.{jpg,jpeg,png}`
- Skip nếu có marker `.cecp-opt` mới hơn file
- Skip file nhỏ hơn `skip_under_kb` (mặc định 200KB) trong batch
- Giới hạn `batch_limit` (mặc định 30) mỗi lần — an toàn VPS 1GB

## State

`/var/lib/cecp-panel/sites/<domain>.json`:

```json
"media_optimize": {
  "enabled": true,
  "on_upload": true,
  "cron": true,
  "webp": true,
  "max_width": 1920,
  "max_height": 1920,
  "quality": 80,
  "skip_under_kb": 200,
  "batch_limit": 30,
  "enabled_at": "2026-07-10T09:00:00Z",
  "last_run_at": null,
  "last_run_stats": {}
}
```

Mu-plugin config mirror: `wp-content/mu-plugins/cecp-media-optimize.json`

## Gợi ý dùng

| Loại site | Nên |
|-----------|-----|
| WooCommerce / tin tức upload hằng ngày | `media enable` + cron |
| Landing tĩnh / brochure | **không bật** |
| Lần đầu sau enable | `media run DOMAIN --dry-run` rồi `media run DOMAIN` vài lần |

## Lưu ý

- Không thay thế backup Drive
- Bulk lần đầu: chạy nhiều lần `--limit 30`, không optimize cả thư viện một phát trên VPS 1GB
- WebP sidecar không tự rewrite HTML — theme/plugin WebP hoặc `Accept` negotiation (webp-express) vẫn hữu ích cho delivery
- `optimize webp DOMAIN` (plugin webp-express) **khác** module này; có thể dùng song song
