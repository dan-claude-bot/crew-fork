#!/usr/bin/env bash
# shared/test/engine.sh — the engine's gh, offline (#864): which owner a call
# reads, the App's token in gh's environment and never its argv, gh's own
# login when no App is configured, and a call the App cannot read refused by
# name instead of falling back to a person. engine.py is a stub here; its own
# test is fleet-floor/test/engine.py.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export XDG_CONFIG_HOME="$TMP/xdg-empty"
HOST_STATE_DIR="$TMP/state"
CREW_ROOT="$ROOT"
# shellcheck source=shared/lib/host/engine.sh
source "$ROOT/shared/lib/host/engine.sh"

# --- the owner, from the call's own arguments --------------------------------
t owner-from-R acme "$(engine_owner_of issue list -R acme/site --state open)"
t owner-from-repo acme "$(engine_owner_of pr view 3 --repo acme/site)"
t owner-from-repo-eq acme "$(engine_owner_of pr list --repo=acme/site)"
t owner-from-graphql-field acme "$(engine_owner_of api graphql -f owner=acme -f name=site -f query=q)"
t owner-from-api-path acme "$(engine_owner_of api -X GET 'repos/acme/site/events?per_page=100')"
t owner-from-api-path-slash acme "$(engine_owner_of api /repos/acme/site)"
t owner-none-for-user-reads "" "$(engine_owner_of api user --jq .login)"

# --- gh as the engine ----------------------------------------------------------
GH_LOG="$TMP/gh.log"
gh() { printf 'token=%s host=%s args=%s\n' "${GH_TOKEN:-none}" "${GH_HOST:-none}" "$*" >>"$GH_LOG"; }
ENGINE_PY_CALLS="$TMP/py.log"
engine_py() {
  echo "$*" >>"$ENGINE_PY_CALLS"
  case "${ENGINE_STUB:-}" in
    none) return 3 ;;
    app)  echo "ghs_STUB" ;;
    uninstalled) echo "engine: the engine's App engine-x is not installed on $2 — install it: https://github.com/apps/engine-x/installations/new" >&2; return 1 ;;
  esac
}

ENGINE_STUB=none; : >"$GH_LOG"; ENGINE_TOKENS=()
engine_gh issue list -R acme/site
t no-app-runs-gh-with-its-own-login "token=none host=none args=issue list -R acme/site" "$(cat "$GH_LOG")"

ENGINE_STUB=app; : >"$GH_LOG"; : >"$ENGINE_PY_CALLS"; ENGINE_TOKENS=()
engine_gh issue list -R acme/site
t app-token-rides-gh-env "token=ghs_STUB host=github.com args=issue list -R acme/site" "$(cat "$GH_LOG")"
t app-token-never-in-argv 0 "$(grep -c 'args=.*ghs_STUB' "$GH_LOG")"

: >"$ENGINE_PY_CALLS"; ENGINE_TOKENS=()
engine_prime acme/site
( engine_gh pr list -R acme/site; engine_gh api graphql -f owner=acme -f name=site ) >/dev/null
t prime-mints-once-and-forks-reuse-it 1 "$(grep -c '^token acme$' "$ENGINE_PY_CALLS")"
t prime-is-per-owner-case-blind 1 "$( engine_prime ACME/other; grep -c '^token' "$ENGINE_PY_CALLS")"

ENGINE_STUB=uninstalled; : >"$GH_LOG"; ENGINE_TOKENS=()
err="$(engine_gh issue list -R nobody/x 2>&1 >/dev/null)"; rc=$?
t uninstalled-is-refused 1 "$rc"
t uninstalled-never-falls-back-to-gh "" "$(cat "$GH_LOG")"
t uninstalled-is-named 1 "$(grep -c 'not installed on nobody' <<<"$err")"
ENGINE_LAST_ERROR=""; engine_prime nobody/x; rc=$?
t prime-uninstalled-is-1 1 "$rc"
t prime-sets-the-reason 1 "$(grep -c 'not installed on nobody' <<<"$ENGINE_LAST_ERROR")"

ENGINE_STUB=app; : >"$GH_LOG"
engine_gh api user --jq .login
t a-call-with-no-owner-is-gh-as-is "token=none host=none args=api user --jq .login" "$(cat "$GH_LOG")"

# --- wake.sh's reads go through it -------------------------------------------
t wake-gh-is-the-engine 1 "$(grep -c '^wake_gh()    { engine_gh "\$@"; }' "$ROOT/shared/lib/host/wake.sh")"

suite_finish
