#!/usr/bin/env bash
#
# tortoise — simulate a hostile network per-domain (packet loss, latency, low bandwidth).
#
# Degrades traffic to specific URLs/domains so you can watch the real app misbehave on a
# bad link, while the rest of your machine stays fast. Works for anyone (SE/demo or
# engineer), against local dev OR a deployed env — it shapes by the backend host's IPs,
# so any browser session pointing at that domain is affected.
#
# Each domain is controlled independently, and only ONE preset can be active on a domain
# at a time (re-applying replaces it — never double-shapes).
#
# macOS only. Uses the built-in dnctl (dummynet) + pfctl. Nothing to install.
#
#   sudo ./tortoise.sh on conference-wifi app.prophecy.io
#   ./tortoise.sh list           # what's being controlled right now
#   ./tortoise.sh presets        # what presets exist
#   sudo ./tortoise.sh off app.prophecy.io     # one domain
#   sudo ./tortoise.sh off all                 # everything
#
set -euo pipefail

ANCHOR="tortoise"
STATE_DIR="/tmp/tortoise.d"
PF_FLAG="$STATE_DIR/.pf_was_enabled"
PIPE_BASE=200          # pipe numbers are PIPE_BASE + 2*id-1 (out) / +2*id (in)
SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
HELPER_PATH="/usr/local/bin/tortoise"          # root-owned copy for passwordless (sudo) control
SUDOERS_FILE="/etc/sudoers.d/tortoise"
# user-defined presets live here (one per line:  name  bandwidth  delayMs  loss%)
PRESETS_FILE="${TORTOISE_PRESETS:-$HOME/.config/tortoise/presets.conf}"

# ---- presets --------------------------------------------------------------------------
# Values are PER DIRECTION (applied to both up and down), so round-trip latency ~= 2*delay
# and packet loss compounds across the round trip. Tuned to the Summit ask:
# packet loss 5-10%, latency 200-500ms RTT, bandwidth throttling.
#
#   name              bw           delay(ms)  plr (per-direction loss)
preset_builtin() {
  case "$1" in
    perfect)         echo "1000Mbit/s 0    0.0"   ;;  # no limits — baseline / sanity
    office-wifi)     echo "50Mbit/s   20   0.0"   ;;  # strong office / home wifi
    home)            echo "25Mbit/s   30   0.001" ;;  # typical home broadband
    coffee-shop)     echo "5Mbit/s    100  0.02"  ;;  # busy public wifi
    conference-wifi) echo "4Mbit/s    120  0.05"  ;;  # crowded venue — the headline case
    flaky)           echo "8Mbit/s    60   0.10"  ;;  # fast but drops packets — kills websockets
    slow-4g)         echo "1500Kbit/s 150  0.02"  ;;  # weak 4G
    slow-3g)         echo "780Kbit/s  150  0.01"  ;;  # 3G
    very-slow)       echo "240Kbit/s  400  0.05"  ;;  # 2.5G / hotel basement
    super-slow)      echo "50Kbit/s   800  0.10"  ;;  # 2G dead zone — brutal
    *)               return 1 ;;
  esac
}
PRESET_NAMES="perfect office-wifi home coffee-shop conference-wifi flaky slow-4g slow-3g very-slow super-slow"

# loss is given by users as a PERCENT (5, 5%, 0.5) → convert to a 0..1 fraction (plr)
norm_loss() { awk -v v="${1%\%}" 'BEGIN{ printf "%.4g", (v+0)/100 }'; }

# Resolve a preset token to "bw delay plr". Order: inline custom: > built-in > user file.
#   inline:   custom:<bw>:<delayMs>:<loss%>      e.g.  custom:2Mbit/s:250:5
#   user file (~/.config/tortoise/presets.conf):   name  bw  delayMs  loss%
resolve_preset() {
  local tok="$1"
  if [[ "$tok" == custom:* ]]; then
    local rest="${tok#custom:}" bw delay loss
    bw="${rest%%:*}"; rest="${rest#*:}"
    delay="${rest%%:*}"; loss="0"
    [[ "$rest" == *:* ]] && loss="${rest#*:}"
    [ -n "$bw" ] && [ -n "$delay" ] || return 1
    echo "$bw $delay $(norm_loss "$loss")"; return 0
  fi
  if preset_builtin "$tok" >/dev/null 2>&1; then preset_builtin "$tok"; return 0; fi
  if [ -f "$PRESETS_FILE" ]; then
    local line; line="$(grep -vE '^[[:space:]]*(#|$)' "$PRESETS_FILE" | awk -v n="$tok" '$1==n{print; exit}')"
    if [ -n "$line" ]; then
      local n bw delay loss; read -r n bw delay loss <<<"$line"
      [ -n "$bw" ] && [ -n "$delay" ] || return 1
      echo "$bw $delay $(norm_loss "${loss:-0}")"; return 0
    fi
  fi
  return 1
}

