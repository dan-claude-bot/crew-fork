# shellcheck shell=bash  # sourced by ../run.sh, so it has no shebang of its own
# fleet-floor/test/floor/inflight.sh — the suite for
# fleet-floor/server/floor/inflight.py (#766): what the console is doing right
# now, one claim per box and one for the fleet.
#
# Sourced by ../run.sh (ok/fail/t/api/body/status/jqf, a collector on $PORT
# backed by stub-box). The claims' own contract — a second action refused, a
# fleet action leaving a held box alone, exactly one fire — is pinned in
# ../concurrent-actions.py against the module; this is the wire and the page.
echo
echo "== actions in flight (#766)"
t "inflight: nothing is in flight at rest" '{"boxes": {}, "fleet": null}' "$(body GET /api/actions)"

# A slow stop on ff-idle: while it runs, every tab can see it, and a second
# action on the same box is refused and fires nothing.
printf '4\n' >"$FLOOR_STATE/ff-idle.slow"
IF_M=$(fs_mark)
( api POST /api/command '{"action":"power-off","box":"ff-idle"}' >"$TMP/if-first" ) &
IF_PID=$!
IF_SEEN=""
for _ in $(seq 1 40); do
  IF_SEEN="$(body GET /api/actions | jqf "d['boxes'].get('ff-idle',{}).get('action','')")"
  [ "$IF_SEEN" = power-off ] && break
  sleep 0.1
done
t "inflight: the box's action is published while it runs" power-off "$IF_SEEN"
t "inflight: ...with its age" True "$(body GET /api/actions | jqf "isinstance(d['boxes']['ff-idle']['age'], int)")"
IF_R="$(api POST /api/command '{"action":"power-on","box":"ff-idle"}')"
t "inflight: a second action on a held box is 409" 409 "$(printf '%s' "$IF_R" | tail -1)"
t "inflight: ...said as busy, naming the first" True \
  "$(printf '%s' "$IF_R" | sed '$d' | jqf "d['busy'] and 'power-off' in d['error'] and 'nothing was run' in d['error']")"
IF_R="$(api POST /api/command '{"action":"credentials-set","box":"ff-idle","service":"gh","kind":"token","secret":"ghp_x"}')"
t "inflight: a credential set waits for the box too" 409 "$(printf '%s' "$IF_R" | tail -1)"
wait "$IF_PID"
rm -f "$FLOOR_STATE/ff-idle.slow"
t "inflight: the first action completed" 200 "$(tail -1 "$TMP/if-first")"
t "inflight: the box was fired at once — one down, no start" "1|0" \
  "$(fs_calls_since "$IF_M" | grep -c '^down ff-idle$')|$(fs_calls_since "$IF_M" | grep -c '^start ff-idle$')"
t "inflight: nothing is left held" '{"boxes": {}, "fleet": null}' "$(body GET /api/actions)"
status POST /api/command '{"action":"power-on","box":"ff-idle"}' >/dev/null

# The page: every action goes through the one in-flight wrapper.
t "inflight: no control fires an action around act()" 0 "$(grep -c 'cmd("' "$FLOOR/src/app.js")"
t "inflight: the page polls /api/actions" 1 "$(grep -c 'api("/api/actions")' "$FLOOR/src/app.js")"
t "inflight: a disabled control is styled as one" 1 "$(grep -c '^\.gbtn\[disabled\],\.act2\[disabled\],\.lbtn\[disabled\]' "$FLOOR/src/style.css")"
t "inflight: the fleet progress bar is on the page" 1 "$(grep -c 'id="actprog"' "$FLOOR/index.html")"
