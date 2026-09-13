#!/usr/bin/env python3
"""CECP Panel monitor: checks services, sites, certificates, disk and backup freshness.

Usage: monitor.py run | status
Configuration comes from the environment (set by lib/monitor.sh). `run` prints one line per
alert to stdout, fields separated by \\x1f: event, severity, domain, message, details-json.
Alerts are only emitted when a check changes state (fail / recovered), plus a reminder while
a check keeps failing (every 6 h for critical, 24 h for warnings).
"""
import glob
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone

SITES_DIR = os.environ.get("CECP_SITES_DIR", "/var/lib/cecp-panel/sites")
STATE = os.environ.get("CECP_MONITOR_STATE", "/var/lib/cecp-panel/monitor/state.json")
BACKUP_STATE = os.environ.get("CECP_BACKUP_STATE", "/var/lib/cecp-panel/backup-state.json")
BACKUP_CRON = "/etc/cron.d/cecp-panel-backup"
SSL_WARN_DAYS = int(os.environ.get("CECP_SSL_WARN_DAYS", "14"))
DISK_WARN_PCT = int(os.environ.get("CECP_DISK_WARN_PCT", "85"))
BACKUP_MAX_AGE_H = int(os.environ.get("CECP_BACKUP_MAX_AGE_HOURS", "36"))
HEAL = os.environ.get("CECP_MONITOR_HEAL", "1") == "1"
REALERT = {"critical": 6 * 3600, "warning": 24 * 3600}
SEP = "\x1f"


def sh(*cmd, timeout=30):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return 1, ""


def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def sites():
    out = []
    for p in sorted(glob.glob(os.path.join(SITES_DIR, "*.json"))):
        d = load_json(p, None)
        if d and d.get("domain"):
            out.append(d)
    return out


def parse_ts(s):
    try:
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except (TypeError, ValueError):
        return None


class Check:
    def __init__(self, key, ok, severity, fail_event, ok_event, fail_msg, ok_msg, domain="", details=None):
        self.key, self.ok, self.severity = key, ok, severity
        self.fail_event, self.ok_event = fail_event, ok_event
        self.fail_msg, self.ok_msg = fail_msg, ok_msg
        self.domain, self.details = domain, details or {}


def unit_exists(name):
    rc, out = sh("systemctl", "list-unit-files", f"{name}.service", "--no-legend")
    return rc == 0 and bool(out)


def check_services(site_list):
    wanted = ["nginx", "mariadb", "php-fpm"]
    for opt in ("redis", "fail2ban"):
        if unit_exists(opt) and sh("systemctl", "is-enabled", opt)[1] == "enabled":
            wanted.append(opt)
    for s in site_list:
        v = str(s.get("php_version", "80"))
        if v != "80":
            wanted.append(f"php{v}-php-fpm")
    checks, extra = [], []
    for svc in dict.fromkeys(wanted):
        if not unit_exists(svc):
            continue
        active = sh("systemctl", "is-active", svc)[1] == "active"
        healed = False
        if not active and HEAL:
            sh("systemctl", "start", svc, timeout=90)
            time.sleep(2)
            active = sh("systemctl", "is-active", svc)[1] == "active"
            healed = active
        if healed:
            extra.append(("service_restarted", "warning", "", f"Service {svc} was down and has been restarted", {"service": svc}))
        checks.append(Check(f"service:{svc}", active, "critical", "service_down", "service_recovered",
                            f"Service {svc} is DOWN (restart failed)", f"Service {svc} is running again",
                            details={"service": svc}))
    return checks, extra


def http_probe(domain, ssl=False):
    scheme = "https" if ssl else "http"
    cmd = ["curl", "-sk", "-o", "/dev/null", "-w", "%{http_code} %{time_starttransfer}", "-m", "15",
           "--resolve", f"{domain}:80:127.0.0.1", "--resolve", f"{domain}:443:127.0.0.1",
           "-H", "Cookie: wordpress_logged_in_cecp_healthcheck=1", f"{scheme}://{domain}/"]
    rc, out = sh(*cmd, timeout=20)
    parts = out.split()
    code = parts[0] if parts else "000"
    ttfb = float(parts[1]) if len(parts) > 1 else 0.0
    return code, ttfb


def check_sites(site_list):
    checks = []
    for s in site_list:
        d = s["domain"]
        ssl = bool(s.get("ssl"))
        code, ttfb = http_probe(d, ssl)
        if not code.startswith(("2", "3")):
            time.sleep(5)  # one retry: do not page for a single slow request or a reload blip
            code, ttfb = http_probe(d, ssl)
        ok = code.startswith(("2", "3"))
        checks.append(Check(f"site:{d}", ok, "critical", "site_down", "site_recovered",
                            f"Site DOWN: {d} (HTTP {code})", f"Site back UP: {d} (HTTP {code})",
                            domain=d, details={"http_code": code, "ttfb_ms": int(ttfb * 1000)}))
    return checks


