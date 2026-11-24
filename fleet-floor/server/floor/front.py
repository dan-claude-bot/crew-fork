"""The front door of several fleets (#814): one floor, one port, many fleets.

The floor process serves ITS fleet — the one it resolved at import, exactly as
it always has — at `/` and at `/f/<its id>/`. Every OTHER fleet on the host is
served by a child: the same floor, started with that fleet's CREW_CONFIG_DIR,
bound to loopback on a port of its own, behind a password only this process
holds. `/f/<id>/…` is proxied to fleet <id>'s child with the prefix taken off,
so inside the child it is the same request the single-fleet floor has always
answered.

That is the isolation argument, and why it is a process and not a parameter:
a child holds ONE fleet's roster, store and registries, so no request routed
to it — whatever its body names — can act on a box of another fleet. A wrong
id in a URL reaches a different fleet's console or a 404, never a different
fleet's boxes through this one's.

The page knows its fleet from its own URL (`/f/<id>/`), so two tabs sit on two
fleets, a reload keeps the fleet, and a link opens the fleet it names.
"""

import base64
import http.client
import os
import secrets
import subprocess
import sys
import threading
import time

from floor import CREW_ROOT, HERE
from floor.fleets import fleet_id_of, fleets_dir, list_fleets, roster_names, valid_id
from floor.ping import log

FLOOR_PY = os.path.join(HERE, "floor.py")
CHILD_READY_S = float(os.environ.get("CREW_FLOOR_CHILD_READY_S", "30"))
PROXY_TIMEOUT_S = 960   # a fleet action's longest path is 15 minutes (round 11)


def home_id(config_dir):
    """The served fleet's index id; a fixture CREW_CONFIG_DIR outside the
    index answers `default`. None for a floor serving no fleet (#831)."""
    if config_dir is None:
        return None
    return fleet_id_of(config_dir) or "default"


class Children:
    """One child floor per other fleet, started on first need and restarted
    if it dies."""

    def __init__(self, home_dir, interval):
        # None: the floor serves no fleet itself (#831: a host with no fleets
        # yet) and every fleet, once made, is a child.
        self.home_dir = os.path.abspath(home_dir) if home_dir else None
        self.interval = interval
        self.lock = threading.Lock()
        self.kids = {}      # id -> {"proc", "port", "token", "dir"}

    def fleets(self):
        """[(id, dir)] — the home fleet first, then every other host fleet."""
        if self.home_dir is None:
            return list(list_fleets())
        hid = home_id(self.home_dir)
        out = [(hid, self.home_dir)]
        for fid, d in list_fleets():
            if d != self.home_dir and fid != hid:
                out.append((fid, d))
        return out

    def dir_of(self, fid):
        for i, d in self.fleets():
            if i == fid:
                return d
        return None

    def _spawn(self, fid, d):
        token = secrets.token_urlsafe(24)
        port_file = os.path.join(d, "store", ".floor-child.port")
        try:
            os.makedirs(os.path.dirname(port_file), exist_ok=True)
            os.unlink(port_file)
        except OSError:
            pass
        env = dict(os.environ)
        env.update({"CREW_CONFIG_DIR": d, "CREW_FLOOR_CHILD": "1",
                    "CREW_FLOOR_BIND": "127.0.0.1", "CREW_FLOOR_PORT": "0",
                    "CREW_FLOOR_PORT_FILE": port_file,
                    "CREW_FLOOR_USER": "floor-front", "CREW_FLOOR_PASS": token,
                    "CREW_FLOOR_INTERVAL": str(self.interval)})
        env.pop("CREW_FLOOR_ROSTER", None)   # a roster override is the home fleet's alone
        env.pop("CREW_FLOOR_STORE", None)
        proc = subprocess.Popen([sys.executable, FLOOR_PY], env=env,
                                stdin=subprocess.DEVNULL, close_fds=True)
        deadline = time.time() + CHILD_READY_S
        port = None
        while time.time() < deadline and proc.poll() is None:
            try:
                with open(port_file, encoding="utf-8") as f:
                    v = f.read().strip()
                if v.isdigit():
                    port = int(v)
                    break
            except OSError:
                pass
            time.sleep(0.1)
        if port is None:
            if proc.poll() is None:
                proc.terminate()
            log("front: fleet %s's floor did not come up (%s)" % (
                fid, "exit %s" % proc.returncode if proc.returncode is not None else "no port in %ds" % CHILD_READY_S))
            return None
        log("front: fleet %s served by a child floor on 127.0.0.1:%d" % (fid, port))
        auth = base64.b64encode(("floor-front:%s" % token).encode()).decode()
        return {"proc": proc, "port": port, "auth": auth, "dir": d}

    def get(self, fid):
        with self.lock:
            k = self.kids.get(fid)
            if k and k["proc"].poll() is None:
                return k
            d = self.dir_of(fid)
            if not d or d == self.home_dir:
                return None
            k = self._spawn(fid, d)
            if k:
                self.kids[fid] = k
            return k

    def start_all(self):
        for fid, d in self.fleets():
            if d != self.home_dir:
                self.get(fid)

    def stop_all(self):
        with self.lock:
            for k in self.kids.values():
                if k["proc"].poll() is None:
                    k["proc"].terminate()


