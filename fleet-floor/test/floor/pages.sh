# shellcheck shell=bash
# fleet-floor/test/floor/pages.sh — pages, not modals (#870), read off the
# shipped page source: the routes, that the overlays are gone, that the header
# opens the pages, and that a poll repaints only a page's live bits. The walk
# itself (a member's page, the back button) is the browser suites' (workspaces.js).
APP="$FLOOR/src/app.js"

if command -v node >/dev/null 2>&1; then
  PG_ROUTES="$(node -e "$(sed -n '/^function parseRoute(/,/^}/p' "$APP")
var cases=['','#/','#/members','#/members/','#/member/ff-idle','#/member/a%2Fb','#/repositories','#/credentials','#/nope','#/member/'];
console.log(cases.map(function(h){var r=parseRoute(h);return (r.route||'-')+(r.box?':'+r.box:'');}).join(' '));")"
  t "pages: the routes (#870)" "- - members members member:ff-idle member:a/b repositories credentials - -" "$PG_ROUTES"
else
  skip "pages: the routes (#870)" "node is not installed"
fi
t "pages: a hash change takes the route" 1 "$(grep -c '^window.addEventListener("hashchange",pageRoute);' "$APP")"
t "pages: a reload on a page's address opens it" 1 "$(grep -c '^pageRoute();$' "$APP")"
t "pages: the three overlays are gone" 0 "$(grep -cE 'regov|rosov|credov|openRoster|openRegistries|openCreds' "$APP" "$FLOOR/src/style.css" | awk -F: '{s+=$2} END {print s}')"
t "pages: the header opens Members, Repositories and Credentials" "1 1 1" \
  "$(grep -c 'getElementById("g-roster").addEventListener("click",function(){if(!LIVE).*goto("#/members");});' "$APP") $(grep -c 'getElementById("g-reg").addEventListener("click",function(){if(!LIVE).*goto("#/repositories");});' "$APP") $(grep -c 'getElementById("g-creds").addEventListener("click",function(){if(!LIVE).*goto("#/credentials");});' "$APP")"
t "pages: the box console opens its member page" 1 "$(grep -c 'b.id==="ac-reg")goto("#/member/"+encodeURIComponent(box));' "$APP")"
t "pages: each poll repaints only a page's live bits" 1 "$(grep -c 'querySelectorAll("#pagebody \[data-live\]")' "$APP")"
t "pages: the poll calls it" 2 "$(grep -c 'pageOnPoll();' "$APP")"
# Nothing new on the wire: every action the pages send is one the collector has.
PG_ACTS="$(sed -n '/^\/\* ===================== pages, not modals (#870)/,/^function pageCredSet/p' "$APP" \
  | grep -oE 'act\("[a-z:]+"(\+box)?,"[a-z-]+"' | sed -E 's/.*,"([a-z-]+)"$/\1/' | sort -u | paste -sd' ' -)"
t "pages: every write is an existing action" "registry-inherit registry-override registry-set roster-set" "$PG_ACTS"
for a in roster-set registry-set registry-override registry-inherit credentials-set power-on power-off pause resume; do
  t "pages: the collector has $a" 1 "$(grep -c "\"$a\"" "$FLOOR/server/floor/actions.py" | awk '{print ($1>0)}')"
done

# #874 finding: a refused write is said BESIDE its control, not only in the
# status line (dev-server-1 read a refused registry-set as saved). pgSay and
# replyWhy run in node over a stand-in element, on the reply a refused
# registry-set gives (the engine's App not installed on the owner); the
# wiring is read off the source.
if command -v node >/dev/null 2>&1; then
  PG_SAY="$(node - "$APP" <<'JS'
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
const grab = (name) => { const i = src.indexOf('function ' + name + '('); return src.slice(i, src.indexOf('\n}\n', i) + 2); };
const status = [];
global.setStatus = (m, bad) => status.push((bad ? 'BAD ' : '') + m);
const el = () => { const e = { children: [], cls: {}, textContent: '', appendChild(c) { this.children.push(c); return c; }, setAttribute() {} };
  e.classList = { contains: (c) => !!e.cls[c], toggle: (c, on) => { e.cls[c] = !!on; } }; return e; };
global.document = { createElement: () => { const e = el(); Object.defineProperty(e, 'className', { set(v) { e.cls[v] = true; } }); return e; } };
eval(grab('replyWhy') + grab('pgSay') + 'global.replyWhy=replyWhy;global.pgSay=pgSay;');
const blk = el();
pgSay(blk, { ok: false, error: "acme/site: the fleet cannot reach it: the engine's App crew-engine is not installed on acme" }, 'saved');
const v = blk.children[0];
console.log([v.cls.pgverdict ? 1 : 0, v.cls.bad ? 1 : 0, /not installed on acme/.test(v.textContent) ? 1 : 0, /^refused/.test(v.textContent) ? 1 : 0, status.length].join(' '));
pgSay(blk, { ok: true }, 'saved — 1 added');
console.log([blk.children.length, v.cls.good ? 1 : 0, v.cls.bad ? 1 : 0, v.textContent].join('|'));
pgSay(blk, null, 'x');
console.log(/another action holds it/.test(v.textContent) ? 1 : 0);
JS
)"
  t "pages: a refused registry-set is said inline, in red, with its reason (#874)" "1 1 1 1 1" "$(sed -n 1p <<<"$PG_SAY")"
  t "pages: ...and a success replaces it in the same place, in green" "1|1|0|saved — 1 added" "$(sed -n 2p <<<"$PG_SAY")"
  t "pages: ...and a write another action held is said as not sent" 1 "$(sed -n 3p <<<"$PG_SAY")"
else
  skip "pages: a refused registry-set is said inline (#874)" "node is not installed"
