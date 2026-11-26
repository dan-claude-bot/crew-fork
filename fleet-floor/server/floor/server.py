"""HTTP: the request handler, the server, and the process entry point."""

import base64
import hmac
import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from floor import HERE, INDEX
from floor.actions import do_command
from floor.alerts import alert_command_from_config
from floor.fleet import Fleet
from floor.ping import PING_INTERVAL_S, log, run
from floor.registry import snapshot as registry_snapshot
from floor.roster import CONFIG_DIR, read_roster, require_operator_config, roster_snapshot
from floor.credentials import credentials_snapshot
from floor.pool import pool_snapshot
from floor.inflight import INFLIGHT
from floor import front
from floor.fleets import valid_id
from floor.jobs import Jobs
from floor import engine
from floor.fleets import list_fleets
from floor.boxentry import box_exec, require_entry_mode

# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "crew-floor"
    protocol_version = "HTTP/1.1"

    # Args injected by serve()
    fleet = None
    auth_token = None
    # The fleet's jobs (#815), and — in the process that owns the port, never
    # in a fleet's child — the other fleets' children and this fleet's id
    # (#814). `children` is None inside a child: it answers its one fleet.
    jobs = None
    children = None
    home_fid = "default"
    # #831: a host with no fleets yet. The floor serves no fleet itself: `/`
    # is the lobby (New fleet) until one exists, then the first fleet's page,
    # and every fleet-scoped API answers 404.
    empty = False
    # WHO, for the registry journal (#488 D5). The floor authenticates one
    # operator identity, so this is the whole of what the process knows about
    # the hand behind a write — and naming it beats recording every registry
    # change against nobody. Set beside the token it is half of.
    auth_user = ""

    def log_message(self, fmt, *args):
        pass                                    # the poller's log() is the log

    # -- auth ---------------------------------------------------------------
    def authed(self):
        got = self.headers.get("Authorization", "")
        if not got.startswith("Basic "):
            return False
        return hmac.compare_digest(got[6:].strip(), self.auth_token)

    def actor(self):
        """Who is acting, for every journal. A fleet's child is reached only
        through the front, with a password only the front holds, so the
        operator identity the FRONT authenticated rides in a header; anywhere
        else it is this process's own."""
        if self.children is None and os.environ.get("CREW_FLOOR_CHILD"):
            return self.headers.get("X-Crew-Floor-Actor", "") or self.auth_user
        return self.auth_user

    # -- the engine's GitHub App (#864) ---------------------------------------
    # Host-level, like the fleets list: served by whichever process the
    # browser reached (the front, under the service), on every fleet's page
    # and in the empty lobby alike. No route reads the key back.
    def engine_route(self, method):
        path = urlparse(self.path).path
        if path == "/api/engine" and method == "GET":
            self.send_json(200, engine_snapshot())
            return True
        if path == "/engine/callback" and method == "GET":
            qs = parse_qs(urlparse(self.path).query)
            code = (qs.get("code") or [""])[0]
            state = (qs.get("state") or [""])[0]
            try:
                st = engine.convert(code, state)
                engine_journal(self.actor(), "create", True, "App %s (id %s)" % (st["slug"], st["id"]))
                self.send_bytes(200, "text/html; charset=utf-8", callback_page(st, ""))
            except engine.EngineError as e:
                engine_journal(self.actor(), "create", False, str(e))
                self.send_bytes(400, "text/html; charset=utf-8", callback_page(None, str(e)))
            return True
        if method != "POST" or path not in ("/api/engine/manifest", "/api/engine/app", "/api/engine/remove"):
            return False
        body = self.read_json_body()
        if body is None:
            return True
        try:
            if path == "/api/engine/manifest":
                action, man = engine.manifest(self.base_url(), str(body.get("org", "") or ""))
                self.send_json(200, {"ok": True, "action": action, "manifest": man})
            elif path == "/api/engine/app":
                st = engine.verify_and_save(body.get("app_id"), body.get("key"))
                body = None
                engine_journal(self.actor(), "set", True, "App %s (id %s)" % (st["slug"], st["id"]))
                self.send_json(200, {"ok": True, "engine": engine_snapshot()})
            else:
                removed = engine.remove()
                engine_journal(self.actor(), "remove", True, "removed" if removed else "none was set")
                self.send_json(200, {"ok": True, "removed": removed, "engine": engine_snapshot()})
        except engine.EngineError as e:
            if path != "/api/engine/manifest":
                engine_journal(self.actor(), "set" if path.endswith("/app") else "remove", False, str(e))
            self.send_json(400, {"ok": False, "error": str(e)})
        except OSError as e:
            self.send_json(500, {"ok": False, "error": "the engine's App could not be stored: %s" % e})
        return True

    def base_url(self):
        """The floor's own address as the browser reached it: GitHub sends the
        browser back here after the manifest flow."""
        host = (self.headers.get("Host") or "").strip()
        if not re.fullmatch(r"[A-Za-z0-9.\-]+(:[0-9]{1,5})?|\[[0-9A-Fa-f:.]+\](:[0-9]{1,5})?", host):
            raise engine.EngineError("the request carried no usable Host header")
        return "http://" + host

    # -- fleets (#814) --------------------------------------------------------
    def fleet_route(self, method):
        """Answer what belongs to the front — the fleets list, a `/f/<id>/`
        request for another fleet — and return True; or, for this process's
        own fleet, strip `/f/<id>` off self.path and return False so the
        ordinary routes answer it."""
        if self.children is None:
            return False
        u = urlparse(self.path)
        path = u.path
        if path == "/api/fleets":
            if method == "GET":
                self.send_json(200, front.fleets_listing(self.children))
            elif method == "POST":
                body = self.read_json_body()
                if body is None:
                    return True
                status, result = front.create_fleet(str(body.get("id", "") or ""))
                if status == 200:
                    self.children.get(result["id"])
                self.send_json(status, result)
            else:
                self.send_bytes(405, "text/plain; charset=utf-8", b"method not allowed\n")
            return True
        if not path.startswith("/f/"):
            return False
        fid, sep, tail = path[3:].partition("/")
        query = ("?" + u.query) if u.query else ""
        if not sep:
            self.send_response(301)
            self.send_header("Location", "/f/%s/%s" % (fid, query))
            self.send_header("Content-Length", "0")
            self.end_headers()
            return True
        if fid == self.home_fid:
            self.path = "/" + tail + query
            return False
        kid = self.children.get(fid) if valid_id(fid) else None
        if not kid:
            self.send_bytes(404, "text/plain; charset=utf-8",
                            ("no fleet %r on this host\n" % fid).encode("utf-8", "replace"))
            return True
        body = None
        if method in ("POST", "PUT", "PATCH"):
            n = int(self.headers.get("Content-Length") or 0)
            if n > 1024 * 1024:
                self.send_json(413, {"ok": False, "error": "body too large"})
                return True
            body = self.rfile.read(n)
        front.proxy(self, kid, method, "/" + tail + query, body)
        return True

    def read_json_body(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
            if n > 64 * 1024:
                self.send_json(413, {"ok": False, "error": "body too large"})
                return None
            return json.loads(self.rfile.read(n).decode("utf-8") or "{}")
        except (ValueError, UnicodeDecodeError) as e:
            self.send_json(400, {"ok": False, "error": "bad JSON: %s" % e})
            return None

    def deny(self):
        # Slow a guesser down. The server is threaded, so this costs the
        # attacker far more than it costs the operator who mistyped once.
        time.sleep(0.5)
        body = b"crew floor: authentication required\n"
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="crew floor"')
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # -- helpers ------------------------------------------------------------
    def send_bytes(self, status, ctype, payload, cache=False):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        if not cache:
            self.send_header("Cache-Control", "no-store")
        # The page has control actions; keep it out of anything else's frame.
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(payload)

    def send_json(self, status, obj):
        self.send_bytes(status, "application/json; charset=utf-8",
                        json.dumps(obj).encode("utf-8"))

    # -- routes -------------------------------------------------------------
    def do_GET(self):
        if not self.authed():
            return self.deny()
        if self.engine_route("GET"):
            return
        if self.fleet_route("GET"):
            return
        path = urlparse(self.path).path
        qs = parse_qs(urlparse(self.path).query)

        if self.empty:
            return self.empty_route(path)

        if path in ("/", "/index.html"):
            try:
                with open(INDEX, "rb") as f:
                    return self.send_bytes(200, "text/html; charset=utf-8", f.read())
            except OSError as e:
                return self.send_bytes(500, "text/plain; charset=utf-8",
                                       ("cannot read %s: %s\n" % (INDEX, e)).encode())

        if path == "/api/fleet":
            return self.send_json(200, self.fleet.get())

        if path == "/api/registries":
            # Its own endpoint rather than a key on `/api/fleet`, because the
            # two answer at different costs and on different clocks: the fleet
            # snapshot is a background thread's 60s probe of every guest, and
            # this is two small reads off the host's own disk. Folding the
            # registries into the snapshot would serve them at the poller's
            # cadence — up to a minute after the operator's own write — and
            # reading them fresh on every request is what makes a hand edit
            # visible with no floor restart (#488 D4).
            return self.send_json(200, registry_snapshot(
                [u["box"] for u in read_roster()]))

        if path == "/api/actions":
            # What the console is doing right now (#766): per box, the action
            # holding it and its step; for the fleet, the action and its
            # progress. Cheap — one dict under a lock — so the page polls it
            # every second while anything is in flight, in every tab.
            return self.send_json(200, INFLIGHT.snapshot())

        if path == "/api/jobs":
            # The floor's jobs (#815): the host's running one, whichever
            # fleet started it, and this fleet's recent ones with their
            # output. Polled every second while a job runs.
            job_id = (qs.get("id") or [""])[0]
            if job_id:
                j = self.jobs.get(job_id)
                return self.send_json(200 if j else 404, j or {"error": "no such job"})
            return self.send_json(200, self.jobs.snapshot())

        if path == "/api/credentials":
            # Which kinds each member's agent takes (#765) — never a
            # credential: there is no endpoint that reads one back.
            return self.send_json(200, credentials_snapshot())

        if path == "/api/pool":
            # The host credential pool (#780): the CLI's own listing — names,
            # kinds, logins, who holds what, the last verdict per member. No
            # endpoint reads a value back; the listing has none to give.
            return self.send_json(200, pool_snapshot())

        if path == "/api/roster":
            # Read fresh on every request, as the registries are: what the
            # editor opens on is the file as it is on disk right now, so a
            # hand edit between two clicks is picked up with no restart.
            return self.send_json(200, roster_snapshot())

        if path == "/api/logs":
            return self.serve_log(qs)

        if path == "/healthz":
            return self.send_bytes(200, "text/plain; charset=utf-8", b"ok\n")

        # The page reports errors for a living; a 404 for the icon Chrome asks
        # for unprompted is noise in exactly the console an operator scans.
        if path == "/favicon.ico":
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        return self.send_bytes(404, "text/plain; charset=utf-8", b"not found\n")

    def empty_route(self, path):
        """GET on a floor that serves no fleet (#831)."""
        if path in ("/", "/index.html"):
            fleets = self.children.fleets()
            if fleets:
                self.send_response(302)
                self.send_header("Location", "/f/%s/" % fleets[0][0])
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            try:
                with open(LOBBY, "rb") as f:
                    return self.send_bytes(200, "text/html; charset=utf-8", f.read())
            except OSError as e:
                return self.send_bytes(500, "text/plain; charset=utf-8",
                                       ("cannot read %s: %s\n" % (LOBBY, e)).encode())
        if path == "/healthz":
            return self.send_bytes(200, "text/plain; charset=utf-8", b"ok\n")
        if path == "/favicon.ico":
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        return self.no_fleet()

    def no_fleet(self):
        return self.send_json(404, {"ok": False, "error": NO_FLEET})

    def serve_log(self, qs):
        box = (qs.get("box") or [""])[0]
        name = (qs.get("file") or [""])[0]
        if box not in {u["box"] for u in read_roster()}:
            return self.send_bytes(400, "text/plain; charset=utf-8", b"unknown box\n")
        # The filename comes from the browser: allow only the shape run_session
        # generates, so no traversal or shell metacharacter can reach the box.
        if name and not re.fullmatch(r"[A-Za-z0-9._@#-]{1,120}", name):
            return self.send_bytes(400, "text/plain; charset=utf-8", b"bad log name\n")
        target = ('"$HOME/duty/logs/%s"' % name) if name else '"$HOME/duty/duty.log"'
        rc, out, err = run(box_exec(box, "bash", "-lc",
                                    "tail -n 500 %s 2>/dev/null" % target), 30)
        payload = out if rc == 0 else "unreadable: %s" % (err.strip() or "rc %d" % rc)
        return self.send_bytes(200, "text/plain; charset=utf-8",
                               payload.encode("utf-8", "replace"))

    # Without these, BaseHTTPRequestHandler answers 501 from inside its own
    # request loop — before do_*() and therefore before any auth check. An
    # unauthenticated caller should learn nothing but "authenticate", so every
    # method this server does not implement is routed through the same gate.
    def do_PUT(self):
        if not self.authed():
            return self.deny()
        if self.fleet_route(self.command):
            return
        return self.send_bytes(405, "text/plain; charset=utf-8", b"method not allowed\n")

    do_DELETE = do_PUT
    do_PATCH = do_PUT
    do_OPTIONS = do_PUT

    def do_HEAD(self):
        if not self.authed():
            return self.deny()
        if self.fleet_route("HEAD"):
            return
        self.send_bytes(405, "text/plain; charset=utf-8", b"")

    def do_POST(self):
        if not self.authed():
            return self.deny()
        if self.engine_route("POST"):
            return
        if self.fleet_route("POST"):
            return
        if self.empty:
            return self.no_fleet()
        path = urlparse(self.path).path
        if path == "/api/jobs":
            body = self.read_json_body()
            if body is None:
                return
            status, result = self.jobs.start(body, actor=self.actor())
            return self.send_json(status, result)
        if path != "/api/command":
            return self.send_bytes(404, "text/plain; charset=utf-8", b"not found\n")
        try:
            n = int(self.headers.get("Content-Length") or 0)
            if n > 64 * 1024:
                return self.send_json(413, {"ok": False, "error": "body too large"})
            body = json.loads(self.rfile.read(n).decode("utf-8") or "{}")
        except (ValueError, UnicodeDecodeError) as e:
            return self.send_json(400, {"ok": False, "error": "bad JSON: %s" % e})
        status, result = do_command(self.fleet, body, actor=self.actor())
        return self.send_json(status, result)


LOBBY = os.path.join(HERE, "floor", "lobby.html")


def _registry_repos(config_dir):
    """owner/repo lines of a fleet's work registry (repos.txt), comments off."""
    out = []
    try:
        with open(os.path.join(config_dir, "repos.txt"), encoding="utf-8") as f:
            for line in f:
                tok = line.split("#", 1)[0].strip().split()
                if tok and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+", tok[0]):
                    out.append(tok[0])
    except OSError:
        pass
    return out


def engine_snapshot():
    """The App (no secret) and, when there is one, which of the host's fleet
    repositories it can read: one token per owner, from the engine's cache."""
    st = engine.status()
    repos = []
    dirs = [d for _fid, d in list_fleets()] or [CONFIG_DIR]
    for d in dirs:
        for r in _registry_repos(d):
            if r not in repos:
                repos.append(r)
    owners = {}
    if st.get("configured"):
        for r in repos:
            o = r.split("/", 1)[0]
            if o.lower() in owners:
                continue
            try:
                engine.token_for(o)
                owners[o.lower()] = {"owner": o, "ok": True, "error": ""}
            except engine.EngineError as e:
                owners[o.lower()] = {"owner": o, "ok": False, "error": str(e)}
    st["repos"] = repos
    st["owners"] = list(owners.values())
    return st


def engine_journal(actor, action, ok, what):
    """One line per change to the engine's App: who, what, the verdict. The
    key never reaches this function."""
    line = "%s actor=%s action=engine-%s ok=%s %s\n" % (
        time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), actor or "-", action,
        "yes" if ok else "no", (what or "").replace("\n", " ")[:300])
    try:
        os.makedirs(engine.engine_dir(), mode=0o700, exist_ok=True)
        with open(os.path.join(engine.engine_dir(), "journal.log"), "a", encoding="utf-8") as f:
            f.write(line)
    except OSError as e:
        log("engine: journal not written (%s)" % e)


