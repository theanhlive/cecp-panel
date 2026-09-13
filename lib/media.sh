#!/usr/bin/env bash
# CECP Panel — per-site media optimize (opt-in)
# On-upload via WP mu-plugin + optional daily cron batch.
set -euo pipefail

MEDIA_CRON_FILE="/etc/cron.d/cecp-media-optimize"
MEDIA_DEFAULT_MAX_WIDTH=1920
MEDIA_DEFAULT_MAX_HEIGHT=1920
MEDIA_DEFAULT_QUALITY=80
MEDIA_DEFAULT_SKIP_KB=200
MEDIA_DEFAULT_BATCH=30

media_domain_lc() { echo "$1" | tr '[:upper:]' '[:lower:]'; }

media_require_site() {
  local domain
  domain="$(media_domain_lc "$1")"
  [[ -f "$(site_meta_path "$domain")" ]] || panel_die "Site not found: $domain"
  echo "$domain"
}

media_is_wordpress() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("wordpress", False))' \
    "$(site_meta_path "$1")" 2>/dev/null || echo False
}

media_docroot() {
  site_json_get "$1" "docroot"
}

media_site_user() {
  site_json_get "$1" "site_user"
}

media_cfg_get() {
  # media_cfg_get DOMAIN [key]  — prints JSON blob or single key
  local domain="$1" key="${2:-}"
  python3 - "$domain" "$key" <<'PY'
import json, sys
domain = sys.argv[1].lower()
key = sys.argv[2]
path = f"/var/lib/cecp-panel/sites/{domain}.json"
with open(path, encoding="utf-8") as f:
    data = json.load(f)
cfg = data.get("media_optimize") or {}
if not key:
    print(json.dumps(cfg, indent=2, ensure_ascii=False))
else:
    v = cfg.get(key, "")
    if isinstance(v, bool):
        print("true" if v else "false")
    else:
        print(v)
PY
}

media_cfg_set() {
  # media_cfg_set DOMAIN JSON_OBJECT
  local domain="$1" json_obj="$2"
  python3 - "$domain" "$json_obj" <<'PY'
import json, sys
domain = sys.argv[1].lower()
obj = json.loads(sys.argv[2])
path = f"/var/lib/cecp-panel/sites/{domain}.json"
with open(path, encoding="utf-8") as f:
    data = json.load(f)
data["media_optimize"] = obj
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(json.dumps(obj, indent=2, ensure_ascii=False))
PY
}

media_ensure_tools() {
  require_root
  # Prefer ImageMagick convert; also try php-gd for WP editor + webp
  if ! command -v convert >/dev/null 2>&1 && ! command -v magick >/dev/null 2>&1; then
    if [[ -f /etc/almalinux-release || -f /etc/rocky-release || -f /etc/redhat-release ]]; then
      dnf -y install ImageMagick 2>/dev/null || true
    else
      apt-get install -y imagemagick 2>/dev/null || true
    fi
  fi
  if [[ -f /etc/almalinux-release || -f /etc/rocky-release || -f /etc/redhat-release ]]; then
    dnf -y install php-gd 2>/dev/null || true
  else
    apt-get install -y php-gd 2>/dev/null || true
  fi
}

media_mu_plugin_dir() {
  local docroot="$1"
  echo "${docroot}/wp-content/mu-plugins"
}

media_install_mu_plugin() {
  local domain="$1"
  local docroot site_user mudir
  docroot="$(media_docroot "$domain")"
  site_user="$(media_site_user "$domain")"
  mudir="$(media_mu_plugin_dir "$docroot")"
  mkdir -p "$mudir"
  local src="$PANEL_ROOT/templates/mu-plugins/cecp-media-optimize.php"
  [[ -f "$src" ]] || panel_die "Missing template: $src"
  install -m 644 "$src" "$mudir/cecp-media-optimize.php"
  chown "${site_user}:${site_user}" "$mudir" "$mudir/cecp-media-optimize.php" 2>/dev/null || true
}

