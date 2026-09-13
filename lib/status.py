#!/usr/bin/env python3
"""CECP Panel machine-readable status (cecp-panel status --json; agent heartbeat payload).

Configuration comes from the environment (set by the panel). Keys of the pre-1.9 heartbeat
(ts, vps_id, hostname, panel_installed, panel_version, sites[].domain/ssl/wordpress,
domains_hosted, memory_kb, disk, load) are kept so existing consumers keep working.
Per-site disk usage is expensive (du) and cached for USAGE_MAX_AGE seconds.
"""
import glob
import json
import os
import re
import socket
import subprocess
import time
from datetime import datetime, timezone

SITES_DIR = os.environ.get("CECP_SITES_DIR", "/var/lib/cecp-panel/sites")
VAR_LIB = os.environ.get("CECP_VAR_LIB", "/var/lib/cecp-panel")
USAGE_CACHE = os.path.join(VAR_LIB, "usage-cache.json")
USAGE_MAX_AGE = int(os.environ.get("CECP_USAGE_MAX_AGE", str(6 * 3600)))
BACKUP_STATE = os.path.join(VAR_LIB, "backup-state.json")
MONITOR_STATE = os.path.join(VAR_LIB, "monitor", "state.json")
LOG_TAIL_BYTES = 512 * 1024


def sh(*cmd, timeout=20):
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


def cert_days_left(domain):
    parent = domain.split(".", 1)[1] if domain.count(".") >= 2 else ""
    for d in (domain, parent):
        if not d:
            continue
        path = f"/etc/letsencrypt/live/{d}/fullchain.pem"
        if not os.path.isfile(path):
            continue
        if d == parent:
            rc, san = sh("openssl", "x509", "-noout", "-ext", "subjectAltName", "-in", path)
            if f"DNS:*.{parent}" not in san:
                continue
        rc, out = sh("openssl", "x509", "-enddate", "-noout", "-in", path)
        if rc == 0 and "=" in out:
            try:
                end = datetime.strptime(out.split("=", 1)[1].strip(), "%b %d %H:%M:%S %Y %Z")
                return int((end.replace(tzinfo=timezone.utc).timestamp() - time.time()) // 86400)
            except ValueError:
                return None
    return None


def cache_stats(domain):
    """Share of PHP page requests served from the FastCGI cache (tail of the access log)."""
    path = f"/var/log/nginx/{domain}-access.log"
    counts = {}
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - LOG_TAIL_BYTES))
            data = f.read().decode("utf-8", "replace")
    except OSError:
        return None
    for m in re.finditer(r" cs=([A-Z]+)", data):
        counts[m.group(1)] = counts.get(m.group(1), 0) + 1
    total = sum(counts.values())
    if not total:
        return {"requests": 0, "hit_ratio": None, "by_status": {}}
    hits = counts.get("HIT", 0) + counts.get("STALE", 0) + counts.get("UPDATING", 0)
    return {"requests": total, "hit_ratio": round(hits / total, 3), "by_status": counts}


def site_disk_usage(sites):
    cache = load_json(USAGE_CACHE, {})
    now = time.time()
    changed = False
    for s in sites:
        d, user = s["domain"], s.get("site_user", "")
        entry = cache.get(d)
        if entry and now - entry.get("ts", 0) < USAGE_MAX_AGE:
            continue
        home = f"/home/{user}"
        if not re.fullmatch(r"site_[a-z0-9_]+", user or "") or not os.path.isdir(home):
            continue
        rc, out = sh("du", "-sm", home, timeout=120)
        if rc == 0 and out:
            cache[d] = {"disk_mb": int(out.split()[0]), "ts": now}
            changed = True
    if changed:
        try:
            tmp = USAGE_CACHE + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(cache, f)
            os.chmod(tmp, 0o600)
            os.replace(tmp, USAGE_CACHE)
        except OSError:
            pass
    return cache


def db_sizes():
    rc, out = sh("mysql", "-Nse", "SELECT table_schema, ROUND(SUM(data_length+index_length)/1048576,1) "
                 "FROM information_schema.tables GROUP BY table_schema")
    sizes = {}
    if rc == 0:
        for line in out.splitlines():
            parts = line.split("\t")
            if len(parts) == 2:
                try:
                    sizes[parts[0]] = float(parts[1])
                except ValueError:
                    pass
    return sizes


def service_state(name):
    rc, out = sh("systemctl", "is-active", name)
    return out or "unknown"


