#!/usr/bin/env bash
# Prove capacity with a real load test, run from ANOTHER machine:
#   cecp-panel optimize loadtest plan DOMAIN [--profile cached|mixed|login-api] [--max-vus N] [--out FILE]
#     writes a k6 script (GET requests only) and prints the exact `k6 run` command
#   cecp-panel optimize loadtest monitor DOMAIN [--duration SEC] [--interval SEC]
#     samples this VPS while the test runs → CSV + verdict: PASS (exit 0), FAIL (exit 2), or
#     INCONCLUSIVE (exit 3: no samples, no requests in the access log, interrupted, too few samples,
#     or journald unusable → "OOM check unavailable"). INCONCLUSIVE is never reported as PASS.
# Neither installs k6, sends load, changes config or restarts anything. Files go to
# LOADTEST_DIR (root only); the monitor reads MariaDB status through a temporary
# --defaults-extra-file (no password in argv).
set -euo pipefail

LOADTEST_DIR="/root/cecp-loadtest"
LOADTEST_STAGES=(50 100 300 500 800 1000)
LOADTEST_MAX_VUS=1000
LOADTEST_LOGIN_DEFAULT_VUS=50
LOADTEST_LOGIN_MAX_VUS=100
# PASS needs at least this many samples (30 s at the default 5 s interval).
LOADTEST_MIN_SAMPLES=6
# Swap-in at or above this many pages/s (≈400 KiB/s) averaged over >= 3 samples spanning >= 15 s,
# with swap-in seen in >= 3 of those samples, is sustained RAM pressure. A single burst is only a note.
LOADTEST_SWAP_RATE_PAGES=100

# cecp-panel optimize loadtest plan|monitor ...
optimize_loadtest() {
  local action="${1:-}"
  shift || true
  case "$action" in
    plan) loadtest_plan "$@" ;;
    monitor) loadtest_monitor "$@" ;;
    *) panel_die "Usage: cecp-panel optimize loadtest plan DOMAIN [--profile cached|mixed|login-api] [--max-vus N] [--out FILE] | monitor DOMAIN [--duration SEC] [--interval SEC]" ;;
  esac
}

loadtest_require_site() {
  validate_domain "$1"
  [[ -f "$(site_meta_path "$1")" ]] || panel_die "$1 không có trong panel (cecp-panel site list)"
}

loadtest_is_wp() {
  local docroot
  docroot="$(site_json_get_or "$1" docroot "")"
  [[ "$(site_json_get_or "$1" wordpress false)" == True || ( -n "$docroot" && -f "$docroot/wp-config.php" ) ]]
}

# A static .css/.js path (relative to the docroot) to request, or nothing.
loadtest_static_asset() {
  local docroot="$1" rel asset=""
  [[ -n "$docroot" && -d "$docroot" ]] || return 0
  for rel in wp-includes/css/dashicons.min.css wp-includes/js/jquery/jquery.min.js; do
    if [[ -f "$docroot/$rel" ]]; then
      asset="$rel"
      break
    fi
  done
  if [[ -z "$asset" ]]; then
    asset="$(find "$docroot" -maxdepth 4 -type f \( -name '*.css' -o -name '*.js' \) -size +1k \
      -not -path '*/.*' -print -quit 2>/dev/null || true)"
    asset="${asset#"$docroot"/}"
  fi
  [[ "$asset" =~ ^[A-Za-z0-9._/-]+$ && "$asset" != *..* ]] && echo "$asset"
  return 0
}

# Absolute path for --out, printed on stdout. The parent is resolved (symlinks, ..) before the
# checks, so a link cannot point the script into a site; a bare /x.js resolves to parent "/".
loadtest_resolve_out() {
  local out="$1" parent resolved mode
  parent="$(dirname -- "$out")"
  resolved="$(realpath -m -- "$parent")" || panel_die "Không phân giải được thư mục $parent"
  [[ -d "$resolved" ]] || panel_die "Thư mục $parent không tồn tại"
  case "$resolved" in
    /home|/home/*|/var/www|/var/www/*) panel_die "--out không được nằm trong thư mục của site (sau khi phân giải): $resolved" ;;
  esac
  [[ "$(stat -c %u -- "$resolved")" == 0 ]] || panel_die "Thư mục $resolved phải thuộc root"
  mode="$(stat -c %a -- "$resolved")"
  (( (8#$mode & 8#022) == 0 )) || panel_die "Thư mục $resolved không được ghi bởi group/other (mode $mode)"
  out="${resolved%/}/${out##*/}"
  [[ ! -L "$out" && ! -d "$out" ]] || panel_die "--out $out là symlink hoặc thư mục"
  echo "$out"
}

