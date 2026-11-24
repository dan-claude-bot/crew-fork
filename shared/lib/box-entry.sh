#!/usr/bin/env bash
# shared/lib/box-entry.sh — ONE DOOR into a box (#792).
#
# box 0.11.0 changed who you are when you enter a box (heavy-duty/box#291):
# `box exec` and `box shell` enter as ROOT unless `--user NAME` names someone
# who exists in the box, and a missing NAME is refused, never a fallback. Before
# 0.11.0 they entered as the box's stamped user — for every crew box, the agent
# (claude, codex, …). A crew call that names no user would therefore start
# running as root on box 0.11.0 without a single error: files root-owned in the
# agent's home, logins written for the wrong user.
#
# So every crew entry that means "as the agent" goes through box_in, which has
# `box exec`'s own argument shape:
#
#     box_in BOX -- CMD...
#
#   stamp mode (box below 0.11.0)   box exec BOX -- CMD...       (today's argv)
#   user mode  (box 0.11.0 or later) box exec --user USER BOX -- CMD...
#
# A call that genuinely means root keeps `box exec` (root is box 0.11.0's
# default) or `box root`, and says so where it stands.
#
# THE MODE is read once per process from `box --version`: 0.11.0 or later —
# its -rc and -dev forms included — is `user`, older is `stamp`. An unreadable
# answer is a refusal (exit 2) naming `box --version`: nothing guesses which
# door a box has. CREW_BOX_ENTRY_MODE (stamp|user) overrides it, for fixtures.
#
# THE USER, in user mode, is the first of:
#   1. BOX_IN_USER, when the caller knows it (the drill names its agent);
#   2. box_entry_agent_of BOX, when the caller defines it (the CLI reads the
#      roster's agent column);
#   3. the box's one regular user (uid 1000–59999 in /etc/passwd, read as root,
#      the default door). Zero is a box not converged yet — rig creates the
#      tenant on box 0.11.0 — and more than one is ambiguous; both refuse
#      rather than entering as root.
# The answer is cached per box for the life of the process.
#
# shellcheck disable=SC1091
source "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/platform.sh"

BOX_ENTRY_FROM="0.11.0"
BOX_ENTRY_MODE_CACHED=""
BOX_ENTRY_USER=""
declare -a BOX_IN_FLAGS=()
declare -A BOX_ENTRY_USERS=()

# box_entry_resolve_mode — sets BOX_ENTRY_MODE_CACHED (stamp|user) in THIS
# shell, so the cache survives; rc 2 when the version is unreadable.
box_entry_resolve_mode() {
  [ -z "$BOX_ENTRY_MODE_CACHED" ] || return 0
  local v
  case "${CREW_BOX_ENTRY_MODE:-}" in
    stamp|user) BOX_ENTRY_MODE_CACHED="$CREW_BOX_ENTRY_MODE"; return 0 ;;
  esac
  v="$(platform_version_of "$(box --version 2>/dev/null </dev/null | head -1)")"
  if [ -z "$v" ]; then
    echo "crew: cannot read the box version ('box --version' gave no version) — the door into a box depends on it (#792); fix box, or set CREW_BOX_ENTRY_MODE=stamp|user" >&2
    return 2
  fi
  if platform_below_floor "$v" "$BOX_ENTRY_FROM"; then BOX_ENTRY_MODE_CACHED=stamp; else BOX_ENTRY_MODE_CACHED=user; fi
}
box_entry_mode() { box_entry_resolve_mode || return 2; printf '%s\n' "$BOX_ENTRY_MODE_CACHED"; }

