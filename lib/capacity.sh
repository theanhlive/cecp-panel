#!/usr/bin/env bash
# Read-only facts before tuning anything:
#   cecp-panel optimize capacity [--json]      — RAM budget vs PHP-FPM pools, rough throughput
#   cecp-panel optimize audit DOMAIN [--json]  — HTTPS, caching, bypass, OPcache, Redis, Cloudflare
# Nothing here writes config, reloads/restarts a service or purges a cache. The audit's two
# page-cache probes use a unique query string, so they add one cache entry (like any visitor).
# The audit is fully read-only, with no exception: it never bootstraps WordPress (a plugin could write
# the database on load), so the Redis check is the drop-in file plus a bounded `redis-cli ping`.
set -euo pipefail

# Parallel dynamic requests one vCPU serves in the throughput estimate: a PHP request is part
# CPU, part waiting on MariaDB/I/O. The req/s figure is capped at min(workers, vCPU × this).
CAPACITY_REQ_PER_VCPU=2

# MB per PHP worker when none is running (pm = ondemand) — the figure php_pool_max_children uses.
CAPACITY_WORKER_MB_DEFAULT=60
CAPACITY_LOG_LINES=5000
CAPACITY_AUDIT_LEVEL=()
CAPACITY_AUDIT_NAME=()
CAPACITY_AUDIT_DETAIL=()

# cecp-panel optimize capacity [--json]
optimize_capacity() {
  local json=0 arg panel_budget
  for arg in "$@"; do
    case "$arg" in
      --json) json=1 ;;
      *) panel_die "Usage: cecp-panel optimize capacity [--json]" ;;
    esac
  done
  panel_budget="$(php_ram_budget_mb 2>/dev/null || echo 0)"
  python3 - "$json" "$SITES_DIR" "$FPM_ISOLATED_DIR" "$ETC_DIR" "$panel_budget" \
    "$CAPACITY_WORKER_MB_DEFAULT" "$CAPACITY_LOG_LINES" "$CAPACITY_REQ_PER_VCPU" <<'PY'
import glob, json, os, re, sys

sys.stdout.reconfigure(encoding="utf-8")
as_json = sys.argv[1] == "1"
sites_dir, iso_dir, etc_dir = sys.argv[2], sys.argv[3], sys.argv[4]
panel_budget = int(sys.argv[5]) if sys.argv[5].isdigit() else 0
default_worker = int(sys.argv[6])
log_lines = int(sys.argv[7])
req_per_vcpu = int(sys.argv[8])
HIT = {"HIT", "STALE", "UPDATING", "REVALIDATED"}


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def kb_field(text, key):
    m = re.search(r"^" + key + r":\s+(\d+)", text, re.M)
    return int(m.group(1)) if m else None


mem = {}
for line in read("/proc/meminfo").splitlines():
    k, _, v = line.partition(":")
    if v.split():
        mem[k] = int(v.split()[0]) // 1024
ram = mem.get("MemTotal", 0)
avail = mem.get("MemAvailable", mem.get("MemFree", 0))
swap_total = mem.get("SwapTotal", 0)
swap_used = max(0, swap_total - mem.get("SwapFree", 0))
try:
    vcpu = len(os.sched_getaffinity(0))
except (AttributeError, OSError):
    vcpu = os.cpu_count() or 1

# RSS counts shared pages (OPcache, libraries) once per process: pessimistic, the spec's per-worker
# figure. PSS splits shared pages between processes: the real total of a group.
groups = {k: {"count": 0, "rss_kb": 0, "pss_kb": 0}
          for k in ("php_fpm_workers", "php_fpm_masters", "mariadb", "redis", "nginx")}
pool_running = {}
pss_ok = True
for pid in os.listdir("/proc"):
    if not pid.isdigit():
        continue
    cmd = read(f"/proc/{pid}/cmdline").replace("\0", " ").strip()
    comm = read(f"/proc/{pid}/comm").strip()
    pool = None
    if cmd.startswith("php-fpm: pool "):
        key, pool = "php_fpm_workers", (cmd[len("php-fpm: pool "):].split() or [""])[0]
    elif cmd.startswith("php-fpm: master"):
        key = "php_fpm_masters"
    elif comm in ("mariadbd", "mysqld"):
        key = "mariadb"
    elif comm.startswith("redis-server"):
        key = "redis"
    elif comm == "nginx":
        key = "nginx"
    else:
        continue
    rss = kb_field(read(f"/proc/{pid}/status"), "VmRSS")
    if not rss:
        continue
    pss = kb_field(read(f"/proc/{pid}/smaps_rollup"), "Pss")
    if pss is None:
        pss_ok = False
        pss = rss
    g = groups[key]
    g["count"] += 1
    g["rss_kb"] += rss
    g["pss_kb"] += pss
    if pool is not None:
        pool_running[pool] = pool_running.get(pool, 0) + 1

procs = {}
for k, g in groups.items():
    n = g["count"]
    procs[k] = {
        "count": n,
        "rss_mb": round(g["rss_kb"] / 1024),
        "pss_mb": round(g["pss_kb"] / 1024),
        "avg_rss_mb": round(g["rss_kb"] / 1024 / n, 1) if n else 0.0,
        "avg_pss_mb": round(g["pss_kb"] / 1024 / n, 1) if n else 0.0,
    }

