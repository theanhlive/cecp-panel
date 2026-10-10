# Cloudflare API token cho AI Agent — tạo, giao, dùng, thu hồi

Tài liệu cho **chủ tài khoản Cloudflare** (người tạo token) và **AI Agent / người vận hành** (người
dùng token). Công cụ đi kèm: [`tools/cf-agent.sh`](../tools/cf-agent.sh) — chạy trên **máy vận
hành** (máy agency, nơi AI Agent chạy), không chạy trên VPS.

Liên quan: [SITE_TUNING.md](SITE_TUNING.md) (vòng tune theo domain), [CLOUDFLARE_DNS.md](CLOUDFLARE_DNS.md)
(DNS/SSL, token trên VPS cho `cecp-panel`).

---

## 1. Vì sao token của agent nằm ở máy vận hành, không nằm trên VPS

- VPS chạy code của khách (WordPress, plugin). Site bị hack ⇒ mọi thứ root đọc được trên VPS đều có
  thể lộ. Token có quyền sửa zone (SSL, cache, DNS) mà nằm trên VPS thì kẻ tấn công đổi được DNS
  (chuyển hướng cả domain) hoặc tắt HTTPS.
- Việc audit / tune Cloudflare là việc **thỉnh thoảng**, do agent làm theo phiên. Không cần quyền đó
  thường trực trên server.
- Trên VPS chỉ để **token riêng, quyền tối thiểu** cho việc panel tự làm hằng ngày:

| Token trên VPS (`/etc/cecp-panel/credentials.env`) | Quyền | Khi nào cần |
|---|---|---|
| Bắt buộc nếu dùng auto-purge | Zone → **Cache Purge → Purge** | `cf purge`, `cache auto-purge` (xoá cache edge khi sửa bài) |
| Chỉ khi cấp SSL bằng DNS-01 | + Zone → **DNS → Edit** | `ssl issue --dns`, `ssl issue --wildcard`, gia hạn certbot DNS-01 |

Không đặt token "Zone Settings Edit / Cache Rules Edit" của agent lên VPS. Các lệnh `cecp-panel cf
brotli|cache-level|edge-cache` và `dns ssl-mode` trên VPS chỉ dùng khi chủ VPS chủ động cấp thêm quyền.

---

## 2. Hai mức token cho agent

| Mức | Quyền (Permissions) | Agent làm được |
|---|---|---|
| **A — chỉ đọc (audit)** | Zone → **Zone → Read**; Zone → **Zone Settings → Read**; Zone → **Cache Rules → Read**; Zone → **DNS → Read** | `verify`, `zones`, `audit`, `snapshot` |
| **B — thay đổi** | Mức A **+** Zone → **Zone Settings → Edit**; Zone → **Cache Rules → Edit** | thêm `apply --ssl-strict / --brotli / --cache-level / --static-cache-rules / --html-cache`, `rollback` |

- Mặc định giao **mức A**. Chỉ tạo mức B khi đã có kế hoạch thay đổi được chủ site đồng ý, và thu hồi
  ngay sau khi xong.
- **DNS → Edit** không nằm trong cả hai mức. Chỉ thêm khi chủ domain yêu cầu một thay đổi DNS cụ thể
  (vd. bật proxy cho một bản ghi: `apply DOMAIN --proxy-record FQDN --allow-dns`).
- Không dùng **Global API Key**. Không dùng token "Edit zone DNS" mẫu cho mọi zone.

---

## 3. Tạo token trong dashboard (từng bước)

1. Đăng nhập Cloudflare → góc phải trên: **My Profile** → **API Tokens** → **Create Token**.
2. Kéo xuống **Custom token** → **Get started**.
3. **Token name**: đặt rõ mục đích và hạn, vd. `agent-audit-khachhang.vn-2026-10`.
4. **Permissions**: thêm từng dòng theo bảng mục 2 (chọn `Zone` → nhóm quyền → `Read` hoặc `Edit`).
5. **Zone Resources**: `Include` → `Specific zone` → chọn **đúng zone** cần làm (vd. `khachhang.vn`).
   Không chọn `All zones` nếu không thật sự cần.
6. **Client IP Address Filtering** (nên có): `Is in` → IP công khai của máy vận hành
   (xem bằng `curl -s https://ifconfig.me`). Token bị lộ cũng không dùng được từ nơi khác.
7. **TTL**: đặt **Start date** hôm nay và **End date** ngắn (vài ngày cho một đợt tune; tối đa vài tuần
   cho audit định kỳ).
8. **Continue to summary** → kiểm tra lại quyền và zone → **Create Token**.
9. Cloudflare hiện token **một lần duy nhất**. Copy vào nơi lưu ở mục 4 ngay, rồi đóng trang.

---

## 4. Lưu token ở đâu

