#!/usr/bin/env bash
# shellcheck disable=SC2016  # the single-quoted programs run in the shells they are handed to
# shared/test/box-entry.sh — the one door into a box (#792), offline.
#
# box 0.11.0 enters a box as root unless `--user NAME` names someone who exists
# in it. Every crew entry that means "as the agent" goes through box_in; this
# suite drives it, the mint and the CLI's own exec sites against a stub `box`
# that answers a configured version and logs every argv it is handed, so each
# row reads the exact door crew opened.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
unset CREW_BOX_ENTRY_MODE BOX_IN_USER CREW_FLEET CREW_FLEETS_DIR
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export XDG_CONFIG_HOME="$TMP/xdg-empty"
mkdir -p "$XDG_CONFIG_HOME" "$TMP/bin"
export BE_LOG="$TMP/calls" BE_STATE="$TMP"
: >"$BE_LOG"
cat >"$TMP/bin/box" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$BE_LOG"
case "${1:-}" in
  --version|-V) [ -z "${BE_VERSION:-}" ] || printf 'box %s (/opt/box/versions/%s)\n' "$BE_VERSION" "$BE_VERSION" ;;
  exec)
    case "$*" in
      *"/etc/passwd"*)
        # A box whose agent is not answering yet: BE_SILENT reads fail, then it answers.
        if [ -n "${BE_SILENT:-}" ]; then
          n="$(cat "$BE_STATE/silent" 2>/dev/null || echo 0)"
          if [ "$n" -lt "$BE_SILENT" ]; then echo $((n + 1)) >"$BE_STATE/silent"; echo "Error: VM agent isn't currently running" >&2; exit 1; fi
        fi
        [ -z "${BE_USERS:-}" ] || printf '%s\n' $BE_USERS ;;
      *) echo ran ;;
    esac ;;
  root) cat >"$BE_STATE/root.stdin" ;;
  list) printf '[{"name":"w1","state":"running"}]\n' ;;
  info) printf '[{"name":"%s","status":"running"}]\n' "${2:-}" ;;
  *) : ;;
esac
EOF
chmod +x "$TMP/bin/box"
export PATH="$TMP/bin:$PATH"
calls() { cat "$BE_LOG"; }
reset_calls() { : >"$BE_LOG"; }
# Each case runs box-entry.sh fresh in its own shell: the cache is per process.
be() { env "$@" bash -c '. "$1/shared/lib/box-entry.sh"; shift; eval "$*"' _ "$ROOT" "${BE_CMD:?}"; }

# --- the mode, read once from `box --version` ------------------------------------
t mode-0.10.0-is-stamp stamp "$(BE_CMD='box_entry_mode' be BE_VERSION=0.10.0)"
t mode-0.10.1-dev-is-stamp stamp "$(BE_CMD='box_entry_mode' be BE_VERSION=0.10.1-dev)"
t mode-0.11.0-is-user user "$(BE_CMD='box_entry_mode' be BE_VERSION=0.11.0)"
t mode-0.11.0-rc1-is-user user "$(BE_CMD='box_entry_mode' be BE_VERSION=0.11.0-rc1)"
t mode-0.12.3-is-user user "$(BE_CMD='box_entry_mode' be BE_VERSION=0.12.3)"
out="$(BE_CMD='box_entry_mode' be BE_VERSION= 2>&1)"; rc=$?
t mode-unreadable-is-2 2 "$rc"
t mode-unreadable-names-box-version 1 "$(grep -c "cannot read the box version ('box --version' gave no version)" <<<"$out")"
t mode-override-wins user "$(BE_CMD='box_entry_mode' be BE_VERSION=0.10.0 CREW_BOX_ENTRY_MODE=user)"
reset_calls
BE_CMD='box_in a -- true >/dev/null; box_in b -- true >/dev/null; box_in c -- true >/dev/null' be BE_VERSION=0.10.0 >/dev/null
t mode-read-once-per-process 1 "$(grep -c '^--version' "$BE_LOG")"

