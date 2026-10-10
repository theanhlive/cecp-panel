#!/usr/bin/env bash
# Snapshots of the config files `optimize` rewrites, and `cecp-panel optimize rollback`.
# Layout: $TUNE_BACKUP_DIR/<UTC timestamp>-<label>/{MANIFEST,files/N}, every level root-only.
# MANIFEST lines (tab-separated): state sha256 mode uid:gid stored path — state "absent" means
# the file did not exist before tuning (rollback removes it).
set -euo pipefail

TUNE_BACKUP_DIR="${TUNE_BACKUP_DIR:-$VAR_LIB/tune-backups}"
TUNE_BACKUP_KEEP="${TUNE_BACKUP_KEEP:-20}"
TUNE_ID_RE='^[0-9]{8}T[0-9]{6}\.[0-9]{3}Z-[a-z0-9-]{1,32}$'
TUNE_PRUNE="${TUNE_PRUNE:-1}"
TUNE_LAST_SNAPSHOT=""
TUNE_M_STATE=()
TUNE_M_SUM=()
TUNE_M_MODE=()
TUNE_M_OWNER=()
TUNE_M_STORED=()
TUNE_M_PATH=()

# Only config files under /etc are snapshotted or restored (MANIFEST paths are checked again).
tune_path_ok() {
  local p="$1"
  [[ "$p" =~ ^/etc/[A-Za-z0-9._@+/-]+$ && "/$p/" != *"/../"* && "/$p/" != *"/./"* ]]
}

