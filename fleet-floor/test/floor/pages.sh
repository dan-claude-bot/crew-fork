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
