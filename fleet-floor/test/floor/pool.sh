# shellcheck shell=bash  # sourced by ../run.sh, so it has no shebang of its own
# fleet-floor/test/floor/pool.sh — the suite for fleet-floor/server/floor/pool.py
# (#780): the host credential pool managed from the console, every action
# through the CLI's own `crew creds` against this collector's fleet
# definition. The boxes are stub-box's: its credentials-shell arm keeps the
# header and the secret apart under $FLOOR_STATE, so a row can prove a pool
# entry reached a box as stdin and grep every place it must never be.
echo
echo "== the credential pool from the console (#780)"
PL_GH="ghp_POOLFLOOR0123456789"
PL_GH2="ghp_POOLFLOORROTATED9"
PL_AGENT="sk-ant-oat-POOLFLOOR"
PL_AGENT2="sk-ant-oat-POOLROTATED"
PL_JOURNAL="$CREW_CONFIG_DIR/.credentials-journal.log"
# The CLI asks GitHub which login a PAT answers as; this gh answers for the
# two tokens above and refuses anything else. $TMP/bin is on the collector's
# PATH, and a command is looked up when it runs.
cat >"$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2:${GH_TOKEN:-}" in
  "api user:ghp_POOLFLOOR0123456789"|"api user:ghp_POOLFLOORROTATED9") echo pool-bot ;;
  *) echo '{"message":"Bad credentials"}'; exit 1 ;;
esac
GH
chmod +x "$TMP/bin/gh"
# Telegram's getMe (#788), from the host: the URL on curl's config (stdin).
cat >"$TMP/bin/curl" <<'CURL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${0%/*}/curl-argv"
case "$(cat)" in
  *'/botTG-POOLFLOOR:ok/getMe"'*) echo '{"ok":true,"result":{"username":"floor_alerts_bot"}}' ;;
  *) echo '{"ok":false}' ;;
esac
CURL
chmod +x "$TMP/bin/curl"
pl_do() {  # pl_do JSON — "<body>\n<status>"
  api POST /api/command "$1"
}
pl_status() { pl_do "$1" | tail -1; }
pl_body() { pl_do "$1" | sed '$d'; }
PL_ALL="$TMP/pool-replies"; : >"$PL_ALL"
pl_keep() { printf '%s\n' "$1" >>"$PL_ALL"; printf '%s' "$1"; }

t "pool: the console reads an empty pool" "True 0" \
  "$(body GET /api/pool | jqf "str(d['operator'])+' '+str(len(d['entries']))")"

# Add: a gh PAT, its login recorded; an agent credential of a profile's kind.
PL_R="$(pl_keep "$(pl_do "{\"action\":\"pool-add\",\"service\":\"gh\",\"name\":\"bot\",\"secret\":\"$PL_GH\"}")")"
t "pool-add: a gh entry is stored" 200 "$(printf '%s' "$PL_R" | tail -1)"
t "pool-add: the reply is the CLI's own line" 1 \
  "$(printf '%s' "$PL_R" | sed '$d' | jqf "' '.join(d['lines'])" | grep -c 'gh:bot stored (token, answers as pool-bot)')"
PL_R="$(pl_keep "$(pl_do "{\"action\":\"pool-add\",\"service\":\"agent\",\"name\":\"max\",\"agent\":\"claude\",\"kind\":\"oauth-token\",\"secret\":\"$PL_AGENT\"}")")"
t "pool-add: an agent entry is stored" 200 "$(printf '%s' "$PL_R" | tail -1)"
PL_SNAP="$(body GET /api/pool)"
printf '%s\n' "$PL_SNAP" >>"$PL_ALL"
t "pool: the listing names both entries" "agent:max gh:bot" "$(jqf "' '.join(sorted(e['id'] for e in d['entries']))" <<<"$PL_SNAP")"
t "pool: a gh entry carries the login it answers as" "pool-bot" \
  "$(jqf "[e for e in d['entries'] if e['id']=='gh:bot'][0]['login']" <<<"$PL_SNAP")"
t "pool: every roster member is listed with its assignment" \
  "$(body GET /api/fleet | jqf "len(d['units'])")" "$(jqf "len(d['members'])" <<<"$PL_SNAP")"
PL_R="$(pl_keep "$(pl_do "{\"action\":\"pool-add\",\"service\":\"gh\",\"name\":\"dead\",\"secret\":\"ghp_nope\"}")")"
t "pool-add: a token GitHub refuses is refused, in the CLI's words" "409 1" \
  "$(printf '%s' "$PL_R" | tail -1) $(printf '%s' "$PL_R" | sed '$d' | jqf "d['error']" | grep -c 'GitHub refused the token for gh:dead')"