def check_ssl():
    checks = []
    now = time.time()
    for path in sorted(glob.glob("/etc/letsencrypt/live/*/fullchain.pem")):
        d = os.path.basename(os.path.dirname(path))
        rc, out = sh("openssl", "x509", "-enddate", "-noout", "-in", path)
        if rc != 0 or "=" not in out:
            continue
        try:
            end = datetime.strptime(out.split("=", 1)[1].strip(), "%b %d %H:%M:%S %Y %Z")
        except ValueError:
            continue
        days = int((end.replace(tzinfo=timezone.utc).timestamp() - now) // 86400)
        sev = "critical" if days < 3 else "warning"
        checks.append(Check(f"ssl:{d}", days >= SSL_WARN_DAYS, sev, "ssl_expiring", "ssl_renewed",
                            f"SSL for {d} expires in {days} days (renewal not happening?)",
                            f"SSL for {d} renewed ({days} days left)", domain=d, details={"days_left": days}))
    return checks


def check_disk():
    u = shutil.disk_usage("/")
    pct = int(u.used * 100 / u.total) if u.total else 0
    sev = "critical" if pct >= 95 else "warning"
    return [Check("disk:/", pct < DISK_WARN_PCT, sev, "disk_high", "disk_ok",
                  f"Disk / at {pct}% (threshold {DISK_WARN_PCT}%)", f"Disk / back to {pct}%",
                  details={"use_pct": pct})]


def check_backups(site_list):
    if not os.path.exists(BACKUP_CRON):
        return []
    max_age = BACKUP_MAX_AGE_H * 3600
    try:
        with open(BACKUP_CRON, encoding="utf-8") as f:
            first = next(l for l in f if l.strip() and not l.startswith("#"))
        if first.split()[4] != "*":  # weekly schedule
            max_age = max(max_age, 8 * 86400)
    except (OSError, StopIteration, IndexError):
        pass
    state = load_json(BACKUP_STATE, {})
    cron_age = time.time() - os.path.getmtime(BACKUP_CRON)
    checks = []
    for s in site_list:
        d = s["domain"]
        last = parse_ts(state.get(d, {}).get("last_ok"))
        if last is None:
            if cron_age < max_age:
                continue  # schedule is newer than one period: nothing to judge yet
            ok, age_h = False, None
        else:
            age_h = int((time.time() - last) / 3600)
            ok = time.time() - last <= max_age
        msg = f"No successful backup of {d} for {age_h} h" if age_h is not None else f"No successful backup of {d} yet"
        checks.append(Check(f"backup:{d}", ok, "warning", "backup_stale", "backup_fresh", msg,
                            f"Backups of {d} are current again", domain=d,
                            details={"last_ok": state.get(d, {}).get("last_ok")}))
    return checks


def emit(event, severity, domain, message, details):
    print(SEP.join([event, severity, domain or "", message, json.dumps(details, separators=(",", ":"))]), flush=True)


def run():
    site_list = sites()
    state = load_json(STATE, {})
    checks_state = state.setdefault("checks", {})
    service_checks, extra = check_services(site_list)
    checks = service_checks + check_sites(site_list) + check_ssl() + check_disk() + check_backups(site_list)
    now = time.time()
    for ev in extra:
        emit(*ev)
    seen = set()
    for c in checks:
        seen.add(c.key)
        prev = checks_state.get(c.key)
        if c.ok:
            if prev and not prev.get("ok", True):
                mins = int((now - prev.get("since", now)) / 60)
                emit(c.ok_event, "info", c.domain, f"{c.ok_msg} after {mins} min", c.details)
            checks_state[c.key] = {"ok": True, "since": now if not prev or not prev.get("ok", True) else prev.get("since", now),
                                   "message": c.ok_msg}
            continue
        if not prev or prev.get("ok", True):
            emit(c.fail_event, c.severity, c.domain, c.fail_msg, c.details)
            checks_state[c.key] = {"ok": False, "since": now, "last_alert": now, "message": c.fail_msg}
        else:
            entry = dict(prev, message=c.fail_msg)
            if now - prev.get("last_alert", 0) >= REALERT.get(c.severity, REALERT["warning"]):
                hours = int((now - prev.get("since", now)) / 3600)
                emit(c.fail_event, c.severity, c.domain, f"{c.fail_msg} — still failing after {hours} h", c.details)
                entry["last_alert"] = now
            checks_state[c.key] = entry
    for key in list(checks_state):  # sites/certs that no longer exist
        if key not in seen:
            del checks_state[key]
    state["last_run"] = now
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, STATE)


def status():
    state = load_json(STATE, {})
    last = state.get("last_run")
    if not last:
        print("Monitor has not run yet (cecp-panel monitor enable | monitor run)")
        return 0
    print(f"=== Monitor — last run {int((time.time() - last) / 60)} min ago ===")
    failing = 0
    for key, c in sorted(state.get("checks", {}).items()):
        since = datetime.fromtimestamp(c.get("since", last), timezone.utc).strftime("%Y-%m-%d %H:%M")
        mark = "OK  " if c.get("ok") else "FAIL"
        failing += 0 if c.get("ok") else 1
        print(f"  [{mark}] {key:40} since {since} UTC  {'' if c.get('ok') else c.get('message', '')}")
    print(f"\n{failing} failing check(s)")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("run", "status"):
        sys.exit("usage: monitor.py run|status")
    sys.exit(run() if sys.argv[1] == "run" else status())