def fleets_listing(children):
    out = []
    hid = home_id(children.home_dir)
    for fid, d in children.fleets():
        sched = "on"
        try:
            with open(os.path.join(d, "fleet.conf"), encoding="utf-8") as f:
                for line in f:
                    s = line.strip().replace('"', "").replace("'", "")
                    if s.startswith("HOST_SCHEDULE="):
                        sched = "off" if s.split("=", 1)[1].strip() == "off" else "on"
        except OSError:
            pass
        out.append({"id": fid, "dir": d, "home": fid == hid, "url": "/f/%s/" % fid,
                    "members": len(roster_names(d)), "schedule": sched})
    return {"home": hid, "fleets_dir": fleets_dir(), "fleets": out}


def proxy(handler, kid, method, path, body):
    """Forward one request to a child and copy its answer back."""
    conn = http.client.HTTPConnection("127.0.0.1", kid["port"], timeout=PROXY_TIMEOUT_S)
    headers = {"Authorization": "Basic " + kid["auth"],
               "X-Crew-Floor-Actor": handler.auth_user or ""}
    ctype = handler.headers.get("Content-Type")
    if ctype:
        headers["Content-Type"] = ctype
    if body is not None:
        headers["Content-Length"] = str(len(body))
    try:
        conn.request(method, path, body=body, headers=headers)
        r = conn.getresponse()
        payload = r.read()
    except (OSError, http.client.HTTPException) as e:
        msg = ("fleet's floor did not answer: %s\n" % e).encode()
        handler.send_response(502)
        handler.send_header("Content-Type", "text/plain; charset=utf-8")
        handler.send_header("Content-Length", str(len(msg)))
        handler.end_headers()
        handler.wfile.write(msg)
        return
    finally:
        conn.close()
    handler.send_response(r.status)
    for h in ("Content-Type", "Cache-Control", "X-Frame-Options", "Referrer-Policy", "Location"):
        v = r.getheader(h)
        if v:
            handler.send_header(h, v)
    handler.send_header("Content-Length", str(len(payload)))
    handler.end_headers()
    if method != "HEAD":
        handler.wfile.write(payload)


def create_fleet(fid):
    """`crew init --fleet <id>`, through the CLI, under the floor's one-job
    slot so it never runs beside another job. (status, result)"""
    import fcntl
    from floor.jobs import _paths, _read_json, describe, CREW_CLI
    if not valid_id(fid) or fid == "default":
        return 400, {"ok": False, "error": "%r is not a fleet id: lower case letters, digits and '-', "
                                           "a letter first, at most 30 (and not 'default')" % fid}
    state_dir, slot_path, rec_path, _ = _paths()
    os.makedirs(state_dir, exist_ok=True)
    with open(slot_path, "a") as slot:
        try:
            fcntl.flock(slot, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return 409, {"ok": False, "busy": True,
                         "error": "one job at a time on this host: %s is running" % describe(_read_json(rec_path))}
        env = dict(os.environ)
        env.pop("CREW_CONFIG_DIR", None)
        env.pop("CREW_FLEET", None)
        p = subprocess.run([CREW_CLI, "init", "--fleet", fid], env=env, stdin=subprocess.DEVNULL,
                           capture_output=True, text=True, timeout=60, close_fds=True)
    out = (p.stdout + p.stderr).strip()
    if p.returncode != 0:
        return 409 if "refusing to overwrite" in out else 500, {"ok": False, "error": out or "exit %d" % p.returncode}
    return 200, {"ok": True, "id": fid, "url": "/f/%s/" % fid, "output": out}


__all__ = ["Children", "fleets_listing", "proxy", "create_fleet", "home_id", "CREW_ROOT"]
