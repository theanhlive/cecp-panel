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
  validate_domain "$domain"
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
  # PHP Imagick lets WordPress read HEIC/HEIF (iPhone) and TIFF uploads and resize very large
  # photos outside PHP's memory_limit (GD decodes the whole bitmap into it). Best effort: the
  # package name differs per distro/repo; GD still handles JPEG/PNG/WebP/BMP.
  if ! php -m 2>/dev/null | grep -qi '^imagick$'; then
    if [[ -f /etc/almalinux-release || -f /etc/rocky-release || -f /etc/redhat-release ]]; then
      dnf -y install php-pecl-imagick-im7 2>/dev/null || dnf -y install php-pecl-imagick 2>/dev/null || true
    else
      apt-get install -y php-imagick 2>/dev/null || true
    fi
    php -m 2>/dev/null | grep -qi '^imagick$' && php_fpm_reload_all >/dev/null 2>&1 || true
  fi
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
  local src="$PANEL_ROOT/templates/mu-plugins/cecp-media-optimize.php"
  [[ -f "$src" ]] || panel_die "Missing template: $src"
  # As the site user (see site_write_file): a root chown of a planted symlink gave away /etc.
  site_write_file "$site_user" "$mudir/cecp-media-optimize.php" 644 <"$src"
}

media_write_mu_config() {
  local domain="$1"
  local docroot site_user mudir
  docroot="$(media_docroot "$domain")"
  site_user="$(media_site_user "$domain")"
  mudir="$(media_mu_plugin_dir "$docroot")"
  python3 - "$domain" <<'PY' | site_write_file "$site_user" "$mudir/cecp-media-optimize.json" 644
import json, sys
domain = sys.argv[1].lower()
path = f"/var/lib/cecp-panel/sites/{domain}.json"
with open(path, encoding="utf-8") as f:
    data = json.load(f)
cfg = data.get("media_optimize") or {}
payload = {
    "enabled": bool(cfg.get("enabled")),
    # Sites enabled before "format" existed keep their behaviour until re-enabled.
    "format": cfg.get("format", "original"),
    "on_upload": bool(cfg.get("on_upload", True)),
    "max_width": int(cfg.get("max_width", 1920)),
    "max_height": int(cfg.get("max_height", 1920)),
    "quality": int(cfg.get("quality", 80)),
    "webp": bool(cfg.get("webp", True)),
    "avif": bool(cfg.get("avif", False)),
    "skip_under_kb": int(cfg.get("skip_under_kb", 200)),
}
json.dump(payload, sys.stdout, indent=2)
sys.stdout.write("\n")
PY
}

media_remove_mu_plugin() {
  local domain="$1"
  local docroot mudir
  docroot="$(media_docroot "$domain")"
  mudir="$(media_mu_plugin_dir "$docroot")"
  site_run_as "$(media_site_user "$domain")" rm -f -- "$mudir/cecp-media-optimize.php" "$mudir/cecp-media-optimize.json" 2>/dev/null || true
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
  local avif=false
  local format=webp

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
      --avif) avif=true; shift ;;
      --format) format="${2:-}"; shift 2 || panel_die "--format needs webp|avif|original" ;;
      --format=*) format="${1#--format=}"; shift ;;
      --no-avif) avif=false; shift ;;
      *) panel_die "Unknown flag: $1 (media enable DOMAIN [--format webp|avif|original] [--max-width N] [--quality N] [--no-upload] [--no-cron] [--no-webp] [--avif])" ;;
    esac
  done
  [[ "$format" =~ ^(webp|avif|original)$ ]] || panel_die "--format must be webp, avif or original"
  [[ "$max_w" =~ ^[0-9]{2,5}$ && "$max_h" =~ ^[0-9]{2,5}$ ]] || panel_die "--max-width/--max-height must be numbers"
  [[ "$quality" =~ ^[0-9]{2}$ ]] || panel_die "--quality must be 10-99"
  [[ "$skip_kb" =~ ^[0-9]{1,6}$ && "$batch" =~ ^[0-9]{1,5}$ ]] || panel_die "--skip-under-kb/--batch must be numbers"

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
  "avif": sys.argv[10] == "true",
  "format": sys.argv[11],
  "last_run_at": None,
  "last_run_stats": {},
}))
' "$on_upload" "$cron" "$webp" "$max_w" "$max_h" "$quality" "$skip_kb" "$batch" "$enabled_at" "$avif" "$format")"

  media_cfg_set "$domain" "$json" >/dev/null
  media_install_mu_plugin "$domain"
  media_write_mu_config "$domain"
  media_set_avif_serving "$domain" "$avif"

  if [[ "$cron" == "true" ]]; then
    media_enable_cron
  fi

  panel_log "Media optimize ENABLED for $domain"
  panel_log "  format=$format on_upload=$on_upload cron=$cron webp=$webp max=${max_w}x${max_h} quality=$quality"
  if [[ "$format" != original ]]; then
    panel_log "  New uploads (any format) → one ${format^^} file, max ${max_w}x${max_h}, original not kept."
    panel_log "  Existing library: cecp-panel media run $domain (WebP copies) | media prune-originals $domain (free disk)"
  fi
  if ! php -m 2>/dev/null | grep -qi '^imagick$' \
     && (( $(php_cfg_mb "$(php_cfg_get "$domain" memory_limit)") < 512 )); then
    panel_log "  WARN: no PHP Imagick — photos above ~25 megapixels need more PHP memory: cecp-panel php config $domain memory_limit=512M"
  fi
  panel_log "  Run backlog now: cecp-panel media run $domain"
  media_status "$domain"
}