media_write_mu_config() {
  local domain="$1"
  local docroot site_user mudir
  docroot="$(media_docroot "$domain")"
  site_user="$(media_site_user "$domain")"
  mudir="$(media_mu_plugin_dir "$docroot")"
  mkdir -p "$mudir"
  python3 - "$domain" "$mudir/cecp-media-optimize.json" <<'PY'
import json, sys
domain, out = sys.argv[1].lower(), sys.argv[2]
path = f"/var/lib/cecp-panel/sites/{domain}.json"
with open(path, encoding="utf-8") as f:
    data = json.load(f)
cfg = data.get("media_optimize") or {}
payload = {
    "enabled": bool(cfg.get("enabled")),
    "on_upload": bool(cfg.get("on_upload", True)),
    "max_width": int(cfg.get("max_width", 1920)),
    "max_height": int(cfg.get("max_height", 1920)),
    "quality": int(cfg.get("quality", 80)),
    "webp": bool(cfg.get("webp", True)),
    "skip_under_kb": int(cfg.get("skip_under_kb", 200)),
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)
    f.write("\n")
print(out)
PY
  chown "${site_user}:${site_user}" "$mudir/cecp-media-optimize.json" 2>/dev/null || true
  chmod 644 "$mudir/cecp-media-optimize.json" 2>/dev/null || true
}

media_remove_mu_plugin() {
  local domain="$1"
  local docroot mudir
  docroot="$(media_docroot "$domain")"
  mudir="$(media_mu_plugin_dir "$docroot")"
  rm -f "$mudir/cecp-media-optimize.php" "$mudir/cecp-media-optimize.json" 2>/dev/null || true
}

media_enable() {
  local domain
  domain="$(media_require_site "${1:-}")"
  shift || true
  require_root

  if [[ "$(media_is_wordpress "$domain")" != "True" ]]; then
    panel_die "Media optimize requires WordPress: $domain"
  fi

  local max_w=$MEDIA_DEFAULT_MAX_WIDTH
  local max_h=$MEDIA_DEFAULT_MAX_HEIGHT
  local quality=$MEDIA_DEFAULT_QUALITY
  local skip_kb=$MEDIA_DEFAULT_SKIP_KB
  local batch=$MEDIA_DEFAULT_BATCH
  local on_upload=true
  local cron=true
  local webp=true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --max-width) max_w="${2:-}"; shift 2 || panel_die "--max-width needs value" ;;
      --max-width=*) max_w="${1#--max-width=}"; shift ;;
      --max-height) max_h="${2:-}"; shift 2 || panel_die "--max-height needs value" ;;
      --max-height=*) max_h="${1#--max-height=}"; shift ;;
      --quality) quality="${2:-}"; shift 2 || panel_die "--quality needs value" ;;
      --quality=*) quality="${1#--quality=}"; shift ;;
      --skip-under-kb) skip_kb="${2:-}"; shift 2 || panel_die "--skip-under-kb needs value" ;;
      --skip-under-kb=*) skip_kb="${1#--skip-under-kb=}"; shift ;;
      --batch) batch="${2:-}"; shift 2 || panel_die "--batch needs value" ;;
      --batch=*) batch="${1#--batch=}"; shift ;;
      --no-upload) on_upload=false; shift ;;
      --no-cron) cron=false; shift ;;
      --no-webp) webp=false; shift ;;
      --webp) webp=true; shift ;;
      *) panel_die "Unknown flag: $1 (media enable DOMAIN [--max-width N] [--quality N] [--no-upload] [--no-cron] [--no-webp])" ;;
    esac
  done

  media_ensure_tools

  local enabled_at json
  enabled_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  json="$(python3 -c '
import json,sys
print(json.dumps({
  "enabled": True,
  "on_upload": sys.argv[1] == "true",
  "cron": sys.argv[2] == "true",
  "webp": sys.argv[3] == "true",
  "max_width": int(sys.argv[4]),
  "max_height": int(sys.argv[5]),
  "quality": int(sys.argv[6]),
  "skip_under_kb": int(sys.argv[7]),
  "batch_limit": int(sys.argv[8]),
  "enabled_at": sys.argv[9],
  "last_run_at": None,
  "last_run_stats": {},
}))
' "$on_upload" "$cron" "$webp" "$max_w" "$max_h" "$quality" "$skip_kb" "$batch" "$enabled_at")"

  media_cfg_set "$domain" "$json" >/dev/null
  media_install_mu_plugin "$domain"
  media_write_mu_config "$domain"

  if [[ "$cron" == "true" ]]; then
    media_enable_cron
  fi

  panel_log "Media optimize ENABLED for $domain"
  panel_log "  on_upload=$on_upload cron=$cron webp=$webp max=${max_w}x${max_h} quality=$quality"
  panel_log "  Run backlog now: cecp-panel media run $domain"
  media_status "$domain"
}

