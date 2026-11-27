"""A member's lifecycle, from the console (#898).

Stop, Start, Pause, Resume, Unhire and the removal of a login are the CLI's
own verbs — `crew stop|start|pause|resume|unhire|logout` — run as a
subprocess against the fleet definition this floor serves, exactly as the
pool is (floor/pool.py). There is ONE implementation of what each does to a
member — the intent the host tick obeys, the drain before a stop, the claims
an unhire hands back — and it lives in cli/crew, on top of shared/lib/host/. A second
copy here would be a second answer to "is this member held", and the two
would drift.

The reply is the CLI's own lines, one row for the member.
"""

import os

from floor.ping import log, run
from floor.roster import CONFIG_DIR, CREW_ROOT

CLI = os.path.join(CREW_ROOT, "cli", "crew")
# Each verb runs under the floor's action deadline (actions.ACTION_TIMEOUT_S),
# the one every other box action has — and the one a fleet action is bounded
# by, one timeout however many members it reaches (#44): a box that answers
# nothing must not hold a request, and the row says "timed out". An unhire
# reads every repository's claims and is never a fleet action, so it alone
# has a longer one.
MEMBER_TIMEOUT_S = int(os.environ.get("CREW_FLOOR_MEMBER_TIMEOUT_S", "420"))


def _deadline(verb):
    from floor.actions import ACTION_TIMEOUT_S
    return MEMBER_TIMEOUT_S if verb == "unhire" else ACTION_TIMEOUT_S


# floor action -> the CLI verb it is. `power-off` and `power-on` are the
# console's Stop and Start buttons, `force-stop` the access panel's kill.
VERBS = {
    "power-off": "stop", "force-stop": "stop", "power-on": "start",
    "pause": "pause", "resume": "resume", "unhire": "unhire", "logout": "logout",
}
SERVICES = ("gh", "agent", "tg")


def argv_for(action, box, body):
    """The CLI argv for ACTION on BOX, or (None, why) for a bad request."""
    verb = VERBS.get(action)
    if verb is None:
        return None, "unknown member action %r" % action
    args = [verb, box]
    if action == "force-stop" or (action == "power-off" and body.get("force") is True):
        args.append("--force")
    if action == "unhire" and body.get("logout") is True:
        args.append("--logout")
    if action == "logout":
        svc = str(body.get("service", ""))
        if svc not in SERVICES:
            return None, "the service is gh, agent or tg"
        args.append(svc)
    return args, ""


def run_verb(args, actor="", runner=None):
    """(rc, lines) from `crew ARGS`, with the floor's fleet definition; the
    operator who asked rides CREW_ACTOR into the intent's record. RUNNER is
    the floor's own `run` (floor/ping.py: the deadline enforced on the whole
    process group, so a wedged guest's `box exec` children go too) — passed
    by actions.py, so its suite's stand-in drives these calls as well."""
    env = dict(os.environ)
    env["CREW_CONFIG_DIR"] = CONFIG_DIR
    if actor:
        env["CREW_ACTOR"] = "floor:%s" % actor
    deadline = _deadline(args[0])
    rc, out, err = (runner or run)([CLI] + args, deadline, None, env=env)
    if rc == 124 and "timed out" in (err or ""):
        # The floor's own words for a deadline, as every box action says it.
        return 124, [err.strip()]
    text = ((out or "") + (err or "")).replace("\r", "")
    return rc, [x.strip() for x in text.splitlines() if x.strip()]


def member_row(action, box, body, actor="", runner=None):
    """One member action: the per-box row `do_command` folds into its reply."""
    args, why = argv_for(action, box, body)
    if args is None:
        return {"box": box, "ok": False, "out": why, "step": "refused"}
    rc, lines = run_verb(args, actor, runner)
    log("%s %s -> crew %s rc %d (actor %s)" % (action, box, " ".join(args[2:]) or args[0], rc, actor or "-"))
    # Each CLI line is `  <box>: <sentence>`; the page wants the sentences.
    said = [ln.split(": ", 1)[1] if ln.startswith(box + ": ") else ln for ln in lines]
    # The path it took, in #486's vocabulary: a forced stop says so.
    step = "force-stop" if "--force" in args else args[0]
    return {"box": box, "ok": rc == 0, "out": "\n".join(said)[-800:], "step": step}
