#!/usr/bin/env python3
"""#875: a member the host tick stopped is ASLEEP, not a lost signal.

0.1.4's host tick stops an idle member and starts it again when its board has
work. Such a box is `stopped` to the inventory; units.build_unit served it as
the default `offline`, and the page drew offline as SIGNAL LOST. Here a stub
store stands in for the host's: a stopped box it last saw running an engine is
`asleep`, hired, with a note saying the tick wakes it; one the operator
holds is `held` with the hold's own note (#898) — the pre-#898 pause marker
reads as stopped, and a written intent as itself; one never seen hired names
Hire.
"""

import os
import shutil
import sys
import tempfile

TMP = tempfile.mkdtemp(prefix="crew-asleep-")
os.environ["CREW_CONFIG_DIR"] = os.path.join(TMP, "config")
os.makedirs(os.path.join(os.environ["CREW_CONFIG_DIR"], "store", "paused"))
for name in ("fleet.roster", "fleet.conf", "repos.txt"):
    open(os.path.join(os.environ["CREW_CONFIG_DIR"], name), "w").close()

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "server"))
from floor import units  # noqa: E402  (env and sys.path first)


class Store:
    """The two calls build_unit makes for a stopped box."""

    def __init__(self, seen):
        self.seen = seen

    def note_state(self, box, state):
        pass

    def stored_unit(self, box, now):
        if box not in self.seen:
            return None
        return {"source": "stored", "stored_at": "2026-11-26T10:00:00Z", "queue": [], "sessions": [],
                "spark": [0.0] * 22, "today": 0, "cost_24h": 0,
                "engine_seen": self.seen[box], "last_seen": "2026-11-26T10:00:00Z"}


store = Store({"zz-asleep": "crew@0.1.4-rc19", "zz-paused": "crew@0.1.4-rc19"})
open(os.path.join(os.environ["CREW_CONFIG_DIR"], "store", "paused", "zz-paused"), "w").close()
now = 1795700000
failures = []
passed = 0


def t(name, want, got):
    global passed
    if want == got:
        passed += 1
        print("ok   asleep: " + name)
    else:
        failures.append(name)
        print("FAIL asleep: %s  — expected [%r] got [%r]" % (name, want, got))


def unit(box):
    return units.build_unit({"box": box, "agent": "claude", "room": "triage"}, "stopped", {}, now, store=store)


try:
    a = unit("zz-asleep")
    t("a stopped box the store saw hired is asleep", "asleep", a["state"])
    t("...and hired", "yes", a["hired"])
    t("...its note says the tick wakes it", True, a["note"].startswith("asleep — the host tick wakes it when its board has work"))
    t("...and when it was last up", True, "last up 2026-11-26T10:00:00Z" in a["note"])
    t("...no alarm: not paused, not disarmed", (False, False), (a["paused"], a["disarmed"]))
    t("...the store's sighting is not served", (False, False), ("engine_seen" in a, "last_seen" in a))
    p = unit("zz-paused")
    t("a stopped box under the pre-#898 pause marker is held, not asleep", "held", p["state"])
    t("...read as stopped, with the hold's note", ("stopped", "stopped by operator — Start lifts it"),
      (p["intent"], p["note"]))
    t("...its health status is held", "held", p["status"])
    idir = os.path.join(os.environ["CREW_CONFIG_DIR"], "store", "intent")
    os.makedirs(idir, exist_ok=True)
    with open(os.path.join(idir, "zz-asleep"), "w") as f:
        f.write("off-duty 2026-11-27T10:00:00Z op\n")
    o = unit("zz-asleep")
    t("an off-duty member that is stopped is held, never asleep", ("held", "off-duty"), (o["state"], o["intent"]))
    t("...with the off-duty note", "off duty — Hire puts it back", o["note"])
    with open(os.path.join(idir, "zz-asleep"), "w") as f:
        f.write("paused 2026-11-27T10:00:00Z op\n")
    fz = units.build_unit({"box": "zz-asleep", "agent": "claude", "room": "builder"}, "frozen", {}, now, store=store)
    t("a frozen box is not probed and reads held, paused", ("held", "paused", True),
      (fz["state"], fz["intent"], fz["paused"]))
    t("...with the pause's note", "paused by operator since 2026-11-27T10:00:00Z — Resume continues it", fz["note"])
    os.remove(os.path.join(idir, "zz-asleep"))
    n = unit("zz-never")
    t("a stopped box never seen hired stays offline", "offline", n["state"])
    t("...and names Hire", True, "Hire" in n["note"] and "crew hire zz-never" in n["note"])
    t("...hired stays unknown", "unknown", n["hired"])
    b = units.build_unit({"box": "zz-bare", "agent": "claude", "room": "triage"}, "stopped", {}, now, store=None)
    t("with no store, a stopped box is as before", ("offline", "stopped — crew up starts it"), (b["state"], b["note"]))
finally:
    shutil.rmtree(TMP, ignore_errors=True)

print("asleep: passed %d, failed %d" % (passed, len(failures)))
sys.exit(1 if failures else 0)
