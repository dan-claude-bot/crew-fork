#!/usr/bin/env python3
"""Regression for #847: a job that reads finished has released its slot.

The floor used to publish a job's final state first and release the one-job
slot and the host maintenance lock after writing its record and journal line.
A client that started the next job the moment it saw "done" got a 409 inside
that window (the workspaces walk on #846's CI). Here the window is held open on
purpose: the journal write sleeps, so a floor that publishes before releasing
is refused every time, and one that releases first never is.
"""

import os
import shutil
import sys
import tempfile
import time

TMP = tempfile.mkdtemp(prefix="crew-job-slot-")
STUB = os.path.join(TMP, "crew")
with open(STUB, "w", encoding="utf-8") as f:
    f.write("#!/bin/sh\necho \"stub crew $*\"\nexit 0\n")
os.chmod(STUB, 0o755)
os.environ["CREW_FLOOR_CREW_CLI"] = STUB
os.environ["CREW_HOST_STATE_DIR"] = os.path.join(TMP, "state")
os.environ["CREW_CONFIG_DIR"] = os.path.join(TMP, "config")
os.makedirs(os.environ["CREW_CONFIG_DIR"], exist_ok=True)
for name in ("fleet.roster", "fleet.conf", "repos.txt"):
    open(os.path.join(os.environ["CREW_CONFIG_DIR"], name), "w").close()

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "server"))
from floor import jobs as floor_jobs  # noqa: E402  (env and sys.path first)
from floor import ping                 # noqa: E402

ping.log = lambda _m: None
floor_jobs.log = lambda _m: None

real_journal = floor_jobs.Jobs._journal


def slow_journal(self, job, log_path):
    time.sleep(0.3)          # the window, held open
    real_journal(self, job, log_path)


floor_jobs.Jobs._journal = slow_journal

failures = []
try:
    jobs = floor_jobs.Jobs("first")
    for n in range(5):
        status, body = jobs.start({"verb": "down"}, actor="test")
        if status != 202:
            failures.append("start %d answered %s: %s" % (n, status, body.get("error")))
            break
        jid = body["job"]["id"]
        deadline = time.time() + 20
        while time.time() < deadline:
            with jobs.lock:
                state = jobs.jobs[jid]["state"]
            if state != "running":
                break
            time.sleep(0.01)
        else:
            failures.append("job %d never finished" % n)
            break
        if state != "done":
            failures.append("job %d read %s, not done" % (n, state))
            break
        # The moment it reads finished, the next one must be accepted.
    status, body = jobs.start({"verb": "down"}, actor="test")
    if status != 202 and not failures:
        failures.append("a job started right after one read done answered %s: %s"
                        % (status, body.get("error")))
    # Its record and journal line were written with the final state.
    rec = floor_jobs._read_json(floor_jobs._paths()[2]) or {}
    if not failures and rec.get("state") not in ("running", "done"):
        failures.append("the job record reads %r" % rec.get("state"))
    time.sleep(1)
    with open(jobs.journal, encoding="utf-8") as f:
        lines = [ln for ln in f if " verb=down" in ln]
    if not failures and len(lines) < 5:
        failures.append("the journal holds %d down lines, expected at least 5" % len(lines))
    if not failures and not all(" rc=0 " in ln for ln in lines):
        failures.append("a journal line was written before the job's rc: %s" % lines)
finally:
    shutil.rmtree(TMP, ignore_errors=True)

for f in failures:
    print("FAIL " + f)
if failures:
    sys.exit(1)
print("ok   a job that reads finished has released its slot: five back to back, no 409 (#847)")
