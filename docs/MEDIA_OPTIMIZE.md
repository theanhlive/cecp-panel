# CECP Panel — Media optimize (per-site)

Tối ưu ảnh **tùy chọn theo website**. Site tĩnh / ít update: **không bật**. Site shop / blog upload nhiều: bật on-upload + cron.

## Mặc định

- **OFF** cho mọi site mới
- Không cài mu-plugin cho đến khi `media enable`
- Cron global chỉ xử lý site có `media_optimize.enabled=true` **và** `cron=true`

## Chế độ lưu ảnh (`--format`, 1.12+)

| `--format` | Ảnh upload mới | File gốc | Khi nào dùng |
|---|---|---|---|
| **`webp`** (mặc định) | Mọi định dạng (JPG, PNG, WebP, BMP; HEIC/HEIF iPhone và TIFF khi server có PHP Imagick) → **một file WebP duy nhất**, xoay đúng chiều theo EXIF, thu về tối đa `max_width`×`max_height` (không bao giờ phóng to → không vỡ/nhoè), các size thumbnail cũng là WebP | **Không giữ** — xoá ngay sau khi chuyển; WordPress không còn tạo cặp `-scaled`/`-rotated` + bản gốc | Hầu hết site (mọi trình duyệt từ 2020 đều hỗ trợ WebP) |
| `avif` | Như trên nhưng AVIF (nhỏ hơn WebP ~20-30%) — cần WordPress ≥ 6.5 và PHP có AVIF, không có thì tự dùng WebP | Không giữ | Chỉ khi chấp nhận Safari < 16.4 không xem được ảnh |
| `original` | Giữ định dạng, nén lại + file `.webp/.avif` đi kèm (nginx tự chọn theo trình duyệt) | Giữ | Hành vi cũ; site bật trước 1.12 vẫn ở chế độ này cho tới khi chạy lại `media enable` |

Chất lượng: ảnh chụp dùng `--quality` (mặc định 80, WebP 80 ≈ JPEG 90 về mắt thường); ảnh nguồn PNG
(logo, ảnh chụp màn hình, ảnh có chữ) tự dùng +10 để nét chữ không nhoè. Nếu bản nén **không nhỏ hơn**
bản upload (ảnh đã tối ưu sẵn) và không cần resize/xoay thì giữ nguyên bản upload. GIF (ảnh động), SVG,
WebP/PNG động không bị đụng tới.

Ví dụ thực tế (test trên WordPress): ảnh điện thoại JPEG 4000×3000 819 KB → WebP 1440×1920 **72 KB**
(đã xoay dọc); BMP scan 5,7 MB → **61 KB**; logo PNG trong suốt vẫn trong suốt.

Ảnh rất lớn (> ~25 megapixel) mà server chỉ có GD: tăng RAM PHP của site
`cecp-panel php config DOMAIN memory_limit=512M` (`media enable` cài Imagick nếu có sẵn gói và cảnh báo khi cần).
`cecp-panel media status DOMAIN` liệt kê định dạng server đọc/chuyển được.

### Dọn file gốc của thư viện cũ

WordPress (từ 5.3) giữ bản gốc full-size của mọi ảnh lớn/xoay (file không có `-scaled` bên cạnh file
`-scaled`) — thường là phần nặng nhất của `uploads/`, chỉ dùng để tạo lại thumbnail.

```bash
cecp-panel media prune-originals example.com          # chạy thử: đếm + dung lượng sẽ giải phóng
cecp-panel media prune-originals example.com --yes    # xoá, bản -scaled trở thành file chính
```

Nên có backup mới (`cecp-panel backup run DOMAIN`) trước khi chạy `--yes`.

## Lệnh

```bash
# Bật (WordPress only)
cecp-panel media enable example.com                    # --format webp: 1 file WebP/ảnh, không giữ gốc
cecp-panel media enable example.com --format original  # hành vi cũ (giữ JPG/PNG + sidecar)
cecp-panel media enable example.com --max-width 2560   # màn hình lớn/retina toàn khung
cecp-panel media enable example.com --max-width 1920 --quality 80
cecp-panel media enable example.com --no-cron          # chỉ on-upload
cecp-panel media enable example.com --no-upload        # chỉ cron batch
cecp-panel media enable example.com --no-webp
cecp-panel media enable example.com --avif             # thêm AVIF (xem Lưu ý về Cloudflare)

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
  "avif": false,
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
- **Phân phối (1.8+)**: nginx tự trả `photo.webp` / `photo.avif` cho request `photo.jpg` khi trình duyệt gửi `Accept: image/webp|avif`; không cần sửa HTML, không cần plugin. Thiếu sidecar → trả file gốc. Áp dụng cho site cũ bằng `site rebuild-vhost --all`.
- Sidecar đặt tên theo tên gốc bỏ đuôi, nên `a.jpg` và `a.png` trong cùng thư mục sẽ dùng chung `a.webp`. Tránh đặt hai ảnh trùng tên khác đuôi.
- **AVIF + Cloudflare**: gói Free/Pro/Business bỏ qua `Vary: Accept`, nên edge có thể trả bản AVIF đã cache cho trình duyệt không hỗ trợ AVIF (Safari < 16.4). Site proxied chỉ nên dùng WebP. Mọi trình duyệt hiện đại đều hỗ trợ WebP.
- AVIF cần PHP ≥ 8.1 có `imageavif` (on-upload), hoặc Pillow ≥ 11.2 / ImageMagick có libheif (batch). Nếu không có encoder thì chỉ tạo WebP (`avif_note` trong kết quả `media run`).
- `optimize webp DOMAIN` (plugin webp-express) **khác** module này; có thể dùng song song
