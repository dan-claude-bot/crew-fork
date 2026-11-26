"""The fleet's review panel and triage actor, on the floor (#879).

The panel is the fleet's own setting (operator ruling, 2026-11-26): the
GitHub logins its builders request reviews from, `FLEET_BENCH` in the
fleet's fleet.conf, and the triage actor beside it, `FLEET_TRIAGE`. A
non-empty FLEET_BENCH wins over a repository's .github/labels.conf
(shared/lib/common/conf.sh `panel_for_repo`); an empty one leaves the
repository to decide, as before #879.

What the page needs besides the two values:
  - a SUGGESTION: the logins this fleet's reviewer members answer as, and
    its triage member's — read from the pool's listing (an assigned gh
    entry's login) and, for a member set by hand, the identity its last
    drain stored;
  - FLAGS: a reviewer whose login is not on the panel (no PR will request
    it), a triage member that is not the triage actor, a panel login no
    member answers as;
  - per member, the panel it was last STAGED with (the CLI writes
    store/staged/<box>.bench at hire and upgrade), so a member still on an
    older panel is named: the setting reaches a box only when it is staged.

`set_panel` rewrites the two lines in place, keeping every other line and
comment of fleet.conf, and journals who changed what.
"""

import os
import re
import tempfile
import threading
import time

from floor.roster import CONFIG_DIR, CONFIG_IS_OPERATOR, read_roster

RE_LOGIN = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$")
JOURNAL = os.path.join(CONFIG_DIR, ".panel-journal.log")
_LOCK = threading.Lock()


def _conf_path():
    return os.path.join(CONFIG_DIR, "fleet.conf")


def conf_value(key, path=None):
    """The last assignment of KEY in fleet.conf, unquoted — read, never run."""
    val = ""
    try:
        with open(path or _conf_path(), encoding="utf-8") as f:
            for line in f:
                s = line.strip()
                if s.startswith(key + "="):
                    val = s.split("=", 1)[1].strip().strip("\"'")
    except OSError:
        pass
    return val


