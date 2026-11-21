#!/usr/bin/env bash
# shared/test/pool.sh — the host credential pool (#774), driven through the
# real `crew creds` against a stub box whose homes are directories: the
# credentials shell (#765) runs for real inside each, with a stub gh that
# accepts known tokens. What it pins: an entry is stored once, 0600 under a
# 0700 directory, and never printed; a gh entry records the login it answers
# as; assignment lives on the roster line and every positional reader still
# reads the line it always read; the gh rule is per repository; a rotation
# reaches every running member at once and a sleeping one is owed it; an
# assigned entry cannot be removed; an off-roster box is reached by naming the
# entries; and no output, journal or record ever carries a secret.
#
# The box-side snippets are single-quoted on purpose: they expand in the box.
# shellcheck disable=SC2016
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"
CLI="$ROOT/cli/crew"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
unset CREW_CREDENTIALS_DIR
export XDG_CONFIG_HOME="$TMP/xdg-empty"
mkdir -p "$XDG_CONFIG_HOME"

CONF="$TMP/conf"
BOXES="$TMP/boxes"
STUB="$TMP/stub"
mkdir -p "$BOXES" "$STUB"
if ! "$CLI" init "$CONF" >/dev/null 2>&1; then
  echo "FAIL pool-fixture-crew-init"; exit 1
fi
cat >"$CONF/fleet.roster" <<'EOF'
# the fleet — a comment the pool must keep
alpha  claude  builder
beta   claude  reviewer

# a note between members
gamma  claude  triage
EOF
printf 'o/r1\no/r2\n' >"$CONF/repos.txt"

# Each box is a directory laid out as a hired box: its own engine profile,
# its instance.conf naming its agent.
for b in alpha beta gamma offroster; do
  mkdir -p "$BOXES/$b/duty/conf/agents"
  cp "$ROOT/shared/conf/agents/claude.conf" "$BOXES/$b/duty/conf/agents/"
  printf 'BOT_AGENT=claude\nBOT_ROLE=builder\n' >"$BOXES/$b/duty/conf/instance.conf"
  printf 'running\n' >"$BOXES/$b/.state"
done

cat >"$STUB/box" <<'EOF'
#!/usr/bin/env bash
# list / info / exec / start against $BOXES/<name>; exec runs the script with
# HOME pointed into the box, stdin passed through (bxpipe's channel).
case "$1" in
  list) printf '['; sep=''; for d in "$BOXES"/*/; do n="${d%/}"; n="${n##*/}"; printf '%s{"name":"%s"}' "$sep" "$n"; sep=','; done; printf ']\n' ;;
  info) printf '[{"name":"%s","status":"%s"}]\n' "$2" "$(cat "$BOXES/$2/.state" 2>/dev/null || echo Stopped)" ;;
  exec)
    name="$2"; shift 3
    [ "$(cat "$BOXES/$name/.state")" = running ] || { echo "Error: Instance is not running" >&2; exit 1; }
    printf '%s\n' "$name" >>"$BOXES/.exec-calls"
    env -u DUTY_DIR HOME="$BOXES/$name" PATH="$POOL_STUB:$PATH" bash -c "$3" ;;
  start) printf 'running\n' >"$BOXES/$2/.state" ;;
  *) exit 2 ;;
esac
EOF
cat >"$STUB/gh" <<'EOF'
#!/usr/bin/env bash
# Tokens: ghp_bot answers as dan-claude-bot, ghp_bot2 as dan-claude-bot (a
# rotation), ghp_other as other-bot; anything else is refused.
login_of() { case "$1" in ghp_bot|ghp_bot2) echo dan-claude-bot ;; ghp_other) echo other-bot ;; ghp_third) echo third-bot ;; *) return 1 ;; esac; }
case "$1 $2" in
  "auth login") tok="$(cat)"; login_of "$tok" >/dev/null || { echo "error validating token" >&2; exit 1; }
                mkdir -p "$HOME/.config/gh"; printf '%s\n' "$tok" >"$HOME/.config/gh/token" ;;
  "auth setup-git") : ;;
  "api user")
    if [ -n "${GH_TOKEN:-}" ]; then login_of "$GH_TOKEN" || { echo '{"message":"Bad credentials"}'; exit 1; }
    else login_of "$(cat "$HOME/.config/gh/token" 2>/dev/null)" || exit 1; fi ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$STUB/box" "$STUB/gh"