db_conf = 0
for cnf in ("/etc/my.cnf.d/cecp-tune.cnf", "/etc/mysql/mariadb.conf.d/99-cecp-tune.cnf",
            "/etc/mysql/conf.d/cecp-tune.cnf"):
    t = read(cnf)
    if not t:
        continue
    m = re.search(r"^\s*innodb_buffer_pool_size\s*=\s*(\d+)\s*([KMG]?)", t, re.M | re.I)
    if m:
        n, unit = int(m.group(1)), m.group(2).upper()
        db_conf = {"G": n * 1024, "M": n, "K": n // 1024}.get(unit, n // 1048576)
    break
m = re.search(r"^REDIS_MAXMEMORY_MB=(\d+)$", read(os.path.join(etc_dir, "redis.env")), re.M)
redis_conf = int(m.group(1)) if m else 0

pools, seen = [], set()
for pat in ("/etc/php-fpm.d/cecp-*.conf", "/etc/opt/remi/php*/php-fpm.d/cecp-*.conf",
            os.path.join(iso_dir, "*.pool.conf"), "/etc/php/*/fpm/pool.d/cecp-*.conf"):
    for path in sorted(glob.glob(pat)):
        if path in seen:
            continue
        seen.add(path)
        t = read(path)
        mc = re.search(r"^\s*pm\.max_children\s*=\s*(\d+)", t, re.M)
        if not mc:
            continue
        dom = re.search(r"^; CECP Panel pool — (\S+)", t, re.M)
        name = re.search(r"^\[([^\]]+)\]", t, re.M)
        pool = name.group(1) if name else ""
        pools.append({"domain": dom.group(1) if dom else pool, "pool": pool,
                      "max_children": int(mc.group(1)),
                      "running_workers": pool_running.get(pool, 0), "file": path})

workers = procs["php_fpm_workers"]
masters_mb = procs["php_fpm_masters"]["pss_mb"]
db_mb = max(procs["mariadb"]["pss_mb"], db_conf)
redis_mb = max(procs["redis"]["pss_mb"], redis_conf)
nginx_mb = procs["nginx"]["pss_mb"]
tracked = workers["pss_mb"] + masters_mb + procs["mariadb"]["pss_mb"] + procs["redis"]["pss_mb"] + nginx_mb
os_mb = max(250, (ram - avail) - tracked)
budget = max(0, ram - db_mb - redis_mb - nginx_mb - masters_mb - os_mb)
measured = workers["count"] > 0
# Verdicts use the PSS average: shared pages (OPcache, libraries) are split between the workers,
# which is the real memory a worker costs. RSS counts them in every worker: pessimistic, WARN only.
worker_rss_mb = workers["avg_rss_mb"] if measured else float(default_worker)
worker_mb = (workers["avg_pss_mb"] if pss_ok else workers["avg_rss_mb"]) if measured else float(default_worker)
metric = ("PSS" if pss_ok else "RSS") if measured else "ước lượng"
safe_max = int(budget // worker_mb) if worker_mb > 0 else 0
sum_children = sum(p["max_children"] for p in pools)
need_mb = round(sum_children * worker_mb)
need_rss_mb = round(sum_children * worker_rss_mb)
concurrent = min(sum_children, safe_max) if sum_children else safe_max


def tail(path, n):
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - n * 512))
            return f.read().decode("utf-8", "replace").splitlines()[-n:]
    except OSError:
        return []


rt_re = re.compile(r" rt=(\d+(?:\.\d+)?) cs=(\S+)$")
uncached, bypass_rt, logged, dynamic, hits = [], [], 0, 0, 0
for meta in sorted(glob.glob(os.path.join(sites_dir, "*.json"))):
    try:
        dom = json.loads(read(meta)).get("domain", "")
    except ValueError:
        continue
    if not re.fullmatch(r"[a-z0-9.-]+", dom or ""):
        continue
    for line in tail(f"/var/log/nginx/{dom}-access.log", log_lines):
        m = rt_re.search(line.rstrip())
        if not m:
            continue
        logged += 1
        cs = m.group(2)
        if cs == "-":
            continue
        dynamic += 1
        if cs in HIT:
            hits += 1
        elif cs == "BYPASS":
            # Logged-in, cart and admin requests always run PHP: kept apart from the MISS/EXPIRED rate.
            bypass_rt.append(float(m.group(1)))
        else:
            uncached.append(float(m.group(1)))


def pct(vals, p):
    vals = sorted(vals)
    return vals[min(len(vals) - 1, int(round(p / 100 * (len(vals) - 1))))]


p50 = pct(uncached, 50) if uncached else None
p95 = pct(uncached, 95) if uncached else None
# Throughput estimate: concurrency capped by the vCPUs (a request also needs CPU, not only a
# worker slot). Rough by design: MISS/EXPIRED latencies only, BYPASS requests excluded.
conc_cpu = min(concurrent, vcpu * req_per_vcpu) if concurrent else 0
rps50 = round(conc_cpu / max(p50, 0.001), 1) if p50 is not None and conc_cpu else None
rps95 = round(conc_cpu / max(p95, 0.001), 1) if p95 is not None and conc_cpu else None

verdicts, notes = [], []


def verdict(level, name, detail):
    verdicts.append({"level": level, "name": name, "detail": detail})


physical = ram - db_mb - redis_mb
calc = f"tổng pm.max_children {sum_children} × {worker_mb:.0f} MB ({metric}) = {need_mb} MB"
if not pools:
    verdict("WARN", "php_ram", "không tìm thấy pool PHP-FPM nào của panel")
elif need_mb > physical:
    verdict("FAIL", "php_ram", f"{calc} > RAM còn lại sau MariaDB/Redis ({physical} MB): các site cùng bận sẽ hết RAM (OOM) — giảm pm_max_children, tối đa an toàn ≈ {safe_max}")
