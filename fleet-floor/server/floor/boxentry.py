"""The one door into a box, for the floor (#792) — shared/lib/box-entry.sh's rule.

box 0.11.0 enters a box as ROOT unless `--user NAME` names someone who exists in
it (heavy-duty/box#291); before 0.11.0, `box exec` entered as the box's stamped
user, the agent. Every floor read and action that means "as the agent" builds
its argv here:

    stamp mode (box below 0.11.0)    box exec BOX -- CMD...
    user mode  (box 0.11.0 or later) box exec --user AGENT BOX -- CMD...

The mode is read once from `box --version` (CREW_BOX_ENTRY_MODE=stamp|user
overrides it, for fixtures). An unreadable version is a refusal: the floor will
not serve rather than guess a door (`require_entry_mode`, called at startup).

The agent, in user mode, is the roster's agent column for the box — the floor
only ever acts on roster boxes — and otherwise the box's one regular user.
"""

import os
import re
import threading

from floor.ping import run

ENTRY_FROM = (0, 11, 0)
_lock = threading.Lock()
_mode = None
_users = {}


def _version_tuple(text):
    m = re.match(r"^\S+\s+(\d+)\.(\d+)(?:\.(\d+))?", (text or "").strip())
    if not m:
        return None
    return tuple(int(x or 0) for x in m.groups())


def entry_mode():
    """'stamp' or 'user'; None when `box --version` cannot be read."""
    global _mode
    with _lock:
        if _mode:
            return _mode
        forced = os.environ.get("CREW_BOX_ENTRY_MODE", "")
        if forced in ("stamp", "user"):
            _mode = forced
            return _mode
        rc, out, _err = run(["box", "--version"], 10)
        v = _version_tuple(out.splitlines()[0] if rc == 0 and out else "")
        if v is None:
            return None
        _mode = "user" if v >= ENTRY_FROM else "stamp"
        return _mode


def require_entry_mode():
    """The floor's startup check: the same refusal the CLI makes."""
    import sys
    if entry_mode() is None:
        sys.exit("crew floor: cannot read the box version ('box --version' gave no "
                 "version) — the door into a box depends on it (#792); fix box, or "
                 "set CREW_BOX_ENTRY_MODE=stamp|user")


def _agent_of(box):
    from floor.roster import read_roster
    for u in read_roster():
        if u.get("box") == box and u.get("agent"):
            return u["agent"]
    return None


def entry_user(box):
    """Who to enter `box` as in user mode, or None when there is no one."""
    with _lock:
        if box in _users:
            return _users[box]
    user = _agent_of(box)
    if not user:
        # Root, on purpose: this is the read that finds who else is there.
        rc, out, _err = run(["box", "exec", box, "--", "awk", "-F:",
                             "$3 >= 1000 && $3 < 60000 {print $1}", "/etc/passwd"], 15)
        names = [x for x in (out or "").split() if x] if rc == 0 else []
        user = names[0] if len(names) == 1 else None
    if user:
        with _lock:
            _users[box] = user
    return user


def box_exec(box, *cmd):
    """The argv that enters `box` as its agent and runs `cmd`."""
    if entry_mode() == "user":
        user = entry_user(box)
        if user:
            return ["box", "exec", "--user", user, box, "--"] + list(cmd)
        # No user to enter as: an argv box refuses (`--user` naming nobody),
        # never one that would run as root.
        return ["box", "exec", "--user", "(no regular user in %s)" % box, box, "--"] + list(cmd)
    return ["box", "exec", box, "--"] + list(cmd)


def shell_hint(box, agent=None):
    """The `box shell` line an operator can paste."""
    if entry_mode() == "user":
        return "box shell --user %s %s" % (agent or entry_user(box) or "<agent>", box)
    return "box shell %s" % box