# ---- helpers --------------------------------------------------------------------------
die()  { echo "✗ $*" >&2; exit 1; }
info() { echo "  $*"; }

require_macos() { [ "$(uname -s)" = "Darwin" ] || die "tortoise is macOS-only (needs dnctl/pfctl)."; }

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "tortoise needs sudo (it changes the packet filter). Re-running with sudo…" >&2
    exec sudo -- "$0" "$@"
  fi
}

# Strip scheme / path / port / userinfo / stray whitespace → canonical bare host.
# Lowercased + trailing-dot-stripped so the SAME domain never yields two entries.
host_from_url() {
  local u; u="$(printf '%s' "$1" | tr -d '[:space:]' | tr 'A-Z' 'a-z')"
  u="${u#*://}"; u="${u%%/*}"; u="${u##*@}"; u="${u%%:*}"
  u="${u%.}"
  printf '%s' "$u"
}

# Resolve a host to IPv4 addresses (dedup). dscacheutil is always present on macOS.
resolve_ips() {
  local host="$1" ips=""
  if command -v dscacheutil >/dev/null 2>&1; then
    ips="$(dscacheutil -q host -a name "$host" 2>/dev/null | awk '/^ip_address:/ {print $2}')"
  fi
  if [ -z "$ips" ] && command -v host >/dev/null 2>&1; then
    ips="$(host -t A "$host" 2>/dev/null | awk '/has address/ {print $NF}')"
  fi
  if [ -z "$ips" ] && command -v dig >/dev/null 2>&1; then
    ips="$(dig +short A "$host" 2>/dev/null | grep -E '^[0-9.]+$')"
  fi
  echo "$ips" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u
}

pf_was_enabled() { pfctl -s info 2>/dev/null | grep -q "Status: Enabled"; }

sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
entry_file() { echo "$STATE_DIR/host_$(sanitize "$1").conf"; }
list_entries() { ls "$STATE_DIR"/host_*.conf 2>/dev/null || true; }
get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tr -d '"'; }   # get <file> <key>

# lowest free control id (drives pipe numbers); reuses an existing host's id on replace.
alloc_id_for_host() {
  local host="$1" f; f="$(entry_file "$host")"
  if [ -f "$f" ]; then get "$f" id; return; fi
  local used; used=" $(for e in $(list_entries); do get "$e" id; done | tr '\n' ' ') "
  local id=1
  while [[ "$used" == *" $id "* ]]; do id=$((id+1)); done
  echo "$id"
}

# (re)configure every active entry's pipes and rebuild the pf anchor as the union of all.
apply_all() {
  # declare the dummynet anchor on top of the user's existing ruleset
  ( cat /etc/pf.conf 2>/dev/null; echo "dummynet-anchor \"$ANCHOR\"" ) | pfctl -f - >/dev/null 2>&1

  local rules="" e
  for e in $(list_entries); do
    local po pi bw delay plr ips ipset
    po="$(get "$e" pipe_out)"; pi="$(get "$e" pipe_in)"
    bw="$(get "$e" bw)"; delay="$(get "$e" delay)"; plr="$(get "$e" plr)"
    ips="$(get "$e" ips)"
    ipset="{ $(echo "$ips" | xargs | sed 's/ /, /g') }"
    dnctl pipe "$po" config bw "$bw" delay "$delay" plr "$plr" >/dev/null 2>&1
    dnctl pipe "$pi" config bw "$bw" delay "$delay" plr "$plr" >/dev/null 2>&1
    # proto { tcp udp } so HTTP/3 (QUIC, UDP/443) is shaped too — Chrome uses it for many sites.
    rules+="dummynet out quick proto { tcp, udp } from any to $ipset port { 80, 443 } pipe $po"$'\n'
    rules+="dummynet in  quick proto { tcp, udp } from $ipset port { 80, 443 } to any pipe $pi"$'\n'
  done

  if [ -n "$rules" ]; then
    printf '%s' "$rules" | pfctl -a "$ANCHOR" -f - >/dev/null 2>&1
    pfctl -E >/dev/null 2>&1 || true
  else
    pfctl -a "$ANCHOR" -F all >/dev/null 2>&1 || true
  fi
}

