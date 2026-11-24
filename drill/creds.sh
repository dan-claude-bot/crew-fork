#!/usr/bin/env bash
# drill/creds.sh — the drill's own credential pool (#828).
#
#   drill/creds.sh [--agent <name>] gh:<name>[,agent:<name>][,tg:<name>]
#
# The round's --creds names pool entries. Since #822 there is no per-user fleet
# whose pool the round could borrow, and a crew service's pool belongs to its
# account, so the drill keeps a pool of its own: $DRILL_POOL_HOME/credentials
# (default ~/.config/crew-drill/credentials), used whenever CREW_CREDENTIALS_DIR
# is not set. No fleet, no service and no environment variable are needed.
#
# This script adds whatever the named entries lack, asking on the terminal:
# each secret through crew's own `crew creds add` (read without echo, written
# 0600, never shown again), and the Telegram group chat when a tg entry is
# named. It is what the round runs itself when it has a terminal; without one,
# the round refuses and prints this command to run once on the drill host.
#
# Sourced by drill/rehearsal-all.sh for drill_creds_dir / drill_creds_missing /
# drill_creds_ensure; run directly, it is the standalone form.

: "${DRILL_POOL_HOME:=$HOME/.config/crew-drill}"
# Test seam: the terminal the prompts read from.
: "${DRILL_CREDS_TTY:=/dev/tty}"

drill_creds_dir() { printf '%s' "${CREW_CREDENTIALS_DIR:-$DRILL_POOL_HOME/credentials}"; }

# drill_creds_have_tty — true when the prompts have a terminal to read from.
drill_creds_have_tty() { { : <"$DRILL_CREDS_TTY"; } 2>/dev/null; }

# drill_creds_missing LIST — one line per thing the pool lacks for LIST: an
# entry id (gh:bot) or `tg-chat` when a tg entry is named and no chat is set.
drill_creds_missing() {
  local list="$1" dir e
  dir="$(drill_creds_dir)"
  for e in ${list//,/ }; do
    [ -r "$dir/entries/${e%%:*}--${e#*:}/secret" ] || echo "$e"
  done
  case ",$list" in *",tg:"*) [ -s "$dir/tg-chat" ] || echo tg-chat ;; esac
}

# drill_creds_ensure CREW AGENT LIST — ask for every missing item on the
# terminal and add it. CREW is the cli/crew to run. Non-zero on the first
# failure, having said which.
drill_creds_ensure() {
  local crew="$1" agent="$2" list="$3" dir fleet m svc name chat
  dir="$(drill_creds_dir)"
  fleet="$DRILL_POOL_HOME/fleet"
  drill_creds_have_tty || { echo "drill/creds.sh: no terminal to ask on" >&2; return 1; }
  mkdir -p "$dir" || return 1
  # crew creds runs against a fleet definition; the drill's is a bare scaffold
  # that exists only so the CLI has one. The pool itself is CREW_CREDENTIALS_DIR.
  if [ ! -f "$fleet/fleet.roster" ]; then
    CREW_CREDENTIALS_DIR="$dir" "$crew" init "$fleet" </dev/null >/dev/null 2>&1 ||
      { echo "drill/creds.sh: crew init $fleet failed" >&2; return 1; }
  fi
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    if [ "$m" = tg-chat ]; then
      printf 'drill: the Telegram group chat id the tg entry posts to: ' >&2
      read -r chat <"$DRILL_CREDS_TTY" || chat=""
      [ -n "$chat" ] || { echo "drill/creds.sh: no chat id given" >&2; return 1; }
      CREW_CONFIG_DIR="$fleet" CREW_CREDENTIALS_DIR="$dir" "$crew" creds chat "$chat" </dev/null ||
        { echo "drill/creds.sh: crew creds chat failed" >&2; return 1; }
      continue
    fi
    svc="${m%%:*}" name="${m#*:}"
    echo "drill: $m is not in the drill's pool ($dir) — adding it"
    if [ "$svc" = agent ]; then
      CREW_CONFIG_DIR="$fleet" CREW_CREDENTIALS_DIR="$dir" "$crew" creds add agent "$name" "$agent" <"$DRILL_CREDS_TTY"
    else
      CREW_CONFIG_DIR="$fleet" CREW_CREDENTIALS_DIR="$dir" "$crew" creds add "$svc" "$name" <"$DRILL_CREDS_TTY"
    fi || { echo "drill/creds.sh: crew creds add $svc $name failed" >&2; return 1; }
  done <<<"$(drill_creds_missing "$list")"
  [ -z "$(drill_creds_missing "$list")" ]
}

# drill_creds_hint AGENT LIST — the one command that fills the pool.
drill_creds_hint() { printf 'drill/creds.sh%s %s' "$([ "$1" = claude ] || printf ' --agent %s' "$1")" "$2"; }

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  AGENT=claude AGENT_ARGS=()
  [ "${1:-}" = --agent ] && { AGENT="${2:?--agent needs a name}"; AGENT_ARGS=(--agent "$AGENT"); shift 2; }
  LIST="${1:-}"
  [[ "$LIST" =~ ^((gh|agent|tg):[A-Za-z0-9][A-Za-z0-9._-]{0,63})(,(gh|agent|tg):[A-Za-z0-9][A-Za-z0-9._-]{0,63})*$ ]] ||
    { echo "usage: drill/creds.sh [--agent <name>] gh:<name>[,agent:<name>][,tg:<name>]" >&2; exit 1; }
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  CREW="$(dirname "$HERE")/cli/crew"
  # `crew creds add gh` asks GitHub who the token is, so gh must be there: on a
  # bare drill host the round's own provisioning runs first (#825).
  if [ -z "${DRILL_NO_PROVISION:-}" ] && [ -r "$HERE/provision.sh" ]; then
    # shellcheck source=drill/provision.sh
    . "$HERE/provision.sh"
    provision_round "$(dirname "$HERE")" "$HERE/creds.sh" ${AGENT_ARGS[@]+"${AGENT_ARGS[@]}"} "$LIST"
  fi
  if [ -z "$(drill_creds_missing "$LIST")" ]; then
    echo "drill: the drill's pool ($(drill_creds_dir)) already holds $LIST"; exit 0
  fi
  drill_creds_ensure "$CREW" "$AGENT" "$LIST" || exit 1
  echo "drill: the drill's pool ($(drill_creds_dir)) holds $LIST"
fi
