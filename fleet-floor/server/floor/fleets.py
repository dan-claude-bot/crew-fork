"""The host's fleets (#814): every fleet definition this host carries.

Mirrors cli/crew's `fleet_dirs`, because the two must name the same fleets:
each directory of the service's index ($CREW_FLEETS_DIR, by default
/var/lib/crew/fleets/<id>/, #822) that holds a fleet.roster. Never the working
directory and never examples/: these are the definitions the service owns,
which is what a one-fleet-per-box check and a fleet switcher may read.

No import-time side effects: the floor's entry point reads this module BEFORE
the package resolves its own fleet, to choose which fleet the process serves.
"""

import os
import re

RE_FLEET_ID = re.compile(r"^[a-z][a-z0-9-]{0,29}$")


def service_conf_value(key):
    """A value from /etc/crew/service.conf (#822), read, never executed."""
    path = os.path.join(os.environ.get("CREW_ETC_DIR") or "/etc/crew", "service.conf")
    val = None
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                if line.startswith(key + "="):
                    val = line.split("=", 1)[1].strip().strip("\"'")
    except OSError:
        return None
    return val


def data_dir():
    return (os.environ.get("CREW_DATA_DIR") or service_conf_value("CREW_DATA_DIR")
            or "/var/lib/crew")


def fleets_dir():
    explicit = os.environ.get("CREW_FLEETS_DIR")
    return explicit if explicit else os.path.join(data_dir(), "fleets")


def is_fleet(d):
    return os.path.isfile(os.path.join(d, "fleet.roster"))


def valid_id(fid):
    return bool(RE_FLEET_ID.match(fid or ""))


def list_fleets():
    """[(id, absolute dir)] — the service's index, in name order (#822: there
    is no per-user definition beside it)."""
    out = []
    idx = fleets_dir()
    try:
        names = sorted(os.listdir(idx))
    except OSError:
        names = []
    for name in names:
        d = os.path.join(idx, name)
        if valid_id(name) and os.path.isdir(d) and is_fleet(d):
            out.append((name, os.path.abspath(d)))
    return out


def fleet_id_of(config_dir):
    """The id of the fleet at `config_dir`, or None when it is not one of the
    host's (an explicit CREW_CONFIG_DIR somewhere else)."""
    target = os.path.abspath(config_dir)
    for fid, d in list_fleets():
        if d == target:
            return fid
    return None


def roster_names(d):
    names = []
    try:
        with open(os.path.join(d, "fleet.roster"), encoding="utf-8") as f:
            for line in f:
                s = line.strip()
                if s and not s.startswith("#"):
                    names.append(s.split()[0])
    except OSError:
        pass
    return names


def claiming_fleet(box, self_dir):
    """The id of ANOTHER fleet on this host whose roster names `box`, or
    None. A box belongs to exactly one fleet (#814)."""
    me = os.path.abspath(self_dir)
    for fid, d in list_fleets():
        if d != me and box in roster_names(d):
            return fid
    return None
