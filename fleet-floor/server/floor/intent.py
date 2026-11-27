"""A member's intent, as the floor reads it (#898).

What the operator wants of a member — stopped, paused, off duty, or (no
file) on duty — is one file per member, `<config>/store/intent/<box>`,
written by the CLI (shared/lib/host/intent.sh) and obeyed by the host tick.
The floor only READS it here: every write goes through the CLI's own verbs
(floor/member.py), so there is one implementation of what a stop, a pause or
an unhire does, and the console and `crew status` read one fact.

The pre-#898 pause marker, `<config>/store/paused/<box>`, held a member off
exactly as `stopped` does now and reads as `stopped`.

`note()` is word for word the CLI's `intent_note`: the two consoles
describing one member differently is the defect, not the wording.
"""

import os

INTENTS = ("stopped", "paused", "off-duty")
SERVICES = ("gh", "agent", "tg")


def _config_dir():
    from floor.roster import CONFIG_DIR
    return CONFIG_DIR


def read(box, config_dir=None):
    """{"intent", "since", "actor", "stopping", "logout"} for BOX. `intent` is
    "on-duty" when no file stands; an unreadable or unknown word reads as
    "stopped" — a file someone wrote means "hold it", the answer that spends
    nothing."""
    d = config_dir or _config_dir()
    rec = {"intent": "on-duty", "since": "", "actor": "", "stopping": False, "logout": False}
    path = os.path.join(d, "store", "intent", box)
    try:
        with open(path, encoding="utf-8") as f:
            words = (f.readline() or "").split()
    except FileNotFoundError:
        if os.path.exists(os.path.join(d, "store", "paused", box)):
            rec["intent"] = "stopped"
        return rec
    except OSError:
        words = []
    rec["intent"] = words[0] if words and words[0] in INTENTS else "stopped"
    rec["since"] = words[1] if len(words) > 1 else ""
    rec["actor"] = words[2] if len(words) > 2 else ""
    rec["stopping"] = "stopping" in words[3:]
    rec["logout"] = "logout" in words[3:]
    return rec


def held(box, config_dir=None):
    """Whether the operator holds BOX off (any intent but on duty)."""
    return read(box, config_dir)["intent"] != "on-duty"


def note(rec):
    """The hold in one sentence, or "" when on duty."""
    w = rec["intent"]
    if w == "stopped":
        if rec["stopping"]:
            return "stopping by operator — finishing its run, then stopped"
        return "stopped by operator — Start lifts it"
    if w == "paused":
        return "paused by operator%s — Resume continues it" % (
            " since %s" % rec["since"] if rec["since"] else "")
    if w == "off-duty":
        if rec["stopping"]:
            return "going off duty — finishing its run, then its claims go back"
        return "off duty — Hire puts it back"
    return ""


def logged_out(box, config_dir=None):
    """The services whose login the operator removed from BOX, in SERVICES
    order — `<config>/store/logout/<box>.<svc>` (shared/lib/host/intent.sh)."""
    d = os.path.join(config_dir or _config_dir(), "store", "logout")
    return [s for s in SERVICES if os.path.exists(os.path.join(d, "%s.%s" % (box, s)))]


def unstaged(box, config_dir=None):
    """The repositories BOX's box was staged without, as the host tick last
    said (`<config>/store/unstaged/<box>`), or ""."""
    path = os.path.join(config_dir or _config_dir(), "store", "unstaged", box)
    try:
        with open(path, encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


def waiting(box, config_dir=None):
    """The issues assigned to BOX's member that wait on a person (labelled
    LABEL_NEEDS_HUMAN), `repo#num` space-separated, as the host tick last
    read them (`<config>/store/waiting/<box>`), or ""."""
    path = os.path.join(config_dir or _config_dir(), "store", "waiting", box)
    try:
        with open(path, encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""