export BOXES POOL_STUB="$STUB"

ALL_OUT="$TMP/all-output"
: >"$ALL_OUT"
creds() {  # creds <stdin> args… — sets OUT and RC; every output is kept for the secret census
  if OUT="$(printf '%s' "$1" | env CREW_CONFIG_DIR="$CONF" PATH="$STUB:$PATH" bash "$CLI" creds "${@:2}" 2>&1)"; then RC=0; else RC=$?; fi
  printf '%s\n' "$OUT" >>"$ALL_OUT"
}
has() { case "$OUT" in *"$1"*) echo yes ;; *) echo "no: $OUT" ;; esac; }
POOL="$CONF/credentials"

# --- add ----------------------------------------------------------------------
creds ghp_bot add gh bot
t pool-add-gh-succeeds 0 "$RC"
t pool-add-gh-names-the-login yes "$(has 'gh:bot stored (token, answers as dan-claude-bot)')"
t pool-add-gh-records-the-login dan-claude-bot "$(sed -n 's/^login=//p' "$POOL/entries/gh--bot/meta")"
t pool-the-secret-is-the-value ghp_bot "$(cat "$POOL/entries/gh--bot/secret")"
t pool-the-secret-is-0600 600 "$(stat -c %a "$POOL/entries/gh--bot/secret")"
t pool-the-pool-is-0700 700 "$(stat -c %a "$POOL")"
t pool-the-entries-dir-is-0700 700 "$(stat -c %a "$POOL/entries")"
creds ghp_nope add gh nope
t pool-a-refused-token-is-refused 1 "$RC"
t pool-a-refused-token-says-so yes "$(has 'GitHub refused the token for gh:nope — nothing stored')"
t pool-a-refused-token-stores-nothing absent "$([ -e "$POOL/entries/gh--nope" ] && echo present || echo absent)"
creds ghp_bot add gh bot
t pool-a-second-add-is-refused-naming-rotate yes "$(has 'rotate it: crew creds rotate gh:bot')"
creds x add gh 'bad name'
t pool-a-bad-name-is-a-usage-error 2 "$RC"
creds sk-ant-oat-first add agent max claude
t pool-add-agent-succeeds 0 "$RC"
t pool-add-agent-takes-the-profiles-first-kind oauth-token "$(sed -n 's/^kind=//p' "$POOL/entries/agent--max/meta")"
creds x add agent max2 claude no-such-kind
t pool-add-agent-refuses-an-unknown-kind 2 "$RC"
creds ghp_other add gh other
t pool-add-a-second-gh-entry 0 "$RC"

# --- list ---------------------------------------------------------------------
creds '' list
t pool-list-names-each-entry yes "$(has 'gh:bot')"
t pool-list-says-who-a-gh-entry-answers-as yes "$(has 'answers as dan-claude-bot')"
t pool-list-says-nobody-is-assigned yes "$(has 'assigned to: nobody')"

# --- assign, and the roster line ----------------------------------------------
creds '' assign alpha gh:bot,agent:max
t pool-assign-succeeds 0 "$RC"
t pool-assign-writes-the-roster-line 1 "$(grep -cE '^alpha claude builder  creds=gh:bot,agent:max$' "$CONF/fleet.roster")"
t pool-assign-keeps-the-comments 2 "$(grep -c '^#' "$CONF/fleet.roster")"
t pool-assign-keeps-the-blank-line 1 "$(grep -c '^$' "$CONF/fleet.roster")"
t pool-assign-fans-out-to-a-running-box yes "$(has 'alpha: credential gh:bot: gh: set — logged in as dan-claude-bot')"
t pool-assign-sets-the-agent-credential-too yes "$(has 'alpha: credential agent:max:')"
t pool-the-box-holds-the-token ghp_bot "$(cat "$BOXES/alpha/.config/gh/token")"
t pool-the-box-holds-the-agent-credential 1 "$(grep -c 'CLAUDE_CODE_OAUTH_TOKEN' "$BOXES/alpha/.config/crew/credentials.env")"
t pool-delivery-is-recorded 2 "$(wc -l <"$POOL/delivered/alpha" | tr -d ' ')"
# Every positional reader of the roster reads the line it always read: the
# token is stripped by read_roster, and roster_line's fourth field stays empty.
eval "$(sed -n '/^read_roster() {/p; /^roster_line() {/p' "$CLI")"
# shellcheck disable=SC2034  # read by the extracted readers
ROSTER="$CONF/fleet.roster"
t pool-read-roster-strips-the-token "alpha claude builder" "$(read_roster | awk '$1 == "alpha"' | tr -s ' ')"
t pool-roster-line-has-no-from "claude builder " "$(roster_line alpha)"