# nginx serves photo.avif / photo.webp for photo.jpg when the browser accepts it (Vary: Accept).
# WebP is always negotiated; AVIF only when enabled here, because Cloudflare ignores Vary on
# non-Enterprise plans and could hand a cached AVIF to a browser without AVIF support.
media_set_avif_serving() {
  local domain="$1" want="$2" cur
  cur="$(site_json_get_or "$domain" img_avif false)"
  [[ "${cur,,}" != "$want" ]] || return 0
  site_json_set "$domain" img_avif "$want"
  site_render_vhost "$domain"
  nginx_test_and_reload || panel_die "nginx rejected the vhost for $domain (config rolled back)"
  if [[ "$want" == "true" ]]; then
    panel_log "AVIF serving ON for $domain. Behind Cloudflare, prefer WebP only (media enable $domain --no-avif) unless Polish/Vary-for-images is on."
  fi
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
  [[ "$(media_is_wordpress "$domain")" == "True" ]] || return 0
  echo ""
  echo "Image formats this site's PHP can process (read → convert):"
  wp_site_exec "$domain" eval '
    $e = _wp_image_editor_choose(); echo "  editor: ", $e ?: "none", "\n";
    foreach (["image/jpeg","image/png","image/webp","image/avif","image/heic","image/tiff","image/bmp"] as $m)
      printf("  %-11s %s\n", substr($m, 6), wp_image_editor_supports(["mime_type" => $m]) ? "yes" : "no");
  ' 2>/dev/null | sed 's/^  bmp .*no$/  bmp         yes (decoded with GD)/' || echo "  (WordPress not reachable)"
}

