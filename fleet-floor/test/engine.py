#!/usr/bin/env python3
"""The engine's GitHub App (#864), offline: a stub GitHub on 127.0.0.1 that
checks every JWT against the App's real public key (openssl), so a key that
does not sign for the App is refused exactly as GitHub refuses it.

Covered: no App → no token (gh's own login); a wrong key stores nothing; a
right one is kept 0600 with no secret in app.json; tokens are minted once per
owner and reused; an owner without the App installed is named with the
install link; the manifest flow's state check and conversion; the CLI door;
and the floor's routes — no reply and no journal line ever carries the key.
"""

import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TMP = tempfile.mkdtemp(prefix="crew-engine-")
os.environ["CREW_ENGINE_DIR"] = os.path.join(TMP, "state", "engine")
os.environ["CREW_HOST_STATE_DIR"] = os.path.join(TMP, "state")
os.environ["CREW_CONFIG_DIR"] = os.path.join(TMP, "config")
os.environ["CREW_FLEETS_DIR"] = os.path.join(TMP, "no-fleets")
os.environ["CREW_ETC_DIR"] = os.path.join(TMP, "etc")
os.makedirs(os.environ["CREW_CONFIG_DIR"])
for name in ("fleet.roster", "fleet.conf"):
    open(os.path.join(os.environ["CREW_CONFIG_DIR"], name), "w").close()
with open(os.path.join(os.environ["CREW_CONFIG_DIR"], "repos.txt"), "w") as f:
    f.write("# the work registry\nacme/site\nnobody/elsewhere  # not installed\n")

KEY = os.path.join(TMP, "app.pem")
PUB = os.path.join(TMP, "app.pub")
OTHER = os.path.join(TMP, "other.pem")
for k in (KEY, OTHER):
    subprocess.run(["openssl", "genrsa", "-out", k, "2048"], check=True, capture_output=True)
subprocess.run(["openssl", "rsa", "-in", KEY, "-pubout", "-out", PUB], check=True, capture_output=True)
PEM = open(KEY).read()
APP_ID = "4242"
HITS = []


