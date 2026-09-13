# CECP Panel → n8n (webhook sự kiện)

## Bật

```bash
cecp-panel notify webhook https://n8n.example.com/webhook/cecp-events
# in ra "Webhook HMAC secret" — lưu vào n8n (credential hoặc biến môi trường)
cecp-panel notify test
```

Tắt: `cecp-panel notify webhook off`. Mọi sự kiện cũng được ghi vào `/var/log/cecp-panel/events.log` (JSON lines).

## Request

`POST` JSON, header:

| Header | Ý nghĩa |
|---|---|
| `X-CECP-Event` | tên sự kiện |
| `X-CECP-Timestamp` | Unix time (giây) lúc gửi |
| `X-CECP-Signature` | `sha256=` + HMAC-SHA256(secret, `"<timestamp>.<body thô>"`) |

Body:

```json
{
  "event": "site_down",
  "severity": "critical",
  "message": "Site DOWN: shop.example.com (HTTP 502)",
  "domain": "shop.example.com",
  "host": "vps1.example.com",
  "ts": "2026-09-13T08:00:00Z",
  "panel_version": "1.8.0-beta",
  "details": { "http_code": "502", "ttfb_ms": 15002 }
}
```

`severity`: `critical` | `warning` | `info`. Gửi lại tối đa 3 lần nếu n8n không trả 2xx.

## Sự kiện

| event | severity | khi nào |
|---|---|---|
| `site_down` / `site_recovered` | critical / info | trang chủ trả 5xx/không phản hồi (kiểm tra 5 phút/lần, bỏ qua cache) |
| `service_down` / `service_restarted` / `service_recovered` | critical / warning / info | nginx, php-fpm, mariadb, redis, fail2ban |
| `socket_fixed` | warning | socket PHP-FPM sai quyền (502) đã được sửa tự động |
| `ssl_expiring` / `ssl_renewed` | warning (critical < 3 ngày) / info | cert còn ít hơn `SSL_WARN_DAYS` |
| `disk_high` / `disk_ok` | warning (critical ≥ 95%) / info | vượt `DISK_WARN_PCT` |
| `backup_failed` / `backup_recovered` | critical / info | một lần backup lỗi / chạy lại được |
| `backup_stale` / `backup_fresh` | warning / info | quá `BACKUP_MAX_AGE_HOURS` không có backup thành công |
| `backup_verify_failed` | critical | `backup verify` không restore/import được |
| `backup_retention_failed` | warning | `restic forget --prune` lỗi |
| `restore_done` / `restore_rolled_back` / `restore_failed` | info / critical / critical | kết quả `backup restore --live` |
| `ssl_expiring`, `disk_high` (cron `notify health` hằng ngày) | warning | tóm tắt hằng ngày |
| `webhook_configured`, `test` | info | cấu hình / thử |

Cảnh báo chỉ gửi khi trạng thái **thay đổi**; nếu lỗi kéo dài, nhắc lại mỗi 6 giờ (critical) hoặc 24 giờ (warning).

## Kiểm chữ ký trong n8n

Node **Webhook** → bật *Raw Body* (Options → Raw Body). Sau đó node **Code** (JavaScript). Node Code chỉ `require('crypto')` được khi n8n chạy với biến môi trường `NODE_FUNCTION_ALLOW_BUILTIN=crypto`.

```javascript
const crypto = require('crypto');
const secret = $env.CECP_WEBHOOK_SECRET;           // hoặc lấy từ credential
const item = $input.first();
const headers = item.json.headers;
const raw = Buffer.from(item.binary.data.data, 'base64').toString('utf8');
const ts = headers['x-cecp-timestamp'];
const expected = 'sha256=' + crypto.createHmac('sha256', secret).update(`${ts}.${raw}`).digest('hex');
const given = headers['x-cecp-signature'] || '';
if (given.length !== expected.length ||
    !crypto.timingSafeEqual(Buffer.from(given), Buffer.from(expected))) {
  throw new Error('Invalid CECP signature');
}
if (Math.abs(Date.now() / 1000 - Number(ts)) > 300) {
  throw new Error('Stale CECP event');
}
return [{ json: JSON.parse(raw) }];
```

Tiếp theo có thể rẽ nhánh theo `event` / `severity` (Switch node) để gửi Zalo, email, tạo ticket…
