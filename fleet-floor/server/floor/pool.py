"""The host credential pool, from the console (#780; the pool is #774).

Every read and every write here is the CLI's own `crew creds`, run as a
subprocess against the fleet definition this floor serves. There is ONE
implementation of the pool — its storage, the per-repository gh rule, the
fan-out to the boxes — and it is shared/lib/host/pool.sh behind cli/crew. A
second copy here would be a second answer to "may these two members share a
login", and the two would drift.

The secret arrives in one POST body and leaves this process as the CLI's
stdin. It is never in argv, a log line, the journal (the CLI's journal never
holds a value) or the reply: the reply is the CLI's own lines, which name
entries, members, logins and verdicts and nothing else.
"""

import json
import os
import re
import subprocess

from floor.ping import log
from floor.roster import CONFIG_DIR, CONFIG_IS_OPERATOR, CREW_ROOT, read_roster

CLI = os.path.join(CREW_ROOT, "cli", "crew")
POOL_TIMEOUT_S = 180
SECRET_MAX = 32 * 1024
RE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
RE_ENTRY = re.compile(r"^(gh|agent|tg):[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
RE_CHAT = re.compile(r"^-?[0-9]{1,20}$")
RE_KIND = re.compile(r"^[a-z][a-z0-9-]{0,39}$")
RE_AGENT = re.compile(r"^[a-z][a-z0-9_-]{0,39}$")
ACTIONS = ("pool-add", "pool-rotate", "pool-rm", "pool-assign", "pool-unassign", "pool-chat")


def _crew(args, stdin_data=None):
    """(rc, lines) from `crew creds ARGS`, with the floor's fleet definition."""
    env = dict(os.environ)
    env["CREW_CONFIG_DIR"] = CONFIG_DIR
    try:
        p = subprocess.run(["bash", CLI, "creds"] + args, input=(stdin_data or "").encode(),
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env,
                           timeout=POOL_TIMEOUT_S, start_new_session=True)
    except subprocess.TimeoutExpired:
        return 124, ["crew creds did not finish within %ds" % POOL_TIMEOUT_S]
    except OSError as e:
        return 127, ["crew creds could not run: %s" % e]
    text = p.stdout.decode("utf-8", "replace").replace("\r", "")
    return p.returncode, [x for x in text.splitlines() if x.strip()]


def pool_snapshot():
    """What the console's pool section opens on: the CLI's own listing, as
    JSON. Never a value — the listing has none to give."""
    if not CONFIG_IS_OPERATOR:
        return {"operator": False, "entries": [], "members": [],
                "error": "the pool is managed on an operator's fleet only (this floor runs on the shipped examples)"}
    rc, lines = _crew(["list", "--json"])
    if rc != 0:
        return {"operator": True, "entries": [], "members": [], "error": " ".join(lines[-2:]) or "crew creds list failed"}
    try:
        snap = json.loads("\n".join(lines))
    except ValueError:
        return {"operator": True, "entries": [], "members": [], "error": "crew creds list answered something that is not JSON"}
    snap["operator"] = True
    return snap


def _refuse(action, error):
    return 400, {"ok": False, "action": action, "refused": True, "error": error, "results": []}


def pool_command(action, body, actor=""):
    """(http_status, reply) for one pool action. 400 when the request is
    refused before the CLI runs (nothing moved); otherwise the CLI's answer:
    ok when it exited 0, its lines either way — a refusal it made (the
    per-repository gh rule, an entry still assigned) is said in its words."""
    if not CONFIG_IS_OPERATOR:
        return _refuse(action, "the pool is managed on an operator's fleet only (this floor runs on the shipped examples)")
    secret = None
    if action == "pool-add":
        service = str(body.get("service", "") or "")
        name = str(body.get("name", "") or "")
        if service not in ("gh", "agent", "tg"):
            return _refuse(action, "the service is gh, agent or tg")
        if not RE_NAME.match(name):
            return _refuse(action, "a name is letters, digits, . _ - (64 at most), a letter or digit first")
        args = ["add", service, name]
        if service == "agent":
            agent = str(body.get("agent", "") or "")
            kind = str(body.get("kind", "") or "")
            if not RE_AGENT.match(agent):
                return _refuse(action, "an agent entry names the agent it is for")
            if kind and not RE_KIND.match(kind):
                return _refuse(action, "kind %r is not a kind" % kind)
            args += [agent] + ([kind] if kind else [])
        secret = body.get("secret")
    elif action == "pool-rotate":
        entry = str(body.get("entry", "") or "")
        if not RE_ENTRY.match(entry):
            return _refuse(action, "an entry is gh:<name>, agent:<name> or tg:<name>")
        args = ["rotate", entry]
        secret = body.get("secret")
    elif action == "pool-chat":
        # The fleet's one Telegram group chat (#788): not a secret, and not
        # per entry — every tg entry delivers it.
        chat = str(body.get("chat", "") or "").strip()
        if not RE_CHAT.match(chat):
            return _refuse(action, "a Telegram chat id is digits, negative for a group (e.g. -1001234567890)")
        args = ["chat", chat]
    elif action == "pool-rm":
        entry = str(body.get("entry", "") or "")
        if not RE_ENTRY.match(entry):
            return _refuse(action, "an entry is gh:<name> or agent:<name>")
        args = ["rm", entry]
    elif action in ("pool-assign", "pool-unassign"):
        box = str(body.get("box", "") or "")
        if box not in {u["box"] for u in read_roster()}:
            return _refuse(action, "unknown box %r" % box)
        entries = body.get("entries", body.get("entry", ""))
        if isinstance(entries, list):
            entries = ",".join(str(e) for e in entries if str(e))
        entries = str(entries or "")
        if entries and not all(RE_ENTRY.match(e) for e in entries.split(",")):
            return _refuse(action, "entries are gh:<name>, agent:<name> and tg:<name>, comma-separated")
        if action == "pool-assign":
            if not entries:
                return _refuse(action, "name the entries to assign")
            args = ["assign", box, entries]
        else:
            if "," in entries:
                return _refuse(action, "unassign one entry at a time, or all of them")
            args = ["unassign", box] + ([entries] if entries else [])
    else:
        return _refuse(action, "unknown pool action %r" % action)
    if action in ("pool-add", "pool-rotate"):
        if not isinstance(secret, str) or not secret.strip():
            return _refuse(action, "an empty secret — nothing set")
        if len(secret) > SECRET_MAX:
            return _refuse(action, "that is too long to be a credential — nothing set")
    rc, lines = _crew(args, secret if secret is not None else None)
    secret = None
    ok = rc == 0
    # The log names the action, its arguments and the status; the arguments
    # are names and entries, never the value (it is not among them).
    log("%s %s -> rc %d (actor %s)" % (action, " ".join(args[1:]), rc, actor or "-"))
    reply = {"ok": ok, "action": action, "lines": lines,
             "results": [{"box": str(body.get("box", "") or "pool"), "ok": ok, "out": "\n".join(lines)}]}
    if not ok:
        reply["error"] = lines[-1] if lines else "crew creds exited %d" % rc
    return (200 if ok else 400 if rc == 2 else 409), reply


if __name__ == "__main__":  # pragma: no cover - a debugging aid
    print(json.dumps(pool_snapshot(), indent=2))