def callback_page(st, error):
    """What the browser lands on after GitHub's manifest flow."""
    import html as _h
    if st:
        msg = ("<h1>The engine has its GitHub App</h1><p><b>%s</b> (App ID %s, owner %s).</p>"
               "<p>Next: <a href=\"%s\">install it on the fleet's repositories</a> — "
               "the tick reads only the repositories it is installed on.</p>"
               % (_h.escape(st.get("slug") or ""), st.get("id"), _h.escape(st.get("owner") or "?"),
                  _h.escape(st.get("install_url") or "")))
    else:
        msg = "<h1>The engine's App was not set</h1><p>%s</p>" % _h.escape(error)
    return ("<!doctype html><meta charset=utf-8><meta name=viewport content=\"width=device-width\">"
            "<title>crew floor — engine</title><body style=\"font:16px system-ui;margin:2rem;max-width:40rem\">"
            "%s<p><a href=\"/\">Back to the floor</a></p></body>" % msg).encode("utf-8")
NO_FLEET = ("no fleet on this host yet — create one: the floor's New fleet, "
            "or crew init --fleet <id>")


def floor_is_empty():
    """#831: this floor serves no fleet — the CLI said so (CREW_FLOOR_EMPTY=1,
    a host whose fleet index is empty), and this is not a fleet's child."""
    return os.environ.get("CREW_FLOOR_EMPTY") == "1" and not os.environ.get("CREW_FLOOR_CHILD")