elif need_mb > budget:
    verdict("WARN", "php_ram", f"{calc} > ngân sách PHP {budget} MB — giảm pm_max_children hoặc tăng RAM, tối đa an toàn ≈ {safe_max}")
elif measured and need_rss_mb > budget:
    verdict("WARN", "php_ram", f"{calc} ≤ ngân sách PHP {budget} MB; theo RSS (bi quan, đếm cả trang dùng chung) {need_rss_mb} MB > ngân sách — xác nhận bằng loadtest")
else:
    verdict("OK", "php_ram", f"{calc} ≤ ngân sách PHP {budget} MB")
if swap_used > 0:
    verdict("WARN", "swap", f"đang dùng swap {swap_used}/{swap_total} MB — RAM đã từng không đủ")
elif swap_total == 0 and ram <= 2048:
    verdict("WARN", "swap", "không có swap trên máy ≤ 2 GB RAM — cecp-panel system ensure-swap")
else:
    verdict("OK", "swap", f"không dùng swap ({swap_total} MB sẵn có)")
if avail < max(64, ram * 5 // 100):
    verdict("FAIL", "ram_available", f"RAM còn trống {avail}/{ram} MB (< 5%)")
else:
    verdict("OK", "ram_available", f"RAM còn trống {avail}/{ram} MB")

if not measured:
    notes.append(f"Chưa có worker PHP nào đang chạy (pm = ondemand): dùng ước lượng {default_worker} MB/worker.")
elif worker_mb < default_worker:
    notes.append(f"Worker đang rảnh nhỏ hơn lúc bận: với {default_worker} MB/worker (mức panel dùng để đặt pm.max_children) "
                 f"tổng cần {sum_children * default_worker} MB, tối đa an toàn ≈ {budget // default_worker}.")
notes.append("Trang đã có trong FastCGI cache do nginx trả thẳng, không tốn worker PHP: các con số trên chỉ giới hạn yêu cầu động (đăng nhập, giỏ hàng, admin, cache MISS). Thông lượng là ước lượng thô.")
if ram <= 1100:
    notes.append(f"RAM ≤ 1 GB: khoảng 1000 người truy cập cùng lúc chỉ chịu được khi gần như toàn bộ là trang đã cache hoặc tệp tĩnh (FastCGI cache / Cloudflare). Truy cập động chỉ xử lý được khoảng {concurrent} yêu cầu cùng lúc.")

if as_json:
    print(json.dumps({
        "ram_mb": ram, "ram_available_mb": avail, "swap_total_mb": swap_total,
        "swap_used_mb": swap_used, "vcpu": vcpu,
        "memory_metric_totals": "pss" if pss_ok else "rss",
        "processes": procs,
        "config": {"innodb_buffer_pool_mb": db_conf, "redis_maxmemory_mb": redis_conf},
        "budget": {"php_mb": budget, "mariadb_mb": db_mb, "redis_mb": redis_mb, "nginx_mb": nginx_mb,
                   "php_masters_mb": masters_mb, "os_other_mb": os_mb, "panel_formula_mb": panel_budget},
        "worker_mb": worker_mb, "worker_memory_metric": metric, "worker_rss_mb": worker_rss_mb,
        "worker_measured": measured,
        "pools": pools, "sum_max_children": sum_children, "safe_max_children": safe_max,
        "php_ram_needed_mb": need_mb, "concurrent_dynamic": concurrent,
        "log": {"requests": logged, "dynamic": dynamic, "cache_hits": hits, "uncached": len(uncached),
                "bypass": len(bypass_rt),
                "uncached_p50_ms": round(p50 * 1000, 1) if p50 is not None else None,
                "uncached_p95_ms": round(p95 * 1000, 1) if p95 is not None else None},
        "concurrency_cap_vcpu": conc_cpu, "req_per_vcpu": req_per_vcpu,
        "dynamic_req_per_sec_p50": rps50, "dynamic_req_per_sec_p95": rps95,
        "verdicts": verdicts, "notes": notes,
    }, ensure_ascii=False))
    sys.exit(0)

out = ["=== Sức chứa máy chủ (chỉ đọc) ===",
       f"  RAM {ram} MB (còn trống {avail} MB) · swap {swap_used}/{swap_total} MB · vCPU {vcpu}",
       "  Bộ nhớ tiến trình (RSS trung bình mỗi tiến trình / tổng PSS của nhóm):"]
labels = {"php_fpm_workers": "php-fpm worker", "php_fpm_masters": "php-fpm master",
          "mariadb": "MariaDB", "redis": "Redis", "nginx": "nginx"}
for k, label in labels.items():
    p = procs[k]
    out.append(f"    {label:15} {p['count']:3} tiến trình · RSS TB {p['avg_rss_mb']:7.1f} MB · tổng PSS {p['pss_mb']} MB")
out.append(f"  Ngân sách RAM cho PHP: {budget} MB = RAM {ram} − MariaDB {db_mb} − Redis {redis_mb} − nginx {nginx_mb}"
           f" − php-fpm master {masters_mb} − hệ điều hành/khác {os_mb}")
out.append(f"    (MariaDB = max(đo được, innodb_buffer_pool {db_conf} MB); Redis = max(đo được, maxmemory {redis_conf} MB);"
           f" công thức panel khi đặt pm.max_children tự động: {panel_budget} MB)")
out.append("  Pool PHP-FPM của panel:")
for p in pools:
    out.append(f"    {p['domain']:40} pm.max_children={p['max_children']:<3} đang chạy {p['running_workers']}")
if not pools:
    out.append("    (không có)")
src = f"đo từ {workers['count']} worker" if measured else "ước lượng — chưa có worker nào chạy"
out.append(f"  Bộ nhớ mỗi worker PHP dùng để đánh giá: {worker_mb:.1f} MB {metric} ({src}); RSS TB {worker_rss_mb:.1f} MB")
out.append(f"  {calc} · tối đa an toàn ≈ {safe_max} worker ({budget} MB / {worker_mb:.0f} MB)")
out.append(f"  Yêu cầu động xử lý đồng thời (ước tính): {concurrent}; trần theo vCPU ({vcpu} × {req_per_vcpu}): {conc_cpu}")
if uncached:
    out.append(f"  Thời gian xử lý yêu cầu MISS/EXPIRED ({len(uncached)} dòng log): p50 {p50 * 1000:.0f} ms · p95 {p95 * 1000:.0f} ms")
    if rps50 is not None:
        out.append(f"  Thông lượng động ước lượng (trần vCPU, không tính BYPASS): ≈ {rps50} req/s (theo p50) · ≈ {rps95} req/s (theo p95)")
else:
    out.append("  Thông lượng động: chưa có số liệu rt= trong log (định dạng log cecp: cecp-panel site rebuild-vhost --all)")
if dynamic:
    out.append(f"  Cache trong log: HIT {100 * hits / dynamic:.0f}% của {dynamic} yêu cầu động ({logged} dòng log)")
if bypass_rt:
    out.append(f"  BYPASS: {len(bypass_rt)} yêu cầu (đăng nhập/giỏ hàng/admin) — đếm riêng, không nằm trong thông lượng ở trên")
out.append("Kết luận:")
out += [f"{v['level']} {v['name']} — {v['detail']}" for v in verdicts]
out.append("Lưu ý:")
out += [f"  - {n}" for n in notes]
print("\n".join(out))
PY
}