teardown_all() {
  pfctl -a "$ANCHOR" -F all >/dev/null 2>&1 || true
  dnctl -q flush >/dev/null 2>&1 || true
  pfctl -f /etc/pf.conf >/dev/null 2>&1 || true
  if [ -f "$PF_FLAG" ] && grep -q "no" "$PF_FLAG"; then
    pfctl -d >/dev/null 2>&1 || true
  fi
  rm -rf "$STATE_DIR"
}

# ---- commands -------------------------------------------------------------------------
cmd_presets() {
  echo "Presets (values are per-direction):"
  echo
  printf "  %-16s %-12s %-10s %-16s\n" "NAME" "BANDWIDTH" "RTT~" "PACKET LOSS"
  local p bw delay plr
  for p in $PRESET_NAMES; do
    read -r bw delay plr <<<"$(preset_builtin "$p")"
    printf "  %-16s %-12s %-10s %-16s\n" "$p" "$bw" "$((delay*2))ms" "$(awk "BEGIN{print $plr*100}")%/dir"
  done
  if [ -f "$PRESETS_FILE" ] && grep -qvE '^[[:space:]]*(#|$)' "$PRESETS_FILE"; then
    echo "  ---- your presets ($PRESETS_FILE) ----"
    while read -r p bw delay loss; do
      [ -n "$p" ] && printf "  %-16s %-12s %-10s %-16s\n" "$p" "$bw" "$((delay*2))ms" "${loss%\%}%/dir"
    done < <(grep -vE '^[[:space:]]*(#|$)' "$PRESETS_FILE")
  fi
  echo
  echo "Apply: sudo $0 on <preset> <domain>   ·   one-off: sudo $0 on custom:<bw>:<delayMs>:<loss%> <domain>"
  echo "Define: $0 define <name> <bw> <delayMs> <loss%>   (e.g. $0 define office 20Mbit/s 40 0.5)"
}

# save a named preset to the user config (no root needed)
cmd_define() {
  local name="${1:-}" bw="${2:-}" delay="${3:-}" loss="${4:-0}"
  [ -n "$name" ] && [ -n "$bw" ] && [ -n "$delay" ] \
    || die "usage: $0 define <name> <bandwidth e.g. 2Mbit/s> <delayMs> <loss%>"
  case "$name" in perfect|office-wifi|home|coffee-shop|conference-wifi|flaky|slow-4g|slow-3g|very-slow|super-slow|custom) die "'$name' is a built-in name — pick another." ;; esac
  mkdir -p "$(dirname "$PRESETS_FILE")"
  if [ -f "$PRESETS_FILE" ]; then
    grep -vE "^[[:space:]]*$name([[:space:]]|$)" "$PRESETS_FILE" > "$PRESETS_FILE.tmp" 2>/dev/null || true
    mv "$PRESETS_FILE.tmp" "$PRESETS_FILE"
  fi
  printf '%s %s %s %s\n' "$name" "$bw" "$delay" "${loss%\%}" >> "$PRESETS_FILE"
  echo "✓ saved preset '$name'  ($bw, ${delay}ms/dir, ${loss%\%}% loss)  →  $PRESETS_FILE"
  echo "  use it:  sudo $0 on $name <domain>"
}

cmd_list() {
  local entries; entries="$(list_entries)"
  if [ -z "$entries" ]; then
    echo "tortoise: nothing under control (OFF)."
    echo "Start with: sudo $0 on conference-wifi <url-or-domain>"
    return 0
  fi
  echo "tortoise — domains under control:"
  echo
  printf "  %-4s %-16s %-38s %-22s\n" "ID" "PRESET" "DOMAIN" "SHAPING"
  local e
  for e in $entries; do
    local id host preset bw delay plr
    id="$(get "$e" id)"; host="$(get "$e" host)"; preset="$(get "$e" preset)"
    bw="$(get "$e" bw)"; delay="$(get "$e" delay)"; plr="$(get "$e" plr)"
    printf "  %-4s %-16s %-38s %s\n" "$id" "$preset" "$host" \
      "$bw, $((delay*2))ms RTT, $(awk "BEGIN{print $plr*100}")% loss"
  done
  echo
  echo "Turn off: sudo $0 off <domain|id>   ·   all: sudo $0 off all"
}