def serve(bind, port, user, password, interval):
    if not os.path.exists(INDEX):
        # Named for both trees this runs in: a checkout, where build.sh is the
        # fix, and an installed one, which carries the built page and not the
        # builder (#365) — so advice naming only build.sh cannot be followed
        # there. "a repository checkout" rather than the obvious alternative:
        # run.sh's floor-named-crew-verb-roster-is-complete greps `crew <word>`
        # out of this whole file, comments included, and prose in that position
        # mints a console verb that does not exist.
        sys.exit("crew floor: %s is missing — build it with fleet-floor/build.sh "
                 "in a repository checkout, or reinstall (an installed tree "
                 "carries the built page, not the builder)" % INDEX)

    empty = floor_is_empty()
    Handler.auth_token = base64.b64encode(("%s:%s" % (user, password)).encode()).decode()
    Handler.auth_user = user
    fleet = None
    if empty:
        # #831: no fleet on the host yet — no poller, no jobs of its own; the
        # first fleet made from the lobby is served as a child, like any other.
        Handler.empty = True
        Handler.home_fid = None
    else:
        alert_command, alert_error = alert_command_from_config(CONFIG_DIR)
        if alert_error:
            log(alert_error)
        fleet = Fleet(interval, alert_command)
        Handler.fleet = fleet
        Handler.home_fid = front.home_id(CONFIG_DIR)
        Handler.jobs = Jobs(Handler.home_fid)
    children = None
    if not os.environ.get("CREW_FLOOR_CHILD"):
        # The process that owns the port also fronts every other fleet on the
        # host (#814); a fleet's child answers its own fleet and nothing else.
        children = front.Children(None if empty else CONFIG_DIR, interval)
        Handler.children = children
        threading.Thread(target=children.start_all, daemon=True).start()

    if os.environ.get("CREW_FLOOR_CHILD"):
        # A fleet's child lives exactly as long as the front that started it:
        # a front killed outright (SIGKILL, OOM) must not leave children
        # polling boxes and holding ports nobody can reach.
        parent = os.getppid()

        def _orphan_watch():
            while True:
                time.sleep(2)
                if os.getppid() != parent:
                    os._exit(0)
        threading.Thread(target=_orphan_watch, daemon=True).start()
    else:
        import signal

        def _term(signum, frame):
            raise KeyboardInterrupt
        signal.signal(signal.SIGTERM, _term)

    if fleet is not None:
        threading.Thread(target=fleet.loop, daemon=True).start()
        if PING_INTERVAL_S > 0:
            threading.Thread(target=fleet.ping_loop, daemon=True).start()

    httpd = ThreadingHTTPServer((bind, port), Handler)
    httpd.daemon_threads = True
    port = httpd.server_address[1]
    port_file = os.environ.get("CREW_FLOOR_PORT_FILE")
    if port_file:
        # A fleet's child is started on port 0; the front reads the port the
        # kernel gave it from here (#814).
        with open(port_file + ".tmp", "w", encoding="utf-8") as f:
            f.write("%d\n" % port)
        os.replace(port_file + ".tmp", port_file)
    if empty:
        log("serving fleet-floor on http://%s:%d/ with no fleet yet — the page offers New fleet" % (bind, port))
    else:
        log("serving fleet-floor on http://%s:%d/ (evidence every %ds, ping every %ds)"
            % (bind, port, interval, PING_INTERVAL_S))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        log("shutting down")
        httpd.shutdown()
    finally:
        if children:
            children.stop_all()


def main():
    # First, and before the auth and index preconditions below: an
    # unconfigured host must get the config answer, not a missing-password or
    # missing-build one — the same order cmd_floor uses.
    if not floor_is_empty():
        require_operator_config()
    # The door into every box depends on box's version (#792): an unreadable
    # one refuses here, as the CLI's need_box does, rather than guessing.
    require_entry_mode()
    ap_port = int(os.environ.get("CREW_FLOOR_PORT", "8420"))
    ap_bind = os.environ.get("CREW_FLOOR_BIND", "0.0.0.0")
    ap_user = os.environ.get("CREW_FLOOR_USER", "operator")
    ap_pass = os.environ.get("CREW_FLOOR_PASS", "")
    ap_int = int(os.environ.get("CREW_FLOOR_INTERVAL", "60"))
    if not ap_pass:
        sys.exit("crew floor: CREW_FLOOR_PASS is unset — refusing to serve "
                 "operator controls without auth")
    serve(ap_bind, ap_port, ap_user, ap_pass, ap_int)
