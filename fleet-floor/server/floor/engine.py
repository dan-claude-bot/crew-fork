"""The engine's GitHub App (#864).

The engine is everything that reads GitHub from the HOST rather than from a
member's box: the tick's board reads (shared/lib/host/wake.sh), the
one-repo-one-fleet events check (cli/crew), and the floor's "can this fleet
reach that repository" probe (registry.py). It reads as one GitHub App per
host, never as a person: members keep the credentials they are given from
Credentials, and nothing here touches a member.

What is kept, in the host state dir's `engine/` (0700, the service user's):
  app.json   the App's id, slug, owner and page — no secret
  app.pem    its private key, 0600

What is never kept: an installation token. One is minted per owner from a
short JWT signed with the key (`openssl dgst -sha256 -sign`, so no Python
crypto dependency), held in this process's memory until it nears its expiry,
and handed to `gh` as GH_TOKEN in the child's environment — never argv, a
file, a log line, the journal or a reply.

No App configured means `token_for` answers None and the caller runs `gh`
with its own login, as before #864. An App configured but not installed on an
owner is an EngineError that names the owner and the install link: an
unreadable board is said, never read as a quiet one.

The floor creates an App with GitHub's manifest flow (`manifest`, then
`convert` on the redirect back) or is given one (`verify_and_save`). The CLI
entry at the bottom is what cli/crew and shared/lib/host/engine.sh run.
"""

import base64
import calendar
import json
import os
import re
import secrets
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

if __name__ == "__main__":  # run as a script by cli/crew: make `floor.` importable
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from floor.fleets import data_dir, service_conf_value  # noqa: E402

API = os.environ.get("CREW_GITHUB_API") or "https://api.github.com"
WEB = os.environ.get("CREW_GITHUB_WEB") or "https://github.com"
HTTP_TIMEOUT_S = 20
# GitHub's account names: letters, digits, single hyphens, at most 39.
RE_OWNER = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$")
RE_APP_ID = re.compile(r"^[0-9]{1,12}$")
RE_CODE = re.compile(r"^[A-Za-z0-9_-]{1,200}$")
KEY_MAX = 16 * 1024
# Read-only, and only what the engine's reads touch: the board (issues, pull
# requests with their check rollup, discussions) and the repository itself.
PERMISSIONS = {
    "metadata": "read",
    "issues": "read",
    "pull_requests": "read",
    "checks": "read",
    "statuses": "read",
    "discussions": "read",
}
MANIFEST_TTL_S = 3600          # GitHub's manifest code lives an hour
TOKEN_SLACK_S = 300            # re-mint a token with less than this left

_LOCK = threading.Lock()
_TOKENS = {}                   # owner (lower) -> (token, expires_epoch)
_STATES = {}                   # manifest state -> created epoch


class EngineError(Exception):
    """A reason the engine cannot read as its App, said to the operator."""


# --------------------------------------------------------------------------
# Where the App lives
# --------------------------------------------------------------------------

def host_state_dir():
    """The CLI's HOST_STATE_DIR, resolved the same way (jobs.host_state_dir)."""
    explicit = os.environ.get("CREW_HOST_STATE_DIR")
    if explicit:
        return explicit
    if service_conf_value("CREW_SERVICE_USER") is not None:
        return os.path.join(data_dir(), "state")
    xdg = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(xdg, "crew")


def engine_dir():
    return os.environ.get("CREW_ENGINE_DIR") or os.path.join(host_state_dir(), "engine")


def _paths():
    d = engine_dir()
    return d, os.path.join(d, "app.json"), os.path.join(d, "app.pem")


def load():
    """The configured App as a dict (id, slug, owner, html_url), or None."""
    _d, meta, key = _paths()
    try:
        with open(meta, encoding="utf-8") as f:
            app = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(app, dict) or not RE_APP_ID.match(str(app.get("id", ""))):
        return None
    if not os.path.isfile(key):
        return None
    return app


def install_url(app):
    slug = (app or {}).get("slug") or ""
    return "%s/apps/%s/installations/new" % (WEB, slug) if slug else ""


def status():
    """What the floor and `crew engine` show. No secret: the key's presence
    is a boolean, and nothing reads it back."""
    app = load()
    if not app:
        return {"configured": False, "permissions": PERMISSIONS}
    return {"configured": True, "id": int(app["id"]), "slug": app.get("slug", ""),
            "name": app.get("name", ""), "owner": app.get("owner", ""),
            "html_url": app.get("html_url", ""), "install_url": install_url(app),
            "permissions": PERMISSIONS}


