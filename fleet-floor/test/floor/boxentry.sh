# shellcheck shell=bash  # sourced by ../run.sh, so it has no shebang of its own
# fleet-floor/test/floor/boxentry.sh — the suite for floor/boxentry.py (#792):
# the floor's door into a box, the rule shared/lib/box-entry.sh keeps for the
# CLI. Driven in-process against a fake `run`, so each row reads the exact
# argv the floor would hand `box`.
echo
echo "== the door into a box (#792)"
BE_OUT="$(python3 - "$FLOOR/server" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import floor.boxentry as be

def scenario(version, users="", forced=None):
    calls = []
    def run(argv, timeout, stdin_data=None):
        calls.append(argv)
        if argv[:2] == ["box", "--version"]:
            return (0, "box %s (/opt/box)\n" % version, "") if version else (1, "", "")
        if "/etc/passwd" in argv:
            return 0, "\n".join(users.split()) + ("\n" if users else ""), ""
        return 0, "", ""
    be.run = run
    be._mode = None
    be._users.clear()
    import os
    if forced:
        os.environ["CREW_BOX_ENTRY_MODE"] = forced
    else:
        os.environ.pop("CREW_BOX_ENTRY_MODE", None)
    return calls

be._agent_of = lambda box: {"r1": "codex"}.get(box)
scenario("0.10.0");  print("stamp-argv", " ".join(be.box_exec("r1", "bash", "-lc", "true")))
scenario("0.11.0");  print("user-roster-argv", " ".join(be.box_exec("r1", "bash", "-lc", "true")))
calls = scenario("0.11.0", users="kimi"); print("user-found-argv", " ".join(be.box_exec("x1", "true")))
print("user-found-as-root", int(any(c[:3] == ["box", "exec", "x1"] and "/etc/passwd" in c for c in calls)))
calls = scenario("0.11.0", users="kimi"); be.box_exec("x1", "a"); be.box_exec("x1", "b")
print("user-cached", sum(1 for c in calls if "/etc/passwd" in c))
scenario("0.11.0", users="");     print("user-nobody-argv", " ".join(be.box_exec("x1", "touch", "f")))
scenario("0.11.0", users="a b");  print("user-two-argv", " ".join(be.box_exec("x1", "touch", "f")))
scenario("0.11.0-rc2"); print("rc-is-user", be.entry_mode())
scenario("0.10.1-dev"); print("dev-is-stamp", be.entry_mode())
scenario("");           print("unreadable", be.entry_mode())
scenario("0.10.0", forced="user"); print("forced", be.entry_mode())
calls = scenario("0.10.0"); be.box_exec("r1", "a"); be.box_exec("r1", "b")
print("mode-read-once", sum(1 for c in calls if c[:2] == ["box", "--version"]))
scenario("0.10.0"); print("hint-stamp", be.shell_hint("r1"))
scenario("0.11.0"); print("hint-user", be.shell_hint("r1"))
PY
)"
bef() { sed -n "s/^$1 //p" <<<"$BE_OUT"; }
t "door: box below 0.11.0 is today's argv" "box exec r1 -- bash -lc true" "$(bef stamp-argv)"
t "door: box 0.11.0 enters as the roster's agent" "box exec --user codex r1 -- bash -lc true" "$(bef user-roster-argv)"
t "door: off the roster, the box's one regular user" "box exec --user kimi x1 -- true" "$(bef user-found-argv)"
t "door: ...found as root, the read that finds who is there" 1 "$(bef user-found-as-root)"
t "door: ...and cached per box" 1 "$(bef user-cached)"
t "door: no regular user is an argv box refuses, never root" "box exec --user (no regular user in x1) x1 -- touch f" "$(bef user-nobody-argv)"
t "door: two regular users likewise" "box exec --user (no regular user in x1) x1 -- touch f" "$(bef user-two-argv)"
t "door: a 0.11.0 candidate is user mode" user "$(bef rc-is-user)"
t "door: a 0.10 dev build is stamp mode" stamp "$(bef dev-is-stamp)"
t "door: an unreadable version is no mode" None "$(bef unreadable)"
t "door: CREW_BOX_ENTRY_MODE overrides" user "$(bef forced)"
t "door: the version is read once per process" 1 "$(bef mode-read-once)"
t "door: the shell hint below 0.11.0" "box shell r1" "$(bef hint-stamp)"
t "door: the shell hint on 0.11.0 names the agent" "box shell --user codex r1" "$(bef hint-user)"
# The collector's snapshot carries the mode and each unit's paste-able line.
BE_SNAP="$(body GET /api/fleet)"
t "door: the snapshot names the entry mode" stamp "$(jqf "d.get('box_entry')" <<<"$BE_SNAP")"
t "door: every unit carries its shell line" 1 \
  "$(jqf "int(all(u.get('shell') == 'box shell %s' % u['box'] for u in d['units']))" <<<"$BE_SNAP")"
# The floor refuses to serve over a box whose version it cannot read.
BE_DIR="$TMP/be-refuse"; mkdir -p "$BE_DIR/bin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$BE_DIR/bin/box"; chmod +x "$BE_DIR/bin/box"
BE_REFUSE="$(PATH="$BE_DIR/bin:$PATH" CREW_FLOOR_PASS=x CREW_FLOOR_PORT=0 timeout 20 python3 "$FLOOR/server/floor.py" 2>&1)"; BE_RC=$?
t "door: the floor refuses an unreadable box version" 1 "$BE_RC"
t "door: ...naming box --version" 1 "$(grep -c "cannot read the box version ('box --version' gave no version)" <<<"$BE_REFUSE")"