# ---------------------------------------------------------------------------
# optimize audit
# ---------------------------------------------------------------------------
capacity_audit_add() {
  local detail="${3//$'\t'/ }"
  CAPACITY_AUDIT_LEVEL+=("$1")
  CAPACITY_AUDIT_NAME+=("$2")
  CAPACITY_AUDIT_DETAIL+=("${detail//$'\n'/ }")
}

# capacity_probe DOMAIN URL [CURL ARGS...] — response headers (CR stripped) of one local request:
# --resolve sends it to 127.0.0.1 with the site's Host and SNI. Empty when nothing answered.
capacity_probe() {
  local domain="$1" url="$2" port=80
  shift 2
  [[ "$url" == https://* ]] && port=443
  curl -s -k -o /dev/null -D - --max-time 20 --resolve "${domain}:${port}:127.0.0.1" \
    -A "CECP-Audit/${CECP_PANEL_VERSION}" "$@" "$url" 2>/dev/null | tr -d '\r' || true
}

capacity_hdr_status() { awk 'NR == 1 { print $2; exit }' <<<"$1"; }

capacity_hdr() {
  awk -v h="${2,,}" '{ n = index($0, ":"); if (n && tolower(substr($0, 1, n - 1)) == h) { v = substr($0, n + 1); sub(/^ +/, "", v) } } END { print v }' <<<"$1"
}

# Level|detail for a request that must never be answered from the page cache.
capacity_bypass_eval() {
  local st cs
  st="$(capacity_hdr_status "$1")"
  cs="$(capacity_hdr "$1" x-cecp-cache)"
  if [[ -z "$st" ]]; then
    echo "WARN|không có phản hồi"
    return 0
  fi
  # HTTP health first: a 5xx is a failure even when the cache header says BYPASS (or is absent).
  if [[ "$st" =~ ^5[0-9]{2}$ ]]; then
    echo "FAIL|HTTP $st — PHP trả lỗi máy chủ (cache ${cs:-không có}); cecp-panel site probe"
    return 0
  fi
  case "$cs" in
    "") echo "PASS|HTTP $st, không qua cache" ;;
    BYPASS) echo "PASS|HTTP $st, cache BYPASS" ;;
    HIT|STALE|UPDATING|REVALIDATED) echo "FAIL|HTTP $st, cache $cs — trang riêng tư đang được trả từ cache" ;;
    *) echo "WARN|HTTP $st, cache $cs — không HIT nhưng cũng không BYPASS (vhost cũ? cecp-panel site rebuild-vhost)" ;;
  esac
}

capacity_worse() {
  case "$1$2" in
    *FAIL*) echo FAIL ;;
    *WARN*) echo WARN ;;
    *) echo PASS ;;
  esac
}

# Level|detail of the page-cache hit ratio in the access log (run before the audit's own requests).
capacity_log_ratio() {
  local log="/var/log/nginx/${1}-access.log"
  if [[ ! -f "$log" ]]; then
    echo "WARN|chưa có access log ($log)"
    return 0
  fi
  tail -n "$CAPACITY_LOG_LINES" "$log" | python3 -c '
import re, sys
sys.stdin.reconfigure(encoding="utf-8", errors="replace")
sys.stdout.reconfigure(encoding="utf-8")
hit = {"HIT", "STALE", "UPDATING", "REVALIDATED"}
n = dyn = hits = byp = 0
for line in sys.stdin:
    m = re.search(r" rt=[0-9.]+ cs=(\S+)$", line.rstrip())
    if not m:
        continue
    n += 1
    cs = m.group(1)
    if cs == "-":
        continue
    dyn += 1
    if cs in hit:
        hits += 1
    elif cs == "BYPASS":
        byp += 1
cacheable = dyn - byp
if dyn < 20:
    print(f"WARN|chưa đủ dữ liệu: {dyn} yêu cầu động trong {n} dòng log định dạng cecp")
else:
    ratio = 100 * hits / cacheable if cacheable else 0.0
    level = "PASS" if ratio >= 50 else "WARN"
    print(f"{level}|HIT {ratio:.0f}% yêu cầu cache được ({hits}/{cacheable}); BYPASS {100 * byp / dyn:.0f}% của {dyn} yêu cầu động")
' || echo "WARN|không đọc được access log"
}