# cecp-panel media prune-originals DOMAIN [--yes]
# WordPress keeps the full-size original of every photo it had to shrink or rotate ("-scaled" /
# "-rotated" + original): usually the biggest files of the library, only used to regenerate
# thumbnails. This deletes those originals (and their sidecars) and makes the scaled copy the
# attachment's own file. Dry run by default: prints what would be freed.
media_prune_originals() {
  local domain yes=0 dry=1 out
  domain="$(media_require_site "${1:-}")"
  shift || true
  [[ "${1:-}" == "--yes" ]] && yes=1
  require_root
  [[ "$(media_is_wordpress "$domain")" == "True" ]] || panel_die "prune-originals requires WordPress: $domain"
  if (( yes )); then
    dry=0
    site_lock "$domain"
  fi
  out="$(wp_site_exec "$domain" eval-file - "$dry" <<'PHP'
<?php
global $wpdb;
$dry = ($args[0] ?? '1') === '1';
$count = 0; $bytes = 0; $page = 1;
do {
    $ids = get_posts(['post_type' => 'attachment', 'post_status' => 'inherit', 'post_mime_type' => 'image',
                      'fields' => 'ids', 'posts_per_page' => 500, 'paged' => $page++, 'orderby' => 'ID', 'order' => 'ASC',
                      'no_found_rows' => true, 'suppress_filters' => true]);
    foreach ($ids as $id) {
        $meta = wp_get_attachment_metadata($id);
        if (empty($meta['original_image'])) {
            continue;
        }
        $file = get_attached_file($id, true);
        $orig = path_join(dirname($file), $meta['original_image']);
        if (!$file || $orig === $file || !is_file($orig)) {
            continue;
        }
        $victims = [$orig, $orig . '.cecp-opt'];
        // photo.webp / photo.avif sidecars of photo.jpg — unless another attachment IS that file.
        $upl = wp_get_upload_dir();
        foreach (['webp', 'avif'] as $x) {
            $side = preg_replace('/\.[^.\/]+$/', '.' . $x, $orig);
            $rel = ltrim(str_replace(trailingslashit($upl['basedir']), '', $side), '/');
            $owner = $wpdb->get_var($wpdb->prepare(
                "SELECT post_id FROM $wpdb->postmeta WHERE meta_key = '_wp_attached_file' AND meta_value = %s LIMIT 1", $rel));
            if (!$owner && $side !== $orig) {
                $victims[] = $side;
            }
        }
        foreach ($victims as $v) {
            if (is_file($v)) {
                $bytes += filesize($v);
                if (!$dry) {
                    @unlink($v);
                }
            }
        }
        if (!$dry) {
            unset($meta['original_image']);
            wp_update_attachment_metadata($id, $meta);
        }
        $count++;
    }
} while ($ids);
printf("%d %d
", $count, $bytes);
PHP
)" || panel_die "prune-originals failed for $domain"
  local n b
  read -r n b <<<"$(tail -1 <<<"$out")"
  [[ "$n" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || panel_die "prune-originals: unexpected output: $out"
  if (( dry )); then
    echo "Dry run: $n original image(s) kept by WordPress, $(numfmt --to=iec --suffix=B "$b") can be freed."
    (( n == 0 )) || echo "Delete them (thumbnails can no longer be regenerated from the full original): cecp-panel media prune-originals $domain --yes"
  else
    panel_log "prune-originals $domain: $n original(s) deleted, $(numfmt --to=iec --suffix=B "$b") freed"
  fi
}

# Runs as the SITE user, never root: uploads/ is writable by the site, so a compromised
# WordPress could plant symlinks (photo.webp -> /etc/shadow) and a root process writing the
# WebP/AVIF sidecars or .cecp-opt markers would overwrite system files through them.
media_run_python() {
  # Args: SITE_USER DOCROOT MAX_W MAX_H QUALITY SKIP_KB BATCH WEBP DRY_RUN [AVIF]
  local site_user="$1"
  shift
  (cd / && runuser -u "$site_user" -- python3 - "$@") <<'PY'
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
avif = len(sys.argv) > 9 and sys.argv[9].lower() == "true"

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
    "avif_written": 0,
    "dry_run": dry,
    "engine": "pillow" if use_pil else ("imagemagick" if im_bin else "none"),
}

if stats["engine"] == "none":
    print(json.dumps({**stats, "ok": False, "error": "No Pillow or ImageMagick available"}))
    sys.exit(0)

pil_avif = False
if use_pil and avif:
    try:
        from PIL import features
        pil_avif = bool(features.check("avif"))
    except Exception:
        pil_avif = False
im_avif = False
if avif and im_bin and not pil_avif:
    try:
        out = subprocess.run([im_bin, "-list", "format"], capture_output=True, text=True, timeout=20).stdout
        im_avif = any(l.split()[0].rstrip("*").upper() == "AVIF" and "rw" in l for l in out.splitlines() if l.split())
    except Exception:
        im_avif = False
if avif and not (pil_avif or im_avif):
    stats["avif_note"] = "no AVIF encoder (Pillow>=11.2 or ImageMagick with libheif); only WebP written"


def to_rgb_or_rgba(im):
    """RGB/RGBA for WebP/AVIF, keeping transparency (palette PNG logos lost it: black background)."""
    if im.mode in ("RGB", "RGBA"):
        return im
    alpha = im.mode in ("LA", "PA", "RGBa", "La") or "transparency" in im.info
    return im.convert("RGBA" if alpha else "RGB")

def drop_if_not_smaller(sidecar: Path, original: Path):
    """A sidecar at least as big as the original only costs bandwidth: nginx would prefer it."""
    try:
        if sidecar.is_file() and sidecar.stat().st_size >= original.stat().st_size:
            sidecar.unlink()
            return False
    except OSError:
        return False
    return sidecar.is_file()

def write_avif(path: Path):
    """photo.jpg -> photo.avif (same name the nginx negotiation looks for). Best effort."""
    if not avif:
        return False
    out = path.with_suffix(".avif")
    try:
        if pil_avif:
            with Image.open(path) as im:
                im = to_rgb_or_rgba(ImageOps.exif_transpose(im))
                im.save(out, "AVIF", quality=max(30, quality - 20))
        elif im_avif:
            subprocess.run([im_bin, str(path), "-quality", str(max(30, quality - 20)), str(out)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
        else:
            return False
    except Exception:
        return False
    return drop_if_not_smaller(out, path)

def optimize_pil(path: Path):
    before = path.stat().st_size
    if before < skip_under:
        return "skip", before, before, False
    with Image.open(path) as im:
        # Stripping the colour profile shifts colours (Display P3 photos from phones look dull).
        icc = im.info.get("icc_profile")
        im = ImageOps.exif_transpose(im)
        w, h = im.size
        resized = w > max_w or h > max_h
        if resized:
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
        if icc:
            save_kw["icc_profile"] = icc
        if dry:
            return "dry", before, before, False
        tmp = path.with_suffix(path.suffix + ".cecp-tmp")
        im.save(tmp, **save_kw)
        # Re-encoding an already optimised file at the same size often makes it BIGGER (and
        # always a bit worse): keep the original unless the new one is smaller.
        if resized or tmp.stat().st_size < before:
            tmp.replace(path)
        else:
            tmp.unlink()
        after = path.stat().st_size
        webp_ok = False
        if webp and ext in (".jpg", ".jpeg", ".png"):
            webp_path = path.with_suffix(".webp")
            try:
                with Image.open(path) as im2:
                    im2 = to_rgb_or_rgba(ImageOps.exif_transpose(im2))
                    im2.save(webp_path, "WEBP", quality=quality, method=4, **({"icc_profile": icc} if icc else {}))
                webp_ok = drop_if_not_smaller(webp_path, path)
            except Exception:
                webp_ok = False
        if write_avif(path):
            stats["avif_written"] += 1
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
        if tmp.is_file() and 0 < tmp.stat().st_size < before:
            tmp.replace(path)
        elif tmp.is_file() and tmp.stat().st_size > 0:
            tmp.unlink()  # not smaller: keep the original (see optimize_pil)
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
            webp_ok = drop_if_not_smaller(webp_path, path)
        except Exception:
            webp_ok = False
    if write_avif(path):
        stats["avif_written"] += 1
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

  local docroot max_w max_h quality skip_kb batch webp avif
  avif="$(media_cfg_get "$domain" "avif")"
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

  local site_user
  site_user="$(media_site_user "$domain")"
  # Files left root-owned by runs of older versions (which ran as root) would not be writable
  # by the site user now. -h/find -P: never follow the site's symlinks.
  if [[ -d "$docroot/wp-content/uploads" ]]; then
    find "$docroot/wp-content/uploads" ! -user "$site_user" -exec chown -h "${site_user}:${site_user}" {} + 2>/dev/null || true
  fi

  panel_log "Media run $domain dry=$dry batch=$batch max=${max_w}x${max_h} q=$quality webp=$webp"
  local out
  out="$(media_run_python "$site_user" "$docroot" "$max_w" "$max_h" "$quality" "$skip_kb" "$batch" "$webp" "$dry" "${avif:-false}")"
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
