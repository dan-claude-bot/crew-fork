# shellcheck shell=bash  # sourced by ../run.sh, so it has no shebang of its own
# fleet-floor/test/floor/credentials.sh — the suite for
# fleet-floor/server/floor/credentials.py (#765): a member's credentials set
# from the console and never read back.
#
# Sourced by ../run.sh, which provides ok/fail/t/api/body/status/unit/uf and a
# running collector on $PORT backed by stub-box. The stub answers the
# credentials shell by its marker, keeping the header and the secret apart
# under $FLOOR_STATE — so a row can prove the secret arrived as stdin, and
# grep every other place it must never be.
echo
echo "== credentials (#765)"
CR_SECRET="ghp_FLOORSECRET0123456789"
CR_JOURNAL="$CREW_CONFIG_DIR/.credentials-journal.log"

# What the console may read: kinds, per member — nothing else.
CR_SNAP="$(body GET /api/credentials)"
t "credentials: every roster member is listed" \
  "$(body GET /api/fleet | jqf "len(d['units'])")" "$(jqf "len(d['members'])" <<<"$CR_SNAP")"
t "credentials: gh takes a token" "token" \
  "$(jqf "[m for m in d['members'] if m['box']=='ff-idle'][0]['services']['gh'][0]" <<<"$CR_SNAP")"
t "credentials: a claude member takes its profile's kinds" "oauth-token api-key credentials-json" \
  "$(jqf "' '.join([m for m in d['members'] if m['box']=='ff-idle'][0]['services']['agent'])" <<<"$CR_SNAP")"
t "credentials: a codex member takes codex's" "api-key auth-json" \
  "$(jqf "' '.join([m for m in d['members'] if m['box']=='ff-lim-breaker'][0]['services']['agent'])" <<<"$CR_SNAP")"
t "credentials: the snapshot carries no value of any kind" 0 \
  "$(grep -ciE 'secret|token\"[[:space:]]*:' <<<"$CR_SNAP")"

# An operator's own profile is what the console offers (round 10): the path
# agent_conf_path resolves, not the shipped file.
mkdir -p "$TMP/cr-op"; printf 'AGENT_CRED_KINDS="api-key:env:OPUS_KEY"\n' >"$TMP/cr-op/claude-opus.conf"
t "credentials: an operator profile's kinds are offered" "api-key" "$(python3 - "$FLOOR/server" "$TMP/cr-op" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
from floor import credentials
credentials.agent_conf_path = lambda a: os.path.join(sys.argv[2], "%s.conf" % a)
print(" ".join(credentials.agent_kinds("claude-opus")))
PY
)"

# A set that takes: 200, the box's verdict, the secret only where it belongs.
CR_M=$(fs_mark)
CR_R="$(api POST /api/command "{\"action\":\"credentials-set\",\"box\":\"ff-idle\",\"service\":\"gh\",\"kind\":\"token\",\"secret\":\"$CR_SECRET\"}")"
t "credentials: a good set is 200" 200 "$(printf '%s' "$CR_R" | tail -1)"
t "credentials: the reply is the box's verdict" "gh: set — logged in as ff-idle-bot" \
  "$(printf '%s' "$CR_R" | sed '$d' | jqf "d['verdict']")"
t "credentials: the secret arrived as stdin" "$CR_SECRET" "$(cat "$FLOOR_STATE/ff-idle.credential")"
t "credentials: the header names service and kind" "gh token" "$(tail -1 "$FLOOR_STATE/ff-idle.credential-headers")"
t "credentials: the secret is in no box argv" 0 "$(fs_calls_since "$CR_M" | grep -c "$CR_SECRET")"
t "credentials: the reply never echoes it" 0 "$(grep -c "$CR_SECRET" <<<"$CR_R")"
t "credentials: the journal says who and which kind" 1 \
  "$(grep -c ' box=ff-idle service=gh kind=token ok=yes verdict=gh: set — logged in as ff-idle-bot$' "$CR_JOURNAL")"
t "credentials: the journal never holds the value" 0 "$(grep -c "$CR_SECRET" "$CR_JOURNAL")"
t "credentials: the collector's log never holds it" 0 "$(grep -c "$CR_SECRET" "$TMP/server.log")"

# An agent kind, on a codex member.
CR_R="$(api POST /api/command '{"action":"credentials-set","box":"ff-lim-breaker","service":"agent","kind":"api-key","secret":"sk-FLOORAGENT"}')"
t "credentials: an agent kind is set" "agent: api-key set (codex) — it cannot be checked locally; the next session is the test" \
  "$(printf '%s' "$CR_R" | sed '$d' | jqf "d['verdict']")"

# Refusals: nothing reaches a box.
CR_M=$(fs_mark)
CR_R="$(api POST /api/command '{"action":"credentials-set","box":"ff-idle","service":"agent","kind":"cookie","secret":"x"}')"
t "credentials: a kind the agent does not take is 400" 400 "$(printf '%s' "$CR_R" | tail -1)"
t "credentials: ...and names the kinds" "agent on ff-idle takes: oauth-token api-key credentials-json" \
  "$(printf '%s' "$CR_R" | sed '$d' | jqf "d['error']")"
CR_R="$(api POST /api/command '{"action":"credentials-set","box":"ff-idle","service":"gh","kind":"token","secret":"  "}')"
t "credentials: an empty secret is 400" 400 "$(printf '%s' "$CR_R" | tail -1)"
CR_R="$(api POST /api/command '{"action":"credentials-set","box":"ff-nosuch","service":"gh","kind":"token","secret":"x"}')"
t "credentials: an unknown box is 400" 400 "$(printf '%s' "$CR_R" | tail -1)"
t "credentials: no refusal reached a box" 0 "$(fs_calls_since "$CR_M" | grep -c 'CREDENTIALS_SH')"

# A box that does not answer: the set did not happen, and the reply says so.
CR_R="$(api POST /api/command '{"action":"credentials-set","box":"ff-unreach","service":"gh","kind":"token","secret":"ghp_x"}')"
t "credentials: an unreachable box is a failed set" False "$(printf '%s' "$CR_R" | sed '$d' | jqf "d['ok']")"
t "credentials: ...journalled as not taken" 1 "$(grep -c ' box=ff-unreach service=gh kind=token ok=no ' "$CR_JOURNAL")"

# The page: the overlay exists and clears its field before the reply.
t "credentials: the page has the button" 1 "$(grep -c 'id="g-creds"' "$FLOOR/index.html")"
t "credentials: the field is cleared before the request resolves" 1 \
  "$(awk '/^function onCredsClick/{f=1} f&&/inp\.value="";/{c=NR} f&&/"credentials-set",\{box:box,service/{print (c&&c<NR)?1:0; exit}' "$FLOOR/src/app.js")"
t "credentials: the input is a password field" 1 "$(grep -c 'data-k="secret" type="password"' "$FLOOR/src/app.js")"
