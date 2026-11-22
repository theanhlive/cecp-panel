#!/usr/bin/env bats
# pm.max_children sizing: php_ram_budget_mb + php_pool_max_children (lib/common.sh, used by
# lib/site.sh, lib/limits.sh, lib/system.sh) and optimize_redis_mem_mb (lib/optimize.sh).
# /proc/meminfo is replaced by $FAKE_MEMINFO through an awk wrapper.

setup() {
  load helpers
  load_common
  # shellcheck source=../../lib/optimize.sh
  source "$CECP_LIB_DIR/optimize.sh"
  set +u
  FAKE_MEMINFO="$T/meminfo"
  awk() {
    local a=() x
    for x in "$@"; do [[ "$x" == /proc/meminfo ]] && a+=("$FAKE_MEMINFO") || a+=("$x"); done
    command awk "${a[@]}"
  }
}

# ram MB — fake MemTotal.
ram() { printf 'MemTotal:       %d kB\nMemFree:          1 kB\n' "$(( $1 * 1024 ))" >"$FAKE_MEMINFO"; }
sites() { local i; for (( i = 1; i <= $1; i++ )); do echo '{}' >"$SITES_DIR/s$i.json"; done; }
redis() { echo "REDIS_MAXMEMORY_MB=$1" >"$ETC_DIR/redis.env"; }
# The MariaDB tune file paths are hard-coded under /etc: skip the formula tests that assume none.
no_host_db_cnf() {
  local c
  for c in /etc/my.cnf.d/cecp-tune.cnf /etc/mysql/mariadb.conf.d/99-cecp-tune.cnf /etc/mysql/conf.d/cecp-tune.cnf; do
    [[ ! -f "$c" ]] || skip "host has $c (path not overridable)"
  done
}

@test "php_ram_budget_mb: 1 GB, no tune file, no Redis = RAM - 30% DB - 300 MB" {
  no_host_db_cnf
  ram 1024
  run php_ram_budget_mb
  assert_status 0
  [[ "$output" == 417 ]] || fail "got $output"       # 1024 - 307 - 0 - 300
}

@test "php_ram_budget_mb: Redis maxmemory from redis.env is subtracted" {
  no_host_db_cnf
  ram 1024
  redis 102
  run php_ram_budget_mb
  [[ "$output" == 315 ]] || fail "got $output"       # 1024 - 307 - 102 - 300
}

@test "php_ram_budget_mb: never below a quarter of RAM (512 MB VPS)" {
  no_host_db_cnf
  ram 512
  redis 64
  run php_ram_budget_mb
  [[ "$output" == 128 ]] || fail "got $output"       # 512-153-64-300 < 0 -> 512/4
}

@test "php_ram_budget_mb: a malformed / hostile redis.env value is ignored" {
  no_host_db_cnf
  ram 1024
  printf '%s\n' 'REDIS_MAXMEMORY_MB=$(touch '"$T"'/pwned)' 'REDIS_MAXMEMORY_MB=100;id' >"$ETC_DIR/redis.env"
  run php_ram_budget_mb
  [[ "$output" == 417 ]] || fail "got $output"
  [[ ! -e "$T/pwned" ]]
}

@test "php_ram_budget_mb: unreadable meminfo falls back to 1024 MB" {
  no_host_db_cnf
  FAKE_MEMINFO="$T/missing"
  run php_ram_budget_mb
  [[ "$output" == 417 ]] || fail "got $output"
}

@test "php_pool_max_children: 1 GB, 1 site = 417/60 = 6" {
  no_host_db_cnf
  ram 1024
  sites 1
  run php_pool_max_children
  [[ "$output" == 6 ]] || fail "got $output"
}

@test "php_pool_max_children: no site yet counts as one site" {
  no_host_db_cnf
  ram 1024
  run php_pool_max_children
  [[ "$output" == 6 ]] || fail "got $output"
}

@test "php_pool_max_children: the budget is shared between sites (2 GB, 3 sites = 6)" {
  no_host_db_cnf
  ram 2048
  sites 3
  run php_pool_max_children
  [[ "$output" == 6 ]] || fail "got $output"         # (2048-614-300)=1134 /60 /3
}

@test "php_pool_max_children: floor is 2 workers (512 MB, many sites)" {
  no_host_db_cnf
  ram 512
  sites 10
  run php_pool_max_children
  [[ "$output" == 2 ]] || fail "got $output"
}

@test "php_pool_max_children: ceiling is 32 workers (16 GB, 1 site)" {
  no_host_db_cnf
  ram 16384
  sites 1
  run php_pool_max_children
  [[ "$output" == 32 ]] || fail "got $output"        # 11169/60 = 186 -> 32
}

@test "php_pool_max_children: 16 GB, 8 sites = 23 (below the ceiling)" {
  no_host_db_cnf
  ram 16384
  sites 8
  run php_pool_max_children
  [[ "$output" == 23 ]] || fail "got $output"
}

@test "php_pool_max_children: clamp and division with a stubbed budget" {
  php_ram_budget_mb() { echo "$BUDGET"; }
  local b s want
  while read -r b s want; do
    rm -f "$SITES_DIR"/*.json
    sites "$s"
    BUDGET="$b" run php_pool_max_children
    [[ "$output" == "$want" ]] || fail "budget $b sites $s: want $want got $output"
  done <<'T'
0 1 2
119 1 2
120 1 2
180 1 3
1920 1 32
1980 1 32
1200 2 10
1200 4 5
600 5 2
T
}

@test "php_pool_max_children: only *.json files in SITES_DIR count as sites" {
  php_ram_budget_mb() { echo 1200; }
  sites 2
  touch "$SITES_DIR/s1.json.bak" "$SITES_DIR/notes.txt"
  mkdir -p "$SITES_DIR/sub" && echo '{}' >"$SITES_DIR/sub/deep.json"
  run php_pool_max_children
  [[ "$output" == 10 ]] || fail "got $output"
}

@test "optimize_redis_mem_mb: 10% of RAM clamped to 64..512" {
  local r want
  while read -r r want; do
    ram "$r"
    run optimize_redis_mem_mb
    [[ "$output" == "$want" ]] || fail "ram $r: want $want got $output"
  done <<'T'
256 64
640 64
1024 102
2048 204
5120 512
16384 512
T
}
