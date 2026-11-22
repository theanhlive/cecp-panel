#!/usr/bin/env bats
# validate_* in lib/common.sh: valid input, boundaries and hostile input (all untrusted:
# arguments come from CECP Core, n8n or the menu). A rejection is panel_die => exit 1.

setup() {
  load helpers
  load_common
}

# accept / reject: run the validator in a subshell (panel_die exits).
accepts() { run "$@"; [[ "$status" -eq 0 ]] || fail "should accept: $* -> $status $output"; }
rejects() { run "$@"; [[ "$status" -eq 1 ]] || fail "should reject: $* -> $status $output"; [[ "$output" == *"ERROR"* ]] || fail "no ERROR line: $output"; }

# --- validate_domain -------------------------------------------------------
@test "validate_domain: ordinary domains are accepted" {
  accepts validate_domain example.com
  accepts validate_domain a.b.c.example.vn
  accepts validate_domain my-site.co.uk
  accepts validate_domain 1.example.com
  accepts validate_domain xn--vi-7ka.vn          # punycode IDN
}

@test "validate_domain: label length boundary 63 ok, 64 rejected" {
  local l63 l64
  l63="$(printf 'a%.0s' {1..63})"
  l64="$(printf 'a%.0s' {1..64})"
  accepts validate_domain "${l63}.com"
  rejects validate_domain "${l64}.com"
}