# machine-readable state (used by the menu-bar app and any scripting)
cmd_json() {
  local first=1
  printf '['
  local e
  for e in $(list_entries); do
    [ $first -eq 1 ] || printf ','
    first=0
    printf '{"id":%s,"host":"%s","preset":"%s","bw":"%s","delay":%s,"plr":%s,"ips":"%s"}' \
      "$(get "$e" id)" "$(get "$e" host)" "$(get "$e" preset)" "$(get "$e" bw)" \
      "$(get "$e" delay)" "$(get "$e" plr)" "$(get "$e" ips)"
  done
  printf ']\n'
}

# diagnose why shaping might not be biting (run with sudo for full detail)
cmd_doctor() {
  echo "tortoise doctor"
  echo "============="
  echo "pf status      : $(pf_was_enabled && echo ENABLED || echo disabled)"
  echo "controls       : $(list_entries | wc -l | xargs) domain(s) in $STATE_DIR"
  local e
  for e in $(list_entries); do
    local host ips
    host="$(get "$e" host)"; ips="$(get "$e" ips)"
    echo "  • $host  →  $ips"
    local live; live="$(resolve_ips "$host" | xargs)"
    if [ "$live" != "$(echo "$ips" | xargs)" ]; then
      echo "    ⚠ DNS now resolves to: $live"
      echo "      (CDN IPs rotated — re-run 'on' to re-shape. app.prophecy.io is behind CloudFront.)"
    fi
  done
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    echo "--- pfctl anchor '$ANCHOR' rules ---"
    pfctl -a "$ANCHOR" -s rules 2>/dev/null | sed 's/^/  /' || echo "  (none)"
    echo "--- dummynet pipes ---"
    dnctl -q list 2>/dev/null | grep -E "^[0-9]+:" | sed 's/^/  /' || echo "  (none)"
  else
    echo "(run 'sudo $0 doctor' to also dump the live pf rules + pipes)"
  fi
  echo
  echo "If a site still loads fast: it's usually (1) HTTP/3/QUIC now covered by udp rules — retry;"
  echo "(2) rotated CDN IPs — re-run 'on'; or (3) warm connections — hard-reload / new tab."
}

# enable passwordless (sudo) control: copy this script to a root-owned path + sudoers drop-in.
cmd_install() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || die "install must run as root (the app does this for you once)."
  local user="${1:-${SUDO_USER:-}}"
  [ -n "$user" ] || die "install needs a username: sudo $0 install <user>"
  install -d -o root -g wheel -m 755 "$(dirname "$HELPER_PATH")"
  install -o root -g wheel -m 755 "$SELF" "$HELPER_PATH"
  local tmp; tmp="$(mktemp)"
  printf '%s ALL=(root) NOPASSWD: %s\n' "$user" "$HELPER_PATH" > "$tmp"
  if visudo -cf "$tmp" >/dev/null 2>&1; then
    install -o root -g wheel -m 440 "$tmp" "$SUDOERS_FILE"; rm -f "$tmp"
    echo "✓ passwordless control enabled for '$user' via $HELPER_PATH"
  else
    rm -f "$tmp"; die "sudoers validation failed — passwordless not enabled."
  fi
}

cmd_uninstall() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || die "uninstall must run as root: sudo $0 uninstall"
  rm -f "$SUDOERS_FILE" "$HELPER_PATH"
  echo "✓ passwordless control removed."
}