# Assign: the member's line gets the token, the box gets the values as stdin.
PL_M=$(fs_mark)
PL_R="$(pl_keep "$(pl_do '{"action":"pool-assign","box":"ff-idle","entries":["gh:bot","agent:max"]}')")"
t "pool-assign: assigning from the console lands" 200 "$(printf '%s' "$PL_R" | tail -1)"
t "pool-assign: the roster line carries the assignment" 1 \
  "$(grep -cE '^ff-idle +claude +reviewer +creds=gh:bot,agent:max$' "$CREW_CONFIG_DIR/fleet.roster")"
t "pool-assign: both values reached the box, in order" "gh token|agent oauth-token" \
  "$(tail -2 "$FLOOR_STATE/ff-idle.credential-headers" | paste -sd'|' -)"
t "pool-assign: the last value arrived as stdin" "$PL_AGENT" "$(cat "$FLOOR_STATE/ff-idle.credential")"
t "pool-assign: no value is in any box argv" 0 "$(fs_calls_since "$PL_M" | grep -cE "$PL_GH|$PL_AGENT")"
t "pool: the listing says who holds the entry, and the verdict" "ff-idle True False" \
  "$(body GET /api/pool | jqf "' '.join([m['box']+' '+str(m['verdict']['ok'])+' '+str(m['owes']) for e in d['entries'] if e['id']=='gh:bot' for m in e['members']])")"
# The per-repository gh rule, said by the CLI and carried to the page: every
# fixture member works the fleet's repos.txt, so a second holder overlaps.
PL_R="$(pl_keep "$(pl_do '{"action":"pool-assign","box":"ff-working","entries":["gh:bot"]}')")"
t "pool-assign: an overlapping gh share is refused" 409 "$(printf '%s' "$PL_R" | tail -1)"
t "pool-assign: ...naming the other member and the repositories" 1 \
  "$(printf '%s' "$PL_R" | sed '$d' | jqf "d['error']" | grep -c 'gh:bot already feeds ff-idle, which works heavy-duty/crew as ff-working would')"
t "pool-assign: ...and the refused line is unchanged" 0 "$(grep -c '^ff-working.*creds=' "$CREW_CONFIG_DIR/fleet.roster")"
# An agent entry is shareable — but only to a member of its agent.
t "pool-assign: an agent entry feeds a second member" 200 \
  "$(pl_status '{"action":"pool-assign","box":"ff-working","entries":["agent:max"]}')"
t "pool-assign: ...never a member of another agent" 409 \
  "$(pl_status '{"action":"pool-assign","box":"ff-lim-breaker","entries":["agent:max"]}')"

# Rotate: every running member the entry feeds gets the new value at once.
PL_R="$(pl_keep "$(pl_do "{\"action\":\"pool-rotate\",\"entry\":\"agent:max\",\"secret\":\"$PL_AGENT2\"}")")"
t "pool-rotate: a rotation from the console lands" 200 "$(printf '%s' "$PL_R" | tail -1)"
t "pool-rotate: the running holders hold the new value" "$PL_AGENT2 $PL_AGENT2" \
  "$(cat "$FLOOR_STATE/ff-idle.credential") $(cat "$FLOOR_STATE/ff-working.credential")"
PL_R="$(pl_keep "$(pl_do "{\"action\":\"pool-rotate\",\"entry\":\"gh:bot\",\"secret\":\"$PL_GH2\"}")")"
t "pool-rotate: a gh rotation re-asks GitHub and lands" 200 "$(printf '%s' "$PL_R" | tail -1)"

# Remove: refused while assigned; cleared, then removed.
t "pool-rm: an assigned entry cannot be removed" 409 "$(pl_status '{"action":"pool-rm","entry":"agent:max"}')"
t "pool-unassign: clearing one member from the console lands" 200 \
  "$(pl_status '{"action":"pool-unassign","box":"ff-working","entry":"agent:max"}')"
t "pool-unassign: clearing a member's whole assignment lands" 200 \
  "$(pl_status '{"action":"pool-unassign","box":"ff-idle"}')"
t "pool-unassign: the roster line is back to what it was" 1 "$(grep -cE '^ff-idle +claude +reviewer$' "$CREW_CONFIG_DIR/fleet.roster")"
t "pool-rm: an unassigned entry is removed" 200 "$(pl_status '{"action":"pool-rm","entry":"agent:max"}')"
t "pool: the listing no longer names it" "gh:bot" "$(body GET /api/pool | jqf "' '.join(sorted(e['id'] for e in d['entries']))")"

