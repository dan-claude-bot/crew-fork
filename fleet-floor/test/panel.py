#!/usr/bin/env python3
"""The fleet's review panel on the floor (#879): what /api/panel answers and
what panel-set writes, over a fixture fleet definition."""

import os
import shutil
import sys
import tempfile

TMP = tempfile.mkdtemp(prefix="crew-panel-")
CONF = os.path.join(TMP, "config")
os.makedirs(os.path.join(CONF, "store", "staged"))
os.environ["CREW_CONFIG_DIR"] = CONF
# The floor suite's own fixture would replace this test's roster.
for _k in ("FLOOR_FIXTURE", "FLOOR_TEST_FIXTURE", "CREW_FLOOR_ROSTER"):
    os.environ.pop(_k, None)
os.environ["CREW_FLEETS_DIR"] = os.path.join(TMP, "no-fleets")
with open(os.path.join(CONF, "fleet.roster"), "w") as f:
    f.write("lf-triage claude triage\nlf-builder claude builder\nlf-reviewer claude reviewer\n")
with open(os.path.join(CONF, "repos.txt"), "w") as f:
    f.write("acme/site\n")
FLEET_CONF = os.path.join(CONF, "fleet.conf")
with open(FLEET_CONF, "w") as f:
    f.write('# the panel\nFLEET_BENCH="old-a old-b"\nFLEET_TRIAGE="dan-claude-bot"\nFLEET_HUMAN="danmt"\nHOST_SCHEDULE=on\n')
with open(os.path.join(CONF, "store", "staged", "lf-builder.bench"), "w") as f:
    f.write("old-a old-b\n")

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "server"))
from floor import panel  # noqa: E402

POOL = {"entries": [
    {"id": "gh:dan-claude-bot", "service": "gh", "login": "dan-claude-bot", "members": [{"box": "lf-triage"}]},
    {"id": "gh:cndgrr", "service": "gh", "login": "cndgrr", "members": [{"box": "lf-builder"}]},
    {"id": "gh:andriujoseba", "service": "gh", "login": "andriujoseba", "members": [{"box": "lf-reviewer"}]},
    {"id": "agent:max", "service": "agent", "login": "", "members": [{"box": "lf-reviewer"}]},
]}

passed, failures = 0, []


def t(name, want, got):
    global passed
    if want == got:
        passed += 1
        print("ok   panel: " + name)
    else:
        failures.append(name)
        print("FAIL panel: %s  — expected [%r] got [%r]" % (name, want, got))


try:
    s = panel.snapshot(POOL)
    t("reads-the-fleets-panel", ["old-a", "old-b"], s["bench"])
    t("reads-the-triage-actor", "dan-claude-bot", s["triage"])
    t("suggests-what-the-reviewers-answer-as", ["andriujoseba"], s["suggest"]["bench"])
    t("suggests-the-triage-members-login", "dan-claude-bot", s["suggest"]["triage"])
    t("flags-a-reviewer-off-the-panel", True,
      any("lf-reviewer reviews as andriujoseba, which is not on the panel" in f for f in s["flags"]))
    t("flags-a-panel-login-no-member-answers-as", True, any(f.startswith("old-a is on the panel, but no member") for f in s["flags"]))
    t("no-member-staged-with-this-panel-is-stale", [], s["stale"])

    code, r = panel.set_panel({"bench": "andriujoseba", "triage": "dan-claude-bot"}, actor="operator")
    t("set-lands", (200, True), (code, r["ok"]))
    text = open(FLEET_CONF).read()
    t("set-rewrites-the-bench", True, 'FLEET_BENCH="andriujoseba"' in text and "old-a" not in text)
    t("set-keeps-every-other-line", True, "# the panel\n" in text and 'FLEET_HUMAN="danmt"' in text and "HOST_SCHEDULE=on" in text)
    s = panel.snapshot(POOL)
    t("after-set-no-flags", [], s["flags"])
    t("after-set-a-member-staged-with-the-old-panel-is-named", ["lf-builder"], s["stale"])
    journal = open(os.path.join(CONF, ".panel-journal.log")).read()
    t("set-is-journalled", True, "actor=operator bench=old-a,old-b->andriujoseba triage=dan-claude-bot->dan-claude-bot" in journal)

    code, r = panel.set_panel({"bench": ["not a login"]}, actor="operator")
    t("a-bad-login-is-refused", (400, True), (code, "not a GitHub login" in r["error"]))
    code, r = panel.set_panel({"bench": ["dan-claude-bot"], "triage": "dan-claude-bot"}, actor="operator")
    t("the-triage-actor-on-the-panel-is-refused", (400, True), (code, "triage never votes" in r["error"]))
    t("a-refusal-writes-nothing", True, 'FLEET_BENCH="andriujoseba"' in open(FLEET_CONF).read())

    code, r = panel.set_panel({"bench": [], "triage": ""}, actor="operator")
    t("an-empty-panel-is-allowed", (200, True), (code, 'FLEET_BENCH=""' in open(FLEET_CONF).read()))
    s = panel.snapshot(POOL)
    t("an-empty-panel-says-the-repositories-decide", True, any("the panel is empty" in f for f in s["flags"]))
finally:
    shutil.rmtree(TMP, ignore_errors=True)

print("panel: passed %d, failed %d" % (passed, len(failures)))
sys.exit(1 if failures else 0)
