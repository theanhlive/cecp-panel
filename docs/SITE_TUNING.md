# Tuning và chứng minh tải theo domain — runbook cho AI Agent

Tài liệu này là **một nguồn duy nhất** để agent (hoặc người vận hành) tune an toàn **một domain cụ thể** trên VPS CECP Panel: đọc profile → audit → capacity → áp dụng **một** thay đổi → audit lại → loadtest → rollback nếu FAIL. Mọi lệnh dưới đây là `cecp-panel` (root), trừ khi ghi rõ chạy trên máy khác.

Profile theo domain (không chứa bí mật): [docs/sites/README.md](sites/README.md), mẫu [docs/sites/_TEMPLATE.md](sites/_TEMPLATE.md).

---

## 0. Phạm vi và giới hạn thật

| Cấu hình VPS (ví dụ) | Ý nghĩa thực tế |
|---|---|
| **1 vCPU / 1 GB RAM / 25 GB disk** | Chỉ kỳ vọng **~800–1000 concurrent** cho **traffic cache được / tĩnh** (GET trang chủ, bài viết, asset) sau khi FastCGI cache + Cloudflare hoạt động đúng. |
| **Login, giỏ hàng, checkout, API động, admin** | **Không** suy ra từ con số trên. Phải đo bằng `optimize capacity` (ngân sách PHP/RAM) và loadtest profile phù hợp (`mixed`, `login-api`). |
| **Nhiều site trên một VPS** | `pm.max_children` chia theo số site; một site tune tăng pool có thể ảnh hưởng site khác — ghi vào profile và hỏi chủ VPS nếu tổng RAM vượt WARN. |

Agent **không** thay DNS, **không** bật cache HTML rộng (Cache Everything), **không** xóa backup/site, **không** in token/mật khẩu vào log hay commit.

---

## 1. Vòng lặp agent (thứ tự bắt buộc)

Thay `DOMAIN` bằng FQDN (vd. `shop.khachhang.vn`). Trước mọi thay đổi cấu hình: đọc/cập nhật profile `docs/sites/<domain>.md` (file local trên máy agency, **không** commit — xem `.gitignore`).

### 1.1 Chuẩn bị

```bash
D=shop.khachhang.vn
cecp-panel status
cecp-panel security check    # không tune nếu FAIL nghiêm trọng chưa xử lý
```

### 1.2 Chỉ đọc — baseline

```bash
cecp-panel optimize audit "$D"
cecp-panel optimize audit "$D" --json > "/tmp/audit-${D}-before.json"
cecp-panel optimize capacity
cecp-panel optimize capacity --json > "/tmp/capacity-before.json"
cecp-panel optimize report "$D"    # tùy chọn: báo cáo tóm tắt hiện trạng
```

- Audit có dòng `FAIL` → **dừng tune**, sửa FAIL trước (HTTPS, cache bypass, v.v.).
- Ghi số liệu baseline vào profile (mục *Baseline numbers*).

### 1.3 Một thay đổi duy nhất (chọn **một** nhóm)

Panel tự snapshot trước khi ghi `/etc` (rollback). **Không** chạy hai lệnh ghi cấu hình trong cùng một vòng.

| Mục tiêu | Lệnh (một trong các lệnh sau) | Ghi chú |
|---|---|---|
| TTL cache origin | `cecp-panel cache ttl "$D" 1h` | Chỉ sau khi audit bypass đúng |
| Tối ưu stack site | `cecp-panel optimize site "$D"` | Redis WP, purge, v.v. theo panel |
| PHP pool | `cecp-panel php config "$D" pm_max_children=N` | N từ `optimize capacity`, không vượt WARN |
| MariaDB / OPcache / nginx toàn VPS | `cecp-panel optimize mariadb` hoặc `optimize opcache` hoặc `optimize nginx` | Ảnh hưởng mọi site — **[HỎI NGƯỜI]** |
| Swap | `cecp-panel system ensure-swap` hoặc `system swap` | Chỉ khi capacity báo thiếu swap |
| Cloudflare edge | `cecp-panel cf brotli on "$D"` / `cf cache-level aggressive "$D"` / `cf edge-cache "$D" on --ttl 1h` | Cần token + approval (mục 4) |