def b64d(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def jwt_ok(auth):
    if not auth.startswith("Bearer "):
        return False
    try:
        head, body, sig = auth[7:].split(".")
    except ValueError:
        return False
    sigf = os.path.join(TMP, "sig")
    with open(sigf, "wb") as f:
        f.write(b64d(sig))
    p = subprocess.run(["openssl", "dgst", "-sha256", "-verify", PUB, "-signature", sigf],
                       input=("%s.%s" % (head, body)).encode(), capture_output=True)
    return p.returncode == 0 and json.loads(b64d(body)).get("iss") == APP_ID


class GitHub(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, st, obj):
        raw = json.dumps(obj).encode()
        self.send_response(st)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        HITS.append("GET " + self.path)
        if not jwt_ok(self.headers.get("Authorization", "")):
            return self.reply(401, {"message": "A JSON web token could not be decoded"})
        if self.path == "/app":
            return self.reply(200, {"id": int(APP_ID), "slug": "crew-engine-test", "name": "crew engine test",
                                    "owner": {"login": "acme"}, "html_url": "https://github.example/apps/crew-engine-test"})
        if self.path in ("/users/acme/installation", "/orgs/acme/installation"):
            return self.reply(200, {"id": 77})
        return self.reply(404, {"message": "Not Found"})

    def do_POST(self):
        HITS.append("POST " + self.path)
        n = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(n)
        if self.path == "/app-manifests/goodcode/conversions":
            return self.reply(201, {"id": int(APP_ID), "slug": "crew-engine-made", "name": "crew engine made",
                                    "owner": {"login": "acme"}, "html_url": "https://github.example/apps/crew-engine-made",
                                    "pem": PEM, "client_secret": "CLIENT-SECRET-XYZ", "webhook_secret": None})
        if self.path.startswith("/app-manifests/"):
            return self.reply(404, {"message": "Not Found"})
        if not jwt_ok(self.headers.get("Authorization", "")):
            return self.reply(401, {"message": "bad JWT"})
        if self.path == "/app/installations/77/access_tokens":
            return self.reply(201, {"token": "ghs_TESTTOKEN", "expires_at": "2099-01-01T00:00:00Z"})
        return self.reply(404, {"message": "Not Found"})


gh = ThreadingHTTPServer(("127.0.0.1", 0), GitHub)
threading.Thread(target=gh.serve_forever, daemon=True).start()
os.environ["CREW_GITHUB_API"] = "http://127.0.0.1:%d" % gh.server_address[1]
os.environ["CREW_GITHUB_WEB"] = "https://github.example"

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER_DIR = os.path.join(os.path.dirname(HERE), "server")
sys.path.insert(0, SERVER_DIR)
from floor import engine  # noqa: E402

failures = []
passed = 0


def t(name, want, got):
    global passed
    if want == got:
        passed += 1
        print("ok   engine: " + name)
    else:
        failures.append(name)
        print("FAIL engine: %s  — expected [%r] got [%r]" % (name, want, got))


def raises(fn):
    try:
        fn()
    except engine.EngineError as e:
        return str(e)
    return ""


def tree_text():
    out = ""
    for root, _d, files in os.walk(os.environ["CREW_ENGINE_DIR"]):
        for fn in files:
            if fn != "app.pem":
                out += open(os.path.join(root, fn), encoding="utf-8", errors="replace").read()
    return out


try:
    # --- no App ----------------------------------------------------------------
    t("no-app-reads-unconfigured", False, engine.status()["configured"])
    t("no-app-no-token-gh-login-instead", None, engine.token_for("acme"))
    t("no-app-gh-env-carries-no-token", None, engine.gh_env("acme").get("GH_TOKEN") if "GH_TOKEN" not in os.environ else None)

    # --- an existing App, pasted ------------------------------------------------
    err = raises(lambda: engine.verify_and_save(APP_ID, open(OTHER).read()))
    t("a-wrong-key-is-refused", True, "did not accept that key" in err)
    t("a-wrong-key-stores-nothing", False, os.path.exists(os.path.join(os.environ["CREW_ENGINE_DIR"], "app.json")))
    t("a-wrong-key-leaves-no-temp-key", [], [f for f in os.listdir(os.environ["CREW_ENGINE_DIR"]) if f.startswith(".verify-")])
    t("a-non-number-id-is-refused", True, "is a number" in raises(lambda: engine.verify_and_save("abc", PEM)))
    t("a-non-key-is-refused", True, "not a GitHub App private key" in raises(lambda: engine.verify_and_save(APP_ID, "hello")))
    st = engine.verify_and_save(APP_ID, PEM)
    t("a-right-key-is-kept", "crew-engine-test", st["slug"])
    t("the-install-link", "https://github.example/apps/crew-engine-test/installations/new", st["install_url"])
    pem_path = os.path.join(os.environ["CREW_ENGINE_DIR"], "app.pem")
    t("the-key-is-0600", "0o600", oct(os.stat(pem_path).st_mode & 0o777))
    t("the-dir-is-0700", "0o700", oct(os.stat(os.environ["CREW_ENGINE_DIR"]).st_mode & 0o777))
    t("app-json-holds-no-key", False, "PRIVATE KEY" in tree_text())
    t("status-holds-no-key", False, "PRIVATE KEY" in json.dumps(engine.status()))

    # --- tokens -----------------------------------------------------------------
    HITS.clear()
    t("a-token-for-an-installed-owner", "ghs_TESTTOKEN", engine.token_for("acme"))
    t("the-token-is-reused-not-reminted", "ghs_TESTTOKEN", engine.token_for("ACME"))
    t("one-installation-read-and-one-mint", 1, sum(1 for h in HITS if h.startswith("POST /app/installations/")))
    env = engine.gh_env("acme")
    t("gh-env-carries-the-token", ("ghs_TESTTOKEN", "github.com"), (env.get("GH_TOKEN"), env.get("GH_HOST")))
    err = raises(lambda: engine.token_for("nobody"))
    t("an-owner-without-the-app-is-named", True, "not installed on nobody" in err and "installations/new" in err)
    t("a-bad-owner-is-refused", True, "not a GitHub account name" in raises(lambda: engine.token_for("a/b")))

    # --- the CLI door -------------------------------------------------------------
    cli = [sys.executable, os.path.join(SERVER_DIR, "floor", "engine.py")]
    p = subprocess.run(cli + ["token", "acme"], capture_output=True, text=True)
    t("cli-token-prints-the-token", (0, "ghs_TESTTOKEN"), (p.returncode, p.stdout.strip()))
    p = subprocess.run(cli + ["token", "nobody"], capture_output=True, text=True)
    t("cli-token-uninstalled-is-1-and-said", (1, True), (p.returncode, "not installed on nobody" in p.stderr))
    p = subprocess.run(cli + ["remove"], capture_output=True, text=True)
    t("cli-remove", (0, False), (p.returncode, engine.status()["configured"]))
    p = subprocess.run(cli + ["token", "acme"], capture_output=True, text=True)
    t("cli-token-without-an-app-is-3", (3, ""), (p.returncode, p.stdout))
    p = subprocess.run(cli + ["set", APP_ID], input=PEM, capture_output=True, text=True)
    t("cli-set-takes-the-key-on-stdin", (0, True), (p.returncode, engine.status()["configured"]))
    t("cli-set-never-echoes-the-key", False, "PRIVATE KEY" in p.stdout + p.stderr)
    engine.remove()

    # --- the manifest flow --------------------------------------------------------
    action, man = engine.manifest("http://100.1.2.3:8420", "")
    m = json.loads(man)
    t("manifest-personal-action", True, action.startswith("https://github.example/settings/apps/new?state="))
    t("manifest-redirects-to-the-floor", "http://100.1.2.3:8420/engine/callback", m["redirect_url"])
    t("manifest-is-read-only", {"read"}, set(m["default_permissions"].values()))
    t("manifest-has-no-webhook", (False, []), ("hook_attributes" in m, m["default_events"]))
    t("manifest-name-fits-github", True, len(m["name"]) <= 34)
    action_org, _ = engine.manifest("http://h:1", "acme")
    t("manifest-org-action", True, action_org.startswith("https://github.example/organizations/acme/settings/apps/new?state="))
    t("manifest-bad-org-refused", True, "not a GitHub organization" in raises(lambda: engine.manifest("http://h:1", "a b")))
    state = action.split("state=", 1)[1]
    t("callback-a-foreign-state-is-refused", True, "not issued by this floor" in raises(lambda: engine.convert("goodcode", "forged")))
    t("callback-a-refused-code-stores-nothing", True,
      "would not hand over" in raises(lambda: engine.convert("badcode", action_org.split("state=", 1)[1])) and not engine.status()["configured"])
    st = engine.convert("goodcode", state)
    t("callback-converts-and-stores", ("crew-engine-made", "acme"), (st["slug"], st["owner"]))
    t("callback-keeps-no-client-secret", False, "CLIENT-SECRET" in tree_text())
    t("callback-a-state-is-used-once", True, "not issued by this floor" in raises(lambda: engine.convert("goodcode", state)))

    # --- the floor's routes -------------------------------------------------------
    from floor import server as floor_server  # noqa: E402
    H = floor_server.Handler
    H.auth_token = base64.b64encode(b"operator:pw").decode()
    H.auth_user = "operator"
    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = "http://127.0.0.1:%d" % srv.server_address[1]

    def call(method, path, body=None, auth=True):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(base + path, data=data, method=method)
        if auth:
            req.add_header("Authorization", "Basic " + H.auth_token)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                return r.status, r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode()

    st_, body = call("GET", "/api/engine", auth=False)
    t("floor-engine-needs-the-password", 401, st_)
    st_, body = call("GET", "/api/engine")
    js = json.loads(body)
    t("floor-engine-status", (200, True), (st_, js["configured"]))
    t("floor-engine-names-the-fleet-repos", ["acme/site", "nobody/elsewhere"], js["repos"])
    t("floor-engine-says-which-owners-it-reads", [("acme", True), ("nobody", False)],
      [(o["owner"], o["ok"]) for o in js["owners"]])
    st_, body = call("POST", "/api/engine/app", {"app_id": APP_ID, "key": open(OTHER).read()})
    t("floor-a-wrong-key-is-400", (400, False), (st_, "PRIVATE KEY" in body))
    t("floor-a-wrong-key-keeps-the-old-app", "crew-engine-made", engine.status()["slug"])
    st_, body = call("POST", "/api/engine/app", {"app_id": APP_ID, "key": PEM})
    t("floor-a-right-key-is-200", (200, "crew-engine-test", False),
      (st_, json.loads(body)["engine"]["slug"], "PRIVATE KEY" in body))
    st_, body = call("POST", "/api/engine/manifest", {"org": ""})
    js = json.loads(body)
    t("floor-manifest-uses-the-floors-address", True,
      json.loads(js["manifest"])["redirect_url"] == base + "/engine/callback")
    st_, body = call("GET", "/engine/callback?code=goodcode&state=forged")
    t("floor-callback-a-forged-state-is-400", (400, True), (st_, "was not set" in body))
    st_, body = call("POST", "/api/engine/remove", {})
    t("floor-remove", (200, True, False), (st_, json.loads(body)["removed"], engine.status()["configured"]))
    journal = open(os.path.join(os.environ["CREW_ENGINE_DIR"], "journal.log")).read()
    t("floor-journal-names-who-and-what", True, "actor=operator action=engine-set ok=yes" in journal
      and "action=engine-set ok=no" in journal and "action=engine-remove ok=yes" in journal)
    t("floor-journal-never-holds-a-key", False, "PRIVATE KEY" in journal or "CLIENT-SECRET" in journal)
    srv.shutdown()
finally:
    gh.shutdown()
    shutil.rmtree(TMP, ignore_errors=True)

print("engine: passed %d, failed %d" % (passed, len(failures)))
sys.exit(1 if failures else 0)
