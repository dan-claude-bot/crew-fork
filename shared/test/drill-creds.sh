#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2030,SC2031  # programs run in the shells they are handed to; per-row env prefixes are meant to stay local
# shared/test/drill-creds.sh — the drill's own credential pool (#828), offline.
#
# drill/creds.sh against a stub `crew` that logs every call (argv, the fleet
# and pool it was pointed at, what it read on stdin) and writes the entries a
# real `crew creds add` would. The "terminal" is a file (DRILL_CREDS_TTY), so
# each prompt's answer is fixed and every row reads what was asked and added.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
export XDG_CONFIG_HOME="$TMP/xdg-empty"
unset CREW_CREDENTIALS_DIR DRILL_POOL_HOME DRILL_CREDS_TTY
CREDS_SH="$ROOT/drill/creds.sh"

export STUB_LOG="$TMP/crew.log"
cat >"$TMP/crew" <<'EOF'
#!/usr/bin/env bash
in="$(cat 2>/dev/null | head -1)"
echo "crew $* | conf=${CREW_CONFIG_DIR:-} pool=${CREW_CREDENTIALS_DIR:-} in=$in" >>"$STUB_LOG"
case "$1 ${2:-}" in
  "init "*) mkdir -p "$2"; : >"$2/fleet.roster" ;;
  "creds add") [ -n "$in" ] || exit 1; mkdir -p "$CREW_CREDENTIALS_DIR/entries/$3--$4"; printf '%s' "$in" >"$CREW_CREDENTIALS_DIR/entries/$3--$4/secret" ;;
  "creds chat") printf '%s\n' "$3" >"$CREW_CREDENTIALS_DIR/tg-chat" ;;
esac
EOF
chmod +x "$TMP/crew"
# shellcheck source=drill/creds.sh
lib() { ( . "$CREDS_SH"; "$@" ); }

# --- where the pool is ------------------------------------------------------------------
t creds-dir-default "$HOME/.config/crew-drill/credentials" "$(lib drill_creds_dir)"
t creds-dir-pool-home "$TMP/h/credentials" "$(DRILL_POOL_HOME="$TMP/h" lib drill_creds_dir)"
t creds-dir-explicit-wins "$TMP/elsewhere" "$(CREW_CREDENTIALS_DIR="$TMP/elsewhere" DRILL_POOL_HOME="$TMP/h" lib drill_creds_dir)"

# --- what it lacks ----------------------------------------------------------------------
export DRILL_POOL_HOME="$TMP/home"
P="$DRILL_POOL_HOME/credentials"
t creds-missing-all "gh:bot|agent:max|tg:alerts|tg-chat" "$(lib drill_creds_missing gh:bot,agent:max,tg:alerts | paste -sd'|')"
mkdir -p "$P/entries/gh--bot"; printf x >"$P/entries/gh--bot/secret"
t creds-missing-some "agent:max" "$(lib drill_creds_missing gh:bot,agent:max | paste -sd'|')"
t creds-missing-no-tg-no-chat "" "$(lib drill_creds_missing gh:bot)"
rm -rf "$DRILL_POOL_HOME"

# --- the terminal -----------------------------------------------------------------------
printf 'answer\n' >"$TMP/tty"
t creds-tty-present 0 "$(DRILL_CREDS_TTY="$TMP/tty" lib drill_creds_have_tty; echo $?)"
t creds-tty-absent 1 "$(DRILL_CREDS_TTY="$TMP/none" lib drill_creds_have_tty; echo $?)"

