# shared/lib/host/intent.sh — a member's intent: what the OPERATOR wants of it
# (#898). One file per member, `<config>/store/intent/<box>`, whose first word
# is the intent and whose rest is when and by whom:
#
#   stopped  <ts> <actor> [stopping]   held off. Keeps its claims. Only Start
#                                      lifts it. `stopping` while the box still
#                                      finishes the run it was in.
#   paused   <ts> <actor>              frozen where it was (`incus pause`);
#                                      Resume continues the same session.
#   off-duty <ts> <actor>              unhired: claims handed back, cron
#                                      disarmed, box stopped and kept.
#
# No file is ON DUTY: the host tick may wake it. The tick obeys this and
# nothing else — it never starts a member that is not on duty, so a stop the
# operator chose is never read as the tick's own sleep (asleep).
#
# The pre-#898 pause marker, `<config>/store/paused/<box>`, held a member off
# exactly as `stopped` does now; it is read as `stopped` so a fleet paused
# before the upgrade stays held, and every write here removes it.
#
# Sourced by cli/crew; the floor reads the same files (floor/intent.py), so
# the console, the CLI and the tick read one fact.
#
# shellcheck shell=bash

INTENTS="stopped paused off-duty"

intent_dir()  { printf '%s/store/intent' "$CONFIG_DIR"; }
intent_file() { printf '%s/%s' "$(intent_dir)" "$1"; }
intent_legacy_file() { printf '%s/store/paused/%s' "$CONFIG_DIR" "$1"; }

# intent_of BOX — on-duty | stopped | paused | off-duty. An unreadable or
# unknown word reads as `stopped`: a file someone wrote means "hold it", and
# holding is the answer that spends nothing.
intent_of() {
  local f w
  f="$(intent_file "$1")"
  if [ -e "$f" ]; then
    read -r w _ <"$f" 2>/dev/null || w="" # Decision-path empty fallback: an unreadable intent file reads as stopped just below, the answer that holds
    case " $INTENTS " in *" $w "*) printf '%s\n' "$w" ;; *) printf 'stopped\n' ;; esac
    return 0
  fi
  [ ! -e "$(intent_legacy_file "$1")" ] || { printf 'stopped\n'; return 0; }
  printf 'on-duty\n'
}

# intent_line BOX — the whole record, or nothing when on duty.
intent_line() {
  local f
  f="$(intent_file "$1")"
  if [ -e "$f" ]; then head -1 "$f" 2>/dev/null; return 0; fi
  [ ! -e "$(intent_legacy_file "$1")" ] || printf 'stopped %s - (paused before #898)\n' "$(head -1 "$(intent_legacy_file "$1")" 2>/dev/null)"
}

# intent_held BOX — rc 0 when the operator holds it off (any intent but on duty).
intent_held() { [ "$(intent_of "$1")" != on-duty ]; }

# intent_set BOX INTENT [FLAG] — written atomically; the legacy marker goes.
intent_set() {
  local box="$1" what="$2" flag="${3:-}" dir tmp actor
  case " $INTENTS " in *" $what "*) ;; *) echo "intent: unknown intent '$what'" >&2; return 2 ;; esac
  dir="$(intent_dir)"; mkdir -p "$dir" || return 1
  actor="${CREW_ACTOR:-${SUDO_USER:-${USER:-$(id -un 2>/dev/null || echo '?')}}}"
  tmp="$(mktemp "$dir/.intent.XXXXXX")" || return 1
  if ! printf '%s %s %s%s\n' "$what" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${actor// /_}" "${flag:+ $flag}" >"$tmp" \
     || ! mv -f "$tmp" "$(intent_file "$box")"; then
    rm -f "$tmp"; return 1
  fi
  rm -f "$(intent_legacy_file "$box")"
}

# intent_clear BOX — back on duty.
intent_clear() { rm -f "$(intent_file "$1")" "$(intent_legacy_file "$1")"; }

# intent_stopping BOX — rc 0 while a graceful Stop waits for the run to end.
intent_stopping() {
  local w flag
  [ -e "$(intent_file "$1")" ] || return 1
  read -r w _ _ flag _ <"$(intent_file "$1")" 2>/dev/null || return 1
  [ "$w" = stopped ] && [ "$flag" = stopping ]
}

# --- credentials the operator removed (#898) ------------------------------------
# `<config>/store/logout/<box>.<svc>`: a service whose login the operator
# removed. While it stands the tick does not wake the member (it would spend a
# start to fail at login), and a box that was off when the removal was asked
# gets it on its next start, before any duty runs (`owed` until then,
# `applied` once it has). Setting the service again
# (crew login, the pool) lifts it.
logout_file() { printf '%s/store/logout/%s.%s' "$CONFIG_DIR" "$1" "$2"; }
logout_mark() {
  mkdir -p "$CONFIG_DIR/store/logout" || return 1
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${3:-owed}" >"$(logout_file "$1" "$2")"
}
logout_lift() { rm -f "$(logout_file "$1" "$2")"; }
# logout_services BOX — the services removed, space-separated ("" for none).
logout_services() {
  local f out="" svc
  for f in "$CONFIG_DIR/store/logout/$1".*; do
    [ -e "$f" ] || continue
    svc="${f##*.}"; out="$out $svc"
  done
  printf '%s' "${out# }"
}
# logout_owed BOX — the services whose removal has not reached the box yet.
logout_owed() {
  local f out="" w
  for f in "$CONFIG_DIR/store/logout/$1".*; do
    [ -e "$f" ] || continue
    read -r _ w _ <"$f" 2>/dev/null || w=owed
    [ "$w" = applied ] || out="$out ${f##*.}"
  done
  printf '%s' "${out# }"
}

# intent_note BOX — the operator's hold in one sentence, word for word the
# floor's (floor/intent.py note()), or nothing when on duty. The two consoles
# describing one member differently is the defect, not the wording.
intent_note() {
  local w ts
  w="$(intent_of "$1")"
  ts="$(intent_line "$1" | awk '{print $2}')"
  case "$w" in
    stopped)
      if intent_stopping "$1"; then echo "stopping by operator — finishing its run, then stopped"
      else echo "stopped by operator — Start lifts it"; fi ;;
    paused) echo "paused by operator${ts:+ since $ts} — Resume continues it" ;;
    off-duty)
      if intent_stopping "$1"; then echo "going off duty — finishing its run, then its claims go back"
      else echo "off duty — Hire puts it back"; fi ;;
  esac
}