def _write_private(path, data, mode):
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-")
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(data)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def save(app, pem):
    """Store the App: the key first (0600), then the metadata that makes it
    live, so a crash between the two leaves the previous App or none."""
    d, meta, key = _paths()
    os.makedirs(d, mode=0o700, exist_ok=True)
    os.chmod(d, 0o700)
    _write_private(key, pem if pem.endswith("\n") else pem + "\n", 0o600)
    keep = {k: app.get(k) for k in ("id", "slug", "name", "html_url")}
    keep["owner"] = ((app.get("owner") or {}).get("login") if isinstance(app.get("owner"), dict)
                     else app.get("owner")) or ""
    keep["saved_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    _write_private(meta, json.dumps(keep, indent=2) + "\n", 0o600)
    with _LOCK:
        _TOKENS.clear()
    return status()


def remove():
    _d, meta, key = _paths()
    removed = False
    for p in (meta, key):
        try:
            os.unlink(p)
            removed = True
        except FileNotFoundError:
            pass
    with _LOCK:
        _TOKENS.clear()
    return removed


# --------------------------------------------------------------------------
# GitHub
# --------------------------------------------------------------------------

def _b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode("ascii")


def jwt(app_id, key_path):
    """A ten-minute JWT for the App, RS256 by openssl. The key stays a path:
    it is never read into this process."""
    now = int(time.time())
    head = _b64u(json.dumps({"alg": "RS256", "typ": "JWT"}, separators=(",", ":")).encode())
    body = _b64u(json.dumps({"iat": now - 60, "exp": now + 540, "iss": str(app_id)},
                            separators=(",", ":")).encode())
    signing = ("%s.%s" % (head, body)).encode("ascii")
    try:
        p = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                           input=signing, capture_output=True, timeout=20, check=False)
    except FileNotFoundError:
        raise EngineError("openssl is not installed on this host; the engine signs its App's JWT with it")
    except subprocess.TimeoutExpired:
        raise EngineError("openssl timed out signing the App's JWT")
    if p.returncode != 0 or not p.stdout:
        raise EngineError("the App's private key does not sign (openssl: %s)"
                          % (p.stderr.decode("utf-8", "replace").strip().splitlines() or ["no output"])[-1][:200])
    return "%s.%s" % (signing.decode("ascii"), _b64u(p.stdout))


def _request(method, path, bearer=None, body=None):
    """(status, json-or-None). Never raises on an HTTP status; raises
    EngineError when GitHub could not be reached at all."""
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("User-Agent", "crew-engine")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    if bearer:
        req.add_header("Authorization", "Bearer " + bearer)
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_S) as r:
            raw = r.read()
            st = r.status
    except urllib.error.HTTPError as e:
        raw = e.read() or b""
        st = e.code
    except (urllib.error.URLError, socket.timeout, OSError) as e:
        raise EngineError("GitHub could not be reached (%s)" % getattr(e, "reason", e))
    try:
        return st, json.loads(raw.decode("utf-8")) if raw else None
    except ValueError:
        return st, None


def _gh_message(js):
    return ((js or {}).get("message") if isinstance(js, dict) else "") or "no message"


def _iso_epoch(s):
    try:
        return calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ"))
    except (TypeError, ValueError):
        return int(time.time()) + 3000


def token_for(owner):
    """An installation token for OWNER's installation of the App, or None
    when no App is configured (the caller falls back to gh's own login)."""
    if not RE_OWNER.match(owner or ""):
        raise EngineError("%r is not a GitHub account name" % owner)
    app = load()
    if not app:
        return None
    k = owner.lower()
    with _LOCK:
        hit = _TOKENS.get(k)
        if hit and hit[1] - TOKEN_SLACK_S > time.time():
            return hit[0]
    _d, _meta, key = _paths()
    signed = jwt(app["id"], key)
    inst = None
    for kind in ("users", "orgs"):
        st, js = _request("GET", "/%s/%s/installation" % (kind, owner), bearer=signed)
        if st == 200 and isinstance(js, dict) and js.get("id"):
            inst = js["id"]
            break
        if st in (401, 403):
            raise EngineError("GitHub refused the App %s (id %s): %s — check its private key"
                              % (app.get("slug") or "?", app["id"], _gh_message(js)))
    if not inst:
        raise EngineError("the engine's App %s is not installed on %s — install it: %s"
                          % (app.get("slug") or app["id"], owner, install_url(app)))
    st, js = _request("POST", "/app/installations/%s/access_tokens" % inst, bearer=signed)
    if st != 201 or not isinstance(js, dict) or not js.get("token"):
        raise EngineError("GitHub would not mint a token for %s's installation (%s: %s)"
                          % (owner, st, _gh_message(js)))
    tok = js["token"]
    with _LOCK:
        _TOKENS[k] = (tok, _iso_epoch(js.get("expires_at")))
    return tok


def gh_env(owner):
    """The environment for a `gh` child reading OWNER's repositories: the
    App's token when one is configured, this process's own otherwise."""
    env = dict(os.environ)
    tok = token_for(owner)
    if tok:
        env["GH_TOKEN"] = tok
        env["GH_HOST"] = "github.com"
        env.pop("GITHUB_TOKEN", None)
    return env


