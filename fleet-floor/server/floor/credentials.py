"""A member's credentials, SET from the console and never read back (#765).

The secret arrives in one POST body and leaves this process as the stdin of
one `box exec` running the credentials shell — the same shell the CLI's
login verb runs, read out of shared/lib/host/credentials.sh between its
markers, as the pause shell is. It is never in argv, a log line, the journal, the reply or a
file on the host; the reply is the box's own verdict, one line.

What the console may know about a member's credentials is what the poll
already publishes (the gh login it answers as, its `authfail` per service)
and which kinds its agent's profile takes. That is `credentials_snapshot`.
"""

import json
import os
import re
import threading
import time

from floor.ping import log, run
from floor.roster import CONFIG_DIR, CONFIG_IS_OPERATOR, CREW_ROOT, read_roster

CREDENTIALS_JOURNAL = os.path.join(CONFIG_DIR, ".credentials-journal.log")
SET_TIMEOUT_S = 60
# A PAT is ~40-93 characters, a setup-token ~100, a credentials file a few
# KB; anything past this is not a credential.
SECRET_MAX = 32 * 1024
RE_KIND = re.compile(r"^[a-z][a-z0-9-]{0,39}$")
_JOURNAL_LOCK = threading.Lock()


def _shell_block(name):
    path = os.path.join(CREW_ROOT, "shared", "lib", "host", "credentials.sh")
    with open(path, encoding="utf-8") as f:
        text = f.read()
    start = text.index("# ---%s---\n" % name)
    return "\n" + text[start:text.index("# ---END---", start)]


CREDENTIALS_SH = _shell_block("CREDENTIALS_SH")


def agent_kinds(agent):
    """The kinds a member of this agent takes, from the host's copy of its
    profile — what the console offers. The box decides against its own."""
    path = os.path.join(CREW_ROOT, "shared", "conf", "agents", "%s.conf" % agent)
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return []
    found = re.findall(r'^AGENT_CRED_KINDS="([^"]*)"$', text, re.M)
    return [s.split(":", 1)[0] for s in (found[-1].split() if found else [])]


def credentials_snapshot():
    """Per member: its agent and the kinds each service takes. No secret, no
    file content — nothing here is readable that the poll does not publish."""
    return {"journal": CREDENTIALS_JOURNAL, "operator": CONFIG_IS_OPERATOR,
            "members": [{"box": u["box"], "agent": u["agent"],
                         "services": {"gh": ["token"], "agent": agent_kinds(u["agent"])}}
                        for u in read_roster()]}


def _journal(actor, box, service, kind, ok, verdict):
    """One line per set: who, which member, which kind, the verdict. The
    secret is not an argument here, so it cannot reach the file."""
    line = "%s actor=%s box=%s service=%s kind=%s ok=%s verdict=%s\n" % (
        time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), actor or "-", box,
        service, kind, "yes" if ok else "no", (verdict or "none").replace("\n", " "))
    try:
        with _JOURNAL_LOCK, open(CREDENTIALS_JOURNAL, "a", encoding="utf-8") as f:
            f.write(line)
        return True
    except OSError as e:
        log("credentials: journal not written (%s)" % e)
        return False


def credentials_set(body, actor=""):
    """(http_status, reply). 400 for a request the shell would refuse anyway
    (nothing moved); 200 with ok false for a credential the box refused or
    still reads as logged out; 200 ok for one that took."""
    box = str(body.get("box", "") or "")
    service = str(body.get("service", "") or "")
    kind = str(body.get("kind", "") or "")
    secret = body.get("secret")
    action = "credentials-set"
    if not CONFIG_IS_OPERATOR:
        return 400, {"ok": False, "action": action, "refused": True,
                     "error": "credentials are set on an operator's fleet only (this floor runs on the shipped examples)"}
    members = {u["box"]: u for u in read_roster()}
    if box not in members:
        return 400, {"ok": False, "action": action, "refused": True, "error": "unknown box %r" % box}
    offered = {"gh": ["token"], "agent": agent_kinds(members[box]["agent"])}
    if service not in offered:
        return 400, {"ok": False, "action": action, "refused": True, "error": "the service is gh or agent"}
    if not RE_KIND.match(kind) or kind not in offered[service]:
        return 400, {"ok": False, "action": action, "refused": True,
                     "error": "%s on %s takes: %s" % (service, box, " ".join(offered[service]) or "nothing")}
    if not isinstance(secret, str) or not secret.strip():
        return 400, {"ok": False, "action": action, "refused": True, "error": "an empty secret — nothing set"}
    if len(secret) > SECRET_MAX:
        return 400, {"ok": False, "action": action, "refused": True, "error": "that is too long to be a credential — nothing set"}
    rc, out, err = run(["box", "exec", box, "--", "bash", "-lc", CREDENTIALS_SH], SET_TIMEOUT_S,
                       "%s %s\n%s\n" % (service, kind, secret))
    secret = None
    lines = [x for x in (out or err or "").replace("\r", "").splitlines() if x.strip()]
    verdict = lines[-1] if lines else ""
    ok = rc == 0 and "NOT logged in" not in verdict
    log("%s %s %s/%s -> rc %d" % (action, box, service, kind, rc))
    recorded = _journal(actor, box, service, kind, ok, verdict)
    reply = {"ok": ok, "action": action, "box": box, "service": service, "kind": kind,
             "verdict": verdict or "no answer from the box", "recorded": recorded,
             "results": [{"box": box, "ok": ok, "out": verdict or "no answer from the box"}]}
    if rc == 2:
        reply["refused"] = True
        return 400, reply
    return 200, reply


if __name__ == "__main__":  # pragma: no cover - a debugging aid
    print(json.dumps(credentials_snapshot(), indent=2))