# Level|detail for OPcache of the site's PHP version (FPM binary first, CLI as fallback).
capacity_opcache() {
  local domain="$1" v bin out="" src="" en mem
  v="$(php_version_normalize "$(site_json_get_or "$domain" php_version 80)" 2>/dev/null)" || v=""
  if [[ -z "$v" ]]; then
    echo "WARN|phiên bản PHP của site không hợp lệ"
    return 0
  fi
  for bin in "$(limits_fpm_bin "$domain" 2>/dev/null || true)" "/usr/sbin/php-fpm${v:0:1}.${v:1}"; do
    [[ -n "$bin" && -x "$bin" ]] || continue
    out="$(timeout 20 "$bin" -i 2>/dev/null | grep -E '^opcache\.(enable|memory_consumption) =>' || true)"
    [[ -n "$out" ]] && { src="php-fpm"; break; }
  done
  if [[ -z "$out" ]]; then
    for bin in "/opt/remi/php${v}/root/usr/bin/php" "$(command -v "php${v:0:1}.${v:1}" 2>/dev/null || true)" \
               "$( [[ "$v" == 80 ]] && command -v php 2>/dev/null || true)"; do
      [[ -n "$bin" && -x "$bin" ]] || continue
      out="$(timeout 20 "$bin" -i 2>/dev/null | grep -E '^opcache\.(enable|memory_consumption) =>' || true)"
      [[ -n "$out" ]] && { src="php-cli"; break; }
      src="php-cli"
    done
  fi
  if [[ -z "$src" ]]; then
    echo "WARN|không tìm thấy PHP $v để kiểm tra"
    return 0
  fi
  en="$(awk -F' => ' '$1 == "opcache.enable" { print $2; exit }' <<<"$out")"
  mem="$(awk -F' => ' '$1 == "opcache.memory_consumption" { print $2; exit }' <<<"$out")"
  case "$en" in
    On|1) echo "PASS|bật (PHP $v, memory_consumption=${mem:-?}M, theo $src)" ;;
    "")
      # Only the CLI binary answered: it may not load the same extensions as php-fpm, so a missing
      # line here says nothing about the web workers.
      if [[ "$src" == php-cli ]]; then
        echo "WARN|không xác định (CLI): không thấy opcache trong PHP $v CLI, php-fpm không đọc được"
      else
        echo "FAIL|Zend OPcache chưa được nạp (PHP $v)"
      fi
      ;;
    *) echo "FAIL|opcache.enable=$en (PHP $v) — cecp-panel optimize opcache" ;;
  esac
}

# Level|detail for the Redis object cache of a WordPress site. Read-only: WordPress is never
# bootstrapped (a plugin could write the database on load), so this is the drop-in file plus a
# bounded `redis-cli ping` on the configured host/port. The password is never needed: an answer of
# PONG or NOAUTH both prove the server is reachable.
capacity_redis() {
  local domain="$1" docroot="$2" host port reply
  if [[ ! -f "$docroot/wp-content/object-cache.php" ]]; then
    echo "WARN|chưa bật Redis object cache — cecp-panel optimize redis-wp $domain"
    return 0
  fi
  if ! command -v redis-cli >/dev/null 2>&1; then
    echo "WARN|có drop-in object-cache.php nhưng không có redis-cli để kiểm tra — chưa xác minh end-to-end (audit không nạp WordPress)"
    return 0
  fi
  host="$(sed -nE 's/^REDIS_HOST=([A-Za-z0-9._-]+)$//p' "$ETC_DIR/redis.env" 2>/dev/null | head -n 1 || true)"
  port="$(sed -nE 's/^REDIS_PORT=([0-9]+)$//p' "$ETC_DIR/redis.env" 2>/dev/null | head -n 1 || true)"
  reply="$(timeout 2 redis-cli -h "${host:-127.0.0.1}" -p "${port:-6379}" ping 2>&1 || true)"
  if [[ "$reply" == PONG* || "$reply" == *NOAUTH* ]]; then
    echo "PASS|có drop-in object-cache.php và Redis ${host:-127.0.0.1}:${port:-6379} trả lời — chưa xác minh end-to-end (audit không nạp WordPress)"
  else
    echo "FAIL|có drop-in object-cache.php nhưng Redis ${host:-127.0.0.1}:${port:-6379} không trả lời (${reply:-hết thời gian 2 s}) — cecp-panel optimize redis-wp $domain"
  fi
}