loadtest_plan() {
  local usage="Usage: cecp-panel optimize loadtest plan DOMAIN [--profile cached|mixed|login-api] [--max-vus N] [--out FILE]"
  local domain="" profile=cached max_vus="" out="" base asset="" docroot secs mins host_ip
  while (( $# )); do
    case "$1" in
      --profile) [[ -n "${2:-}" ]] || panel_die "$usage"; profile="$2"; shift 2 ;;
      --max-vus) [[ -n "${2:-}" ]] || panel_die "$usage"; max_vus="$2"; shift 2 ;;
      --out) [[ -n "${2:-}" ]] || panel_die "$usage"; out="$2"; shift 2 ;;
      -*) panel_die "$usage" ;;
      *) [[ -z "$domain" ]] || panel_die "$usage"; domain="${1,,}"; shift ;;
    esac
  done
  [[ -n "$domain" ]] || panel_die "$usage"
  loadtest_require_site "$domain"
  case "$profile" in
    cached|mixed)
      max_vus="${max_vus:-$LOADTEST_MAX_VUS}"
      validate_int_range "$max_vus" 1 "$LOADTEST_MAX_VUS" "--max-vus"
      ;;
    login-api)
      max_vus="${max_vus:-$LOADTEST_LOGIN_DEFAULT_VUS}"
      validate_int_range "$max_vus" 1 "$LOADTEST_LOGIN_MAX_VUS" "--max-vus (login-api)"
      ;;
    *) panel_die "Invalid --profile '$profile' (cached|mixed|login-api)" ;;
  esac
  max_vus=$((10#$max_vus))
  if [[ "$profile" != cached ]] && ! loadtest_is_wp "$domain"; then
    panel_die "Profile $profile gọi WordPress REST API — $domain không phải site WordPress (dùng --profile cached)"
  fi

  if [[ -z "$out" ]]; then
    install -d -m 700 "$LOADTEST_DIR"
    chmod 700 "$LOADTEST_DIR"
    out="$LOADTEST_DIR/${domain}-${profile}.js"
  else
    [[ "$out" =~ ^/[A-Za-z0-9._/-]+\.js$ && "$out" != *..* ]] \
      || panel_die "Invalid --out '$out' (đường dẫn tuyệt đối, kết thúc bằng .js)"
    out="$(loadtest_resolve_out "$out")"
  fi

  if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" || "$(site_json_get_or "$domain" ssl false)" == True ]]; then
    base="https://${domain}"
  else
    base="http://${domain}"
  fi
  docroot="$(site_json_get_or "$domain" docroot "")"
  [[ "$profile" == login-api ]] || asset="$(loadtest_static_asset "$docroot")"

  secs="$(python3 - "$domain" "$profile" "$max_vus" "$out" "$base" "$asset" "$CECP_PANEL_VERSION" \
    "${LOADTEST_STAGES[@]}" <<'PY'
import json, os, sys, time

domain, profile, max_vus, out, base, asset, version = sys.argv[1:8]
max_vus = int(max_vus)
targets = [int(v) for v in sys.argv[8:] if int(v) < max_vus] + [max_vus]
RAMP, HOLD, DOWN = 30, 60, 30
q = json.dumps

stages = []
for t in targets:
    stages.append(f"    {{ duration: '{RAMP}s', target: {t} }},")
    stages.append(f"    {{ duration: '{HOLD}s', target: {t} }},")
stages.append(f"    {{ duration: '{DOWN}s', target: 0 }},")
total = len(targets) * (RAMP + HOLD) + DOWN

js = [
    f"// CECP Panel — kịch bản k6 '{profile}' cho {domain} (tạo lúc {time.strftime('%Y-%m-%d %H:%M')}).",
    "// Chạy từ một máy KHÁC, không chạy trên VPS đang được thử; nhắm vào staging hoặc giờ thấp điểm.",
    "// Chỉ gửi GET: không gửi biểu mẫu, không thanh toán, không kích hoạt gửi email.",
    "import http from 'k6/http';",
    "import { check, sleep } from 'k6';",
]
if profile == "login-api":
    js.append("import encoding from 'k6/encoding';")
js += [
    "",
    f"const BASE = (__ENV.BASE_URL || {q(base)}).replace(/\\/+$/, '');",
    "",
    "export const options = {",
    "  stages: [",
    *stages,
    "  ],",
    "  thresholds: {",
    "    http_req_failed: ['rate<0.01'],",
    "    http_req_duration: ['p(95)<1000'],",
    "  },",
    "  discardResponseBodies: true,",
    f"  userAgent: {q('CECP-Loadtest/' + version + ' (k6)')},",
    "};",
    "",
]

if profile == "login-api":
    js += [
        "// Tài khoản thử chỉ đọc từ biến môi trường của máy chạy k6, không bao giờ ghi vào tệp này.",
        "const USER = __ENV.TEST_USER || '';",
        "const PASS = __ENV.TEST_PASS || '';",
        "if (!USER || !PASS) {",
        "  throw new Error('Thiếu TEST_USER / TEST_PASS: export trong shell của máy chạy k6 (mật khẩu ứng dụng WordPress).');",
        "}",
        "const AUTH = 'Basic ' + encoding.b64encode(USER + ':' + PASS);",
        "const params = (name) => ({ headers: { Authorization: AUTH }, tags: { name: name } });",
        "",
        "export default function () {",
        "  const me = http.get(BASE + '/wp-json/wp/v2/users/me?context=edit', params('rest_me'));",
        "  check(me, { 'rest_me 200': (r) => r.status === 200 });",
        "  const posts = http.get(BASE + '/wp-json/wp/v2/posts?per_page=5&context=edit&_fields=id,status', params('rest_posts_edit'));",
        "  check(posts, { 'rest_posts_edit 200': (r) => r.status === 200 });",
        "  sleep(1);",
        "}",
    ]
else:
    js += [
        f"const ASSET = {q('/' + asset if asset else '')};",
        "",
        "export default function () {",
        "  const home = http.get(BASE + '/', { tags: { name: 'home' } });",
        "  check(home, { 'home 200': (r) => r.status === 200 });",
        "  if (ASSET) {",
        "    const st = http.get(BASE + ASSET, { tags: { name: 'static' } });",
        "    check(st, { 'static 200': (r) => r.status === 200 });",
        "  }",
    ]
    if profile == "mixed":
        js += [
            "  const rest = http.get(BASE + '/wp-json/wp/v2/posts?per_page=5&_fields=id,link', { tags: { name: 'rest_public' } });",
            "  check(rest, { 'rest_public 200': (r) => r.status === 200 });",
        ]
    js += ["  sleep(1);", "}"]

tmp = f"{out}.tmp{os.getpid()}"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write("\n".join(js) + "\n")
os.replace(tmp, out)
print(total)
PY
)"
  mins=$(( (secs + 59) / 60 ))
  host_ip="$(panel_local_ipv4 || true)"
  echo "Đã tạo kịch bản k6: $out (profile $profile, tối đa $max_vus VU, khoảng $mins phút, chỉ GET)"
  echo "CẢNH BÁO: chạy k6 từ một máy KHÁC, không chạy trên VPS này (k6 sẽ tranh CPU/RAM với site và cho kết quả sai)."
  echo "          Nhắm vào staging, hoặc site thật vào giờ thấp điểm. Cloudflare/limit_req có thể chặn khi mọi VU đến từ một IP."
  echo "  1) Chép tệp sang máy chạy k6:  scp root@${host_ip:-<IP-VPS>}:$out ."
  echo "  2) Trên VPS, theo dõi trong lúc chạy:  cecp-panel optimize loadtest monitor $domain --duration $(( secs + 60 > 7200 ? 7200 : secs + 60 ))"
  echo "  3) Trên máy chạy k6:"
  if [[ "$profile" == login-api ]]; then
    echo "     read -r -p 'TEST_USER: ' TEST_USER; read -r -s -p 'TEST_PASS (mật khẩu ứng dụng): ' TEST_PASS; echo; export TEST_USER TEST_PASS"
  fi
  echo "     k6 run -e BASE_URL=$base ${out##*/}"
}

