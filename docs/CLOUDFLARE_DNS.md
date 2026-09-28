# Cloudflare DNS + SSL cho site trên CECP Panel — runbook (người & AI Agent)

Tài liệu này là **quy trình chuẩn** để đưa một domain chạy qua Cloudflare (proxy "mây cam") về
VPS cài CECP Panel. AI Agent triển khai phải làm **đúng thứ tự** dưới đây và dừng lại hỏi chủ
VPS ở những bước ghi **[HỎI NGƯỜI]**.

Ví dụ trong tài liệu: domain `khachhang.vn`, VPS đã cài panel, chạy lệnh bằng root.

---

## 0. Quy tắc bắt buộc cho AI Agent

1. **Không bao giờ in, log, commit hay gửi đi Cloudflare API token.** Token chỉ nằm trong
   `/etc/cecp-panel/credentials.env` (root, `600`). Không truyền token trên dòng lệnh của lệnh
   khác ngoài cách ở bước 2.
2. **`dns ssl-mode` áp cho CẢ ZONE** (mọi subdomain của `khachhang.vn`, kể cả subdomain đang
   chạy ở server khác). Trước khi đổi, kiểm tra zone còn subdomain nào khác không — nếu có:
   **[HỎI NGƯỜI]**.
3. Không tắt proxy (`proxied=false`) một bản ghi đang chạy thật, không bật `security cf-only on
   --force`, không xoá bản ghi DNS nếu chủ VPS chưa yêu cầu.
4. Mọi lệnh `cecp-panel` dưới đây chạy lại được nhiều lần (idempotent). Khi một lệnh lỗi:
   đọc thông báo, chạy phần **Kiểm tra** (mục 6), đối chiếu bảng lỗi (mục 8) — không đoán.
5. `dig` nằm trong gói `bind-utils` (AlmaLinux/Rocky) / `dnsutils` (Ubuntu); thiếu thì cài, hoặc
   thay `dig +short TÊN` bằng `getent ahostsv4 TÊN | awk '{print $1}' | sort -u`.
6. Chỉ dùng tên miền đầy đủ (FQDN) trong lệnh: `shop.khachhang.vn`, không dùng `shop`
   (tên ngắn sẽ được hiểu là subdomain của `CF_DEFAULT_ZONE`).

---

## 1. Điều kiện trước — [HỎI NGƯỜI] nếu chưa có

| Cần có | Cách kiểm tra (agent tự chạy) | Nếu chưa có |
|---|---|---|
| Domain đã thêm vào Cloudflare, nameserver đã trỏ về Cloudflare | `dig NS khachhang.vn +short` → kết thúc bằng `.ns.cloudflare.com.` | Chủ domain thêm site trong dashboard Cloudflare và đổi nameserver tại nhà đăng ký tên miền (có thể mất tới 24h) |
| API token Cloudflare | `grep -c '^CF_API_TOKEN=.\+' /etc/cecp-panel/credentials.env` → `1` | Chủ tài khoản tạo token (mục 1.1) |
| Panel đã production hoá | `cecp-panel security check` | `cecp-panel security apply-production` |

### 1.1 Quyền của API token (người tạo trong Cloudflare → My Profile → API Tokens → Create Token → Custom)

Phạm vi **Zone Resources**: chỉ các zone cần quản lý (hoặc All zones của tài khoản).

| Quyền | Dùng cho lệnh |
|---|---|
| Zone → **DNS → Edit** | `dns point/add`, `ssl issue --dns`, `ssl issue --wildcard` |
| Zone → **Zone Settings → Edit** | `dns ssl-mode`, `cf brotli`, `cf cache-level` |
| Zone → **Cache Rules → Edit** | `cf edge-cache` |
| Zone → **Cache Purge → Purge** | `cf purge`, auto-purge edge cache |
| Zone → **Zone → Read** | tìm zone của domain (thường có sẵn khi chọn các quyền trên) |

Một token có thể dùng cho nhiều zone: panel tự tìm đúng zone từ tên miền (dò từ tên đầy đủ lên
dần: `a.shop.khachhang.vn` → `shop.khachhang.vn` → `khachhang.vn`).

---

## 2. Nạp token vào panel (một lần cho mỗi VPS)

Không tương tác (dành cho agent) — token đi qua biến môi trường, không nằm trong lệnh hiển thị:

```bash
read -rs CECP_CF_TOKEN            # dán token, Enter (không hiện ra màn hình / log)
export CECP_CF_TOKEN CECP_CF_ZONE=khachhang.vn
cecp-panel onboard                # ghi /etc/cecp-panel/credentials.env (600), rồi:
unset CECP_CF_TOKEN
```

Hoặc tương tác: `cecp-panel onboard` và dán khi được hỏi. `CF_DEFAULT_ZONE` chỉ là zone mặc định
cho tên ngắn; các zone khác vẫn dùng được với FQDN.

Kiểm tra: `cecp-panel dns list` (liệt kê bản ghi A của zone mặc định) — lỗi `Zone not found` hoặc
`Authentication error` ⇒ token sai quyền/phạm vi.

---

## 3. Thứ tự triển khai một site mới (khuyến nghị)

```bash
D=khachhang.vn

# 3.1 Tạo site trên VPS (vhost + PHP pool + DB; --wp cài WordPress)
cecp-panel site add "$D" --wp

# 3.2 Cấp chứng chỉ Let's Encrypt qua DNS-01 (không cần bản ghi A, chạy được cả khi đã proxy)
cecp-panel ssl issue "$D" --dns
#     Nhiều subdomain trên cùng VPS: một chứng chỉ wildcard cho DOMAIN + *.DOMAIN
#     cecp-panel ssl issue "$D" --wildcard

# 3.3 Trỏ DNS về VPS, BẬT proxy Cloudflare (mặc định proxied=true)
cecp-panel dns point "$D"

# 3.4 Chế độ SSL của zone: strict (Cloudflare → origin bằng HTTPS, kiểm tra chứng chỉ thật)
#     ⚠ áp cho cả zone — xem quy tắc 0.2
cecp-panel dns ssl-mode strict "$D"
```

Vì sao thứ tự này:
- **Chứng chỉ trước, DNS sau:** khi bản ghi đã proxy và zone đang `full`/`strict`, Cloudflare nối
  tới origin qua cổng 443; nếu origin chưa có chứng chỉ, panel từ chối bắt tay TLS với hostname
  lạ ⇒ khách thấy lỗi **525**.
- **DNS-01 thay vì HTTP-01** (`ssl issue` không `--dns`): HTTP-01 hỏng khi Cloudflare bật
  "Always Use HTTPS" hoặc khi đã bật `security cf-only`. DNS-01 không phụ thuộc đường HTTP.
- **Không dùng `flexible`:** origin đã có HTTPS và tự chuyển 80 → 443, `flexible` (Cloudflare nối
  origin bằng HTTP) sẽ gây **vòng lặp chuyển hướng**. `ssl issue --dns` tự cảnh báo khi phát hiện.

`ssl issue` cũng tự chuyển URL WordPress (`home`/`siteurl`) sang `https://` và bật
`FORCE_SSL_ADMIN`.

### 3.5 Subdomain / staging

```bash
cecp-panel site add shop.khachhang.vn --wp       # dùng lại wildcard nếu đã cấp ở 3.2
cecp-panel dns point shop.khachhang.vn
cecp-panel site staging khachhang.vn             # tạo staging.khachhang.vn
cecp-panel dns point staging.khachhang.vn
```

⚠ **Chứng chỉ miễn phí của Cloudflare (Universal SSL) chỉ phủ `khachhang.vn` và `*.khachhang.vn`
(một cấp).** Tên hai cấp như `staging.shop.khachhang.vn` khi bật proxy sẽ lỗi chứng chỉ ở phía
trình duyệt, trừ khi mua Advanced Certificate. Với tên hai cấp: **[HỎI NGƯỜI]** (dùng tên một cấp
như `staging-shop.khachhang.vn`, hoặc để bản ghi đó không proxy).

### 3.6 `www`

Vhost của panel chỉ nhận đúng tên đã `site add`. Không trỏ `www.khachhang.vn` về VPS như một
site riêng. Cách chuẩn: tạo bản ghi `www` (proxied) + **Redirect Rule** trong Cloudflare
(`www.khachhang.vn/*` → `https://khachhang.vn/$1`, 301). Việc này làm trong dashboard:
**[HỎI NGƯỜI]** nếu agent không có quyền Cloudflare dashboard.

---

## 4. Tăng tốc ở Cloudflare (tuỳ chọn, sau khi site chạy ổn)

```bash
cecp-panel cf recommend                          # gợi ý cấu hình
cecp-panel cf brotli on khachhang.vn
cecp-panel cf edge-cache khachhang.vn on --ttl 1h  # cache HTML tại Cloudflare (bỏ qua khi đăng nhập/giỏ hàng)
cecp-panel cache auto-purge khachhang.vn on      # sửa bài → tự xoá cache cả origin lẫn Cloudflare
```

