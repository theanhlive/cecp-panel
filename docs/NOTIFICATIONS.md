# Thông báo VPS: Telegram, Zalo Bot, Discord, n8n

Panel gửi cảnh báo khi: website/dịch vụ sập, backup lỗi, SSL sắp hết hạn, ổ đĩa đầy, quét bảo mật
phát hiện mã độc, cập nhật WordPress… Mỗi sự kiện cũng được ghi vào `/var/log/cecp-panel/events.log`.

```bash
cecp-panel notify setup        # wizard: chọn kênh, dán token, chọn loại thông báo, gửi thử
```

Token/URL được **dán ở ô nhập ẩn**, không gõ trên dòng lệnh (dòng lệnh lưu vào lịch sử shell và mọi
user trên VPS xem được). Chúng được lưu ở `/etc/cecp-panel/notify.env` (chỉ root đọc được, quyền 600).

## Kênh

### Telegram
1. Mở Telegram → **@BotFather** → `/newbot` → đặt tên → copy **token** (dạng `123456789:ABC…`).
2. `cecp-panel notify telegram` → dán token.
3. Mở Telegram, **nhắn một tin bất kỳ cho bot** (hoặc thêm bot vào nhóm rồi nhắn trong nhóm) → Enter.
   Panel tự tìm Chat ID và gửi tin thử.

### Zalo Bot
1. Mở Zalo → tìm **Zalo Bot Manager** (hoặc vào https://bot.zapps.vn) → **Tạo bot** → copy **Bot Token**.
2. `cecp-panel notify zalo` → dán token.
3. Mở Zalo, **nhắn một tin cho bot** → Enter. Panel tự tìm Chat ID và gửi tin thử.

Nếu bot đang nhận tin qua webhook ở hệ thống khác (n8n…), panel không đọc được tin nhắn: nhập Chat ID thủ công.

### Discord
1. Kênh Discord → **Chỉnh sửa kênh → Tích hợp → Webhook → Webhook mới → Sao chép URL**.
2. `cecp-panel notify discord` → dán URL.

### n8n / hệ thống khác
`cecp-panel notify webhook https://n8n.example.com/webhook/ID` — JSON có chữ ký HMAC ([WEBHOOK_N8N.md](WEBHOOK_N8N.md)).
Webhook nhận **mọi** loại thông báo trừ khi đặt `--channel webhook`.

## Chọn loại thông báo

| Nhóm | Gồm |
|---|---|
| `security` | Quét bảo mật phát hiện mã độc / cảnh báo, khôi phục từ bản sạch |
| `uptime` | Website, nginx, PHP-FPM, MariaDB, Redis sập / tự khởi động lại / hồi phục |
| `backup` | Backup lỗi, backup quá cũ, kiểm tra backup lỗi, restore |
| `ssl` | Chứng chỉ sắp hết hạn |
| `resources` | Ổ đĩa sắp đầy |
| `updates` | Cập nhật WordPress / hệ thống, đẩy staging |

Mức độ: `info` (mọi thông báo, gồm cả "đã hồi phục", "đã cập nhật") < `warning` < `critical`.
Tin nhắn thử và thông báo đổi cấu hình luôn được gửi.

```bash
cecp-panel notify events                                   # xem bảng hiện tại
cecp-panel notify events edit                              # bật/tắt từng nhóm (hỏi từng dòng)
cecp-panel notify events set security,uptime,backup        # cho mọi kênh
cecp-panel notify events set all --min warning             # mọi nhóm, bỏ tin "thông tin"
cecp-panel notify events set security,uptime --channel zalo --min critical   # riêng Zalo: chỉ việc khẩn
cecp-panel notify events set default --channel zalo        # Zalo dùng lại cài đặt chung
cecp-panel notify events set none                          # tắt hết (vẫn ghi events.log)
```

Gợi ý: Zalo/Telegram cá nhân chỉ nhận `security,uptime` mức `warning`, Discord nhận tất cả để lưu vết.

## Khác

```bash
cecp-panel notify test               # gửi thử tới mọi kênh (hoặc: notify test zalo)
cecp-panel notify off zalo           # tắt một kênh (telegram | zalo | discord | webhook)
cecp-panel notify status
cecp-panel notify enable-cron        # kiểm tra SSL + ổ đĩa hằng ngày (wizard tự bật)
cecp-panel monitor enable            # kiểm tra site/dịch vụ mỗi 5 phút, báo khi sập / hồi phục
```

AI Agent / tự động hoá (không có terminal): truyền bí mật qua biến môi trường, không qua đối số:

```bash
read -rs CECP_TELEGRAM_TOKEN; export CECP_TELEGRAM_TOKEN CECP_TELEGRAM_CHAT=-100123456
cecp-panel notify telegram; unset CECP_TELEGRAM_TOKEN
# tương tự: CECP_ZALO_TOKEN + CECP_ZALO_CHAT, CECP_DISCORD_WEBHOOK
```