Thứ tự ưu tiên của `cf-agent.sh`: biến môi trường `CF_API_TOKEN`, nếu không có thì đọc file trong
`CF_API_TOKEN_FILE`. **Không bao giờ** truyền token làm tham số dòng lệnh (công cụ từ chối `--token`).

**Cách 1 — biến môi trường cho một phiên shell:**

```bash
read -rs CF_API_TOKEN      # dán token, Enter (không hiện ra màn hình, không vào history)
export CF_API_TOKEN
tools/cf-agent.sh verify
# xong việc:
unset CF_API_TOKEN
```

**Cách 2 — file bí mật git-ignored** (máy agency có hub AI: theo `config/api-credentials.md` của hub,
file nằm trong thư mục `secrets/` đã bị git bỏ qua):

```bash
export CF_API_TOKEN_FILE=/đường/dẫn/secrets/cloudflare-agent-token.txt   # file chỉ chứa token, chmod 600
tools/cf-agent.sh verify
```

**Không bao giờ** để token ở: repo (kể cả commit rồi xoá), chat, prompt gửi AI, task/report của
agent, ticket, log, ảnh chụp màn hình, profile site `docs/sites/*.md`. Nghi lộ ⇒ **Roll** hoặc xoá
token trong dashboard ngay (mục 6).

---

## 5. Dùng `tools/cf-agent.sh`

Cần `bash`, `curl`, `python3`. Token đi vào curl qua cấu hình trên stdin (`curl -K -`), không nằm
trong danh sách tiến trình, không bị in ra; thông báo lỗi tự che token.

```bash
D=shop.khachhang.vn
tools/cf-agent.sh verify                 # token còn hiệu lực + nhóm quyền nhìn thấy được
tools/cf-agent.sh zones                  # zone mà token thấy
tools/cf-agent.sh audit "$D"             # chỉ đọc; --json cho máy đọc
tools/cf-agent.sh snapshot "$D"          # lưu ./cf-snapshots/<zone>-<thời gian>.json (thư mục 700, git-ignored)
```

`audit` báo: zone, bản ghi A/AAAA/CNAME và trạng thái proxy, SSL mode, Always Use HTTPS, Brotli,
Cache Level, Cache Rules, số WAF custom rule. **FAIL** khi SSL mode là `off`/`flexible`; **WARN** khi
bản ghi web chưa proxy, `full` thay vì `strict`, Brotli tắt, hoặc Cache Rule cache mà không bỏ qua
đăng nhập/giỏ hàng.

**Thay đổi** (cần token mức B; mỗi lệnh tự snapshot trước và in trước → sau):

```bash
tools/cf-agent.sh apply "$D" --ssl-strict --yes-i-approved   # ⚠ áp cho CẢ ZONE — chỉ thêm cờ duyệt sau khi chủ site đồng ý
tools/cf-agent.sh apply "$D" --brotli --cache-level aggressive
tools/cf-agent.sh apply "$D" --static-cache-rules    # cache tĩnh (css/js/ảnh/font) theo host, 30 ngày tại edge
tools/cf-agent.sh rollback ./cf-snapshots/khachhang.vn-20261010T080000Z.json
```

**Hành động có cổng chặn** — bị từ chối (thoát mã khác 0, không gọi API ghi) nếu thiếu cờ xác nhận:

| Hành động | Lệnh | Điều kiện |
|---|---|---|
| Cache HTML tại edge | `apply "$D" --html-cache [--ttl 1h] --yes-i-approved` | Chủ site đã đồng ý; audit bypass OK. Quy tắc bỏ qua đăng nhập/giỏ hàng/admin **giống hệt** `cecp-panel cf edge-cache` (cùng mô tả `cecp-panel: DOMAIN`, nên `cf edge-cache DOMAIN off` trên VPS cũng tắt được nếu token VPS có Cache Rules Edit) |
| Ghi bản ghi DNS | `apply "$D" --proxy-record FQDN --allow-dns`; `rollback FILE --allow-dns` | Chủ domain đã đồng ý; token có DNS Edit |
| "Cache Everything" | không có | **Không bao giờ** — công cụ từ chối `--cache-everything` |

Lỗi `Authentication error` / `cannot read …` ⇒ token thiếu quyền hoặc sai zone: sửa token (mục 3),
không thử đường khác.

---

## 6. Sau khi xong việc — thu hồi

1. Dashboard → **My Profile** → **API Tokens** → token vừa dùng → **Delete** (hoặc để hết hạn nếu đã
   đặt End date ngắn và đó là token chỉ đọc).
2. `unset CF_API_TOKEN` trên máy vận hành; xoá file token nếu đã tạo riêng cho đợt này.
3. Giữ `cf-snapshots/` trên máy vận hành tới khi chắc không cần rollback (không commit; chứa IP origin).
4. Ghi vào profile site (`docs/sites/<domain>.md`): ngày, thay đổi, đường dẫn snapshot — **không** ghi token.
