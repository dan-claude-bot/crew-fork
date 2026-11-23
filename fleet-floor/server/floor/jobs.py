"""The floor runs the CLI's verbs (#815): one job at a time on the host.

A job is ONE invocation of the CLI, as a host process, for the fleet this
process serves: `up` (the whole roster), `create` (`up <box>`, one member),
`hire`, `upgrade` and `down`. The floor adds no flow of its own: the verb does
what it does on the command line, and the page shows it running.

Three rules carry the whole design:

  ONE AT A TIME, HOST-WIDE. The slot is a lock file under the host state
  directory, taken non-blocking by the request that starts a job and held by
  the job until its process exits. Every floor process on the host — the one
  serving `/`, and each fleet's child behind `/f/<id>/` — takes the same file,
  so a second job anywhere on the host is refused, naming the one running. The
  record of the running job sits beside the lock, so any tab on any fleet can
  show what the host is doing.

  NEVER BESIDE THE SCHEDULE. A job also takes the host maintenance lock the
  scheduled verbs take (`restart`, `reset`, `tick`), so the cron never starts
  or stops a box mid-`up`, and a floor job is refused while a scheduled run
  holds it.

  THE PLAN FIRST. `up` and `create` run only after a `--dry-run` of the same
  verb has been shown: the run names the plan job it confirms, and is refused
  unless that plan succeeded, is recent, is this fleet's, and the roster has not
  changed since it was read.

The child process never inherits a lock: `subprocess` closes every descriptor
but the three standard ones (close_fds), so no orphan can outlive the job
holding the slot (the #809 shape).
"""

import fcntl
import json
import os
import subprocess
import threading
import time
import uuid

from floor import CREW_ROOT
from floor.ping import log
from floor.roster import CONFIG_DIR, read_roster, roster_etag

CREW_CLI = os.environ.get("CREW_FLOOR_CREW_CLI") or os.path.join(CREW_ROOT, "cli", "crew")
PLAN_FRESH_S = int(os.environ.get("CREW_FLOOR_PLAN_FRESH_S", "900"))
OUTPUT_LINES = 4000
RECENT = 20

# verb -> (needs a box, needs a confirmed plan, argv builder)
VERBS = {
    "up":      (False, True,  lambda box: ["up"]),
    "create":  (True,  True,  lambda box: ["up", box]),
    "hire":    (True,  False, lambda box: ["hire", box]),
    "upgrade": (True,  False, lambda box: ["upgrade", box]),
    "down":    (False, False, lambda box: ["down"]),
}


def host_state_dir():
    explicit = os.environ.get("CREW_HOST_STATE_DIR")
    if explicit:
        return explicit
    # On a service host, the service's own state dir — the CLI's default (#822).
    from floor.fleets import data_dir, service_conf_value
    if service_conf_value("CREW_SERVICE_USER") is not None:
        return os.path.join(data_dir(), "state")
    xdg = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(xdg, "crew")


def _paths():
    d = host_state_dir()
    return (d, os.path.join(d, ".floor-job.lock"), os.path.join(d, "floor-job.json"),
            os.path.join(d, ".host-maintenance.lock"))


def _read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _write_json(path, obj):
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f)
    os.replace(tmp, path)


def _maintenance_holder(lock_path):
    raw = ""
    try:
        with open(lock_path + ".holder", encoding="utf-8") as f:
            raw = f.read().split()
    except OSError:
        raw = []
    if len(raw) >= 2 and raw[0].isdigit():
        age = max(0, int(time.time()) - int(raw[0]))
        return "'crew %s' (running %ds, pid %s)" % (raw[1], age, raw[2] if len(raw) > 2 else "?")
    return "another host maintenance job of the CLI"


def describe(rec):
    if not rec:
        return "another job"
    what = "crew %s" % " ".join(rec.get("argv") or [rec.get("verb", "?")])
    return "%s on fleet %s (running %ds)" % (what, rec.get("fleet", "?"),
                                             max(0, int(time.time() - rec.get("started", time.time()))))


