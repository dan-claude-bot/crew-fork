# shared/lib/host/engine.sh — the engine reads GitHub as its App (#864).
#
# The engine is what reads GitHub from the HOST: the tick's board reads
# (wake.sh's wake_gh), the one-repo-one-fleet events check (cli/crew's
# foreign_actor_check). Every such call goes through engine_gh, which runs gh
# with GH_TOKEN set to the App's installation token for the repository's
# owner — or with gh's own login when no App is configured, as before #864.
# Members are untouched: a box's gh is the member's own credential.
#
# The token comes from fleet-floor/server/floor/engine.py (one copy, the
# floor's too). It is held in ENGINE_TOKENS for the life of this process and
# handed to gh in the child's environment — never argv, a file or a log line.
# engine_prime fills the cache in the CALLING shell, so the $(...) forks the
# board reads run in inherit it instead of each minting their own.
#
# The owner is read from the call's own arguments, so no call site changes:
#   -R o/r | --repo o/r | --repo=o/r    -f owner=o | -F owner=o    repos/o/r/…
#
# shellcheck shell=bash

declare -gA ENGINE_TOKENS=()   # owner (lower) -> token, or "-" for gh's own login
ENGINE_LAST_ERROR=""

engine_py() {
  CREW_HOST_STATE_DIR="$HOST_STATE_DIR" python3 "$CREW_ROOT/fleet-floor/server/floor/engine.py" "$@"
}

# engine_owner_of ARGS… — the account the call reads, or nothing.
engine_owner_of() {
  local a prev="" v=""
  for a in "$@"; do
    case "$prev" in
      -R|--repo) v="${a%%/*}"; break ;;
      -f|-F) case "$a" in owner=*) v="${a#owner=}"; break ;; esac ;;
    esac
    case "$a" in
      --repo=*) v="${a#--repo=}"; v="${v%%/*}"; break ;;
      repos/*/*) v="${a#repos/}"; v="${v%%/*}"; break ;;
      /repos/*/*) v="${a#/repos/}"; v="${v%%/*}"; break ;;
    esac
    prev="$a"
  done
  printf '%s\n' "$v"
}

# engine_token OWNER — sets ENGINE_TOKEN to the token, or "-" for gh's own
# login, in THIS shell (never run it in $(...): the reason would be lost with
# the subshell). Returns 1 with ENGINE_LAST_ERROR set when the App is
# configured but cannot read OWNER.
ENGINE_TOKEN=""
engine_token() {
  local owner="$1" key tok rc err
  key="${owner,,}"
  ENGINE_TOKEN="" ENGINE_LAST_ERROR=""
  if [ -n "${ENGINE_TOKENS[$key]:-}" ]; then ENGINE_TOKEN="${ENGINE_TOKENS[$key]}"; return 0; fi
  command -v python3 >/dev/null 2>&1 || { ENGINE_TOKEN=-; return 0; }
  err="$(mktemp)"
  tok="$(engine_py token "$owner" 2>"$err")" && rc=0 || rc=$?
  ENGINE_LAST_ERROR="$(sed 's/^engine: //' "$err" | tail -n1)"
  rm -f -- "$err"
  case "$rc" in
    0) ENGINE_TOKEN="$tok"; ENGINE_LAST_ERROR="" ;;
    3) ENGINE_TOKEN=-; ENGINE_LAST_ERROR="" ;;
    *) [ -n "$ENGINE_LAST_ERROR" ] || ENGINE_LAST_ERROR="the engine's App could not mint a token for $owner (rc $rc)"
       return 1 ;;
  esac
}

# engine_prime REPO — mint (or reuse) the token for REPO's owner in THIS
# shell. Returns 1, with ENGINE_LAST_ERROR, when the App cannot read it.
engine_prime() {
  local owner="${1%%/*}"
  [ -n "$owner" ] || return 0
  engine_token "$owner" || return 1
  ENGINE_TOKENS[${owner,,}]="$ENGINE_TOKEN"
}

# engine_gh ARGS… — gh, as the engine. A call whose owner the App cannot read
# fails with the reason on stderr; it never quietly falls back to a person.
engine_gh() {
  local owner
  owner="$(engine_owner_of "$@")"
  if [ -z "$owner" ]; then gh "$@"; return; fi
  engine_token "$owner" || { echo "engine: $ENGINE_LAST_ERROR" >&2; return 1; }
  if [ "$ENGINE_TOKEN" = - ]; then gh "$@"; return; fi
  GH_TOKEN="$ENGINE_TOKEN" GH_HOST=github.com GITHUB_TOKEN='' gh "$@"
}

# engine_configured — 0 when an App is configured (status reads, no token).
engine_configured() {
  local js
  command -v python3 >/dev/null 2>&1 || return 1
  js="$(engine_py status 2>/dev/null)" || return 1
  grep -q '"configured": true' <<<"$js"
}

# engine_describe — one line for `crew engine`, the tick and service check.
engine_describe() {
  local js
  js="$(engine_py status 2>/dev/null)" || js=""  # Decision-path empty fallback: an unread status reads as no App, said as such below
  if grep -q '"configured": true' <<<"$js"; then
    printf '%s' "$js" | python3 -c 'import json,sys; s=json.load(sys.stdin); print("GitHub App %s (id %s, owner %s)" % (s.get("slug") or "?", s.get("id"), s.get("owner") or "?"))'
  elif gh auth status >/dev/null 2>&1; then
    echo "no GitHub App — reading with gh's own login (Credentials → Engine on the floor gives it one)"
  else
    echo "no GitHub App and no gh login — no board can be read (Credentials → Engine on the floor gives it one)"
  fi
}