# Level|detail for Cloudflare proxy + SSL mode. Runs in a subshell: credential errors exit it.
capacity_cf_check() {
  local domain="$1" https="$2" zone zid recs mode
  cf_load >/dev/null 2>&1
  zone="$(dns_find_zone "$domain" 2>/dev/null)" || zone=""
  if [[ -z "$zone" ]]; then
    echo "WARN|token Cloudflare không quản lý zone nào chứa $domain"
    return 0
  fi
  zid="$(dns_zone_id "$zone" 2>/dev/null)" || zid=""
  [[ -n "$zid" ]] || { echo "WARN|không đọc được zone $zone"; return 0; }
  recs="$(dns_cf_api GET "/zones/${zid}/dns_records?name=${domain}&per_page=50" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
if not d.get("success"):
    raise SystemExit(1)
r = [x for x in d.get("result") or [] if x.get("type") in ("A", "AAAA", "CNAME")]
print(" ".join(x["type"] + ":" + ("proxied" if x.get("proxied") else "dns-only") for x in r) or "none")
' 2>/dev/null)" || recs=""
  mode="$(dns_cf_api GET "/zones/${zid}/settings/ssl" 2>/dev/null | python3 -c '
import json, sys
print((json.load(sys.stdin).get("result") or {}).get("value", ""))
' 2>/dev/null)" || mode=""
  if [[ -z "$recs" ]]; then
    echo "WARN|không đọc được bản ghi DNS của $domain (zone $zone)"
  elif [[ "$recs" == none ]]; then
    echo "WARN|zone $zone không có bản ghi A/AAAA/CNAME cho $domain"
  elif [[ "$recs" == *dns-only* ]]; then
    echo "WARN|bản ghi DNS không bật proxy ($recs): lộ IP gốc, không có cache/nén ở biên; SSL mode ${mode:-?}"
  else
    case "$mode" in
      strict) echo "PASS|proxied ($recs), SSL mode Full (strict)" ;;
      full) echo "WARN|proxied, SSL mode Full — nên dùng Full (strict): cecp-panel dns ssl-mode strict" ;;
      flexible)
        if [[ "$https" == 1 ]]; then
          echo "FAIL|proxied, SSL mode Flexible trong khi origin chuyển hướng sang HTTPS — vòng lặp chuyển hướng; đổi sang Full (strict)"
        else
          echo "WARN|proxied, SSL mode Flexible — Cloudflare ↔ origin không mã hoá"
        fi
        ;;
      *) echo "WARN|proxied, SSL mode ${mode:-không đọc được}" ;;
    esac
  fi
}

# Every check of one panel site; results go into CAPACITY_AUDIT_*.
# Level|detail for an HTTP status seen from loopback. 5xx is a broken origin. 4xx other than 401 is
# usually the loopback request itself being blocked (WAF, allowlist, Cloudflare-only lock): no verdict
# on the site, so WARN, never FAIL.
capacity_code_eval() {
  local st="$1" ok="$2"
  if [[ "$st" =~ ^5 ]]; then
    echo "FAIL|HTTP $st từ loopback — origin lỗi máy chủ"
  elif [[ "$st" =~ ^4 && "$st" != 401 ]]; then
    echo "WARN|HTTP $st từ loopback — loopback bị chặn (WAF, allowlist hoặc cf-only?), không kết luận được"
  else
    echo "PASS|$ok"
  fi
}

