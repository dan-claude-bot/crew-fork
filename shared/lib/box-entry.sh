#!/usr/bin/env bash
# shared/lib/box-entry.sh — the ONE door crew uses to run anything inside a box
# (#792). Every host-side `box exec` in crew goes through box_in (or builds its
# argv with box_in_argv); nothing else spells `box exec`.
#
# WHY A DOOR AND NOT A FLAG AT EACH SITE. box 0.11.0 changes who you are when
# you get in (heavy-duty/box#291, amended 2026-11-22): `box exec` and
# `box shell` enter as ROOT unless `--user NAME` names someone, and box stops
# creating users at all (`box new --user` is refused) — the agent's user
# arrives with rig convergence. Before 0.11.0 the same calls entered as the
# box's stamped user, which crew's mint set to the agent. A crew call that
# names no user therefore keeps working on 0.11.0 and silently runs as root:
# files root-owned in the agent's home, logins written for the wrong user, and
# no error anywhere. One door is what makes "every agent-side call carries
# --user" checkable, the same way bxn made "stdin is always pinned" checkable
# (#48).
#
# THE ENTRY MODE IS READ, NEVER GUESSED.
#   user   box 0.11.0 or later, its -rc/-dev forms included: --user <agent>
#   stamp  anything older: today's argv, byte for byte
# An unreadable `box --version` refuses (exit 2). Defaulting to either mode
# would be a guess with a silent failure on one side: stamp on a 0.11.0 host
# runs as root, user on a 0.10 host passes a flag that box never had.
#
# THE AGENT COMES FROM THE ROSTER ROW (column 2), or from a binding the calling
# verb made for an ad-hoc box it was given `--agent` for (box_entry_bind). A box
# with neither is refused in user mode: entering it would mean picking a user
# out of the air or entering as root, and both are the defect this door closes.
#
# A CALL THAT GENUINELY MEANS ROOT does not use this door. It uses `box root`
# (the mint's converge script) or `box incus … exec` (the reset's largest-paths
# read), and says so where it does.

BOX_ENTRY_USER_SINCE="0.11.0"

# The process-wide cache. Not exported on purpose: a value inherited from an
# environment is a value nobody read from this host's box.
# platform.sh, version-skew.sh and box-mint.sh each source this file, so the
# state is initialised once: a second source must not forget the reading, the
# bindings or a mint in progress.
if [ -z "${BOX_ENTRY_LOADED:-}" ]; then
  BOX_ENTRY_LOADED=1
  BOX_ENTRY_MODE_CACHE=""
  BOX_ENTRY_BOX_VERSION=""
  # Boxes minted in this process whose convergence has not completed yet
  # (box_mint_fresh marks and clears them). Space-separated, padded.
  BOX_ENTRY_UNCONVERGED=" "
  declare -gA BOX_ENTRY_AGENTS=()
fi

# box_entry_mode_of VERSION — user|stamp for a bare version; rc 2 when the
# argument is not a version at all.
box_entry_mode_of() { # VERSION
  local v="${1:-}"
  [[ "$v" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-[A-Za-z0-9][A-Za-z0-9.-]*)?$ ]] || return 2
  # The numeric triple alone decides: 0.11.0-rc1 and 0.11.0-dev are 0.11.0's
  # own pre-releases and already carry its entry model.
  if [ "$((10#${BASH_REMATCH[1]}))" -gt 0 ] || [ "$((10#${BASH_REMATCH[2]}))" -ge 11 ]; then
    printf 'user\n'
  else
    printf 'stamp\n'
  fi
}

# box_entry_mode_load — read `box --version` ONCE per process and cache the
# mode. Silent on success; on an unreadable answer it names the command and
# returns 2. Call it in the parent shell (need_box does, for cli/crew) so the
# cache outlives the $(…) subshells most box_in calls run in; a subshell that
# finds the cache empty reads it again rather than guessing.
box_entry_mode_load() {
  [ -z "$BOX_ENTRY_MODE_CACHE" ] || return 0
  local line version mode
  line="$(box --version </dev/null 2>/dev/null | head -1 || true)"
  # `box 0.10.1 (/opt/box/versions/0.10.1)` — the word after `box`.
  version="$(awk '$1 == "box" { print $2; exit }' <<<"$line")"
  if ! mode="$(box_entry_mode_of "$version")"; then
    echo "crew: cannot read this host's box version — 'box --version' answered '${line:-nothing}'." >&2
    echo "crew: box $BOX_ENTRY_USER_SINCE and later enter a box as root unless --user names the agent, older boxes enter as the agent; crew will not guess which this host has." >&2
    return 2
  fi
  BOX_ENTRY_MODE_CACHE="$mode"
  BOX_ENTRY_BOX_VERSION="$version"
}

# box_entry_mode — print the cached mode (reading it first if needed).
box_entry_mode() {
  box_entry_mode_load || return 2
  printf '%s\n' "$BOX_ENTRY_MODE_CACHE"
}