# --- asking and adding --------------------------------------------------------------------
: >"$STUB_LOG"
printf -- '-100123\n' >"$TMP/tty"
DRILL_CREDS_TTY="$TMP/tty" lib drill_creds_ensure "$TMP/crew" claude gh:bot,agent:max,tg:alerts >"$TMP/ensure.out" 2>&1
t creds-ensure-rc 0 "$?"
t creds-ensure-inits-the-scaffold-once 1 "$(grep -c "^crew init $DRILL_POOL_HOME/fleet " "$STUB_LOG")"
t creds-ensure-adds-gh "crew creds add gh bot | conf=$DRILL_POOL_HOME/fleet pool=$P in=-100123" "$(grep '^crew creds add gh' "$STUB_LOG")"
t creds-ensure-adds-agent-with-the-agent 1 "$(grep -c '^crew creds add agent max claude | ' "$STUB_LOG")"
t creds-ensure-adds-tg 1 "$(grep -c '^crew creds add tg alerts | ' "$STUB_LOG")"
t creds-ensure-sets-the-chat 1 "$(grep -c "^crew creds chat -100123 | conf=$DRILL_POOL_HOME/fleet pool=$P" "$STUB_LOG")"
t creds-ensure-says-what-it-adds 3 "$(grep -c "is not in the drill's pool ($P) — adding it" "$TMP/ensure.out")"
t creds-ensure-leaves-nothing-missing "" "$(lib drill_creds_missing gh:bot,agent:max,tg:alerts)"
: >"$STUB_LOG"
DRILL_CREDS_TTY="$TMP/tty" lib drill_creds_ensure "$TMP/crew" claude gh:bot,agent:max,tg:alerts >/dev/null 2>&1
t creds-ensure-second-run-asks-nothing 0 "$(grep -c . "$STUB_LOG")"
rm -rf "$DRILL_POOL_HOME"; : >"$STUB_LOG"
DRILL_CREDS_TTY="$TMP/none" lib drill_creds_ensure "$TMP/crew" claude gh:bot >"$TMP/ensure.out" 2>&1
t creds-ensure-no-tty-fails 1 "$?"
t creds-ensure-no-tty-calls-nothing 0 "$(grep -c . "$STUB_LOG")"
: >"$TMP/empty-tty"
DRILL_CREDS_TTY="$TMP/empty-tty" lib drill_creds_ensure "$TMP/crew" claude gh:bot >"$TMP/ensure.out" 2>&1
t creds-ensure-a-refused-add-fails 1 "$?"
t creds-ensure-a-refused-add-names-it 1 "$(grep -c 'crew creds add gh bot failed' "$TMP/ensure.out")"
rm -rf "$DRILL_POOL_HOME"

# --- the hint -------------------------------------------------------------------------------
t creds-hint-default-agent "drill/creds.sh gh:a,agent:b" "$(lib drill_creds_hint claude gh:a,agent:b)"
t creds-hint-other-agent "drill/creds.sh --agent grok gh:a" "$(lib drill_creds_hint grok gh:a)"

# --- standalone -------------------------------------------------------------------------------
OUT="$(DRILL_NO_PROVISION=1 bash "$CREDS_SH" 'bot' 2>&1)"; RC=$?
t creds-cli-malformed-rc 1 "$RC"
t creds-cli-malformed-usage 1 "$(grep -c '^usage: drill/creds.sh' <<<"$OUT")"
mkdir -p "$P/entries/gh--bot"; printf x >"$P/entries/gh--bot/secret"
OUT="$(DRILL_NO_PROVISION=1 bash "$CREDS_SH" gh:bot 2>&1)"; RC=$?
t creds-cli-full-pool-rc 0 "$RC"
t creds-cli-full-pool-says-so 1 "$(grep -c "already holds gh:bot" <<<"$OUT")"
OUT="$(DRILL_NO_PROVISION=1 DRILL_CREDS_TTY="$TMP/none" bash "$CREDS_SH" gh:bot,agent:max 2>&1)"; RC=$?
t creds-cli-no-tty-rc 1 "$RC"

# --- wiring -------------------------------------------------------------------------------------
ALL="$ROOT/drill/rehearsal-all.sh"
t creds-wired-sources-the-lib 1 "$(grep -c '^    \. "\$CREDS_LIB"$' "$ALL")"
t creds-wired-no-crew-creds-list 0 "$(grep -c 'creds list' "$ALL" || true)"
t creds-wired-gh-fallback 1 "$(grep -c 'export GH_TOKEN$' "$ALL")"
t creds-standalone-provisions-first 1 "$(grep -c 'provision_round "$(dirname "$HERE")" "$HERE/creds.sh"' "$CREDS_SH")"

suite_finish