capacity_audit_site() {
  local domain="$1" site_user docroot php_ver wp ssl is_wp=0 scheme=http https=0 base
  local ratio st hdrs ahdrs cc maxage enc_html enc_asset="" asset="" rel probe h1 h2 c1 c2 r lvl det
  local page_hit=0
  # Metadata read under set -e: a missing key is reported, not a reason to abort the audit.
  site_user="$(site_json_get "$domain" site_user 2>/dev/null || true)"
  docroot="$(site_json_get "$domain" docroot 2>/dev/null || true)"
  php_ver="$(site_json_get_or "$domain" php_version 80)"
  wp="$(site_json_get_or "$domain" wordpress false)"
  ssl="$(site_json_get_or "$domain" ssl false)"
  det="không"
  if [[ -z "$docroot" ]]; then
    capacity_audit_add WARN docroot "hồ sơ site không có docroot — bỏ qua tệp WordPress và tệp tĩnh"
  fi
  if [[ "$wp" == True || ( -n "$docroot" && -f "$docroot/wp-config.php" ) ]]; then
    is_wp=1
    det="có"
  fi
  capacity_audit_add PASS site "có trong panel (user ${site_user:-?}, PHP $php_ver, WordPress: $det)"
  # Before any probe: the audit's own requests must not count in the hit ratio.
  ratio="$(capacity_log_ratio "$domain")"

  if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" || "$ssl" == True ]]; then
    st="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 --resolve "${domain}:443:127.0.0.1" "https://${domain}/" 2>/dev/null || true)"
    if [[ -n "$st" && "$st" != 000 ]]; then
      r="$(capacity_code_eval "$st" "HTTPS trả HTTP $st, chứng chỉ hợp lệ")"
      capacity_audit_add "${r%%|*}" https "${r#*|}"
      scheme=https; https=1
    else
      st="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 --resolve "${domain}:443:127.0.0.1" "https://${domain}/" 2>/dev/null || true)"
      if [[ -n "$st" && "$st" != 000 ]]; then
        r="$(capacity_code_eval "$st" "")"
        lvl="${r%%|*}"
        [[ "$lvl" == PASS ]] && lvl=WARN
        capacity_audit_add "$lvl" https "HTTPS trả HTTP $st nhưng chứng chỉ không hợp lệ với $domain (tự ký/hết hạn?)"
        scheme=https; https=1
      else
        capacity_audit_add FAIL https "vhost không phục vụ HTTPS trên 127.0.0.1:443"
      fi
    fi
  else
    capacity_audit_add WARN https "chưa có HTTPS — cecp-panel ssl issue $domain"
  fi
  base="${scheme}://${domain}"

  hdrs="$(capacity_probe "$domain" "$base/" -H 'Accept-Encoding: br, gzip')"
  st="$(capacity_hdr_status "$hdrs")"
  enc_html="$(capacity_hdr "$hdrs" content-encoding)"

  for rel in wp-includes/css/dashicons.min.css wp-includes/js/jquery/jquery.min.js; do
    if [[ -n "$docroot" && -f "$docroot/$rel" ]]; then
      asset="$rel"
      break
    fi
  done
  if [[ -z "$asset" && -n "$docroot" && -d "$docroot" ]]; then
    asset="$(find "$docroot" -maxdepth 4 -type f \( -name '*.css' -o -name '*.js' \) -size +1k \
      -not -path '*/.*' -print -quit 2>/dev/null || true)"
    asset="${asset#"$docroot"/}"
  fi
  [[ "$asset" =~ ^[A-Za-z0-9._/-]+$ ]] || asset=""
  if [[ -z "$asset" ]]; then
    capacity_audit_add WARN static_cache "không tìm thấy tệp .css/.js trong docroot để thử"
  else
    ahdrs="$(capacity_probe "$domain" "$base/$asset" -H 'Accept-Encoding: br, gzip')"
    enc_asset="$(capacity_hdr "$ahdrs" content-encoding)"
    cc="$(capacity_hdr "$ahdrs" cache-control)"
    maxage=0
    [[ "$cc" =~ max-age=([0-9]+) ]] && maxage="${BASH_REMATCH[1]}"
    r="$(capacity_hdr_status "$ahdrs")"
    if [[ "$r" != 200 ]]; then
      capacity_audit_add WARN static_cache "/$asset trả HTTP ${r:-000}"
    elif (( 10#$maxage >= 604800 )); then
      capacity_audit_add PASS static_cache "/$asset: Cache-Control: $cc"
    elif (( 10#$maxage > 0 )); then
      capacity_audit_add WARN static_cache "/$asset: max-age=$maxage giây — nên ≥ 7 ngày"
    else
      capacity_audit_add WARN static_cache "/$asset: không có Cache-Control max-age"
    fi
  fi

  det="HTML: ${enc_html:-không nén} (HTTP ${st:-000}), tệp tĩnh: ${enc_asset:-không nén}"
  lvl=WARN
  if [[ "$st" == 200 ]]; then
    r="$enc_html"
  else
    r="$enc_asset"
  fi
  if [[ "$r" == br || "$r" == gzip ]]; then
    lvl=PASS
  fi
  capacity_audit_add "$lvl" compression "$det"

  if [[ "$st" == 401 ]]; then
    capacity_audit_add WARN page_cache "site bật basic auth (HTTP 401) — bỏ qua kiểm tra cache trang và bypass"
  else
    probe="$base/?cecp_audit=$(date +%s)${RANDOM}"
    h1="$(capacity_probe "$domain" "$probe")"
    h2="$(capacity_probe "$domain" "$probe")"
    c1="$(capacity_hdr "$h1" x-cecp-cache)"
    c2="$(capacity_hdr "$h2" x-cecp-cache)"
    r="$(capacity_hdr_status "$h2")"
    if [[ -z "$r" ]]; then
      capacity_audit_add FAIL page_cache "trang chủ không phản hồi"
    elif [[ "$r" =~ ^3 ]]; then
      capacity_audit_add WARN page_cache "trang chủ chuyển hướng (HTTP $r → $(capacity_hdr "$h2" location)) — kiểm tra trên URL đích"
    elif [[ ! "$r" =~ ^2 ]]; then
      if [[ "$r" =~ ^4 && "$r" != 401 ]]; then
        capacity_audit_add WARN page_cache "loopback bị chặn (HTTP $r) — không kiểm tra được cache trang từ 127.0.0.1"
      else
        capacity_audit_add FAIL page_cache "trang chủ trả HTTP $r"
      fi
    elif [[ "$c2" == HIT ]]; then
      capacity_audit_add PASS page_cache "${c1:--} → HIT"
      page_hit=1
    elif [[ -z "$c2" ]]; then
      capacity_audit_add WARN page_cache "không có header X-CECP-Cache (trang không chạy qua PHP?)"
    elif (( is_wp )); then
      capacity_audit_add FAIL page_cache "lần 1 ${c1:--}, lần 2 $c2 — trang không được cache (plugin gửi Set-Cookie hoặc Cache-Control: no-cache/private?)"
    else
      capacity_audit_add WARN page_cache "lần 1 ${c1:--}, lần 2 $c2 — trang không được cache"
    fi

    # A bypass verdict means something only if the page is cached: then a broken bypass would
    # answer HIT. Without a HIT the bypass checks are not run, and say so instead of a vacuous PASS.
    if (( page_hit )); then
      r="$(capacity_bypass_eval "$(capacity_probe "$domain" "$probe" -H 'Cookie: wordpress_logged_in_cecpaudit=1')")"
      capacity_audit_add "${r%%|*}" bypass_logged_in "cookie wordpress_logged_in_*: ${r#*|}"
      r="$(capacity_bypass_eval "$(capacity_probe "$domain" "$base/wp-admin/")")"
      capacity_audit_add "${r%%|*}" bypass_wp_admin "/wp-admin/: ${r#*|}"
      r="$(capacity_bypass_eval "$(capacity_probe "$domain" "$base/wp-login.php")")"
      capacity_audit_add "${r%%|*}" bypass_wp_login "/wp-login.php: ${r#*|}"
      if (( is_wp )) && [[ -n "$docroot" && -d "$docroot/wp-content/plugins/woocommerce" ]]; then
        h1="$(capacity_bypass_eval "$(capacity_probe "$domain" "$probe" -H 'Cookie: woocommerce_items_in_cart=1')")"
        h2="$(capacity_bypass_eval "$(capacity_probe "$domain" "$probe" -H 'Cookie: woocommerce_cart_hash=cecpaudit')")"
        lvl="$(capacity_worse "${h1%%|*}" "${h2%%|*}")"
        capacity_audit_add "$lvl" bypass_woocommerce "woocommerce_items_in_cart: ${h1#*|}; woocommerce_cart_hash: ${h2#*|}"
      fi
    else
      capacity_audit_add WARN bypass_logged_in "bypass chưa kiểm chứng được (trang chưa vào cache)"
      capacity_audit_add WARN bypass_wp_admin "bypass chưa kiểm chứng được (trang chưa vào cache)"
      capacity_audit_add WARN bypass_wp_login "bypass chưa kiểm chứng được (trang chưa vào cache)"
      if (( is_wp )) && [[ -n "$docroot" && -d "$docroot/wp-content/plugins/woocommerce" ]]; then
        capacity_audit_add WARN bypass_woocommerce "bypass chưa kiểm chứng được (trang chưa vào cache)"
      fi
    fi
  fi

  r="$(capacity_opcache "$domain")"
  capacity_audit_add "${r%%|*}" opcache "${r#*|}"
  if (( is_wp )); then
    r="$(capacity_redis "$domain" "$docroot" "$site_user")"
    capacity_audit_add "${r%%|*}" redis_object_cache "${r#*|}"
  fi
  # Cloudflare is checked only when a token line exists; `export CF_API_TOKEN=` counts too.
  if [[ -f "$CREDENTIALS_ENV" ]] && grep -qE '^(export +)?CF_API_TOKEN=' "$CREDENTIALS_ENV" 2>/dev/null; then
    r="$(capacity_cf_check "$domain" "$https" 2>/dev/null)" || r=""
    [[ "$r" == *"|"* ]] || r="WARN|không kiểm tra được Cloudflare (credentials hoặc API lỗi)"
    capacity_audit_add "${r%%|*}" cloudflare "${r#*|}"
  else
    capacity_audit_add WARN cloudflare "chưa cấu hình token Cloudflare"
  fi
  capacity_audit_add "${ratio%%|*}" log_hit_ratio "${ratio#*|}"
}

# cecp-panel optimize audit DOMAIN [--json] — exit 0 (also with WARN), 2 when any check FAILs.
optimize_audit() {
  local domain="" json=0 arg i fails=0
  local usage="Usage: cecp-panel optimize audit DOMAIN [--json]"
  for arg in "$@"; do
    case "$arg" in
      --json) json=1 ;;
      -*) panel_die "$usage" ;;
      *) [[ -z "$domain" ]] || panel_die "$usage"; domain="${arg,,}" ;;
    esac
  done
  [[ -n "$domain" ]] || panel_die "$usage"
  validate_domain "$domain"
  CAPACITY_AUDIT_LEVEL=()
  CAPACITY_AUDIT_NAME=()
  CAPACITY_AUDIT_DETAIL=()
  if [[ -f "$(site_meta_path "$domain")" ]]; then
    capacity_audit_site "$domain"
  else
    capacity_audit_add FAIL site "$domain không có trong panel (cecp-panel site list)"
  fi
  for i in "${!CAPACITY_AUDIT_LEVEL[@]}"; do
    if [[ "${CAPACITY_AUDIT_LEVEL[$i]}" == FAIL ]]; then
      fails=$((fails + 1))
    fi
  done
  if [[ "$json" == 1 ]]; then
    for i in "${!CAPACITY_AUDIT_LEVEL[@]}"; do
      printf '%s\t%s\t%s\n' "${CAPACITY_AUDIT_LEVEL[$i]}" "${CAPACITY_AUDIT_NAME[$i]}" "${CAPACITY_AUDIT_DETAIL[$i]}"
    done | python3 -c '
import json, sys
sys.stdin.reconfigure(encoding="utf-8", errors="replace")
sys.stdout.reconfigure(encoding="utf-8")
checks = []
for line in sys.stdin:
    level, name, detail = line.rstrip("\n").split("\t", 2)
    checks.append({"status": level, "name": name, "detail": detail})
count = {s: sum(1 for c in checks if c["status"] == s) for s in ("PASS", "WARN", "FAIL")}
print(json.dumps({"domain": sys.argv[1], "checks": checks,
                  "summary": {"pass": count["PASS"], "warn": count["WARN"], "fail": count["FAIL"]},
                  "exit_code": 2 if count["FAIL"] else 0}, ensure_ascii=False))
' "$domain"
  else
    echo "=== Kiểm tra tối ưu (chỉ đọc): $domain ==="
    for i in "${!CAPACITY_AUDIT_LEVEL[@]}"; do
      printf '%s %s — %s\n' "${CAPACITY_AUDIT_LEVEL[$i]}" "${CAPACITY_AUDIT_NAME[$i]}" "${CAPACITY_AUDIT_DETAIL[$i]}"
    done
    echo "Tổng: $(printf '%s\n' "${CAPACITY_AUDIT_LEVEL[@]}" | grep -c '^PASS$' || true) PASS," \
      "$(printf '%s\n' "${CAPACITY_AUDIT_LEVEL[@]}" | grep -c '^WARN$' || true) WARN, $fails FAIL"
  fi
  if (( fails > 0 )); then
    return 2
  fi
  return 0
}