# box_entry_bind BOX AGENT — this process knows BOX's agent without a roster
# row (`crew hire <box> --agent …`, a drill's own box). A binding wins over
# the roster, because the verb that made it was told explicitly.
box_entry_bind() { # BOX AGENT
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 0
  BOX_ENTRY_AGENTS["$1"]="$2"
}

# box_entry_roster_file — the roster in force: cli/crew's own resolved $ROSTER
# when it has one, otherwise the operator-owned cascade platform.sh uses.
box_entry_roster_file() {
  if [ -n "${ROSTER:-}" ]; then printf '%s\n' "$ROSTER"
  elif [ -n "${CREW_ROSTER:-}" ]; then printf '%s\n' "$CREW_ROSTER"
  elif [ -n "${CREW_CONFIG_DIR:-}" ]; then printf '%s\n' "$CREW_CONFIG_DIR/fleet.roster"
  else printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/crew/fleet.roster"
  fi
}

# box_entry_agent BOX — the agent BOX enters as in user mode; empty when
# nothing names one.
box_entry_agent() { # BOX
  if [ -n "${BOX_ENTRY_AGENTS[$1]+set}" ]; then
    printf '%s\n' "${BOX_ENTRY_AGENTS[$1]}"
    return 0
  fi
  local roster
  roster="$(box_entry_roster_file)"
  [ -r "$roster" ] || return 0
  { grep -vE '^[[:space:]]*(#|$)' "$roster" || true; } \
    | awk -v n="$1" '$1 == n { print $2; exit }'
}

box_entry_mark_unconverged() { # BOX
  case "$BOX_ENTRY_UNCONVERGED" in *" $1 "*) : ;; *) BOX_ENTRY_UNCONVERGED="$BOX_ENTRY_UNCONVERGED$1 " ;; esac
}
box_entry_mark_converged() { # BOX
  BOX_ENTRY_UNCONVERGED="${BOX_ENTRY_UNCONVERGED// $1 / }"
}

# box_in_argv BOX -- CMD… — fill the array BOX_IN_ARGV with the argv that
# enters BOX, for the callers that must wrap it (`timeout`, `time`). rc 2, and
# BOX_IN_ARGV empty, when the door refuses; the refusal is on stderr.
box_in_argv() { # BOX -- CMD...
  BOX_IN_ARGV=()
  local name="${1:-}" agent
  shift || true
  if [ -z "$name" ] || [ "${1:-}" != "--" ]; then
    echo "crew: box_in: usage: box_in <box> -- <command…>" >&2
    return 2
  fi
  shift
  box_entry_mode_load || return 2
  if [ "$BOX_ENTRY_MODE_CACHE" = stamp ]; then
    BOX_IN_ARGV=(box exec "$name" -- "$@")
    return 0
  fi
  agent="$(box_entry_agent "$name")"
  if [ -z "$agent" ]; then
    echo "crew: $name has no roster row naming its agent — box $BOX_ENTRY_BOX_VERSION enters as root unless --user names one, so crew will not enter it" >&2
    return 2
  fi
  case "$BOX_ENTRY_UNCONVERGED" in
    *" $name "*)
      echo "crew: $name is not converged yet — its $agent user arrives with rig convergence (box root $name, then rig bootstrap $agent-box); crew will not enter it before then" >&2
      return 2 ;;
  esac
  BOX_IN_ARGV=(box exec --user "$agent" "$name" -- "$@")
}

# box_in BOX -- CMD… — run CMD inside BOX as its agent. stdin is the caller's:
# bxn pins it to /dev/null, bxpipe and bxput hand it data.
box_in() { # BOX -- CMD...
  local -a BOX_IN_ARGV
  box_in_argv "$@" || return 2
  "${BOX_IN_ARGV[@]}"
}

# box_shell_hint BOX [AGENT] — the `box shell` line an operator should type to
# reach BOX as its agent. A hint never refuses: in user mode with no agent it
# prints the placeholder, and an unreadable mode prints the --user form, since
# that one can never land the operator in a root shell by accident.
box_shell_hint() { # BOX [AGENT]
  local name="$1" agent="${2:-}"
  [ -n "$agent" ] || agent="$(box_entry_agent "$name")"
  if box_entry_mode_load 2>/dev/null && [ "$BOX_ENTRY_MODE_CACHE" = stamp ]; then
    printf 'box shell %s\n' "$name"
  else
    printf 'box shell --user %s %s\n' "${agent:-<agent>}" "$name"
  fi
}

# box_exec_hint BOX -- CMD… — the `box exec` line for a printed hint, same rule.
box_exec_hint() { # BOX -- CMD...
  local name="$1" agent
  shift 2
  agent="$(box_entry_agent "$name")"
  if box_entry_mode_load 2>/dev/null && [ "$BOX_ENTRY_MODE_CACHE" = stamp ]; then
    printf 'box exec %s -- %s\n' "$name" "$*"
  else
    printf 'box exec --user %s %s -- %s\n' "${agent:-<agent>}" "$name" "$*"
  fi
}