# box_entry_resolve_user BOX — sets BOX_ENTRY_USER for BOX (see the header),
# caching it; rc 3 when the box has no single regular user to enter as.
box_entry_resolve_user() { # BOX
  local box="$1" u="" users n
  BOX_ENTRY_USER="${BOX_ENTRY_USERS[$box]:-}"
  [ -z "$BOX_ENTRY_USER" ] || return 0
  u="${BOX_IN_USER:-}"
  if [ -z "$u" ] && declare -F box_entry_agent_of >/dev/null; then u="$(box_entry_agent_of "$box" 2>/dev/null || true)"; fi
  if [ -z "$u" ]; then
    # Root, on purpose: this is the read that finds who else is there. A box
    # that does not answer (its agent restarting just after a converge, the
    # rc11 round's three role boxes) is not a box with no user: the read is
    # retried for BOX_ENTRY_ANSWER_S, and a box still silent after that is
    # named as not answering, with box's own words — never as unconverged.
    local err rc deadline=$((SECONDS + ${BOX_ENTRY_ANSWER_S:-90}))
    err="$(mktemp)"
    while :; do
      rc=0
      # shellcheck disable=SC2016  # the awk program is the guest's, not this shell's
      users="$(box exec "$box" -- awk -F: '$3 >= 1000 && $3 < 60000 {print $1}' /etc/passwd </dev/null 2>"$err")" || rc=$?
      if [ "$rc" -eq 0 ] || [ "$SECONDS" -ge "$deadline" ]; then break; fi
      sleep "${BOX_ENTRY_ANSWER_POLL_S:-3}"
    done
    if [ "$rc" -ne 0 ]; then
      echo "crew: $box is not answering (box exec as root failed, rc $rc: $(tr '\n' ' ' <"$err" | cut -c1-200)) — nothing was run" >&2
      rm -f "$err"
      return 3
    fi
    rm -f "$err"
    n="$(grep -c . <<<"$users" || true)"
    case "$n" in
      1) u="$users" ;;
      0) echo "crew: $box has no regular user to enter as — not converged yet (on box 0.11.0 rig creates the agent's user); nothing was run as root" >&2; return 3 ;;
      *) echo "crew: $box has $n regular users ($(paste -sd' ' - <<<"$users")) — cannot tell which is the agent; nothing was run as root" >&2; return 3 ;;
    esac
  fi
  BOX_ENTRY_USERS[$box]="$u"
  BOX_ENTRY_USER="$u"
}
box_entry_user() { local rc=0; box_entry_resolve_user "$1" || { rc=$?; return "$rc"; }; printf '%s\n' "$BOX_ENTRY_USER"; }

# box_in BOX -- CMD... — `box exec` as the box's agent, whichever box is here.
box_in() {
  local box="$1"
  shift
  box_entry_resolve_mode || return 2
  # Every return here carries its status explicitly: a bare `return` inside a
  # function called from a trap handler returns the status from BEFORE the
  # trap, not the last command's (bash's own rule) — and drill cleanups call
  # this from EXIT traps.
  local rc=0
  if [ "$BOX_ENTRY_MODE_CACHED" = stamp ]; then box exec "$box" "$@" || rc=$?; return "$rc"; fi
  box_entry_resolve_user "$box" || { rc=$?; return "$rc"; }
  box exec --user "$BOX_ENTRY_USER" "$box" "$@" || rc=$?
  return "$rc"
}

# box_in_flags BOX — sets BOX_IN_FLAGS to the words box_in would insert after
# `box exec` (none in stamp mode, `--user USER` in user mode), for a caller
# that must wrap the call itself — `timeout 10 box exec "${BOX_IN_FLAGS[@]}"
# BOX -- …` — because a shell function cannot run under timeout(1).
box_in_flags() { # BOX
  # shellcheck disable=SC2034  # the caller's to read
  BOX_IN_FLAGS=()
  box_entry_resolve_mode || return 2
  [ "$BOX_ENTRY_MODE_CACHED" = user ] || return 0
  local rc=0
  box_entry_resolve_user "$1" || { rc=$?; return "$rc"; }
  # shellcheck disable=SC2034  # the caller's to read
  BOX_IN_FLAGS=(--user "$BOX_ENTRY_USER")
}

# box_shell_hint BOX [AGENT] — the `box shell` line an operator can paste.
box_shell_hint() { # BOX [AGENT]
  local box="$1" agent="${2:-}"
  box_entry_resolve_mode 2>/dev/null || { printf 'box shell %s\n' "$box"; return 0; }
  if [ "$BOX_ENTRY_MODE_CACHED" = user ]; then
    if [ -z "$agent" ] && declare -F box_entry_agent_of >/dev/null; then agent="$(box_entry_agent_of "$box" 2>/dev/null || true)"; fi
    printf 'box shell --user %s %s\n' "${agent:-<agent>}" "$box"
  else
    printf 'box shell %s\n' "$box"
  fi
}