fi
t "pages: Repositories' writes answer at their block" 1 \
  "$(grep -c "return pgAfter(r,scope,'#pagebody .regblk\[data-kind=\"'+kind+'\"\]',okText);" "$APP")"
t "pages: ...Add and remove hand their block to it" 2 \
  "$(grep -cE 'return repoWrite\(k,cur\.(filter|concat)\(.*\),rb,"saved — ' "$APP")"
t "pages: a refusal repaints nothing, so the input stays as typed" 1 \
  "$(grep -c 'if(!(r&&r.ok)){pgSay(scope,r,okText);return r;}' "$APP")"
t "pages: member scope, edit, remove and Add member say theirs inline" "2 1 1 1" \
  "$(grep -c 'return pgAfter(r,blk,' "$APP") $(grep -c 'return pgAfter(r,eacts,' "$APP") $(grep -c 'pgSay(racts,r,"");' "$APP") $(grep -c 'pgSay(acts,r,"");' "$APP")"
t "pages: the pool and the engine say theirs inline too" "1 1" \
  "$(grep -c 'out.textContent=(r&&r.ok)?((r.lines&&r.lines.join(" · "))||"done"):"refused — "+replyWhy(r);' "$APP") $(grep -c 'pgSay(b.parentNode,r,"");return;}' "$APP" | awk '{print ($1>=2)}')"
t "pages: cmd() hands a failed request's reason back to the caller" 1 \
  "$(grep -c 'return {ok:false,failed:true,late:late,' "$APP")"

# #875: asleep is its own case in the renderer — calm, never SIGNAL LOST.
t "asleep: the HUD vocabulary has it, before the offline split" 1 \
  "$(grep -c 'if(u.state==="asleep")return "asleep";' "$APP")"
t "asleep: it is counted, and a chip filters it" "1 1" \
  "$(grep -c 'var c={working:0,idle:0,asleep:0,' "$APP") $(grep -c 'data-v="asleep">Asleep<' "$FLOOR/src/body.html")"
t "asleep: the tile has its own case: dimmed, ASLEEP, no SIGNAL LOST" "1 1" \
  "$(grep -c 'var asleep=unit.state==="asleep";' "$APP") $(grep -c 'off?"— BPM":asleep?"ASLEEP":' "$APP")"
t "asleep: SIGNAL LOST stays offline's alone" 1 \
  "$(awk '/^function drawCamCell/{f=1} f&&/if\(off\)\{/{print 1; exit}' "$APP")"
t "asleep: the room veils it calm and says why" "1 1" \
  "$(grep -c 'if(STATE==="asleep")asleepVeil();' "$APP") $(grep -c '^function asleepVeil(){' "$APP")"
t "asleep: the room's card says ASLEEP, not SILENT" 1 \
  "$(grep -c ',sl=asleep?"ASLEEP":stw||(off?"SILENT":' "$APP")"
t "asleep: member cards draw it calm" 1 "$(grep -c '^.mst.s-asleep{' "$FLOOR/src/style.css")"

# The engine's permissions sentence is the collector's list, not a copy.
t "engine: the existing-App permissions come from /api/engine, not the page" "0 1" \
  "$(grep -c 'permissions: metadata, issues' "$APP") $(grep -c "permissions'+enginePermsWords(e.permissions)+'" "$APP")"
if command -v node >/dev/null 2>&1; then
  t "engine: ...said in words, all read-only" \
    "permissions (all read-only): metadata, contents, actions, issues, pull requests, checks, commit statuses, discussions" \
    "$(node -e "$(sed -n '/^var ENGINE_PERM_WORDS=/p;/^function enginePermsWords(/,/^}/p' "$APP")
console.log('permissions'+enginePermsWords({metadata:'read',contents:'read',actions:'read',issues:'read',pull_requests:'read',checks:'read',statuses:'read',discussions:'read'}));")"
fi

# #875 on Credentials: an asleep member's logins are read at its next wake —
# said so, with what its next wake delivers — never "unknown".
if command -v node >/dev/null 2>&1; then
  PG_ZZ="$(node - "$APP" <<'JS'
const src = require('fs').readFileSync(process.argv[2], 'utf8');
const grab = (n) => { const i = src.indexOf('function ' + n + '('); return src.slice(i, src.indexOf('\n}\n', i) + 2); };
global.esc = (x) => String(x);
global.POOL = { entries: [
  { id: 'gh:bot', members: [{ box: 'zz', verdict: null }] },
  { id: 'agent:max', members: [{ box: 'zz', verdict: { ok: true }, owes: true }] },
  { id: 'tg:alerts', members: [{ box: 'zz', verdict: { ok: true } }] }] };
eval(grab('poolPending') + grab('liveCreds') + 'global.liveCreds=liveCreds;');
const a = liveCreds({ state: 'asleep', box: 'zz', gh: 'unknown', vendor: 'unknown' }, 'claude', 'zz');
const r = liveCreds({ state: 'idle', box: 'zz', gh: 'unknown', vendor: 'unknown' }, 'claude', 'zz');
console.log([/gh: asleep — read at its next wake/.test(a) ? 1 : 0, /claude: asleep — read at its next wake/.test(a) ? 1 : 0,
  /assigned: gh:bot, agent:max, delivered at its next wake/.test(a) ? 1 : 0, /unknown/.test(a) ? 1 : 0,
  /gh: unknown/.test(r) ? 1 : 0].join(' '));
JS
)"
  t "asleep: its logins read at its next wake, with what it delivers — not unknown; a running box keeps unknown" "1 1 1 0 1" "$PG_ZZ"
fi
t "asleep: the members page reads the pool for it" 1 \
  "$(sed -n '/^function renderMembers(){/,/^}/p' "$APP" | grep -c 'api("/api/pool")')"