# Telegram (#788): a bot entry, the fleet's one group chat, delivered with it.
PL_TG="TG-POOLFLOOR:ok"
t "pool-chat: a chat that is not a chat id is 400" 400 "$(pl_status '{"action":"pool-chat","chat":"my group"}')"
t "pool-chat: setting the fleet's group chat lands" 200 "$(pl_status '{"action":"pool-chat","chat":"-1001234567890"}')"
t "pool: the listing carries the group chat" "-1001234567890" "$(body GET /api/pool | jqf "d['tg_chat']")"
PL_R="$(pl_keep "$(pl_do "{\"action\":\"pool-add\",\"service\":\"tg\",\"name\":\"alerts\",\"secret\":\"$PL_TG\"}")")"
t "pool-add: a telegram bot is stored" 200 "$(printf '%s' "$PL_R" | tail -1)"
t "pool: a tg entry carries the bot it answers as" "floor_alerts_bot" \
  "$(body GET /api/pool | jqf "[e for e in d['entries'] if e['id']=='tg:alerts'][0]['login']")"
t "pool-assign: a telegram bot is assigned from the console" 200 \
  "$(pl_status '{"action":"pool-assign","box":"ff-idle","entries":["tg:alerts"]}')"
t "pool-assign: ...and reaches the box with the fleet's chat in its header" "tg bot -1001234567890" \
  "$(tail -1 "$FLOOR_STATE/ff-idle.credential-headers")"
t "pool-assign: ...the token arriving as stdin" "$PL_TG" "$(cat "$FLOOR_STATE/ff-idle.credential")"
t "pool-assign: one bot feeds a second member" 200 \
  "$(pl_status '{"action":"pool-assign","box":"ff-working","entries":["tg:alerts"]}')"
t "pool: the page offers the group chat" 1 "$(grep -c 'data-pool-act="chat"' "$FLOOR/index.html")"
t "pool: the page offers telegram on Add and on Assign" "1 1" \
  "$(grep -c '<option value="tg">tg</option>' "$FLOOR/index.html") $(grep -c 'sel("tg","telegram")' "$FLOOR/index.html")"
t "pool: no curl argv carried the bot token" 0 "$(grep -c -- "$PL_TG" "$TMP/bin/curl-argv" 2>/dev/null || true)"
pl_status '{"action":"pool-unassign","box":"ff-idle"}' >/dev/null
pl_status '{"action":"pool-unassign","box":"ff-working","entry":"tg:alerts"}' >/dev/null

# Refused before the CLI runs: nothing moved.
t "pool-add: a bad name is 400" 400 "$(pl_status '{"action":"pool-add","service":"gh","name":"bad name","secret":"x"}')"
t "pool-add: an empty secret is 400" 400 "$(pl_status '{"action":"pool-add","service":"gh","name":"x","secret":"  "}')"
t "pool-assign: an unknown box is 400" 400 "$(pl_status '{"action":"pool-assign","box":"ff-nosuch","entries":["gh:bot"]}')"
t "pool-assign: a malformed entry is 400" 400 "$(pl_status '{"action":"pool-assign","box":"ff-idle","entries":["bot"]}')"
t "pool-rotate: a malformed entry is 400" 400 "$(pl_status '{"action":"pool-rotate","entry":"x","secret":"y"}')"

# No value anywhere it must not be.
for pl_secret in "$PL_GH" "$PL_GH2" "$PL_AGENT" "$PL_AGENT2" "$PL_TG"; do
  t "pool: no reply or listing carries ${pl_secret:0:14}…" 0 "$(grep -c -- "$pl_secret" "$PL_ALL" || true)"
  t "pool: the collector's log never holds ${pl_secret:0:14}…" 0 "$(grep -c -- "$pl_secret" "$TMP/server.log" || true)"
  t "pool: the journal never holds ${pl_secret:0:14}…" 0 "$(grep -c -- "$pl_secret" "$PL_JOURNAL" 2>/dev/null || true)"
done

# The page: the pool section is in the overlay, and a value field is cleared
# before the request resolves, as a member's set is.
t "pool: the page offers Assign, Rotate and Add" "1 1 1" \
  "$(grep -c "data-pool-act=\"assign\"" "$FLOOR/index.html") $(grep -c "data-pool-act=\"rotate\"" "$FLOOR/index.html") $(grep -c "data-pool-act=\"add\"" "$FLOOR/index.html")"
t "pool: a value field is cleared before the request is sent" 1 \
  "$(sed -n '/^function onPoolClick(b){/,/^}/p' "$FLOOR/src/app.js" | awk '/inp.value="";/ {c=NR} /act\("ov:pool","pool-"\+what,body\)/ {a=NR} END {print (c && a && c < a) ? 1 : 0}')"
# #870: a page, not an overlay — leaving it for the floor clears every secret
# field, and moving between pages re-renders the body, which drops them too.
t "pool: leaving a page forgets a typed pool value" 1 \
  "$(sed -n '/^function pageRoute(){/,/^}/p' "$FLOOR/src/app.js" | grep -c "querySelectorAll('input\[type=\"password\"\],textarea')")"
rm -f "$TMP/bin/gh" "$TMP/bin/curl"