# The gh rule is per repository. beta works the fleet's repos.txt, as alpha
# does, so one login on both is refused, naming alpha and what they share.
creds '' assign beta gh:bot
t pool-an-overlapping-gh-share-is-refused 1 "$RC"
t pool-the-refusal-names-the-member-and-repos yes "$(has 'gh:bot already feeds alpha, which works o/r1,o/r2 as beta would')"
t pool-a-refused-assign-writes-nothing 0 "$(grep -c '^beta.*creds=' "$CONF/fleet.roster")"
# Disjoint selections may share one login: alpha works o/r1 only, gamma o/r2.
mkdir -p "$CONF/repos.d"
printf 'o/r1\n' >"$CONF/repos.d/alpha.txt"
printf 'o/r2\n' >"$CONF/repos.d/gamma.txt"
creds '' assign gamma gh:bot
t pool-a-disjoint-gh-share-is-accepted 0 "$RC"
# ...and an agent entry may feed any number of members.
creds '' assign beta agent:max,gh:other
t pool-an-agent-entry-is-shareable 0 "$RC"
# gh:other feeds beta, which works o/r2 as gamma does: refused, per repository.
creds '' assign gamma gh:other
t pool-a-share-overlapping-one-repo-is-refused yes "$(has 'gh:other already feeds beta, which works o/r2 as gamma would')"
# A member answers as one login: a second gh entry REPLACES the first.
creds ghp_third add gh third
creds '' assign gamma gh:third
t pool-a-new-gh-entry-replaces-the-old 1 "$(grep -cE '^gamma claude triage  creds=gh:third$' "$CONF/fleet.roster")"
creds '' assign gamma gh:bot,gh:other
t pool-two-gh-entries-at-once-is-a-usage-error 2 "$RC"
creds '' assign nobody gh:bot
t pool-an-off-roster-assign-is-refused 1 "$RC"

# --- list --json, for the floor (#780) ----------------------------------------
creds '' list --json
t pool-json-parses 0 "$(jq -e . >/dev/null 2>&1 <<<"$OUT"; echo $?)"
t pool-json-names-the-pool "$POOL" "$(jq -r .pool <<<"$OUT")"
t pool-json-lists-every-entry "agent:max gh:bot gh:other gh:third" "$(jq -r '[.entries[].id] | sort | join(" ")' <<<"$OUT")"
t pool-json-a-gh-entry-has-its-login dan-claude-bot "$(jq -r '.entries[] | select(.id == "gh:bot") | .login' <<<"$OUT")"
t pool-json-an-agent-entry-has-its-agent-and-kind "claude oauth-token" "$(jq -r '.entries[] | select(.id == "agent:max") | "\(.agent) \(.kind)"' <<<"$OUT")"
t pool-json-names-who-holds-an-entry "alpha beta" "$(jq -r '.entries[] | select(.id == "agent:max") | [.members[].box] | sort | join(" ")' <<<"$OUT")"
t pool-json-carries-the-verdict true "$(jq -r '.entries[] | select(.id == "gh:bot") | .members[] | select(.box == "alpha") | .verdict.ok' <<<"$OUT")"
t pool-json-says-what-is-owed false "$(jq -r '.entries[] | select(.id == "gh:bot") | .members[] | select(.box == "alpha") | .owes' <<<"$OUT")"
t pool-json-lists-every-member-with-its-assignment "alpha:gh:bot,agent:max beta:agent:max,gh:other gamma:gh:third" \
  "$(jq -r '[.members[] | "\(.box):\(.creds | join(","))"] | join(" ")' <<<"$OUT")"
t pool-json-carries-no-value 0 "$(grep -cE 'ghp_|sk-ant' <<<"$OUT" || true)"