def _staged(box):
    try:
        with open(os.path.join(CONFIG_DIR, "store", "staged", "%s.bench" % box), encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return None


def _stored_identity(box):
    try:
        from floor import store
        conn = store.connect(readonly=True)
        try:
            row = conn.execute("SELECT content FROM state_files WHERE box=? AND name=?",
                               (box, ".identity")).fetchone()
        finally:
            conn.close()
        v = (row[0] if row else "").strip().splitlines()
        return v[0].strip() if v and RE_LOGIN.match(v[0].strip()) else ""
    except Exception:                                       # noqa: BLE001
        return ""


def _logins(pool):
    """{box: gh login} from the pool listing, then the stored identity."""
    out = {}
    for e in (pool or {}).get("entries") or []:
        if e.get("service") != "gh" or not e.get("login"):
            continue
        for m in e.get("members") or []:
            if m.get("box"):
                out[m["box"]] = e["login"]
    for u in read_roster():
        if u["box"] not in out:
            ident = _stored_identity(u["box"])
            if ident:
                out[u["box"]] = ident
    return out


def snapshot(pool=None):
    if pool is None:
        from floor.pool import pool_snapshot
        pool = pool_snapshot()
    bench = conf_value("FLEET_BENCH").split()
    triage = conf_value("FLEET_TRIAGE")
    logins = _logins(pool)
    members = []
    for u in read_roster():
        roles = [r for r in (u.get("room") or "").split(",") if r]
        members.append({"box": u["box"], "roles": roles, "login": logins.get(u["box"], ""),
                        "staged": _staged(u["box"])})
    reviewers = [m for m in members if "reviewer" in m["roles"]]
    triagers = [m for m in members if "triage" in m["roles"]]
    suggest_bench = sorted({m["login"] for m in reviewers if m["login"]})
    suggest_triage = next((m["login"] for m in triagers if m["login"]), "")
    flags = []
    if bench:
        for m in reviewers:
            if m["login"] and m["login"] not in bench:
                flags.append("%s reviews as %s, which is not on the panel — no PR will request its review"
                             % (m["box"], m["login"]))
        answered = {m["login"] for m in members}
        for login in bench:
            if login not in answered:
                flags.append("%s is on the panel, but no member of this fleet answers as it — its review is requested and only a person can give it" % login)
    elif reviewers:
        flags.append("the panel is empty: each repository's .github/labels.conf decides who is requested — set it here to your reviewers")
    for m in triagers:
        if m["login"] and triage and m["login"] != triage:
            flags.append("%s triages as %s, but the triage actor is %s" % (m["box"], m["login"], triage))
    want = " ".join(bench)
    stale = [m["box"] for m in members if m["staged"] is not None and m["staged"] != want]
    return {"operator": CONFIG_IS_OPERATOR, "path": _conf_path(), "bench": bench, "triage": triage,
            "suggest": {"bench": suggest_bench, "triage": suggest_triage},
            "members": members, "flags": flags, "stale": stale}


def _rewrite(path, values):
    """Replace each KEY=… line (the last one wins, so every one is replaced)
    and append any key the file lacks; every other line is kept."""
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        lines = []
    seen = set()
    out = []
    for line in lines:
        key = line.strip().split("=", 1)[0] if "=" in line and not line.lstrip().startswith("#") else ""
        if key in values:
            out.append('%s="%s"' % (key, values[key]))
            seen.add(key)
        else:
            out.append(line)
    for key, val in values.items():
        if key not in seen:
            out.append('%s="%s"' % (key, val))
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".fleet.conf.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write("\n".join(out) + "\n")
        try:
            os.chmod(tmp, os.stat(path).st_mode & 0o777)
        except OSError:
            os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def set_panel(body, actor=""):
    """(http_status, reply). The panel as a list of logins (empty: the
    repositories decide) and the triage actor (one login, or empty)."""
    action = "panel-set"
    if not CONFIG_IS_OPERATOR:
        return 400, {"ok": False, "action": action, "refused": True,
                     "error": "the panel is set on an operator's fleet only (this floor runs on the shipped examples)"}
    raw = body.get("bench")
    if isinstance(raw, str):
        raw = raw.replace(",", " ").split()
    if not isinstance(raw, list):
        return 400, {"ok": False, "action": action, "refused": True, "error": "the panel is a list of GitHub logins"}
    bench = []
    for x in raw:
        x = str(x).strip().lstrip("@")
        if not x:
            continue
        if not RE_LOGIN.match(x):
            return 400, {"ok": False, "action": action, "refused": True, "error": "%r is not a GitHub login" % x}
        if x not in bench:
            bench.append(x)
    triage = str(body.get("triage", "") or "").strip().lstrip("@")
    if triage and not RE_LOGIN.match(triage):
        return 400, {"ok": False, "action": action, "refused": True, "error": "%r is not a GitHub login" % triage}
    if triage and triage in bench:
        return 400, {"ok": False, "action": action, "refused": True,
                     "error": "%s is the triage actor and on the panel: triage never votes on a PR, so its review would never come" % triage}
    with _LOCK:
        before = (conf_value("FLEET_BENCH"), conf_value("FLEET_TRIAGE"))
        try:
            _rewrite(_conf_path(), {"FLEET_BENCH": " ".join(bench), "FLEET_TRIAGE": triage})
        except OSError as e:
            return 500, {"ok": False, "action": action, "error": "fleet.conf could not be written: %s" % e}
        line = "%s actor=%s bench=%s->%s triage=%s->%s\n" % (
            time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), actor or "-",
            before[0].replace(" ", ",") or "-", ",".join(bench) or "-", before[1] or "-", triage or "-")
        recorded = True
        try:
            with open(JOURNAL, "a", encoding="utf-8") as f:
                f.write(line)
        except OSError:
            recorded = False
    return 200, {"ok": True, "action": action, "bench": bench, "triage": triage, "recorded": recorded,
                 "results": [{"box": "fleet", "ok": True,
                              "out": "panel: %s; triage: %s — reaches each member at its next wake, or at once with Upgrade"
                                     % (", ".join(bench) or "the repositories decide", triage or "none")}]}