# --- box_in: the argv each mode opens ---------------------------------------------
reset_calls; BE_CMD='box_in b1 -- bash -lc true' be BE_VERSION=0.10.0 >/dev/null
t stamp-is-todays-argv "exec b1 -- bash -lc true" "$(grep '^exec' "$BE_LOG")"
reset_calls; BE_CMD='box_in b1 -- bash -lc true' be BE_VERSION=0.11.0 BOX_IN_USER=claude >/dev/null
t user-names-the-agent "exec --user claude b1 -- bash -lc true" "$(grep '^exec' "$BE_LOG")"
reset_calls; BE_CMD='box_entry_agent_of() { echo codex; }; box_in b1 -- true' be BE_VERSION=0.11.0 >/dev/null
t user-reads-the-callers-agent "exec --user codex b1 -- true" "$(grep '^exec' "$BE_LOG")"
reset_calls; BE_CMD='box_in b1 -- true' be BE_VERSION=0.11.0 BE_USERS=kimi >/dev/null
t user-finds-the-one-regular-user "exec --user kimi b1 -- true" "$(grep '^exec' "$BE_LOG" | tail -1)"
t user-finds-it-as-root 1 "$(grep -c '^exec b1 -- awk -F: .* /etc/passwd$' "$BE_LOG")"
reset_calls; BE_CMD='box_in b1 -- true; box_in b1 -- true' be BE_VERSION=0.11.0 BE_USERS=kimi >/dev/null
t user-is-cached-per-box 1 "$(grep -c '/etc/passwd' "$BE_LOG")"
reset_calls; out="$(BE_CMD='box_in b1 -- touch x' be BE_VERSION=0.11.0 BE_USERS= 2>&1)"; rc=$?
t no-user-is-refused-3 3 "$rc"
t no-user-says-not-converged 1 "$(grep -c 'b1 has no regular user to enter as — not converged yet' <<<"$out")"
t no-user-runs-nothing-as-root 0 "$(grep -c 'touch x' "$BE_LOG")"
# The rc11 round: a box not answering just after its converge is not a box with
# no user — the read is retried, and a box still silent is named as not answering.
reset_calls; rm -f "$BE_STATE/silent"
out="$(BE_CMD='box_in b1 -- true' be BE_VERSION=0.11.0 BE_USERS=claude BE_SILENT=2 BOX_ENTRY_ANSWER_POLL_S=0 2>&1)"; rc=$?
t silent-then-answering-resolves "0 exec --user claude b1 -- true" "$rc $(grep '^exec --user' "$BE_LOG")"
t silent-then-answering-read-three-times 3 "$(grep -c '/etc/passwd' "$BE_LOG")"
reset_calls; rm -f "$BE_STATE/silent"
out="$(BE_CMD='box_in b1 -- touch x' be BE_VERSION=0.11.0 BE_USERS=claude BE_SILENT=99 BOX_ENTRY_ANSWER_S=1 BOX_ENTRY_ANSWER_POLL_S=0 2>&1)"; rc=$?
t never-answering-is-refused-3 3 "$rc"
t never-answering-says-so-with-boxs-words 1 "$(grep -c "b1 is not answering (box exec as root failed, rc 1: Error: VM agent isn't currently running" <<<"$out")"
t never-answering-is-not-called-unconverged 0 "$(grep -c 'no regular user' <<<"$out" || true)"
t never-answering-runs-nothing 0 "$(grep -c 'touch x' "$BE_LOG")"
rm -f "$BE_STATE/silent"
reset_calls; out="$(BE_CMD='box_in b1 -- touch x' be BE_VERSION=0.11.0 BE_USERS='alice bob' 2>&1)"; rc=$?
t two-users-are-refused-3 3 "$rc"
t two-users-are-named 1 "$(grep -c 'b1 has 2 regular users (alice bob)' <<<"$out")"
t two-users-run-nothing 0 "$(grep -c 'touch x' "$BE_LOG")"
reset_calls; out="$(BE_CMD='box_in b1 -- touch x' be BE_VERSION= 2>&1)"; rc=$?
t unreadable-version-runs-nothing "2 0" "$rc $(grep -c '^exec' "$BE_LOG")"

# From an EXIT trap a bare `return` would report the status from before the
# trap; box_in returns the command's own (drill cleanups run in EXIT traps).
t box-in-from-an-exit-trap-returns-the-commands-status "rc=0" \
  "$(env BE_VERSION=0.10.0 bash -c '. "$1/shared/lib/box-entry.sh"; trap "box_in b1 -- true >/dev/null; echo rc=\$?" EXIT; exit 1' _ "$ROOT")"
t box-in-from-an-exit-trap-in-user-mode-too "rc=0" \
  "$(env BE_VERSION=0.11.0 BOX_IN_USER=claude bash -c '. "$1/shared/lib/box-entry.sh"; trap "box_in b1 -- true >/dev/null; echo rc=\$?" EXIT; exit 1' _ "$ROOT")"

# --- box_in_flags (for timeout(1)) and the shell hint -----------------------------
t flags-stamp-are-empty 0 "$(BE_CMD='box_in_flags b1; echo ${#BOX_IN_FLAGS[@]}' be BE_VERSION=0.10.0)"
t flags-user-are-the-user "--user claude" "$(BE_CMD='box_in_flags b1; echo "${BOX_IN_FLAGS[*]}"' be BE_VERSION=0.11.0 BOX_IN_USER=claude)"
t hint-stamp "box shell b1" "$(BE_CMD='box_shell_hint b1' be BE_VERSION=0.10.0)"
t hint-user "box shell --user claude b1" "$(BE_CMD='box_shell_hint b1 claude' be BE_VERSION=0.11.0)"
t hint-user-unknown-agent "box shell --user <agent> b1" "$(BE_CMD='box_shell_hint b1' be BE_VERSION=0.11.0)"
t hint-never-refuses "box shell b1" "$(BE_CMD='box_shell_hint b1' be BE_VERSION= 2>/dev/null)"

# --- the mint: box 0.11.0 creates no user, rig does ---------------------------------
mint() { env "$@" bash -c '. "$1/shared/lib/box-mint.sh"; box_mint_fresh m1 claude 4 8GiB 60GiB' _ "$ROOT"; }
reset_calls; rm -f "$TMP/root.stdin"; mint BE_VERSION=0.11.0 >/dev/null 2>&1
t mint-user-box-new-has-no-user "new --name m1 --cpu 4 --memory 8GiB --disk 60GiB" "$(grep '^new ' "$BE_LOG")"
t mint-user-bootstraps-the-tenant 1 "$(grep -cx 'rig bootstrap claude-box --user claude' "$TMP/root.stdin")"
t mint-user-refuses-without-the-user 1 "$(grep -c "^id -u claude >/dev/null 2>&1 || { echo \"crew: rig converged but no 'claude' user exists" "$TMP/root.stdin")"
reset_calls; rm -f "$TMP/root.stdin"; mint BE_VERSION=0.10.0 >/dev/null 2>&1
t mint-stamp-box-new-names-the-user "new --name m1 --user claude --cpu 4 --memory 8GiB --disk 60GiB" "$(grep '^new ' "$BE_LOG")"
t mint-stamp-bootstrap-is-as-it-was 1 "$(grep -cx 'rig bootstrap claude-box' "$TMP/root.stdin")"
t mint-pins-the-declared-rig 1 "$(grep -c "RIG_REF=$(. "$ROOT/shared/lib/platform.sh"; echo "$CREW_PLATFORM_RIG_MIN") bash" "$TMP/root.stdin")"
reset_calls; mint BE_VERSION= >/dev/null 2>&1; rc=$?
t mint-unreadable-version-mints-nothing "2 0" "$rc $(grep -c '^new ' "$BE_LOG")"
t platform-declares-rig-0.4.1 0.4.1 "$(. "$ROOT/shared/lib/platform.sh"; echo "$CREW_PLATFORM_RIG_MIN")"

# --- the CLI's doors -----------------------------------------------------------------
CONF="$TMP/conf"; mkdir -p "$CONF"
cp "$ROOT/examples/fleet.conf" "$ROOT/examples/repos.txt" "$ROOT/examples/notify-repos.txt" "$ROOT/examples/doctrine.conf" "$CONF/"
printf 'w1 codex reviewer\n' >"$CONF/fleet.roster"
cli() { printf 'ghp_fixture\n' | env CREW_CONFIG_DIR="$CONF" "$@" bash "$ROOT/cli/crew" login w1 gh 2>&1; }
reset_calls; cli BE_VERSION=0.11.0 >/dev/null
t cli-user-enters-as-the-roster-agent 1 "$(grep -c '^exec --user codex w1 -- bash -lc' "$BE_LOG")"
t cli-user-never-enters-bare 0 "$(grep -cE '^exec w1 -- bash' "$BE_LOG")"
reset_calls; cli BE_VERSION=0.10.0 >/dev/null
t cli-stamp-enters-as-today 1 "$(grep -cE '^exec w1 -- bash -lc' "$BE_LOG" | awk '{print ($1 > 0)}')"
reset_calls; out="$(cli BE_VERSION=)"; rc=$?
t cli-unreadable-version-is-2 2 "$rc"
t cli-unreadable-version-enters-nothing 0 "$(grep -c '^exec' "$BE_LOG")"
OUT="$(env CREW_CONFIG_DIR="$CONF" BE_VERSION=0.11.0 bash "$ROOT/cli/crew" help 2>&1)"
t cli-help-teaches-the-user-door 1 "$(grep -c 'box shell --user <agent> <box>' <<<"$OUT")"

# --- the engine-skew report reads each box as its agent -------------------------------
reset_calls
BE_CMD='hired_engine_versions >/dev/null' env BE_VERSION=0.11.0 BE_USERS=claude bash -c \
  '. "$1/shared/lib/version-skew.sh"; box() { printf "%s\n" "$*" >>"$BE_LOG"; case "$1" in --version) echo "box 0.11.0 (x)";; list) echo "[{\"name\":\"s1\"}]";; exec) case "$*" in *passwd*) echo claude;; *) echo crew@1.2.3;; esac;; esac; }; export -f box; hired_engine_versions' _ "$ROOT" >/dev/null 2>&1
t skew-reads-the-stamp-as-the-agent 1 "$(grep -c '^exec --user claude s1 -- bash -lc' "$BE_LOG")"

# --- no direct `box exec` is left where the door belongs -------------------------------
t engine-libs-have-no-bare-agent-exec 0 \
  "$(grep -nE '(^|[^_a-z-])box exec "' "$ROOT/cli/crew" "$ROOT/shared/lib/version-skew.sh" | grep -vE ':[0-9]+:\s*#' | grep -c . || true)"
t drill-exec-goes-through-the-door 0 \
  "$(grep -nE '(^|[^_a-z-])box exec "' "$ROOT"/drill/*.sh | grep -vE ':[0-9]+:\s*#|box_in\(\)|armed_self_box exec' | grep -c . || true)"
t floor-exec-goes-through-the-door 0 \
  "$(grep -nE '"box", "exec"' "$ROOT"/fleet-floor/server/floor/*.py | grep -v 'boxentry.py' | grep -c . || true)"

suite_finish