Real IP của khách (cho rate limit, fail2ban, log) đã được bật bởi `security apply-production`
(`cecp-panel cf realip`, tự cập nhật hằng tuần).

---

## 5. Khoá IP gốc — chỉ cho Cloudflare vào cổng 80/443

Chỉ làm khi **mọi site trên VPS** đã proxy qua Cloudflare:

```bash
cecp-panel security cf-only status   # phải in: "All sites resolve to Cloudflare."
cecp-panel security cf-only on       # tự từ chối nếu còn site chưa proxy
```

- SSH không bị ảnh hưởng. Hoàn tác: `cecp-panel security cf-only off`.
- Sau khi bật, site mới phải được proxy **trước khi** mở cho khách; cấp SSL luôn bằng `--dns`.
- Agent **không** dùng `--force` khi chưa được chủ VPS đồng ý.

---

## 6. Kiểm tra sau triển khai (agent chạy và báo kết quả)

```bash
D=khachhang.vn
dig +short "$D"                                   # IP Cloudflare (104.x / 172.64-71.x), KHÔNG phải IP VPS
curl -sI "https://$D/" | grep -iE '^(HTTP|cf-ray|x-cecp-cache|strict-transport)'
#   HTTP/2 200 (hoặc 301/302), có cf-ray ⇒ đi qua Cloudflare; x-cecp-cache: HIT/MISS/BYPASS
cecp-panel ssl status                              # số ngày còn lại của chứng chỉ origin
cecp-panel security cf-only status                 # site nào chưa proxy
cecp-panel status                                  # tổng quan dịch vụ + site
```

Kết quả mong đợi: `dig` ra IP Cloudflare, `curl` có `cf-ray`, mã 2xx/3xx, `ssl status` > 30 ngày.

---

## 7. Gỡ / chuyển site

```bash
cecp-panel site remove khachhang.vn      # xoá site + chứng chỉ trên VPS (bản ghi DNS KHÔNG tự xoá)
```

Bản ghi DNS ở Cloudflare do người quyết định xoá hay trỏ đi nơi khác: **[HỎI NGƯỜI]**.
Chuyển sang VPS mới: làm mục 3 trên VPS mới, restore backup, rồi mới `dns point` (IP mới).

---

## 8. Bảng lỗi thường gặp

| Triệu chứng | Nguyên nhân thường gặp | Cách xử lý |
|---|---|---|
| Lỗi **521** (web server down) | nginx tắt, hoặc firewall chặn IP Cloudflare | `cecp-panel status`; `cecp-panel security firewall`; `cf-only status` |
| Lỗi **522** (timeout) | IP trong bản ghi A sai / VPS không trả lời | `cecp-panel dns list`, so với IP VPS; `cecp-panel dns point DOMAIN` |
| Lỗi **525** (SSL handshake failed) | Zone `full`/`strict` nhưng origin chưa có chứng chỉ cho domain này | `cecp-panel ssl issue DOMAIN --dns` |
| Lỗi **526** (invalid SSL) | Zone `strict`, chứng chỉ origin hết hạn / sai tên | `cecp-panel ssl status`; `cecp-panel ssl renew`; `cecp-panel ssl fix DOMAIN` |
| **Vòng lặp chuyển hướng** (ERR_TOO_MANY_REDIRECTS) | Zone `flexible` trong khi origin có HTTPS | `cecp-panel dns ssl-mode strict DOMAIN` |
| `certbot DNS-01 failed` | Token thiếu quyền DNS Edit trên zone đó | Sửa quyền token (mục 1.1) |
| `No active Cloudflare zone for …` | Domain chưa thêm vào Cloudflare / nameserver chưa đổi / token không có zone này | Mục 1 |
| Trình duyệt báo lỗi chứng chỉ ở tên 2 cấp | Universal SSL chỉ phủ 1 cấp | Mục 3.5 |
| wp-admin chuyển sang https lỗi khi chưa có SSL | (đã sửa từ 1.12.0-beta) | `cecp-panel ssl issue DOMAIN --dns` |

Chẩn đoán tự động cho một site: `cecp-panel ssl fix DOMAIN` (đọc trạng thái proxy, chế độ SSL,
chứng chỉ và đề xuất cách sửa; `--auto` để tự áp dụng).
