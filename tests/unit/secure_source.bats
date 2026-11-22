#!/usr/bin/env bats
# secure_source (lib/common.sh): a file root sources must be root-owned and not group/other
# writable. Real-file tests need root (the panel runs as root); a stubbed `stat` covers the
# mode logic everywhere.

setup() {
  load helpers
  load_common
  F="$T/conf.env"
  printf 'CONF_VALUE=%s\n' hello >"$F"
  chmod 600 "$F"
}

need_root() { [[ "$(id -u)" -eq 0 ]] || skip "needs root (real file ownership)"; }

# stub_stat UID MODE — `stat -c %u|%a FILE` answers UID / MODE for any file.
stub_stat() {
  STUB_UID="$1" STUB_MODE="$2"
  stat() { case "$2" in %u) echo "$STUB_UID" ;; %a) echo "$STUB_MODE" ;; esac; }
}

@test "secure_source: a root-owned 600 file is sourced into the caller" {
  need_root
  secure_source "$F"
  [[ "$CONF_VALUE" == hello ]]
}

@test "secure_source: modes 644, 640, 400 and 755 are accepted" {
  need_root
  local m
  for m in 644 640 400 755; do
    chmod "$m" "$F"
    run secure_source "$F"
    [[ "$status" -eq 0 ]] || fail "mode $m refused: $output"
  done
}

@test "secure_source: group-writable (660/620) is refused and NOT sourced" {
  need_root
  echo 'touch "$T/pwned"' >>"$F"
  local m
  for m in 660 620 670; do
    chmod "$m" "$F"
    run secure_source "$F"
    assert_status 1
    assert_output_has "writable by group/others (mode $m)"
  done
  [[ ! -e "$T/pwned" ]]
}

@test "secure_source: world-writable (602/666/777) is refused and NOT sourced" {
  need_root
  echo 'touch "$T/pwned"' >>"$F"
  local m
  for m in 602 666 777; do
    chmod "$m" "$F"
    run secure_source "$F"
    assert_status 1
    assert_output_has "writable by group/others"
  done
  [[ ! -e "$T/pwned" ]]
}

@test "secure_source: a file owned by another user is refused and NOT sourced" {
  need_root
  echo 'touch "$T/pwned"' >>"$F"
  chown 65534 "$F"
  run secure_source "$F"
  assert_status 1
  assert_output_has "not owned by root"
  [[ ! -e "$T/pwned" ]]
}

@test "secure_source: a missing file returns 1 without dying" {
  run secure_source "$T/nope.env"
  assert_status 1
  [[ "$output" != *ERROR* ]] || fail "should be silent: $output"
  run secure_source ""
  assert_status 1
}

@test "secure_source: a directory is not sourced" {
  mkdir "$T/dir.env"
  run secure_source "$T/dir.env"
  assert_status 1
}

@test "secure_source: a symlink (mode 777 on the link) is refused, even to a safe file" {
  need_root
  ln -s "$F" "$T/link.env"
  run secure_source "$T/link.env"
  assert_status 1
  assert_output_has "writable by group/others"
}

@test "secure_source: a hostile file NAME (; \$() ../ spaces) is never executed as code" {
  need_root
  local d="$T/a;touch \$(echo pwned1) ../b"
  mkdir -p "$d"
  local f="$d/x \$(touch pwned2);touch pwned3.env"
  echo 'NAME_OK=1' >"$f"
  chmod 600 "$f"
  ( cd "$T" && secure_source "$f" && [[ "$NAME_OK" == 1 ]] )
  [[ ! -e "$T/pwned1" && ! -e "$T/pwned2" && ! -e "$T/pwned3.env" ]]
}

@test "secure_source (stubbed stat): uid 0 + 600 is sourced" {
  stub_stat 0 600
  secure_source "$F"
  [[ "$CONF_VALUE" == hello ]]
}

@test "secure_source (stubbed stat): every group/other write bit is refused" {
  local m
  for m in 620 602 622 660 606 666 1777 2775 4757; do
    stub_stat 0 "$m"
    run secure_source "$F"
    [[ "$status" -eq 1 ]] || fail "mode $m accepted"
  done
}

@test "secure_source (stubbed stat): setuid/sticky bits without write bits are accepted" {
  local m
  for m in 4755 2755 1755 644 444 0; do
    stub_stat 0 "$m"
    run secure_source "$F"
    [[ "$status" -eq 0 ]] || fail "mode $m refused: $output"
  done
}

@test "secure_source (stubbed stat): non-root owner uid is refused before the mode check" {
  local u
  for u in 1 1000 65534 00; do
    stub_stat "$u" 600
    run secure_source "$F"
    assert_status 1
    assert_output_has "not owned by root"
  done
}