Sau thay đổi:

```bash
cecp-panel optimize audit "$D"
cecp-panel cache purge "$D"    # nếu đổi TTL/cache
# ghi snapshot id / giá trị mới vào profile (Rollback ID, Current values)
```

### 1.4 Loadtest — máy khác + monitor trên VPS

**Plan** (trên VPS, tạo script k6; chạy k6 trên máy **KHÁC**):

```bash
cecp-panel optimize loadtest plan "$D" --profile cached --max-vus 300
# in ra lệnh: k6 run -e BASE_URL=...  → chạy lệnh đó trên máy load (không phải VPS)
```

Profile khác:

- `mixed` — thêm GET REST công khai.
- `login-api` — cần `TEST_USER` / `TEST_PASS` qua `__ENV` khi chạy k6 (không ghi vào file script).

**Monitor** (trên VPS, trong lúc k6 chạy):

```bash
cecp-panel optimize loadtest monitor "$D" --duration 900 --interval 5
```

Ghi kết quả PASS / FAIL / INCONCLUSIVE và đường dẫn CSV vào profile (*Last loadtest result*). INCONCLUSIVE nghĩa là chưa đo được gì đáng tin (không có yêu cầu, quá ít lần đo, hoặc dừng giữa chừng): chạy lại với traffic thật, không ghi là PASS.

### 1.5 Rollback khi FAIL

```bash
cecp-panel optimize rollback list
cecp-panel optimize rollback latest    # hoặc ID cụ thể từ list
cecp-panel optimize audit "$D"
```

Chạy lại monitor ngắn nếu cần xác nhận hồi phục.

### 1.6 Probe trang không cache — **bắt buộc** sau mỗi lần nâng cấp panel và mỗi lần cập nhật WordPress/plugin

Trang chủ thường đến từ page cache, nên kiểm tra "trang chủ trả 200" **không** chứng minh site còn chạy.
Sự cố thật: sau khi nâng cấp 1.12, template pool tắt `putenv`; WooCommerce 6.2.2 gọi `putenv`, mọi trang
không cache trả HTTP 500 suốt 4 ngày trong khi trang chủ vẫn 200. Lệnh dưới chỉ đọc (không ghi, không
restart, không purge), gọi `127.0.0.1` với Host của site:

```bash
cecp-panel site probe "$D"      # hoặc: cecp-panel site probe --all
```

- Với WordPress: `/wp-login.php`, `/wp-json/` và `/?cecp_probe=<ngẫu nhiên>`; site khác: chỉ URL có query.
  Mỗi dòng `PASS|WARN|FAIL domain path HTTP mã`; HTTP >= 500 là FAIL, thoát mã 2.
- Khi FAIL, lệnh đọc 200 dòng cuối log lỗi nginx và log PHP-FPM, tìm `Call to undefined function NAME()` /
  `has been disabled for security reasons` rồi in cách sửa. Với `putenv`:
  `cecp-panel php config "$D" allow_putenv=on` — việc này mở lại đường LD_PRELOAD cho site đó, nên cập nhật
  plugin gọi `putenv` là cách ưu tiên; chỉ bật khi chưa cập nhật được.
- `cecp-panel update panel`, `site rebuild-vhost --all` và `security apply-production` tự chạy bản tóm tắt
  ("Probe: N site(s) OK" hoặc các dòng FAIL) ở cuối, **không** làm hỏng hay rollback việc nâng cấp. Sau
  cập nhật WordPress/plugin (`wp update`, `update all`) vẫn phải chạy `site probe` bằng tay.
- `cecp-panel security check` cũng đếm `PHP Fatal error` trong 24 giờ qua của từng site.
- Chưa probe = chưa xong nâng cấp; ghi kết quả vào profile site.

---

## 2. Bảng quyết định theo loại site