# add/replace control for one or more domains
cmd_on() {
  local preset="${1:-}"; shift || true
  [ -n "$preset" ] || { cmd_presets; die "missing <preset>."; }
  local params; params="$(resolve_preset "$preset")" \
    || { cmd_presets; die "unknown preset '$preset' (and not a custom:<bw>:<delayMs>:<loss%> spec)."; }
  read -r bw delay plr <<<"$params"
  local label="$preset"; [[ "$preset" == custom:* ]] && label="custom"
  [ "$#" -ge 1 ] || die "missing <url-or-domain>. e.g. sudo $0 on $preset app.prophecy.io"

  require_root on "$preset" "$@"
  mkdir -p "$STATE_DIR"
  [ -f "$PF_FLAG" ] || { if pf_was_enabled; then echo yes; else echo no; fi > "$PF_FLAG"; }

  local arg
  for arg in "$@"; do
    local h; h="$(host_from_url "$arg")"; [ -n "$h" ] || continue
    local ips; ips="$(resolve_ips "$h")"
    [ -n "$ips" ] || die "could not resolve '$h' to an IP. Check the domain / your DNS / VPN."
    if [ -z "$(echo "$ips" | grep -vE '^127\.')" ]; then
      die "'$h' resolves only to loopback ($(echo $ips | xargs)).
     macOS can't shape loopback, so a backend on localhost/127.0.0.1 can't be degraded this way.
     For LOCAL dev: shape the REMOTE backend domain your app talks to
     (browser devtools → localStorage.getItem('domainUrl')), not localhost:3000.
     If the backend really is local, front it with a proxy (toxiproxy). See README → 'Local development'."
    fi

    # ONE preset per domain: drop every existing entry for this exact host — whatever its
    # filename (stale spellings, old buggy names) — reusing its id so pipes don't churn.
    local was="" reuse_id="" e
    for e in $(list_entries); do
      if [ "$(get "$e" host)" = "$h" ]; then
        [ -z "$reuse_id" ] && { reuse_id="$(get "$e" id)"; was="$(get "$e" preset)"; }
        rm -f "$e"
      fi
    done
    local id="${reuse_id:-$(alloc_id_for_host "$h")}"
    local f; f="$(entry_file "$h")"
    {
      echo "id=$id"
      echo "host=$h"
      echo "preset=$label"
      echo "ips=$(echo "$ips" | xargs)"
      echo "pipe_out=$((PIPE_BASE + 2*id - 1))"
      echo "pipe_in=$((PIPE_BASE + 2*id))"
      echo "bw=$bw"; echo "delay=$delay"; echo "plr=$plr"
    } > "$f"
    if [ -n "$was" ] && [ "$was" != "$label" ]; then
      info "replaced '$was' → '$label' on $h"
    fi
  done

  apply_all
  echo "✓ tortoise updated."
  echo
  cmd_list
}

cmd_off() {
  local target="${1:-all}"
  require_root off "$target"

  if [ "$target" = "all" ]; then
    teardown_all
    echo "✓ tortoise OFF — all shaping removed, network restored."
    return 0
  fi

  # match by domain (host_from_url) or by id
  local h; h="$(host_from_url "$target")"
  local f; f="$(entry_file "$h")"
  if [ ! -f "$f" ]; then
    # maybe it's an id
    local e found=""
    for e in $(list_entries); do
      if [ "$(get "$e" id)" = "$target" ]; then found="$e"; break; fi
    done
    [ -n "$found" ] || { cmd_list; die "no active control matches '$target' (use a domain or id, or 'all')."; }
    f="$found"; h="$(get "$f" host)"
  fi

  rm -f "$f"
  if [ -z "$(list_entries)" ]; then
    teardown_all
    echo "✓ tortoise OFF — '$h' removed (was the last one), network restored."
  else
    apply_all
    echo "✓ removed '$h' from control."
    echo
    cmd_list
  fi
}

# ---- dispatch -------------------------------------------------------------------------
require_macos
case "${1:-}" in
  on)              shift; cmd_on "$@" ;;
  off)             shift; cmd_off "$@" ;;
  list|ls|status)  cmd_list ;;
  presets|p)       cmd_presets ;;
  define)          shift; cmd_define "$@" ;;
  json)            cmd_json ;;
  doctor)          cmd_doctor ;;
  install)         shift; cmd_install "$@" ;;
  uninstall)       cmd_uninstall ;;
  ""|-h|--help|help)
    echo "tortoise — simulate a hostile network per-domain (macOS)."
    echo
    echo "  sudo $0 on <preset> <url-or-domain> [more...]    shape domain(s) (replaces existing)"
    echo "  sudo $0 off <domain|id>                          stop shaping one domain"
    echo "  sudo $0 off all                                  stop everything, restore network"
    echo "       $0 list                                     domains under control + preset"
    echo "       $0 presets                                  available presets"
    echo
    cmd_presets
    ;;
  *) die "unknown command '$1'. Try: $0 help" ;;
esac