# --------------------------------------------------------------------------
# Giving the engine an App
# --------------------------------------------------------------------------

def verify_and_save(app_id, pem):
    """An existing App: check the key signs for it (GET /app as the App)
    BEFORE anything is stored. Returns status(); raises EngineError."""
    app_id = str(app_id or "").strip()
    if not RE_APP_ID.match(app_id):
        raise EngineError("the App ID is a number (the App's settings page, 'App ID')")
    if not isinstance(pem, str) or "PRIVATE KEY-----" not in pem or len(pem) > KEY_MAX:
        raise EngineError("that is not a GitHub App private key (a .pem that begins -----BEGIN RSA PRIVATE KEY-----)")
    d = engine_dir()
    os.makedirs(d, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".verify-")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(pem.strip() + "\n")
        st, js = _request("GET", "/app", bearer=jwt(app_id, tmp))
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass
    if st != 200 or not isinstance(js, dict) or str(js.get("id")) != app_id:
        raise EngineError("GitHub did not accept that key for App %s (%s: %s) — nothing stored"
                          % (app_id, st, _gh_message(js)))
    return save(js, pem.strip())


def manifest(base_url, org=""):
    """(action_url, manifest_json) for the floor's 'Create GitHub App' form.
    BASE_URL is the floor's own address as the browser reached it; GitHub
    sends the browser back to BASE_URL/engine/callback with a one-time code."""
    org = (org or "").strip()
    if org and not RE_OWNER.match(org):
        raise EngineError("%r is not a GitHub organization name" % org)
    if not re.match(r"^https?://[^/\s]+$", base_url or ""):
        raise EngineError("the floor's address is not usable as a redirect (%r)" % base_url)
    state = secrets.token_urlsafe(24)
    now = time.time()
    with _LOCK:
        for s, t in list(_STATES.items()):
            if now - t > MANIFEST_TTL_S:
                _STATES.pop(s, None)
        _STATES[state] = now
    host = (socket.gethostname() or "host").split(".")[0]
    name = ("crew engine %s" % host)[:34]
    man = {
        "name": name,
        "url": "https://github.com/heavy-duty/crew",
        "redirect_url": base_url + "/engine/callback",
        "description": "crew's engine on %s: reads the fleet's boards. Read-only; members use their own credentials." % host,
        "public": False,
        "default_permissions": PERMISSIONS,
        "default_events": [],
    }
    where = ("%s/organizations/%s/settings/apps/new" % (WEB, org)) if org else ("%s/settings/apps/new" % WEB)
    return "%s?state=%s" % (where, state), json.dumps(man)


def convert(code, state):
    """The redirect back: a state this process issued, then GitHub's code
    for the App and its key. Returns status(); raises EngineError."""
    with _LOCK:
        t = _STATES.pop(state or "", None)
    if t is None or time.time() - t > MANIFEST_TTL_S:
        raise EngineError("this link was not issued by this floor, or is more than an hour old — start again from Credentials → Engine")
    if not RE_CODE.match(code or ""):
        raise EngineError("GitHub sent back no usable code")
    st, js = _request("POST", "/app-manifests/%s/conversions" % code)
    if st != 201 or not isinstance(js, dict) or not js.get("pem") or not js.get("id"):
        raise EngineError("GitHub would not hand over the new App (%s: %s)" % (st, _gh_message(js)))
    pem = js.pop("pem")
    for secret in ("client_secret", "webhook_secret"):
        js.pop(secret, None)
    return save(js, pem)


# --------------------------------------------------------------------------
# The CLI's door: python3 engine.py token OWNER | status | set APP_ID | remove
# --------------------------------------------------------------------------

def main(argv):
    verb = argv[1] if len(argv) > 1 else "status"
    try:
        if verb == "token" and len(argv) == 3:
            tok = token_for(argv[2])
            if tok is None:
                return 3                      # no App: the caller uses gh's login
            sys.stdout.write(tok + "\n")
            return 0
        if verb == "status" and len(argv) == 2:
            print(json.dumps(status()))
            return 0
        if verb == "set" and len(argv) == 3:
            st = verify_and_save(argv[2], sys.stdin.read(KEY_MAX + 1))
            print("engine: GitHub App %s (id %s, owner %s) — install it on the fleet's repositories: %s"
                  % (st["slug"], st["id"], st["owner"] or "?", st["install_url"]))
            return 0
        if verb == "remove" and len(argv) == 2:
            print("engine: App removed — the engine reads with gh's own login" if remove()
                  else "engine: no App was configured")
            return 0
    except EngineError as e:
        sys.stderr.write("engine: %s\n" % e)
        return 1
    sys.stderr.write("usage: engine.py token OWNER | status | set APP_ID (key on stdin) | remove\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