loadtest_monitor() {
  local usage="Usage: cecp-panel optimize loadtest monitor DOMAIN [--duration SEC] [--interval SEC]"
  local domain="" duration=900 interval=5 csv rc=0
  while (( $# )); do
    case "$1" in
      --duration) [[ -n "${2:-}" ]] || panel_die "$usage"; duration="$2"; shift 2 ;;
      --interval) [[ -n "${2:-}" ]] || panel_die "$usage"; interval="$2"; shift 2 ;;
      -*) panel_die "$usage" ;;
      *) [[ -z "$domain" ]] || panel_die "$usage"; domain="${1,,}"; shift ;;
    esac
  done
  [[ -n "$domain" ]] || panel_die "$usage"
  loadtest_require_site "$domain"
  validate_int_range "$duration" 10 7200 "--duration"
  validate_int_range "$interval" 1 300 "--interval"
  duration=$((10#$duration))
  interval=$((10#$interval))
  (( interval <= duration )) || panel_die "--interval ($interval) lớn hơn --duration ($duration)"
  install -d -m 700 "$LOADTEST_DIR"
  chmod 700 "$LOADTEST_DIR"
  # PID in the name: two runs started in the same second must not share a CSV.
  csv="$LOADTEST_DIR/${domain}-monitor-$(date +%Y%m%d-%H%M%S)-$$.csv"
  echo "=== Theo dõi tải $domain trong $duration giây, mỗi $interval giây (chỉ đọc) ==="
  echo "CSV: $csv — bắt đầu chạy k6 trên máy khác ngay bây giờ; Ctrl-C để dừng sớm (vẫn in kết luận)."
  python3 - "$domain" "$duration" "$interval" "$csv" "$FPM_ISOLATED_DIR" \
    "$LOADTEST_MIN_SAMPLES" "$LOADTEST_SWAP_RATE_PAGES" <<'PY' || rc=$?
import csv, glob, os, re, shutil, subprocess, sys, tempfile, time

sys.stdout.reconfigure(encoding="utf-8")
domain, duration, interval, csv_path, iso_dir = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5]
min_samples, swap_limit = int(sys.argv[6]), float(sys.argv[7])
start = time.time()


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def meminfo_mb(key):
    m = re.search(r"^" + key + r":\s+(\d+)", read("/proc/meminfo"), re.M)
    return int(m.group(1)) // 1024 if m else 0


FIXTURE = {"lines": None, "i": 0}


def swap_pages():
    # TEST ONLY (tests/integration/scenario.sh): CECP_LOADTEST_SWAP_FIXTURE=FILE makes this read successive
    # cumulative "pswpin pswpout" lines from FILE instead of /proc/vmstat. Never set it in production.
    fixture = os.environ.get("CECP_LOADTEST_SWAP_FIXTURE", "")
    if fixture:
        if FIXTURE["lines"] is None:
            FIXTURE["lines"] = [p.split() for p in read(fixture).splitlines() if p.strip()]
        if not FIXTURE["lines"]:
            return 0, 0
        pair = FIXTURE["lines"][min(FIXTURE["i"], len(FIXTURE["lines"]) - 1)]
        FIXTURE["i"] += 1
        return int(pair[0]), int(pair[1])
    v = dict(line.split(" ", 1) for line in read("/proc/vmstat").splitlines() if " " in line)
    return int(v.get("pswpin", 0)), int(v.get("pswpout", 0))


def load1():
    try:
        return float(read("/proc/loadavg").split()[0])
    except (IndexError, ValueError):
        return 0.0


class Tail:
    """New complete lines appended to a file since the monitor started (survives rotation)."""

    def __init__(self, path):
        self.path, self.buf = path, b""
        try:
            self.pos = os.path.getsize(path)
        except OSError:
            self.pos = 0

    def lines(self):
        try:
            size = os.path.getsize(self.path)
        except OSError:
            return []
        if size < self.pos:
            self.pos, self.buf = 0, b""
        if size == self.pos:
            return []
        with open(self.path, "rb") as f:
            f.seek(self.pos)
            data = f.read(min(size - self.pos, 64 << 20))
        self.pos += len(data)
        parts = (self.buf + data).split(b"\n")
        self.buf = parts.pop()
        return [p.decode("utf-8", "replace") for p in parts]


class Journal:
    """New journal messages since the monitor started. lines() is None when journalctl is missing or fails."""

    def __init__(self, extra):
        self.extra, self.cursor = extra, None
        self.ok = shutil.which("journalctl") is not None

    def lines(self):
        if not self.ok:
            return None
        cmd = ["journalctl", "-q", "--no-pager", "-o", "cat", "--show-cursor"] + self.extra
        cmd += ["--after-cursor=" + self.cursor] if self.cursor else ["--since", "@%d" % int(start)]
        try:
            proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                  universal_newlines=True, errors="replace", timeout=30)
        except (OSError, subprocess.SubprocessError):
            self.ok = False
            return None
        if proc.returncode not in (0, 1):
            self.ok = False
            return None
        msgs = []
        for line in proc.stdout.splitlines():
            if line.startswith("-- cursor: "):
                self.cursor = line[len("-- cursor: "):].strip()
            else:
                msgs.append(line)
        if proc.returncode == 1 and not msgs:
            # journalctl (systemd 252) exits 1 when the filter matches nothing: "no entries", not a broken journal
            return []
        if proc.returncode != 0:
            self.ok = False
            return None
        return msgs


pool_name, pool_max = "", 0
for pat in ("/etc/php-fpm.d/cecp-*.conf", "/etc/opt/remi/php*/php-fpm.d/cecp-*.conf",
            os.path.join(iso_dir, "*.pool.conf"), "/etc/php/*/fpm/pool.d/cecp-*.conf"):
    for path in sorted(glob.glob(pat)):
        t = read(path)
        if not re.search(r"^; CECP Panel pool — " + re.escape(domain) + r"\s", t, re.M):
            continue
        n = re.search(r"^\[([^\]]+)\]", t, re.M)
        mc = re.search(r"^\s*pm\.max_children\s*=\s*(\d+)", t, re.M)
        pool_name = n.group(1) if n else ""
        pool_max = int(mc.group(1)) if mc else 0


def php_workers():
    total = site = 0
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        cmd = read(f"/proc/{pid}/cmdline").replace("\0", " ").strip()
        if cmd.startswith("php-fpm: pool "):
            total += 1
            if pool_name and (cmd[len("php-fpm: pool "):].split() or [""])[0] == pool_name:
                site += 1
    return total, site


def saturated(line):
    """pm.max_children warning of THIS site's pool only (other pools on the VPS do not count)."""
    return bool(pool_name) and "server reached pm.max_children" in line and f"[pool {pool_name}]" in line


OOM_RE = re.compile(r"Out of memory|oom-kill|oomd|Killed process")
mysql_bin = shutil.which("mysql") or shutil.which("mariadb")
cnf = None


def threads_running():
    if not mysql_bin or cnf is None:
        return ""
    try:
        out = subprocess.run([mysql_bin, "--defaults-extra-file=" + cnf, "-NB", "-e",
                              "SHOW GLOBAL STATUS LIKE 'Threads_running'"],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             universal_newlines=True, timeout=10).stdout.split()
    except (OSError, subprocess.SubprocessError):
        return ""
    return int(out[1]) if len(out) >= 2 and out[1].isdigit() else ""


fpm_logs = [Tail(p) for p in sorted(set(["/var/log/php-fpm/error.log"]
                                        + glob.glob("/var/opt/remi/php*/log/php-fpm/error.log")
                                        + glob.glob("/var/log/php*-fpm.log")))]
fpm_journal = Journal(["-u", "php-fpm*", "-u", "php*-fpm*"])
kernel = Journal(["-k"])
access = Tail(f"/var/log/nginx/{domain}-access.log")
status_re = re.compile(r'\] "[^"]*" (\d{3}) ')
cs_re = re.compile(r" cs=(\S+)$")
HIT = {"HIT", "STALE", "UPDATING", "REVALIDATED"}

cols = ["time", "load1", "mem_available_mb", "swap_in_pages", "swap_out_pages", "php_workers_total",
        "php_workers_site", "fpm_max_children_warnings", "mariadb_threads_running", "requests",
        "req_per_sec", "status_5xx", "status_429", "cache_hits", "cache_dynamic", "oom_kills"]
rows, stamps, interrupted, oom_ok = [], [], False, True
fh = None
try:
    fd, cnf = tempfile.mkstemp(prefix="cecp-loadtest-", suffix=".cnf")
    with os.fdopen(fd, "w") as f:
        f.write("[client]\nuser=root\nconnect-timeout=3\n")
    out_fd = os.open(csv_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    fh = os.fdopen(out_fd, "w", newline="", encoding="utf-8")
    writer = csv.writer(fh)
    writer.writerow(cols)
    prev_in, prev_out = swap_pages()
    prev_t = start
    for i in range(1, duration // interval + 1):
        time.sleep(max(0.0, start + i * interval - time.time()))
        now = time.time()
        sw_in, sw_out = swap_pages()
        total, site = php_workers()
        warn = sum(1 for t in fpm_logs for line in t.lines() if saturated(line))
        warn += sum(1 for line in (fpm_journal.lines() or []) if saturated(line))
        kl = kernel.lines()
        if kl is None:
            oom_ok = False
            kl = []
        oom = sum(1 for line in kl if OOM_RE.search(line))
        req = e5 = e429 = hits = dyn = 0
        for line in access.lines():
            m = status_re.search(line)
            if not m:
                continue
            req += 1
            code = int(m.group(1))
            e5 += code >= 500
            e429 += code == 429
            c = cs_re.search(line.rstrip())
            if c and c.group(1) != "-":
                dyn += 1
                hits += c.group(1) in HIT
        row = {"time": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(now)), "load1": load1(),
               "mem_available_mb": meminfo_mb("MemAvailable"), "swap_in_pages": sw_in - prev_in,
               "swap_out_pages": sw_out - prev_out, "php_workers_total": total, "php_workers_site": site,
               "fpm_max_children_warnings": warn, "mariadb_threads_running": threads_running(),
               "requests": req, "req_per_sec": round(req / max(now - prev_t, 0.001), 1),
               "status_5xx": e5, "status_429": e429, "cache_hits": hits, "cache_dynamic": dyn,
               "oom_kills": oom}
        prev_in, prev_out, prev_t = sw_in, sw_out, now
        rows.append(row)
        stamps.append(now)
        writer.writerow([row[c] for c in cols])
        fh.flush()
        print(f"{row['time']}  load {row['load1']:5.2f} · RAM trống {row['mem_available_mb']} MB · swap-in {row['swap_in_pages']}"
              f" · PHP {site}/{pool_max or '?'} (tổng {total}) · DB chạy {row['mariadb_threads_running'] if row['mariadb_threads_running'] != '' else '?'}"
              f" · {row['req_per_sec']} req/s · 5xx {e5} · 429 {e429} · max_children {warn} · OOM {oom}", flush=True)
except KeyboardInterrupt:
    interrupted = True
finally:
    if fh is not None:
        fh.close()
    if cnf is not None:
        os.unlink(cnf)


def swap_windows():
    """(average pages/s, samples with swap-in > 0) for each smallest window of >= 3 samples spanning >= 15 s."""
    times = [start] + stamps  # times[k + 1] is when rows[k] was taken
    out = []
    for b in range(len(rows)):
        a = b - 2
        if a < 0:
            continue
        while a > 0 and times[b + 1] - times[a] < 15:
            a -= 1
        span = times[b + 1] - times[a]
        if span < 15:
            continue
        win = rows[a:b + 1]
        out.append((sum(r["swap_in_pages"] for r in win) / span, sum(1 for r in win if r["swap_in_pages"] > 0)))
    return out


req_total = sum(r["requests"] for r in rows)
e5_total = sum(r["status_5xx"] for r in rows)
e429_total = sum(r["status_429"] for r in rows)
oom_total = sum(r["oom_kills"] for r in rows)
warn_total = sum(r["fpm_max_children_warnings"] for r in rows)
hits_total = sum(r["cache_hits"] for r in rows)
dyn_total = sum(r["cache_dynamic"] for r in rows)
windows = swap_windows()
swap_peak_rate = max((w[0] for w in windows), default=0.0)
# Sustained = a window spanning >= 15 s with >= 3 samples, average >= limit, and swap-in in >= 3 of its samples.
swap_sustained = [w[0] for w in windows if w[0] >= swap_limit and w[1] >= 3]
rate5 = 100 * e5_total / req_total if req_total else 0.0

fails = []
if oom_total:
    fails.append(f"OOM killer: {oom_total} dòng nhật ký khớp Out of memory / oom-kill / oomd / Killed process (journalctl -k)")
if swap_sustained:
    fails.append(f"swap-in kéo dài {max(swap_sustained):.1f} trang/s (ngưỡng {swap_limit:g}) trong cửa sổ ≥ 15 s, ≥ 3 lần đo có swap-in — RAM không đủ")
if req_total and rate5 >= 1:
    fails.append(f"tỉ lệ 5xx {rate5:.2f}% ({e5_total}/{req_total}) ≥ 1%")
if warn_total:
    fails.append(f"PHP-FPM pool của site chạm pm.max_children {warn_total} lần — pool bão hoà, yêu cầu phải xếp hàng")

reasons = []
if not rows:
    reasons.append("không có lần đo nào")
if interrupted:
    reasons.append("dừng bằng Ctrl-C trước khi đo xong")
if rows and len(rows) < min_samples:
    reasons.append(f"chỉ {len(rows)} lần đo (cần ≥ {min_samples})")
if not req_total:
    reasons.append("access log không ghi nhận yêu cầu nào — k6 có đang chạy đúng BASE_URL không?")
if not oom_ok:
    reasons.append("OOM check unavailable (journalctl không chạy được)")

threads = [r["mariadb_threads_running"] for r in rows if r["mariadb_threads_running"] != ""]
peaks = "chưa có lần đo nào"
if rows:
    peaks = (f"load {max(r['load1'] for r in rows):.2f}, RAM trống thấp nhất {min(r['mem_available_mb'] for r in rows)} MB,"
             f" PHP worker của site {max(r['php_workers_site'] for r in rows)}/{pool_max or '?'}"
             f" (tổng {max(r['php_workers_total'] for r in rows)}),"
             f" MariaDB Threads_running {max(threads) if threads else '?'},"
             f" {max(r['req_per_sec'] for r in rows)} req/s, {req_total} yêu cầu, 5xx {rate5:.2f}%")
    if dyn_total:
        peaks += f", cache HIT {100 * hits_total / dyn_total:.0f}% yêu cầu động"
    peaks += f", swap-in đỉnh {swap_peak_rate:.1f} trang/s"

print("Kết luận:" + (" (dừng sớm bằng Ctrl-C)" if interrupted else ""))
if not oom_ok:
    print("OOM check unavailable — journalctl không chạy được, không xác nhận được là không có OOM.")
if swap_peak_rate >= swap_limit and not swap_sustained:
    print(f"  Ghi chú: swap-in {swap_peak_rate:.1f} trang/s vượt ngưỡng {swap_limit:g} nhưng chỉ trong pico ngắn, không phải swap kéo dài — không tính là FAIL.")
if fails:
    for f in fails:
        print(f"FAIL loadtest — {f}")
    print(f"  Đỉnh: {peaks}")
    code = 2
elif reasons:
    print("INCONCLUSIVE loadtest — chưa đủ bằng chứng để PASS: " + "; ".join(reasons))
    if rows:
        print(f"  Đỉnh: {peaks}")
    code = 3
else:
    print(f"PASS loadtest — đỉnh: {peaks}")
    code = 0
if req_total and e429_total * 100 >= req_total:
    print(f"  Lưu ý: {e429_total} phản hồi 429 — limit_req/Cloudflare đang chặn máy chạy k6, số liệu không phản ánh sức chứa thật.")
if not pool_name:
    print("  Lưu ý: không tìm thấy pool PHP-FPM của site (cecp-panel site rebuild-vhost).")
print(f"CSV: {csv_path}")
sys.exit(code)
PY
  return "$rc"
}