class Jobs:
    """This fleet's jobs: the one running (host-wide), and its recent ones."""

    def __init__(self, fleet_id):
        self.fleet_id = fleet_id
        self.lock = threading.Lock()
        self.jobs = {}          # id -> job dict (this process's jobs only)
        self.order = []
        self.journal = os.path.join(CONFIG_DIR, ".jobs-journal.log")
        self.logdir = os.path.join(CONFIG_DIR, "store", "jobs")

    # -- reading ------------------------------------------------------------
    def _public(self, j, lines=None):
        out = {k: j[k] for k in ("id", "fleet", "verb", "box", "plan", "argv", "state",
                                 "rc", "started", "ended", "actor", "confirms", "step")}
        out["elapsed"] = int((j["ended"] or time.time()) - j["started"])
        out["lines"] = len(j["output"])
        out["output"] = j["output"][-lines:] if lines else j["output"]
        return out

    def get(self, job_id):
        with self.lock:
            j = self.jobs.get(job_id)
            return self._public(j) if j else None

    def snapshot(self):
        """What any tab asks every second while something runs: the HOST's
        running job (from the shared record, whichever fleet started it) and
        this fleet's recent jobs with their output tails."""
        _, _, rec_path, _ = _paths()
        rec = _read_json(rec_path)
        current = None
        if rec and rec.get("state") == "running":
            # A record whose process is gone was left by a floor that died
            # mid-job; the lock it held died with it, so it is not running.
            pid = rec.get("floor_pid")
            alive = True
            if isinstance(pid, int):
                try:
                    os.kill(pid, 0)
                except OSError:
                    alive = False
            if alive:
                current = {k: rec.get(k) for k in ("id", "fleet", "verb", "box", "plan",
                                                   "argv", "started", "step", "actor")}
                current["elapsed"] = int(time.time() - rec.get("started", time.time()))
        with self.lock:
            recent = [self._public(self.jobs[i], lines=200) for i in self.order[-RECENT:]][::-1]
        return {"fleet": self.fleet_id, "current": current, "recent": recent,
                "verbs": sorted(VERBS)}

    # -- starting -----------------------------------------------------------
    def start(self, body, actor=""):
        verb = str(body.get("verb", "") or "")
        box = str(body.get("box", "") or "").strip()
        plan = bool(body.get("plan"))
        confirms = str(body.get("confirm", "") or "")
        if verb not in VERBS:
            return 400, {"ok": False, "error": "unknown verb %r (one of: %s)" % (verb, ", ".join(sorted(VERBS)))}
        needs_box, needs_plan, argv_of = VERBS[verb]
        if needs_box:
            if box not in {u["box"] for u in read_roster()}:
                return 400, {"ok": False, "error": "%r is not a member of this fleet's roster" % box}
        else:
            box = ""
        if plan and not needs_plan:
            return 400, {"ok": False, "error": "%s has no plan to show; it runs when confirmed" % verb}
        argv = argv_of(box)
        if plan:
            argv = argv + ["--dry-run"]
        elif needs_plan:
            err = self._check_plan(confirms, verb, box)
            if err:
                return 409, {"ok": False, "error": err}

        state_dir, slot_path, rec_path, maint_path = _paths()
        try:
            os.makedirs(state_dir, exist_ok=True)
            slot = open(slot_path, "a")
        except OSError as e:
            return 500, {"ok": False, "error": "cannot open the floor's job slot at %s: %s" % (slot_path, e)}
        try:
            fcntl.flock(slot, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            slot.close()
            running = _read_json(rec_path)
            return 409, {"ok": False, "busy": True,
                         "error": "one job at a time on this host: %s is running" % describe(running),
                         "running": running}
        maint = None
        if not plan:
            try:
                maint = open(maint_path, "a")
                fcntl.flock(maint, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                if maint:
                    maint.close()
                slot.close()
                return 409, {"ok": False, "busy": True,
                             "error": "the host maintenance lock is held by %s; no job was started"
                                      % _maintenance_holder(maint_path)}
            try:
                with open(maint_path + ".holder", "w", encoding="utf-8") as f:
                    f.write("%d floor:%s %d\n" % (int(time.time()), verb, os.getpid()))
            except OSError:
                pass

        job = {"id": uuid.uuid4().hex[:12], "fleet": self.fleet_id, "verb": verb, "box": box,
               "plan": plan, "argv": argv, "state": "running", "rc": None,
               "started": time.time(), "ended": None, "actor": actor, "confirms": confirms,
               "step": "starting crew %s" % " ".join(argv), "output": [],
               "etag": roster_etag()}
        with self.lock:
            self.jobs[job["id"]] = job
            self.order.append(job["id"])
            if len(self.order) > 200:
                old = self.order.pop(0)
                self.jobs.pop(old, None)
        self._record(job)
        threading.Thread(target=self._run, args=(job, slot, maint), daemon=True).start()
        return 202, {"ok": True, "job": self._public(job)}

    def _check_plan(self, plan_id, verb, box):
        if not plan_id:
            return ("%s runs only after its plan has been shown: run the plan first "
                    "(the dry run), then confirm that plan" % verb)
        with self.lock:
            p = self.jobs.get(plan_id)
            p = dict(p) if p else None
        if not p or not p["plan"]:
            return "plan %s is not a plan this floor showed — run the plan again" % plan_id
        if p["verb"] != verb or p["box"] != box:
            return "plan %s was for %s %s, not %s %s — run the plan again" % (
                plan_id, p["verb"], p["box"] or "(fleet)", verb, box or "(fleet)")
        if p["state"] != "done" or p["rc"] != 0:
            return "plan %s did not succeed (state %s, exit %s) — nothing to confirm" % (plan_id, p["state"], p["rc"])
        if time.time() - (p["ended"] or 0) > PLAN_FRESH_S:
            return "plan %s is older than %ds — run the plan again so it reads the host as it is" % (plan_id, PLAN_FRESH_S)
        if p["etag"] != roster_etag():
            return "the roster changed since plan %s was read — run the plan again" % plan_id
        return ""

    # -- running ------------------------------------------------------------
    def _record(self, job):
        _, _, rec_path, _ = _paths()
        rec = {k: job[k] for k in ("id", "fleet", "verb", "box", "plan", "argv", "state",
                                   "rc", "started", "ended", "actor", "step")}
        rec["floor_pid"] = os.getpid()
        try:
            _write_json(rec_path, rec)
        except OSError as e:
            log("jobs: cannot write the job record %s: %s" % (rec_path, e))

    def _run(self, job, slot, maint):
        env = dict(os.environ)
        env["CREW_CONFIG_DIR"] = CONFIG_DIR
        env.pop("CREW_FLEET", None)
        env["CREW_FLEET_WALK"] = "1"      # a job is one fleet's, never a host walk
        log_path = None
        logf = None
        try:
            os.makedirs(self.logdir, exist_ok=True)
            log_path = os.path.join(self.logdir, "%s-%s.log" % (time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(job["started"])), job["id"]))
            logf = open(log_path, "w", encoding="utf-8")
        except OSError:
            logf = None
        rc = None
        try:
            proc = subprocess.Popen([CREW_CLI] + job["argv"], env=env, stdin=subprocess.DEVNULL,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    close_fds=True, start_new_session=True,
                                    text=True, errors="replace", bufsize=1)
            last_rec = 0.0
            for line in proc.stdout:
                line = line.rstrip("\n")
                with self.lock:
                    job["output"].append(line)
                    if len(job["output"]) > OUTPUT_LINES:
                        del job["output"][:len(job["output"]) - OUTPUT_LINES]
                    if line.strip():
                        job["step"] = line.strip()[:200]
                if logf:
                    logf.write(line + "\n")
                    logf.flush()
                if time.time() - last_rec > 1:
                    self._record(job)
                    last_rec = time.time()
            rc = proc.wait()
        except OSError as e:
            with self.lock:
                job["output"].append("the floor could not run crew: %s" % e)
            rc = 127
        finally:
            with self.lock:
                job["rc"] = rc
                job["ended"] = time.time()
                job["state"] = "done" if rc == 0 else "failed"
                job["step"] = ("finished: exit %s" % rc)
            if logf:
                logf.close()
            self._record(job)
            self._journal(job, log_path)
            if maint:
                try:
                    with open(maint.name + ".holder", "w", encoding="utf-8"):
                        pass
                except OSError:
                    pass
                maint.close()
            slot.close()

    def _journal(self, job, log_path):
        line = "%s %s fleet=%s verb=%s%s%s argv=%s rc=%s dur=%ds log=%s\n" % (
            time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(job["ended"])),
            job["actor"] or "-", self.fleet_id, job["verb"],
            (" box=%s" % job["box"]) if job["box"] else "",
            " plan=yes" if job["plan"] else (" confirms=%s" % job["confirms"] if job["confirms"] else ""),
            json.dumps(" ".join(job["argv"])), job["rc"],
            int(job["ended"] - job["started"]), log_path or "-")
        try:
            with open(self.journal, "a", encoding="utf-8") as f:
                f.write(line)
        except OSError as e:
            log("jobs: cannot append to %s: %s" % (self.journal, e))
