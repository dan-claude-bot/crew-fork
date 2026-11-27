#!/usr/bin/env python3
"""#898 and #899 on the floor, with no fleet: a member's intent as the floor
reads it, the CLI verb each lifecycle action runs, the state laid over a
unit, a roster removal refused for a member on duty, and the health window
the store serves from its one row per change.
"""

import os
import shutil
import sys
import tempfile

TMP = tempfile.mkdtemp(prefix="crew-member-state-")
CONF = os.path.join(TMP, "config")
os.environ["CREW_CONFIG_DIR"] = CONF
os.environ["CREW_FLOOR_STORE"] = os.path.join(TMP, "fleet.sqlite")
os.makedirs(os.path.join(CONF, "store"))
with open(os.path.join(CONF, "fleet.roster"), "w") as f:
    f.write("mm-a claude builder\nmm-b claude reviewer\n")
for name in ("fleet.conf", "repos.txt"):
    open(os.path.join(CONF, name), "w").close()

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "server"))
from floor import intent, member, store, units  # noqa: E402  (env and sys.path first)
from floor import roster as froster  # noqa: E402

failures = []
passed = 0


def t(name, want, got):
    global passed
    if want == got:
        passed += 1
        print("ok   member: " + name)
    else:
        failures.append(name)
        print("FAIL member: %s  — expected [%r] got [%r]" % (name, want, got))