# tune_backup LABEL FILE... — copy the FILEs into a new snapshot (missing ones are recorded as
# "absent"). The snapshot directory is left in TUNE_LAST_SNAPSHOT (no stdout capture needed).
tune_backup() {
  local label="${1:-}" id dir f n=0 sum mode owner
  shift || true
  [[ "$label" =~ ^[a-z0-9-]{1,24}$ ]] || panel_die "tune_backup: nhãn không hợp lệ '$label'"
  (( $# > 0 )) || panel_die "tune_backup: chưa chỉ định tệp cần sao lưu"
  local -a files=()
  local -A seen=()
  for f in "$@"; do
    tune_path_ok "$f" || panel_die "tune_backup: đường dẫn không hợp lệ '$f'"
    [[ -e "$f" && ! -f "$f" ]] && panel_die "tune_backup: '$f' không phải tệp thường"
    [[ -n "${seen[$f]:-}" ]] && continue
    seen[$f]=1
    files+=("$f")
  done
  install -d -m 700 -o root -g root "$TUNE_BACKUP_DIR"
  chmod 700 "$TUNE_BACKUP_DIR"
  while :; do
    id="$(date -u +%Y%m%dT%H%M%S.%3NZ)-${label}"
    dir="$TUNE_BACKUP_DIR/$id"
    mkdir -m 700 "$dir" 2>/dev/null && break
    [[ -e "$dir" ]] || panel_die "Không tạo được thư mục bản sao: $dir"
    sleep 0.01
  done
  mkdir -m 700 "$dir/files"
  {
    printf '# CECP Panel tune backup\n# id: %s\n# label: %s\n# created: %s\n' \
      "$id" "$label" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '# state\tsha256\tmode\towner\tstored\tpath\n'
    for f in "${files[@]}"; do
      if [[ -f "$f" ]]; then
        n=$((n + 1))
        (umask 077; cat -- "$f" >"$dir/files/$n")
        sum="$(sha256sum "$dir/files/$n" | cut -d' ' -f1)"
        read -r mode owner < <(stat -L -c '%a %u:%g' -- "$f")
        printf 'present\t%s\t%s\t%s\t%s\t%s\n' "$sum" "$mode" "$owner" "files/$n" "$f"
      else
        printf 'absent\t-\t-\t-\t-\t%s\n' "$f"
      fi
    done
  } >"$dir/MANIFEST"
  chmod 600 "$dir/MANIFEST"
  TUNE_LAST_SNAPSHOT="$dir"
  panel_log "Đã lưu bản sao cấu hình trước khi thay đổi: $id ($n tệp)"
  if [[ "$TUNE_PRUNE" == "1" ]]; then
    tune_prune
  fi
  return 0
}

# Snapshot ids, oldest first (the timestamp prefix sorts chronologically).
tune_list_ids() {
  [[ -d "$TUNE_BACKUP_DIR" ]] || return 0
  find "$TUNE_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
    | grep -E "$TUNE_ID_RE" | sort || true
}

# Keep the newest TUNE_BACKUP_KEEP snapshots; never touches anything outside TUNE_BACKUP_DIR.
tune_prune() {
  local keep="$TUNE_BACKUP_KEEP" id n
  [[ "$keep" =~ ^[0-9]{1,4}$ ]] && (( keep >= 1 )) || keep=20
  local -a ids=()
  mapfile -t ids < <(tune_list_ids)
  n=$(( ${#ids[@]} - keep ))
  (( n > 0 )) || return 0
  for id in "${ids[@]:0:n}"; do
    [[ "$id" =~ $TUNE_ID_RE ]] || continue
    rm -rf -- "${TUNE_BACKUP_DIR:?}/${id}"
  done
  panel_log "Đã dọn $n bản sao cấu hình cũ (giữ $keep bản mới nhất)"
}

# tune_resolve_id ID|latest — prints a validated snapshot id that exists.
tune_resolve_id() {
  local id="${1:-}"
  if [[ "$id" == "latest" ]]; then
    id="$(tune_list_ids | tail -n 1)"
    [[ -n "$id" ]] || panel_die "Chưa có bản sao cấu hình nào để khôi phục"
  fi
  [[ "$id" =~ $TUNE_ID_RE ]] || panel_die "Mã bản sao không hợp lệ: '$id' (xem: cecp-panel optimize rollback list)"
  [[ -f "$TUNE_BACKUP_DIR/$id/MANIFEST" ]] || panel_die "Không tìm thấy bản sao: $id"
  echo "$id"
}

# Load DIR/MANIFEST into the TUNE_M_* arrays; every stored copy must match its sha256.
tune_manifest_load() {
  local dir="$1" state sum mode owner stored path
  TUNE_M_STATE=(); TUNE_M_SUM=(); TUNE_M_MODE=(); TUNE_M_OWNER=(); TUNE_M_STORED=(); TUNE_M_PATH=()
  [[ -f "$dir/MANIFEST" ]] || panel_die "Bản sao thiếu MANIFEST: $dir"
  while IFS=$'\t' read -r state sum mode owner stored path; do
    [[ -z "$state" || "$state" == \#* ]] && continue
    tune_path_ok "${path:-}" || panel_die "MANIFEST hỏng (đường dẫn '${path:-}'): $dir"
    case "$state" in
      present)
        [[ "$sum" =~ ^[0-9a-f]{64}$ && "$mode" =~ ^[0-7]{3,4}$ && "$owner" =~ ^[0-9]+:[0-9]+$ \
           && "$stored" =~ ^files/[0-9]+$ ]] || panel_die "MANIFEST hỏng (dòng của $path): $dir"
        [[ -f "$dir/$stored" ]] || panel_die "Bản sao thiếu tệp $stored ($path): $dir"
        [[ "$(sha256sum "$dir/$stored" | cut -d' ' -f1)" == "$sum" ]] \
          || panel_die "Bản sao của $path đã bị thay đổi (sai sha256): $dir"
        ;;
      absent) ;;
      *) panel_die "MANIFEST hỏng (trạng thái '$state'): $dir" ;;
    esac
    TUNE_M_STATE+=("$state")
    TUNE_M_SUM+=("$sum")
    TUNE_M_MODE+=("$mode")
    TUNE_M_OWNER+=("$owner")
    TUNE_M_STORED+=("$stored")
    TUNE_M_PATH+=("$path")
  done <"$dir/MANIFEST"
  (( ${#TUNE_M_PATH[@]} > 0 )) || panel_die "MANIFEST rỗng: $dir"
}

# A Debian/Ubuntu mods-available ini enabled with phpenmod leaves conf.d symlinks behind.
tune_before_remove() {
  local p="$1"
  if [[ "$p" =~ ^/etc/php/([0-9]+\.[0-9]+)/mods-available/([A-Za-z0-9_-]+)\.ini$ ]] \
     && command -v phpdismod &>/dev/null; then
    phpdismod -v "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" 2>/dev/null || true
  fi
}

# Put every file of snapshot DIR back (atomic replace, original mode/owner); "absent" files
# are removed. Does not reload any service.
tune_restore_files() {
  local dir="$1" i path tmp
  tune_manifest_load "$dir"
  for i in "${!TUNE_M_PATH[@]}"; do
    path="${TUNE_M_PATH[$i]}"
    if [[ "${TUNE_M_STATE[$i]}" == "absent" ]]; then
      if [[ -f "$path" || -L "$path" ]]; then
        tune_before_remove "$path"
        rm -f -- "$path"
        panel_log "  - đã gỡ $path (trước đó chưa có tệp này)"
      fi
      continue
    fi
    mkdir -p -- "$(dirname -- "$path")"
    tmp="$(mktemp "${path}.cecp-rb.XXXXXX")"
    cat -- "$dir/${TUNE_M_STORED[$i]}" >"$tmp"
    chown "${TUNE_M_OWNER[$i]}" "$tmp"
    chmod "${TUNE_M_MODE[$i]}" "$tmp"
    mv -f -- "$tmp" "$path"
    selinux_fixup_path "$path"
    panel_log "  - đã khôi phục $path"
  done
}

# MariaDB parses every option file on --help --verbose and fails on an unknown/bad option.
tune_mariadb_config_check() {
  local c bin=""
  for c in mariadbd mysqld /usr/libexec/mariadbd /usr/libexec/mysqld /usr/sbin/mariadbd /usr/sbin/mysqld; do
    bin="$(command -v "$c" 2>/dev/null || true)"
    [[ -n "$bin" ]] && break
  done
  if [[ -z "$bin" ]]; then
    command -v my_print_defaults &>/dev/null || return 0
    my_print_defaults mysqld >/dev/null
    return
  fi
  "$bin" --help --verbose >/dev/null
}

tune_mariadb_restart() {
  systemctl restart mariadb 2>/dev/null || systemctl restart mysql 2>/dev/null
}

# tune_rollback_abort PRE MESSAGE ERRORTEXT NGINX PHP MARIADB — undo a failed rollback with the
# snapshot taken just before it, reload what was already touched, then panel_die.
tune_rollback_abort() {
  local pre="$1" msg="$2" err="$3" nginx="$4" php="$5" mariadb="$6"
  [[ -n "$err" ]] && printf '%s\n' "$err" | sed 's/^/    /' >&2
  panel_log "LỖI: $msg — trả lại cấu hình đang dùng trước khi khôi phục (${pre##*/}) ..."
  tune_restore_files "$pre"
  if [[ "$nginx" == "1" ]] && nginx -t 2>/dev/null; then
    systemctl reload nginx 2>/dev/null || true
  fi
  if [[ "$php" == "1" ]]; then
    php_fpm_reload_all || true
  fi
  if [[ "$mariadb" == "1" ]] && ! tune_mariadb_restart; then
    panel_log "CẢNH BÁO: MariaDB vẫn chưa khởi động được — kiểm tra: journalctl -u mariadb"
  fi
  panel_die "$msg. Cấu hình đã được trả về trạng thái trước khi chạy rollback."
}

# cecp-panel optimize rollback list
tune_rollback_list() {
  require_root
  local id paths
  local -a ids=()
  mapfile -t ids < <(tune_list_ids)
  if (( ${#ids[@]} == 0 )); then
    echo "Chưa có bản sao cấu hình nào ($TUNE_BACKUP_DIR)."
    return 0
  fi
  echo "=== Bản sao cấu hình trước khi tối ưu (cũ → mới, giữ ${TUNE_BACKUP_KEEP} bản) ==="
  for id in "${ids[@]}"; do
    paths="$(awk -F'\t' '!/^#/ && NF >= 6 { printf "%s%s%s", (n++ ? ", " : ""), $6, ($1 == "absent" ? " (chưa có)" : "") }' \
      "$TUNE_BACKUP_DIR/$id/MANIFEST" 2>/dev/null || true)"
    printf '  %-40s %s\n' "$id" "${paths:-?}"
  done
  echo "Khôi phục: cecp-panel optimize rollback MÃ|latest"
}

# cecp-panel optimize rollback ID|latest — restore a snapshot, check configs (nginx -t, MariaDB
# option parse) BEFORE any reload/restart. The current files are snapshotted first, so a failed
# rollback is undone automatically and a successful one can be undone with that snapshot id.
tune_rollback() {
  require_root
  local id dir pre path err="" nginx=0 php=0 mariadb=0 sysctl=0
  id="$(tune_resolve_id "${1:-}")"
  dir="$TUNE_BACKUP_DIR/$id"
  tune_manifest_load "$dir"
  local -a paths=("${TUNE_M_PATH[@]}")
  if command -v security_audit_log &>/dev/null; then
    security_audit_log "optimize rollback $id"
  fi
  # The target may be the oldest snapshot: do not prune until the restore is done.
  local TUNE_PRUNE=0
  tune_backup rollback "${paths[@]}"
  pre="$TUNE_LAST_SNAPSHOT"
  panel_log "Khôi phục cấu hình từ bản sao $id ..."
  tune_restore_files "$dir"
  for path in "${paths[@]}"; do
    case "$path" in
      /etc/nginx/*) nginx=1 ;;
      /etc/my.cnf|/etc/my.cnf.d/*|/etc/mysql/*) mariadb=1 ;;
      /etc/php.d/*|/etc/opt/remi/*|/etc/php/*) php=1 ;;
      /etc/sysctl.conf|/etc/sysctl.d/*) sysctl=1 ;;
    esac
  done
  if (( nginx )) && ! err="$(nginx -t 2>&1)"; then
    tune_rollback_abort "$pre" "nginx -t báo lỗi với cấu hình của bản sao $id" "$err" 0 0 0
  fi
  if (( mariadb )) && ! err="$(tune_mariadb_config_check 2>&1)"; then
    tune_rollback_abort "$pre" "MariaDB không chấp nhận cấu hình của bản sao $id" "$err" 0 0 0
  fi
  if (( nginx )); then
    systemctl reload nginx
    nginx_save_known_good
  fi
  if (( php )); then
    php_fpm_reload_all || true
  fi
  if (( mariadb )) && ! tune_mariadb_restart; then
    tune_rollback_abort "$pre" "MariaDB không khởi động lại được với cấu hình của bản sao $id" "" "$nginx" "$php" 1
  fi
  if (( sysctl )); then
    sysctl --system >/dev/null 2>&1 || true
    panel_log "Lưu ý: tham số kernel đã gỡ chỉ trở về mặc định sau khi khởi động lại máy"
  fi
  tune_prune
  panel_log "Đã khôi phục cấu hình từ bản sao $id. Muốn hoàn tác: cecp-panel optimize rollback ${pre##*/}"
}