media_disable() {
  local domain
  domain="$(media_require_site "${1:-}")"
  require_root

  local json
  json="$(python3 -c '
import json,sys
print(json.dumps({
  "enabled": False,
  "on_upload": False,
  "cron": False,
  "webp": True,
  "max_width": 1920,
  "max_height": 1920,
  "quality": 80,
  "skip_under_kb": 200,
  "batch_limit": 30,
  "disabled_at": sys.argv[1],
}))
' "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
  media_cfg_set "$domain" "$json" >/dev/null
  media_remove_mu_plugin "$domain"
  panel_log "Media optimize DISABLED for $domain (mu-plugin removed)"
  # Keep global cron; run-all skips disabled sites
}

media_status() {
  local domain="${1:-}"
  if [[ -z "$domain" ]]; then
    echo "=== Media optimize (all sites) ==="
    shopt -s nullglob
    local f
    local any=0
    for f in "$SITES_DIR"/*.json; do
      [[ -f "$f" ]] || continue
      any=1
      python3 - "$f" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
cfg = d.get("media_optimize") or {}
en = bool(cfg.get("enabled"))
flag = "ON " if en else "off"
print(f"  {d.get('domain','?'):40} {flag}  upload={cfg.get('on_upload', False)} cron={cfg.get('cron', False)} "
      f"max={cfg.get('max_width','-')}q={cfg.get('quality','-')} webp={cfg.get('webp', False)} "
      f"last={cfg.get('last_run_at') or '-'}")
PY
    done
    shopt -u nullglob
    [[ "$any" == "1" ]] || echo "  (no sites)"
    echo ""
    if [[ -f "$MEDIA_CRON_FILE" ]]; then
      echo "Global cron: enabled ($MEDIA_CRON_FILE)"
      cat "$MEDIA_CRON_FILE"
    else
      echo "Global cron: disabled (cecp-panel media enable-cron)"
    fi
    return 0
  fi

  domain="$(media_require_site "$domain")"
  echo "=== Media optimize: $domain ==="
  media_cfg_get "$domain"
  local docroot mudir
  docroot="$(media_docroot "$domain")"
  mudir="$(media_mu_plugin_dir "$docroot")"
  echo ""
  echo "mu-plugin: $mudir/cecp-media-optimize.php"
  if [[ -f "$mudir/cecp-media-optimize.php" ]]; then
    echo "  installed: yes"
  else
    echo "  installed: no"
  fi
  if [[ -f "$mudir/cecp-media-optimize.json" ]]; then
    echo "  config: $mudir/cecp-media-optimize.json"
  fi
}

media_run_python() {
  # Args: DOCROOT MAX_W MAX_H QUALITY SKIP_KB BATCH WEBP DRY_RUN
  python3 - "$@" <<'PY'
import os, sys, time, json
from pathlib import Path

docroot = Path(sys.argv[1])
max_w = int(sys.argv[2])
max_h = int(sys.argv[3])
quality = int(sys.argv[4])
skip_kb = int(sys.argv[5])
batch = int(sys.argv[6])
webp = sys.argv[7].lower() == "true"
dry = sys.argv[8].lower() == "true"

uploads = docroot / "wp-content" / "uploads"
if not uploads.is_dir():
    print(json.dumps({"ok": False, "error": f"uploads missing: {uploads}", "processed": 0}))
    sys.exit(0)

exts = {".jpg", ".jpeg", ".png"}
skip_under = skip_kb * 1024
candidates = []
for root, dirs, files in os.walk(uploads):
    # skip cache-like dirs
    dirs[:] = [d for d in dirs if d not in (".git", "cache", "wflogs")]
    for name in files:
        p = Path(root) / name
        if p.suffix.lower() not in exts:
            continue
        if name.endswith(".cecp-opt"):
            continue
        marker = Path(str(p) + ".cecp-opt")
        if marker.is_file() and marker.stat().st_mtime >= p.stat().st_mtime:
            continue
        try:
            st = p.stat()
        except OSError:
            continue
        # Prefer larger / newer files first
        candidates.append((st.st_size, -st.st_mtime, p))

candidates.sort(reverse=True)
candidates = [c[2] for c in candidates[: max(1, batch * 3)]]

# Prefer Pillow; fallback to ImageMagick CLI
use_pil = False
try:
    from PIL import Image, ImageOps
    use_pil = True
except Exception:
    use_pil = False

import shutil
import subprocess

def has_im():
    return shutil.which("magick") or shutil.which("convert")

im_bin = shutil.which("magick") or shutil.which("convert")

stats = {
    "ok": True,
    "processed": 0,
    "skipped": 0,
    "errors": 0,
    "bytes_before": 0,
    "bytes_after": 0,
    "webp_written": 0,
    "dry_run": dry,
    "engine": "pillow" if use_pil else ("imagemagick" if im_bin else "none"),
}

if stats["engine"] == "none":
    print(json.dumps({**stats, "ok": False, "error": "No Pillow or ImageMagick available"}))
    sys.exit(0)

def optimize_pil(path: Path):
    before = path.stat().st_size
    if before < skip_under:
        return "skip", before, before, False
    with Image.open(path) as im:
        im = ImageOps.exif_transpose(im)
        w, h = im.size
        if w > max_w or h > max_h:
            resample = getattr(getattr(Image, "Resampling", Image), "LANCZOS", Image.LANCZOS)
            im.thumbnail((max_w, max_h), resample)
        ext = path.suffix.lower()
        save_kw = {}
        if ext in (".jpg", ".jpeg"):
            if im.mode not in ("RGB", "L"):
                im = im.convert("RGB")
            save_kw = dict(format="JPEG", quality=quality, optimize=True, progressive=True)
        elif ext == ".png":
            if im.mode not in ("RGB", "RGBA", "L", "LA", "P"):
                im = im.convert("RGBA")
            save_kw = dict(format="PNG", optimize=True)
        else:
            return "skip", before, before, False
        if dry:
            return "dry", before, before, False
        tmp = path.with_suffix(path.suffix + ".cecp-tmp")
        im.save(tmp, **save_kw)
        tmp.replace(path)
        after = path.stat().st_size
        webp_ok = False
        if webp and ext in (".jpg", ".jpeg", ".png"):
            webp_path = path.with_suffix(".webp")
            try:
                im2 = Image.open(path)
                im2 = ImageOps.exif_transpose(im2)
                if im2.mode not in ("RGB", "RGBA"):
                    im2 = im2.convert("RGB")
                im2.save(webp_path, "WEBP", quality=quality, method=4)
                webp_ok = True
            except Exception:
                webp_ok = False
        marker = Path(str(path) + ".cecp-opt")
        marker.write_text(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()) + "\n", encoding="utf-8")
        return "ok", before, after, webp_ok

def optimize_im(path: Path):
    before = path.stat().st_size
    if before < skip_under:
        return "skip", before, before, False
    if dry:
        return "dry", before, before, False
    tmp = path.with_suffix(path.suffix + ".cecp-tmp")
    # ImageMagick: resize only if larger, strip metadata, quality
    cmd = [im_bin, str(path), "-auto-orient", "-resize", f"{max_w}x{max_h}>", "-strip"]
    ext = path.suffix.lower()
    if ext in (".jpg", ".jpeg"):
        cmd += ["-quality", str(quality), str(tmp)]
    else:
        cmd += ["-quality", str(quality), str(tmp)]
    try:
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if tmp.is_file() and tmp.stat().st_size > 0:
            tmp.replace(path)
        else:
            tmp.unlink(missing_ok=True)
            return "err", before, before, False
    except Exception:
        tmp.unlink(missing_ok=True)
        return "err", before, before, False
    after = path.stat().st_size
    webp_ok = False
    if webp:
        webp_path = path.with_suffix(".webp")
        try:
            subprocess.run(
                [im_bin, str(path), "-quality", str(quality), str(webp_path)],
                check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            webp_ok = webp_path.is_file()
        except Exception:
            webp_ok = False
    Path(str(path) + ".cecp-opt").write_text(
        time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()) + "\n", encoding="utf-8"
    )
    return "ok", before, after, webp_ok

processed = 0
for path in candidates:
    if processed >= batch:
        break
    try:
        if use_pil:
            status, b, a, w = optimize_pil(path)
        else:
            status, b, a, w = optimize_im(path)
    except Exception:
        stats["errors"] += 1
        continue
    if status == "skip":
        stats["skipped"] += 1
        continue
    if status == "err":
        stats["errors"] += 1
        continue
    stats["bytes_before"] += b
    stats["bytes_after"] += a
    if w:
        stats["webp_written"] += 1
    stats["processed"] += 1
    processed += 1
    if status == "dry":
        pass

stats["saved_bytes"] = max(0, stats["bytes_before"] - stats["bytes_after"])
print(json.dumps(stats))
PY
}

media_run() {
  local domain dry=false limit=""
  domain="$(media_require_site "${1:-}")"
  shift || true
  require_root

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry=true; shift ;;
      --limit) limit="${2:-}"; shift 2 || panel_die "--limit needs value" ;;
      --limit=*) limit="${1#--limit=}"; shift ;;
      *) panel_die "Usage: cecp-panel media run DOMAIN [--dry-run] [--limit N]" ;;
    esac
  done

  local enabled
  enabled="$(media_cfg_get "$domain" "enabled")"
  if [[ "$enabled" != "true" ]]; then
    panel_die "Media optimize is OFF for $domain (run: cecp-panel media enable $domain)"
  fi

  local docroot max_w max_h quality skip_kb batch webp
  docroot="$(media_docroot "$domain")"
  max_w="$(media_cfg_get "$domain" "max_width")"
  max_h="$(media_cfg_get "$domain" "max_height")"
  quality="$(media_cfg_get "$domain" "quality")"
  skip_kb="$(media_cfg_get "$domain" "skip_under_kb")"
  batch="$(media_cfg_get "$domain" "batch_limit")"
  webp="$(media_cfg_get "$domain" "webp")"
  [[ -n "$limit" ]] && batch="$limit"
  max_w="${max_w:-$MEDIA_DEFAULT_MAX_WIDTH}"
  max_h="${max_h:-$MEDIA_DEFAULT_MAX_HEIGHT}"
  quality="${quality:-$MEDIA_DEFAULT_QUALITY}"
  skip_kb="${skip_kb:-$MEDIA_DEFAULT_SKIP_KB}"
  batch="${batch:-$MEDIA_DEFAULT_BATCH}"
  webp="${webp:-true}"

  media_ensure_tools
  # Optional Pillow for better batch quality
  python3 -c 'import PIL' 2>/dev/null || {
    if [[ -f /etc/almalinux-release || -f /etc/rocky-release || -f /etc/redhat-release ]]; then
      dnf -y install python3-pillow 2>/dev/null || true
    else
      apt-get install -y python3-pil 2>/dev/null || true
    fi
  }

  panel_log "Media run $domain dry=$dry batch=$batch max=${max_w}x${max_h} q=$quality webp=$webp"
  local out
  out="$(media_run_python "$docroot" "$max_w" "$max_h" "$quality" "$skip_kb" "$batch" "$webp" "$dry")"
  echo "$out" | python3 -m json.tool 2>/dev/null || echo "$out"

  if [[ "$dry" != "true" ]]; then
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    python3 - "$domain" "$now" "$out" <<'PY'
import json, sys
domain, now, raw = sys.argv[1].lower(), sys.argv[2], sys.argv[3]
path = f"/var/lib/cecp-panel/sites/{domain}.json"
with open(path, encoding="utf-8") as f:
    data = json.load(f)
cfg = data.get("media_optimize") or {}
try:
    stats = json.loads(raw)
except Exception:
    stats = {"raw": raw}
cfg["last_run_at"] = now
cfg["last_run_stats"] = stats
data["media_optimize"] = cfg
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
    # Fix ownership of any new webp/markers under uploads
    local site_user
    site_user="$(media_site_user "$domain")"
    if [[ -d "$docroot/wp-content/uploads" ]]; then
      chown -R "${site_user}:${site_user}" "$docroot/wp-content/uploads" 2>/dev/null || true
    fi
  fi
  panel_log "Media run done: $domain"
}

media_run_all() {
  require_root
  panel_log "=== Media run-all $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  shopt -s nullglob
  local f domain enabled cron_on
  for f in "$SITES_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    domain="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["domain"])' "$f")"
    enabled="$(media_cfg_get "$domain" "enabled" 2>/dev/null || echo false)"
    cron_on="$(media_cfg_get "$domain" "cron" 2>/dev/null || echo false)"
    if [[ "$enabled" != "true" || "$cron_on" != "true" ]]; then
      continue
    fi
    panel_log "--- $domain ---"
    media_run "$domain" || panel_log "WARN: media run failed for $domain"
  done
  shopt -u nullglob
  panel_log "=== Media run-all done ==="
}

media_enable_cron() {
  require_root
  # Daily 03:20 local server time — light batch for enabled sites only
  cat >"$MEDIA_CRON_FILE" <<EOF
# CECP Panel — media optimize (only sites with media_optimize.enabled+cron)
20 3 * * * root /usr/local/bin/cecp-panel media run-all >>${LOG_DIR}/media-optimize.log 2>&1
EOF
  chmod 644 "$MEDIA_CRON_FILE"
  panel_log "Media cron enabled: daily 03:20 ($MEDIA_CRON_FILE)"
}

media_disable_cron() {
  require_root
  rm -f "$MEDIA_CRON_FILE"
  panel_log "Media global cron removed"
}