def write(rel, text):
    path = os.path.join(CONF, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


try:
    # --- intent, as the CLI writes it -----------------------------------------
    t("no file is on duty", "on-duty", intent.read("mm-a")["intent"])
    write("store/intent/mm-a", "stopped 2026-11-27T10:00:00Z floor:dan stopping\n")
    r = intent.read("mm-a")
    t("a stop mid-run reads stopping", ("stopped", True, "2026-11-27T10:00:00Z"), (r["intent"], r["stopping"], r["since"]))
    t("...and says it is finishing its run", "stopping by operator — finishing its run, then stopped", intent.note(r))
    write("store/intent/mm-a", "off-duty 2026-11-27T10:00:00Z op logout\n")
    r = intent.read("mm-a")
    t("off duty keeps its logout flag", ("off-duty", True, False), (r["intent"], r["logout"], r["stopping"]))
    write("store/intent/mm-a", "garbled\n")
    t("an unknown word holds, as stopped", "stopped", intent.read("mm-a")["intent"])
    os.remove(os.path.join(CONF, "store/intent/mm-a"))
    write("store/paused/mm-a", "2026-11-01T00:00:00Z\n")
    t("the pre-#898 pause marker reads as stopped", "stopped", intent.read("mm-a")["intent"])
    os.remove(os.path.join(CONF, "store/paused/mm-a"))
    write("store/logout/mm-a.agent", "2026-11-27T10:00:00Z applied\n")
    write("store/logout/mm-a.tg", "2026-11-27T10:00:00Z owed\n")
    t("the removed logins, in service order", ["agent", "tg"], intent.logged_out("mm-a"))
    write("store/waiting/mm-a", "o/r#7 o/r#9\n")
    t("the items waiting on a person", "o/r#7 o/r#9", intent.waiting("mm-a"))

    # --- the verb each action runs --------------------------------------------
    t("Stop is crew stop", (["stop", "mm-a"], ""), member.argv_for("power-off", "mm-a", {}))
    t("Stop with the box ticked is --force", ["stop", "mm-a", "--force"], member.argv_for("power-off", "mm-a", {"force": True})[0])
    t("...only a true force forces", ["stop", "mm-a"], member.argv_for("power-off", "mm-a", {"force": "yes"})[0])
    t("force-stop is crew stop --force", ["stop", "mm-a", "--force"], member.argv_for("force-stop", "mm-a", {})[0])
    t("Start is crew start", ["start", "mm-a"], member.argv_for("power-on", "mm-a", {})[0])
    t("Pause is crew pause", ["pause", "mm-a"], member.argv_for("pause", "mm-a", {})[0])
    t("Unhire with logout", ["unhire", "mm-a", "--logout"], member.argv_for("unhire", "mm-a", {"logout": True})[0])
    t("Logout names its service", ["logout", "mm-a", "agent"], member.argv_for("logout", "mm-a", {"service": "agent"})[0])
    t("...and refuses another", (None, "the service is gh, agent or tg"), member.argv_for("logout", "mm-a", {"service": "x; rm"}))

    # --- the state laid over a unit -------------------------------------------
    base = dict(units.unit_defaults(), box="mm-a", state="idle", note="")
    on = {"intent": "on-duty", "since": "", "actor": "", "stopping": False, "logout": False}
    u = units.apply_member_state(dict(base), on, "running")
    t("no agent login: AUTH BLOCKED, said why", True, u["note"].startswith("AUTH BLOCKED — no agent login (removed by the operator)"))
    t("...its status is auth", "auth", u["status"])
    os.remove(os.path.join(CONF, "store/logout/mm-a.agent"))
    os.remove(os.path.join(CONF, "store/logout/mm-a.tg"))
    u = units.apply_member_state(dict(base), on, "running")
    t("an idle member with an item waiting on a person says so", "waiting on a human — o/r#7 o/r#9", u["note"])
    t("...its status is waiting", "waiting", u["status"])
    os.remove(os.path.join(CONF, "store/waiting/mm-a"))
    write("store/unstaged/mm-a", "o/other\n")
    u = units.apply_member_state(dict(base), on, "running")
    t("an idle member staged without a repository says unstaged", True, u["note"].startswith("unstaged — its box was staged without o/other"))
    os.remove(os.path.join(CONF, "store/unstaged/mm-a"))
    stopping = dict(on, intent="stopped", stopping=True)
    u = units.apply_member_state(dict(base, cur={"start": 1, "key": "k"}), stopping, "running")
    t("a stopping member still running its run is working, with the hold", ("working", "stopping by operator — finishing its run, then stopped"), (u["state"], u["note"]))
    u = units.apply_member_state(dict(base, state="asleep"), dict(on, intent="stopped"), "stopped")
    t("a stopped member is held, never asleep", ("held", "held"), (u["state"], u["status"]))
    u = units.apply_member_state(dict(base, state="working", lock={"stuck": True}), on, "running")
    t("a stuck run is its own status", "stuck", u["status"])

    # --- a roster removal --------------------------------------------------------
    write("store/staged/mm-b.bench", "x\n")
    keep_a = [{"box": "mm-a", "agent": "claude", "room": "builder"}]
    before = {"mm-a": {}, "mm-b": {}}
    t("removing a hired member on duty is refused", True, "mm-b is on duty — Unhire it first" in froster._removal_refused(before, keep_a))
    write("store/intent/mm-b", "off-duty 2026-11-27T10:00:00Z op\n")
    t("...an off-duty one is removed", "", froster._removal_refused(before, keep_a))
    os.remove(os.path.join(CONF, "store/intent/mm-b"))
    os.remove(os.path.join(CONF, "store/staged/mm-b.bench"))
    t("...one never hired is removed", "", froster._removal_refused(before, keep_a))

    # --- the health window ----------------------------------------------------------
    now = 1_800_000_000
    store.record_statuses({"mm-a": "idle", "mm-b": "asleep"}, now - 7200)
    store.record_statuses({"mm-a": "idle", "mm-b": "asleep"}, now - 7100)
    store.record_statuses({"mm-a": "working"}, now - 3600)
    store.record_statuses({"mm-a": "idle"}, now - 600)
    c = store.connect()
    rows = c.execute("SELECT COUNT(*) AS n FROM status_log WHERE box = 'mm-a'").fetchone()["n"]
    c.close()
    t("one row per change, not per poll", 3, rows)
    h = store.health("mm-a", now)
    t("the totals cover only what was recorded", ({"idle": 3600 + 600, "working": 3000}, 7200),
      (h["totals"], h["covered_s"]))
    t("the segments are the spans in order", [[86400 - 7200, 86400 - 3600, "idle"], [86400 - 3600, 86400 - 600, "working"], [86400 - 600, 86400, "idle"]],
      h["segments"])
    old = store.health("mm-a", now + 86400 * 2)
    t("a status older than the window runs from the window's start", ({"idle": 86400}, 86400), (old["totals"], old["covered_s"]))
    t("a box with no rows is an empty window", (0, []), (store.health("nobody", now)["covered_s"], store.health("nobody", now)["segments"]))
finally:
    shutil.rmtree(TMP, ignore_errors=True)

print("member: passed %d, failed %d" % (passed, len(failures)))
sys.exit(1 if failures else 0)