def main():
    metas = []
    for p in sorted(glob.glob(os.path.join(SITES_DIR, "*.json"))):
        d = load_json(p, None)
        if d and d.get("domain"):
            metas.append(d)
    usage = site_disk_usage(metas)
    dbs = db_sizes()
    backup = load_json(BACKUP_STATE, {})
    monitor = load_json(MONITOR_STATE, {})
    checks = monitor.get("checks", {})

    services = {}
    for name in ("nginx", "mariadb", "php-fpm", "redis", "fail2ban", "crond"):
        rc, _ = sh("systemctl", "cat", f"{name}.service")
        if rc == 0:
            services[name] = service_state(name)
    for m in metas:
        v = str(m.get("php_version", "80"))
        if m.get("php_isolated") and m.get("pool_name"):
            unit = f"cecp-php-fpm@{m['pool_name']}"
            services[unit] = service_state(unit)
        elif v != "80":
            services[f"php{v}-php-fpm"] = service_state(f"php{v}-php-fpm")

    sites = []
    for m in metas:
        d = m["domain"]
        b = backup.get(d, {})
        mon = checks.get(f"site:{d}")
        sites.append({
            "domain": d,
            "ssl": bool(m.get("ssl")),
            "wordpress": bool(m.get("wordpress")),
            "ssl_days_left": cert_days_left(d) if m.get("ssl") else None,
            "php_version": str(m.get("php_version", "80")),
            "limits": ({"cpu_pct": int(m.get("limit_cpu", 0) or 0), "mem_mb": int(m.get("limit_mem_mb", 0) or 0),
                        "tasks": int(m.get("limit_tasks", 0) or 0)} if m.get("php_isolated") else None),
            "disk_mb": usage.get(d, {}).get("disk_mb"),
            "db_mb": dbs.get(m.get("db_name", "")),
            "cache": {
                "ttl": m.get("cache_ttl") or "5m",
                "auto_purge": bool(m.get("cache_autopurge")),
                "cf_edge": bool(m.get("cf_edge")),
                **(cache_stats(d) or {}),
            },
            "backup": {"last_ok": b.get("last_ok") or None, "last_error": b.get("last_error") or None,
                       "last_verify_ok": b.get("last_verify_ok") or None},
            "uptime": ({"ok": bool(mon.get("ok")), "since": int(mon.get("since", 0)) or None} if mon else None),
            "wp": ({"auto_update": bool(m.get("wp_autoupdate")), "last_update": m.get("wp_last_update") or None,
                    "last_update_result": m.get("wp_last_update_result") or None} if m.get("wordpress") else None),
            "staging_of": m.get("staging_of") or None,
            "staging_site": m.get("staging_site") or None,
            "protected": bool(m.get("site_auth") or m.get("admin_protect_auth") or m.get("admin_protect_ips")),
        })

    mem = {}
    try:
        with open("/proc/meminfo", encoding="utf-8") as f:
            for line in f:
                if line.startswith(("MemTotal:", "MemAvailable:", "SwapTotal:", "SwapFree:")):
                    k, v = line.split(":", 1)
                    mem[k.strip()] = int(v.split()[0])
    except OSError:
        pass
    disk = {}
    try:
        st = os.statvfs("/")
        disk["root_total_kb"] = (st.f_blocks * st.f_frsize) // 1024
        disk["root_avail_kb"] = (st.f_bavail * st.f_frsize) // 1024
        if disk["root_total_kb"]:
            disk["root_use_pct"] = int(100 * (1 - disk["root_avail_kb"] / disk["root_total_kb"]))
    except OSError:
        pass
    try:
        with open("/proc/uptime", encoding="utf-8") as f:
            uptime = int(float(f.read().split()[0]))
    except (OSError, ValueError, IndexError):
        uptime = None

    failing = sum(1 for c in checks.values() if not c.get("ok", True))
    data = {
        "schema": 2,
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "vps_id": os.environ.get("CECP_VPS_ID") or None,
        "hostname": socket.gethostname(),
        "panel_installed": os.path.isfile("/usr/local/bin/cecp-panel"),
        "panel_version": os.environ.get("CECP_PANEL_VERSION"),
        "uptime_s": uptime,
        "cpu_count": os.cpu_count(),
        "load": list(os.getloadavg()),
        "memory_kb": mem,
        "disk": disk,
        "services": services,
        "monitor": {"last_run": int(monitor["last_run"]) if monitor.get("last_run") else None, "failing": failing},
        "sites": sites,
        "domains_hosted": [s["domain"] for s in sites],
    }
    print(json.dumps(data, indent=2))


if __name__ == "__main__":
    main()