# --- rotate -------------------------------------------------------------------
printf 'Stopped\n' >"$BOXES/beta/.state"
creds sk-ant-oat-second rotate agent:max
t pool-rotate-succeeds 0 "$RC"
t pool-rotate-reaches-a-running-member yes "$(has 'alpha: credential agent:max:')"
t pool-rotate-names-a-sleeping-member yes "$(has 'beta: not running — it gets the new value when it is next up')"
t pool-the-running-member-holds-the-new-value 1 \
  "$(grep -c 'sk-ant-oat-second' "$BOXES/alpha/.config/crew/credentials.env" 2>/dev/null; true)"
t pool-the-running-member-holds-no-old-value 0 \
  "$(grep -c 'sk-ant-oat-first' "$BOXES/alpha/.config/crew/credentials.env" 2>/dev/null; true)"
creds '' list
t pool-list-says-the-sleeper-owes-the-value yes "$(has 'beta:')"
t pool-list-names-what-the-sleeper-owes yes "$(has 'owes the current value')"
# A gh rotation re-asks GitHub and refuses a dead token, keeping the old one.
creds ghp_dead rotate gh:bot
t pool-a-dead-rotation-is-refused 1 "$RC"
t pool-a-dead-rotation-says-so yes "$(has 'GitHub refused the new token for gh:bot — the old value stands')"
t pool-a-dead-rotation-keeps-the-old-value ghp_bot "$(cat "$POOL/entries/gh--bot/secret")"

# --- rm -----------------------------------------------------------------------
creds '' rm agent:max
t pool-an-assigned-entry-cannot-be-removed 1 "$RC"
t pool-the-refusal-names-who-holds-it yes "$(has 'agent:max is assigned to alpha,beta')"
creds '' unassign beta agent:max
t pool-unassign-one-entry-keeps-the-other 1 "$(grep -cE '^beta claude reviewer  creds=gh:other$' "$CONF/fleet.roster")"
creds '' unassign alpha
t pool-unassign-all-drops-the-token 1 "$(grep -cE '^alpha claude builder$' "$CONF/fleet.roster")"
creds '' rm agent:max
t pool-an-unassigned-entry-is-removed 0 "$RC"
t pool-removal-deletes-the-entry absent "$([ -e "$POOL/entries/agent--max" ] && echo present || echo absent)"

# --- push, to a box no roster names (the drill's path) -------------------------
creds '' push offroster
t pool-push-off-roster-needs-entries 1 "$RC"
creds '' push offroster --entries gh:other
t pool-push-off-roster-with-entries 0 "$RC"
t pool-push-reaches-the-box ghp_other "$(cat "$BOXES/offroster/.config/gh/token")"
printf 'Stopped\n' >"$BOXES/offroster/.state"
creds '' push offroster --entries gh:other
t pool-push-refuses-a-stopped-box yes "$(has 'offroster is not running')"
# CREW_CREDENTIALS_DIR points another fleet definition at this pool.
OTHER="$TMP/other-conf"
"$CLI" init "$OTHER" >/dev/null 2>&1
printf 'running\n' >"$BOXES/offroster/.state"
if OUT="$(env CREW_CONFIG_DIR="$OTHER" CREW_CREDENTIALS_DIR="$POOL" PATH="$STUB:$PATH" \
    bash "$CLI" creds push offroster --entries gh:bot 2>&1)"; then RC=0; else RC=$?; fi
printf '%s\n' "$OUT" >>"$ALL_OUT"
t pool-another-definition-reaches-the-pool 0 "$RC"
t pool-another-definition-sets-the-value ghp_bot "$(cat "$BOXES/offroster/.config/gh/token")"

# --- no secret anywhere it should not be --------------------------------------
for secret in ghp_bot ghp_bot2 ghp_other ghp_third ghp_nope ghp_dead sk-ant-oat-first sk-ant-oat-second; do
  t "pool-no-output-carries-$secret" 0 "$(grep -c -- "$secret" "$ALL_OUT" || true)"
  t "pool-the-journal-carries-no-$secret" 0 "$(grep -c -- "$secret" "$CONF/.credentials-journal.log" 2>/dev/null || true)"
  t "pool-no-record-carries-$secret" 0 "$(cat "$POOL"/delivered/* "$POOL"/verdicts/* "$POOL"/entries/*/meta 2>/dev/null | grep -c -- "$secret" || true)"
done

suite_finish