| Loại site | Cache được (GET, guest) | **Bắt buộc bypass** (không cache edge/HTML origin cho request này) |
|---|---|---|
| Landing / brochure | Trang tĩnh, asset | `wp-admin`, `wp-login.php`, cookie đăng nhập |
| WooCommerce | Trang sản phẩm, blog guest | `woocommerce_items_in_cart`, cart, checkout, `my-account`, admin/login |
| Membership / login | Trang marketing guest | `wordpress_logged_in_*`, mọi trang sau login, admin |
| API-heavy | Asset, một số GET REST công khai | POST/PUT/DELETE; `/wp-json/` **đã xác thực**; endpoint custom có session |

Cookie/rule bypass panel audit kiểm tra (ví dụ): logged-in cookie, `/wp-admin/`, `/wp-login.php`. Woo: giỏ hàng và luồng thanh toán **không** được cache.

Audit chỉ chạy các kiểm tra bypass **sau khi** trang chủ đã vào cache (HIT). Nếu chưa HIT, các dòng bypass là `WARN bypass chưa kiểm chứng được (trang chưa vào cache)`, không phải PASS: một bypass hỏng chỉ lộ ra khi trang đã được cache.

**REST đã xác thực (`/wp-json/`)**: micro-cache của origin (nginx) bypass theo **cookie** (`wordpress_logged_in_*`, `woocommerce_*`, …), **không** bypass theo header `Authorization`. Một request API có `Authorization: Basic` vì vậy đi qua cache, và chỉ an toàn khi WordPress trả `Cache-Control: no-store` (hoặc `private`/`no-cache`) cho REST đã đăng nhập. Trước khi chạy profile `login-api`, kiểm tra không cookie: gửi request có header `Authorization` **không kèm cookie**, rồi đọc `Cache-Control` (phải có `no-store`/`private`/`no-cache`) và `X-CECP-Cache` (không được `HIT`). Không đạt thì **không** chạy `login-api`. Đặt header xác thực từ biến môi trường hoặc tệp `curl -K`, không gõ mật khẩu vào dòng lệnh.

---

## 3. Ngưỡng PASS / FAIL (loadtest + audit)

### 3.1 k6 thresholds (trong script k6 do `plan` tạo — k6 tự đánh giá)

| Kiểm tra | PASS | FAIL → rollback + báo chủ VPS |
|---|---|---|
| Tỷ lệ lỗi HTTP (`http_req_failed`) | **< 1 %** | ≥ 1 % |
| p95 trang nhẹ (`http_req_duration`, cached GET) | **< 1000 ms** | ≥ 1000 ms kéo dài |

### 3.2 Monitor verdict (`optimize loadtest monitor`, chạy trên VPS)

| Kiểm tra | PASS | FAIL → rollback + báo chủ VPS | INCONCLUSIVE (exit 3, không bao giờ là PASS) |
|---|---|---|---|
| OOM | Không có dòng OOM | OOM killer: `Out of memory`, `oom-kill`, `oomd`, `Killed process` (`journalctl -k`) | `OOM check unavailable` = journald không dùng được (journalctl thiếu hoặc lỗi, exit ≠ 0 và ≠ 1) — **không** có nghĩa là "không có OOM". Không có dòng nào khớp (journalctl exit 1) là bình thường, vẫn PASS. |
| 5xx | < 1 % yêu cầu | ≥ 1 % yêu cầu | — |
| Pool bão hoà | Không có `server reached pm.max_children` trong `[pool <pool của site>]` | Có (chỉ pool của site này được tính) | — |
| Swap-in | Không có cửa sổ nào (≥ 3 lần đo, ≥ 15 s) mà trung bình ≥ 100 trang/s **và** có swap-in ở ≥ 3 lần đo đó | Có cửa sổ như trên: swap kéo dài ≥ 100 trang/s (≈ 400 KB/s) | — (pico ngắn vượt 100 trang/s chỉ in ghi chú, không FAIL) |
| Số lần đo | — | — | < 6 lần đo |
| Traffic | — | — | 0 yêu cầu trong access log, 0 lần đo, hoặc dừng bằng Ctrl-C |

Ghi chú:

- Số liệu 5xx và cache HIT lấy từ access log chỉ gồm yêu cầu **động/HTML**: các location tĩnh (`.css`, `.js`, ảnh, font) có `access_log off`, nên không được đếm.
- Một lần đo swap-in đơn lẻ (pico ngắn, ví dụ php-fpm worker idle được page in một lượt) không đủ để FAIL: cần tốc độ trung bình ≥ 100 trang/s trong cửa sổ ≥ 15 s **và** swap-in xuất hiện ở ≥ 3 lần đo — tức swap kéo dài, không phải pico ngắn.
- Exit code: PASS 0 · FAIL 2 · INCONCLUSIVE 3. INCONCLUSIVE nghĩa là chạy lại có traffic thật, không được coi là đạt.

### 3.3 Audit sau tune

| Kiểm tra | PASS | FAIL |
|---|---|---|
| `optimize audit` | Không `FAIL` mới | Bất kỳ `FAIL` mới so với baseline |

---

## 4. Cloudflare (Free) — lệnh `cecp-panel cf`

Tham chiếu DNS/SSL đầy đủ: [CLOUDFLARE_DNS.md](CLOUDFLARE_DNS.md). Token: `/etc/cecp-panel/credentials.env` — **không** log.

Agent audit / đổi Cloudflare **từ máy vận hành** (token không đặt lên VPS): `tools/cf-agent.sh audit|snapshot|apply|rollback` — tạo và giao token theo [CLOUDFLARE_AGENT_TOKEN.md](CLOUDFLARE_AGENT_TOKEN.md). Cache HTML cần `--yes-i-approved`, ghi DNS cần `--allow-dns`.

| Việc | Lệnh | Approval |
|---|---|---|
| SSL zone | `cecp-panel dns ssl-mode full DOMAIN` | **[HỎI NGƯỜI]** — áp **cả zone** |
| Brotli | `cecp-panel cf brotli on DOMAIN` | Token CF + chủ VPS |
| Cache level | `cecp-panel cf cache-level aggressive DOMAIN` (hoặc theo recommend) | Token CF |
| HTML edge (logged-out GET) | `cecp-panel cf edge-cache DOMAIN on --ttl 1h` | **[HỎI NGƯỜI]** — chỉ sau audit bypass OK |
| **Cấm** | Cache Everything, cache POST, cache checkout/cart | — |
| Khoá IP gốc | `cecp-panel security cf-only on` | **[HỎI NGƯỜI]** — mọi site phải proxied; `--force` rất nguy hiểm |

Không đổi bản ghi DNS trừ khi runbook Cloudflare và chủ VPS yêu cầu.

---

## 5. Cổng phê duyệt và hành vi cấm

**[HỎI NGƯỜI]** trước khi:

- Bật `cf edge-cache`, đổi `dns ssl-mode`, bật `security cf-only on`
- `optimize nginx` / `optimize mariadb` / `optimize opcache` (toàn VPS)
- Tăng `pm.max_children` vượt mức WARN của `optimize capacity`

**Cấm:**

- Đổi DNS, xóa site/backup, `backup prune`, `site remove`
- Nhiều thay đổi cấu hình trong một vòng không rollback giữa chừng
- Ghi API token / mật khẩu vào profile, chat, hoặc ticket

**Bắt buộc ghi nhận** (trong profile site):

- Trước/sau: TTL, `pm.max_children`, snapshot rollback id, kết quả audit & loadtest
- *Open risks* nếu còn WARN

---

## 6. Tài liệu liên quan

- Hack / nhiễm: [INCIDENT_RESPONSE.md](INCIDENT_RESPONSE.md) — quét trước khi tune mạnh
- Cloudflare DNS: [CLOUDFLARE_DNS.md](CLOUDFLARE_DNS.md)
- Token Cloudflare cho agent (máy vận hành, `tools/cf-agent.sh`): [CLOUDFLARE_AGENT_TOKEN.md](CLOUDFLARE_AGENT_TOKEN.md)
- Ảnh media: [MEDIA_OPTIMIZE.md](MEDIA_OPTIMIZE.md) (tách khỏi tune HTTP)