@test "validate_domain: total length boundary 253 ok, 254 rejected" {
  local l63 d253 d254
  l63="$(printf 'a%.0s' {1..63})"
  d253="${l63}.${l63}.${l63}.$(printf 'b%.0s' {1..61})"   # 63*3 + 61 + 3 dots = 253
  [[ ${#d253} -eq 253 ]]
  accepts validate_domain "$d253"
  d254="${l63}.${l63}.${l63}.$(printf 'b%.0s' {1..62})"
  [[ ${#d254} -eq 254 ]]
  rejects validate_domain "$d254"
}

@test "validate_domain: empty, single label, dots and hyphens at edges are rejected" {
  rejects validate_domain ""
  rejects validate_domain localhost
  rejects validate_domain .example.com
  rejects validate_domain example.com.
  rejects validate_domain example..com
  rejects validate_domain -example.com
  rejects validate_domain example-.com
}

@test "validate_domain: uppercase is rejected (callers lowercase first)" {
  rejects validate_domain Example.com
}

@test "validate_domain: an all-numeric TLD (IP address) is rejected" {
  rejects validate_domain 192.168.1.1
  rejects validate_domain example.123
}

@test "validate_domain: shell metacharacters are rejected" {
  rejects validate_domain 'example.com;id'
  rejects validate_domain 'ex$(id).com'
  rejects validate_domain 'ex`id`.com'
  rejects validate_domain 'example.com|sh'
  rejects validate_domain 'example.com&&id'
  rejects validate_domain 'a b.com'
  rejects validate_domain "example.com'"
}

@test "validate_domain: path traversal and slashes are rejected" {
  rejects validate_domain '../etc/passwd'
  rejects validate_domain 'example.com/../x'
  rejects validate_domain '..'
  rejects validate_domain 'example.com/'
}

@test "validate_domain: newline / NUL-ish / tab tricks are rejected" {
  rejects validate_domain $'example.com\nid'
  rejects validate_domain $'example.com\n'
  rejects validate_domain $'example.com\t'
  rejects validate_domain $'\nexample.com'
}

@test "validate_domain: raw unicode is rejected in C and UTF-8 locales" {
  rejects validate_domain 'ví.vn'
  rejects validate_domain 'xn--ví.vn'
  rejects validate_domain 'exаmple.com'            # Cyrillic 'а' homoglyph
  LC_ALL=C.UTF-8 rejects validate_domain 'ví.vn'
  LC_ALL=C.UTF-8 rejects validate_domain 'exаmple.com'
}

# --- validate_dns_name -----------------------------------------------------
@test "validate_dns_name: a single label or a full domain is accepted" {
  accepts validate_dns_name test2
  accepts validate_dns_name www
  accepts validate_dns_name a
  accepts validate_dns_name shop.example.com
}

@test "validate_dns_name: wildcard, underscore, empty and injection are rejected" {
  rejects validate_dns_name ""
  rejects validate_dns_name '*'
  rejects validate_dns_name '_dmarc'
  rejects validate_dns_name '-www'
  rejects validate_dns_name 'www;id'
  rejects validate_dns_name '$(id)'
  rejects validate_dns_name '../x'
  rejects validate_dns_name "$(printf 'a%.0s' {1..64})"
}

# --- validate_ipv4 ---------------------------------------------------------
@test "validate_ipv4: boundaries 0.0.0.0 and 255.255.255.255 are accepted" {
  accepts validate_ipv4 0.0.0.0
  accepts validate_ipv4 255.255.255.255
  accepts validate_ipv4 203.0.113.7
}

@test "validate_ipv4: an octet above 255 is rejected in every position" {
  rejects validate_ipv4 256.1.1.1
  rejects validate_ipv4 1.256.1.1
  rejects validate_ipv4 1.1.256.1
  rejects validate_ipv4 1.1.1.256
  rejects validate_ipv4 999.999.999.999
}

@test "validate_ipv4: wrong shape is rejected" {
  rejects validate_ipv4 ""
  rejects validate_ipv4 1.2.3
  rejects validate_ipv4 1.2.3.4.5
  rejects validate_ipv4 1.2.3.4/24
  rejects validate_ipv4 1.2.3.0004
  rejects validate_ipv4 ::1
  rejects validate_ipv4 -1.2.3.4
}

@test "validate_ipv4: injection and newline are rejected" {
  rejects validate_ipv4 '1.2.3.4;id'
  rejects validate_ipv4 '1.2.3.$(id)'
  rejects validate_ipv4 $'1.2.3.4\n5.6.7.8'
  rejects validate_ipv4 ' 1.2.3.4'
}

@test "validate_ipv4: leading zeros are rejected (inet_aton reads 010 as octal 8)" {
  rejects validate_ipv4 010.0.0.1
  rejects validate_ipv4 10.08.09.1
  rejects validate_ipv4 10.0.0.00
  rejects validate_ipv4 10.0.0.0256
  accepts validate_ipv4 10.0.0.0
  accepts validate_ipv4 0.0.0.0
}

# --- validate_url ----------------------------------------------------------
@test "validate_url: http and https URLs with port, path and query are accepted" {
  accepts validate_url https://example.com
  accepts validate_url http://example.com/
  accepts validate_url 'https://n8n.example.com:5678/webhook/abc-123?x=1&y=2'
  accepts validate_url https://raw.githubusercontent.com/o/r/main
  accepts validate_url https://10.0.0.1:8443/path/to%20x
}

@test "validate_url: other schemes and missing host are rejected" {
  rejects validate_url ""
  rejects validate_url ftp://example.com
  rejects validate_url file:///etc/passwd
  rejects validate_url 'javascript:alert(1)'
  rejects validate_url https://
  rejects validate_url example.com
  rejects validate_url HTTPS://example.com
}

@test "validate_url: credentials, spaces, quotes and backticks are rejected" {
  rejects validate_url 'https://user:pw@example.com/'
  rejects validate_url 'https://exa mple.com/'
  rejects validate_url 'https://example.com/a b'
  rejects validate_url "https://example.com/'x"
  rejects validate_url 'https://example.com/"x'
  rejects validate_url 'https://example.com/`id`'
  rejects validate_url 'https://example.com/<x>'
}

@test "validate_url: shell metacharacters in the HOST part are rejected" {
  rejects validate_url 'https://example.com;id/'
  rejects validate_url 'https://$(id).com/'
  rejects validate_url 'https://example.com|sh'
}

@test "validate_url: newline injection is rejected" {
  rejects validate_url $'https://example.com/\n;rm -rf /'
  rejects validate_url $'https://example.com\nhttps://evil.com'
}

@test "validate_url: port longer than 5 digits and unicode host are rejected" {
  rejects validate_url https://example.com:123456/
  rejects validate_url https://ví.vn/
}

# --- validate_int_range ----------------------------------------------------
@test "validate_int_range: inclusive bounds are accepted" {
  accepts validate_int_range 1 1 10
  accepts validate_int_range 10 1 10
  accepts validate_int_range 0 0 0
  accepts validate_int_range 999999 0 999999
}

@test "validate_int_range: one past either bound is rejected" {
  rejects validate_int_range 0 1 10
  rejects validate_int_range 11 1 10
}

@test "validate_int_range: leading zeros are decimal, not octal" {
  accepts validate_int_range 08 1 10
  accepts validate_int_range 010 1 10    # 10, not octal 8
  rejects validate_int_range 011 1 10    # 11
}

@test "validate_int_range: non-numbers, signs and more than 6 digits are rejected" {
  rejects validate_int_range "" 0 10
  rejects validate_int_range -1 -5 10
  rejects validate_int_range +1 0 10
  rejects validate_int_range 1.5 0 10
  rejects validate_int_range 1e3 0 10000
  rejects validate_int_range 0x10 0 100
  rejects validate_int_range 1234567 0 9999999
  rejects validate_int_range ' 5' 0 10
}

@test "validate_int_range: arithmetic injection is rejected and never evaluated" {
  local marker="$T/pwned"
  rejects validate_int_range 'a[$(touch '"$marker"')]' 0 10
  rejects validate_int_range '1;id' 0 10
  rejects validate_int_range '$(id)' 0 10
  rejects validate_int_range $'5\n6' 0 10
  [[ ! -e "$marker" ]]
}

@test "validate_int_range: the error names the field and the range" {
  run validate_int_range 99 1 10 "PHP workers"
  assert_status 1
  assert_output_has "Invalid PHP workers: '99' (expected 1-10)"
}
