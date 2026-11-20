#!/usr/bin/env python3
"""gamehost acceptance tests (spec section 14, tests 1-13, plus previews, delete and auth rate limiting).

Runs against a live stack in TLS_MODE=external. Standard library only.

Environment:
  GAMEHOST_TEST_URL           Caddy base URL, e.g. http://127.0.0.1:8081 (required)
  GAMEHOST_BASE_DOMAIN        e.g. games.test (required; sent as the Host header, so no DNS is needed)
  GAMEHOST_API_HOST           default deploy.<base>
  GAMEHOST_ADMIN_TOKEN        (required)
  GAMEHOST_MAX_UPLOAD_MB      the stack's limit (the oversize test sends more than this)
  GAMEHOST_MAX_UNPACKED_MB    the stack's limit (the bomb test expands beyond this)
  GAMEHOST_TEST_RESTART_CMD   shell command that restarts the stack (restart test skipped if unset)
  GAMEHOST_TEST_TMP_CHECK_CMD shell command that lists /data/tmp; output must be empty after restart
  GAMEHOST_TEST_RELEASES_CMD  shell command listing a site's release dirs; {key} is substituted
"""
import http.client
import io
import json
import os
import random
import subprocess
import sys
import threading
import time
import traceback
import urllib.parse
import uuid
import zipfile

BASE = os.environ["GAMEHOST_TEST_URL"].rstrip("/")
DOMAIN = os.environ["GAMEHOST_BASE_DOMAIN"]
API_HOST = os.environ.get("GAMEHOST_API_HOST") or f"deploy.{DOMAIN}"
ADMIN = os.environ["GAMEHOST_ADMIN_TOKEN"]
MAX_UPLOAD_MB = int(os.environ.get("GAMEHOST_MAX_UPLOAD_MB", "512"))
MAX_UNPACKED_MB = int(os.environ.get("GAMEHOST_MAX_UNPACKED_MB", "2048"))
RUN = uuid.uuid4().hex[:6]
HOSTPORT = urllib.parse.urlsplit(BASE).netloc


# ---------------------------------------------------------------- HTTP helpers

class Resp:
    def __init__(self, status, headers, body):
        self.status = status
        self.headers = {k.lower(): v for k, v in headers}
        self.body = body

    def json(self):
        return json.loads(self.body or b"null")

    @property
    def code(self):
        try:
            return self.json()["error"]["code"]
        except Exception:
            return None

    def __repr__(self):
        return f"<{self.status} {self.body[:300]!r}>"


def request(method, host, path, body=None, headers=None, timeout=300):
    conn = http.client.HTTPConnection(HOSTPORT, timeout=timeout)
    h = {"Host": host}
    h.update(headers or {})
    try:
        conn.request(method, path, body=body, headers=h)
        r = conn.getresponse()
        data = r.read()
        return Resp(r.status, r.getheaders(), data)
    finally:
        conn.close()


def api(method, path, token=ADMIN, body=None, headers=None):
    h = dict(headers or {})
    if token is not None:
        h["Authorization"] = f"Bearer {token}"
    if isinstance(body, (dict, list)):
        body = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    return request(method, API_HOST, path, body, h)


def site_get(key, path="/", headers=None):
    return request("GET", f"{key}.{DOMAIN}", path, headers=headers)


def multipart(fields):
    """fields: list of (name, value, filename|None)."""
    boundary = "----gh" + uuid.uuid4().hex
    out = io.BytesIO()
    for name, value, filename in fields:
        out.write(f"--{boundary}\r\n".encode())
        disp = f'form-data; name="{name}"'
        if filename:
            disp += f'; filename="{filename}"'
        out.write(f"Content-Disposition: {disp}\r\n".encode())
        if filename:
            out.write(b"Content-Type: application/octet-stream\r\n")
        out.write(b"\r\n")
        out.write(value if isinstance(value, bytes) else value.encode())
        out.write(b"\r\n")
    out.write(f"--{boundary}--\r\n".encode())
    return out.getvalue(), f"multipart/form-data; boundary={boundary}"


def deploy(manifest_text, bundle, token=ADMIN, preview=None, commit=None, ref=None):
    fields = [("manifest", manifest_text, "gamehost.toml"), ("bundle", bundle, "bundle.zip")]
    if preview is not None:
        fields.append(("preview", preview, None))
    if commit:
        fields.append(("commit", commit, None))
    if ref:
        fields.append(("ref", ref, None))
    body, ctype = multipart(fields)
    try:
        return api("POST", "/api/deploy", token, body, {"Content-Type": ctype})
    except (BrokenPipeError, ConnectionResetError) as e:
        # The server may answer and close before an oversize body is fully sent.
        return Resp(0, [], str(e).encode())


def make_zip(files, symlinks=(), raw_names=()):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in files.items():
            z.writestr(name, data)
        for name, target in symlinks:
            info = zipfile.ZipInfo(name)
            info.create_system = 3
            info.external_attr = 0o120777 << 16
            z.writestr(info, target)
        for name, data in raw_names:
            info = zipfile.ZipInfo("placeholder")
            info.filename = name  # bypass zipfile's own sanitizing
            z.writestr(info, data)
    return buf.getvalue()


def manifest(name, extra=""):
    return f'name = "{name}"\ndir = "build/web"\n{extra}'


def fake_wasm(tag, kb=64):
    filler = (f"godot-engine-{tag}-" * 4096).encode()
    return b"\x00asm\x01\x00\x00\x00" + filler[: kb * 1024]


def create_site(name):
    r = api("POST", "/api/sites", body={"name": name})
    assert r.status == 201, r
    return r.json()["token"]


# ---------------------------------------------------------------- tests

TESTS = []


class Skip(Exception):
    pass


def test(fn):
    TESTS.append(fn)
    return fn


def eq(a, b, msg=""):
    assert a == b, f"{msg} expected {b!r}, got {a!r}"


@test
def t00_healthz():
    r = request("GET", API_HOST, "/healthz")
    eq(r.status, 200)
    eq(r.json(), {"ok": True})


@test
def t01_create_deploy_serve():
    name = f"basic-{RUN}"
    create_site(name)
    r = deploy(manifest(name), make_zip({"index.html": "<html>hello v1</html>", "index.wasm": fake_wasm("a")}),
               commit="abc123", ref="main")
    eq(r.status, 201, str(r))
    j = r.json()
    eq(j["site"], name)
    eq(j["preview"], None)
    eq(j["files"], 2)
    assert j["url"].startswith(f"http://{name}.{DOMAIN}"), j
    assert j["bytes_brotli"] < j["bytes"], j
    eq(j["previous_release"], None)
    page = site_get(name)
    eq(page.status, 200)
    eq(page.body, b"<html>hello v1</html>")
    eq(page.headers.get("cache-control"), "no-cache")
    eq(page.headers.get("x-content-type-options"), "nosniff")
    d = api("GET", f"/api/sites/{name}")
    eq(d.status, 200)
    eq(d.json()["releases"][0]["commit"], "abc123")
    lst = api("GET", "/api/sites")
    assert any(s["name"] == name and s["current_release"] == j["release"] for s in lst.json()), lst
    eq(site_get(name, "/release.json").status, 404, "release metadata must not be served")


@test
def t02_wasm_mime_and_brotli():
    name = f"basic-{RUN}"
    plain = site_get(name, "/index.wasm", {"Accept-Encoding": "identity"})
    eq(plain.status, 200)
    eq(plain.headers.get("content-type"), "application/wasm")
    br = site_get(name, "/index.wasm", {"Accept-Encoding": "br"})
    eq(br.status, 200)
    eq(br.headers.get("content-encoding"), "br")
    eq(br.headers.get("content-type"), "application/wasm")
    assert len(br.body) < len(plain.body), (len(br.body), len(plain.body))
    gz = site_get(name, "/index.wasm", {"Accept-Encoding": "gzip"})
    eq(gz.headers.get("content-encoding"), "gzip")
    eq(gz.headers.get("content-type"), "application/wasm")
    assert "accept-encoding" in gz.headers.get("vary", "").lower(), gz.headers


@test
def t03_cross_origin_isolation():
    on, off = f"coi-on-{RUN}", f"coi-off-{RUN}"
    create_site(on)
    create_site(off)
    extra = '[headers]\ncross_origin_isolation = true\n[headers.custom]\n"Permissions-Policy" = "gamepad=(self)"'
    eq(deploy(manifest(on, extra), make_zip({"index.html": "x"})).status, 201)
    eq(deploy(manifest(off), make_zip({"index.html": "x"})).status, 201)
    a, b = site_get(on), site_get(off)
    eq(a.headers.get("cross-origin-opener-policy"), "same-origin")
    eq(a.headers.get("cross-origin-embedder-policy"), "require-corp")
    eq(a.headers.get("permissions-policy"), "gamepad=(self)")
    assert "cross-origin-opener-policy" not in b.headers and "cross-origin-embedder-policy" not in b.headers, b.headers


@test
def t04_etag_stable_across_releases():
    name = f"etag-{RUN}"
    create_site(name)
    wasm = fake_wasm("stable")
    eq(deploy(manifest(name), make_zip({"index.html": "v1", "index.wasm": wasm, "index.pck": b"pck-1" * 400})).status, 201)
    w1 = site_get(name, "/index.wasm", {"Accept-Encoding": "br"}).headers["etag"]
    w1_plain = site_get(name, "/index.wasm", {"Accept-Encoding": "identity"}).headers["etag"]
    p1 = site_get(name, "/index.pck", {"Accept-Encoding": "identity"}).headers["etag"]
    time.sleep(1.1)
    eq(deploy(manifest(name), make_zip({"index.html": "v1", "index.wasm": wasm, "index.pck": b"pck-2" * 400})).status, 201)
    w2 = site_get(name, "/index.wasm", {"Accept-Encoding": "br"}).headers["etag"]
    w2_plain = site_get(name, "/index.wasm", {"Accept-Encoding": "identity"}).headers["etag"]
    p2 = site_get(name, "/index.pck", {"Accept-Encoding": "identity"}).headers["etag"]
    eq(w2, w1, "unchanged .wasm (br) ETag")
    eq(w2_plain, w1_plain, "unchanged .wasm (identity) ETag")
    assert p1 != p2, "changed .pck must get a new ETag"
    eq(site_get(name, "/index.wasm", {"Accept-Encoding": "br", "If-None-Match": w1}).status, 304)
    eq(site_get(name, "/index.pck", {"Accept-Encoding": "identity", "If-None-Match": p1}).status, 200)


@test
def t05_no_404_or_mixed_during_deploys():
    name = f"atomic-{RUN}"
    create_site(name)
    eq(deploy(manifest(name), make_zip({"index.html": "release-0", "a.js": "a-0"})).status, 201)
    stop = threading.Event()
    bad = []
    count = [0]

    def loop():
        while not stop.is_set():
            r = site_get(name)
            count[0] += 1
            if r.status != 200 or not r.body.startswith(b"release-"):
                bad.append(r)

    threads = [threading.Thread(target=loop) for _ in range(4)]
    for t in threads:
        t.start()
    try:
        for i in range(1, 6):
            r = deploy(manifest(name), make_zip({"index.html": f"release-{i}", "a.js": f"a-{i}"}))
            eq(r.status, 201, str(r))
            time.sleep(0.2)
    finally:
        stop.set()
        for t in threads:
            t.join()
    assert not bad, f"{len(bad)} bad responses out of {count[0]}: {bad[:3]}"
    assert count[0] > 20, count[0]
    eq(site_get(name).body, b"release-5")


@test
def t06_rollback_restores_content_and_headers():
    name = f"rollback-{RUN}"
    create_site(name)
    r1 = deploy(manifest(name, "[headers]\ncross_origin_isolation = true"), make_zip({"index.html": "one"})).json()
    time.sleep(1.1)
    r2 = deploy(manifest(name), make_zip({"index.html": "two"})).json()
    page = site_get(name)
    eq(page.body, b"two")
    assert "cross-origin-opener-policy" not in page.headers
    rb = api("POST", f"/api/sites/{name}/rollback")
    eq(rb.status, 200, str(rb))
    eq(rb.json()["release"], r1["release"])
    page = site_get(name)
    eq(page.body, b"one")
    eq(page.headers.get("cross-origin-opener-policy"), "same-origin")
    fwd = api("POST", f"/api/sites/{name}/rollback", body={"release": r2["release"]})
    eq(fwd.status, 200)
    eq(site_get(name).body, b"two")
    missing = api("POST", f"/api/sites/{name}/rollback", body={"release": "19990101T000000Z-00000000"})
    eq(missing.status, 404)
    eq(missing.code, "release_not_found")


@test
def t07_releases_keep():
    name = f"keep-{RUN}"
    create_site(name)
    for i in range(3):
        eq(deploy(manifest(name, "[releases]\nkeep = 2"), make_zip({"index.html": f"v{i}"})).status, 201)
        time.sleep(1.1)
    releases = api("GET", f"/api/sites/{name}").json()["releases"]
    eq(len(releases), 2, "releases reported by the API")
    cmd = os.environ.get("GAMEHOST_TEST_RELEASES_CMD")
    if cmd:
        out = subprocess.run(cmd.replace("{key}", name), shell=True, capture_output=True, text=True, check=True).stdout.split()
        eq(len(out), 2, f"release dirs on disk: {out}")


@test
def t08_rejections_leave_site_untouched():
    name = f"reject-{RUN}"
    create_site(name)
    eq(deploy(manifest(name), make_zip({"index.html": "good"})).status, 201)
    before = api("GET", f"/api/sites/{name}").json()["current_release"]

    bomb = make_zip({"index.html": "x", "zeros.bin": b"\0" * ((MAX_UNPACKED_MB + 1) * 1024 * 1024)})
    assert len(bomb) < MAX_UPLOAD_MB * 1024 * 1024, "the bomb must fit under the upload limit"
    ok_zip = make_zip({"index.html": "x"})

    cases = [
        ("zip-slip", manifest(name), make_zip({"index.html": "x"}, raw_names=[("../evil.html", "x")]), 422, "bundle_invalid"),
        ("absolute path", manifest(name), make_zip({"index.html": "x"}, raw_names=[("/tmp/evil.html", "x")]), 422, "bundle_invalid"),
        ("symlink", manifest(name), make_zip({"index.html": "x"}, symlinks=[("link", "/etc/passwd")]), 422, "bundle_invalid"),
        ("unpacked-size bomb", manifest(name), bomb, 413, "bundle_unpacked_too_large"),
        ("missing entry", manifest(name), make_zip({"main.html": "x"}), 422, "entry_missing"),
        ("missing custom entry", manifest(name, 'entry = "game.html"'), ok_zip, 422, "entry_missing"),
        ("bad name", manifest("Bad_Name"), ok_zip, 422, "manifest_invalid"),
        ("reserved name", manifest("deploy"), ok_zip, 422, "manifest_invalid"),
        ("unknown key", manifest(name, 'entyr = "index.html"'), ok_zip, 422, "manifest_invalid"),
        ("header newline", manifest(name, '[headers.custom]\n"X-Evil" = "a\\nb"'), ok_zip, 422, "manifest_invalid"),
        ("header placeholder", manifest(name, '[headers.custom]\n"X-Evil" = "{env.GAMEHOST_ADMIN_TOKEN}"'), ok_zip, 422, "manifest_invalid"),
        ("not a zip", manifest(name), b"definitely not a zip", 422, "bundle_invalid"),
    ]
    for label, m, bundle, status, code in cases:
        r = deploy(m, bundle)
        eq(r.status, status, f"{label}: {r}")
        eq(r.code, code, f"{label}: {r}")

    # Oversize upload: refused by Caddy's request_body limit and/or the API's streaming limit.
    r = deploy(manifest(name), os.urandom((MAX_UPLOAD_MB + 2) * 1024 * 1024))
    assert r.status in (413, 0), f"oversize: {r}"

    eq(api("GET", f"/api/sites/{name}").json()["current_release"], before)
    eq(site_get(name).body, b"good")


@test
def t09_token_scoping():
    a, b = f"scope-a-{RUN}", f"scope-b-{RUN}"
    tok_a = create_site(a)
    create_site(b)
    eq(deploy(manifest(b), make_zip({"index.html": "b"})).status, 201)
    eq(deploy(manifest(a), make_zip({"index.html": "a"}), token=tok_a).status, 201)
    r = deploy(manifest(b), make_zip({"index.html": "hijack"}), token=tok_a)
    eq(r.status, 403, str(r))
    eq(api("POST", f"/api/sites/{b}/rollback", token=tok_a).status, 403)
    eq(api("GET", f"/api/sites/{b}", token=tok_a).status, 403)
    eq(api("GET", f"/api/sites/{a}", token=tok_a).status, 200)
    eq(api("GET", "/api/sites", token=tok_a).status, 403)
    eq(api("POST", "/api/sites", token=tok_a, body={"name": f"new-{RUN}"}).status, 403)
    eq(api("DELETE", f"/api/sites/{a}", token=tok_a).status, 403)
    eq(api("GET", "/api/sites", token=None).status, 401)
    garbage = api("GET", "/api/sites", token="gh_garbage")
    eq(garbage.status, 401)
    eq(garbage.code, "unauthorized")
    eq(deploy(manifest(a), make_zip({"index.html": "a"}), token="gh_garbage").status, 401)
    eq(site_get(b).body, b"b")
    # Rotation kills the old token immediately.
    rot = api("POST", f"/api/sites/{a}/token")
    eq(rot.status, 200)
    eq(api("GET", f"/api/sites/{a}", token=tok_a).status, 401)
    eq(api("GET", f"/api/sites/{a}", token=rot.json()["token"]).status, 200)


@test
def t10_deploy_to_uncreated_site():
    r = deploy(manifest(f"never-{RUN}"), make_zip({"index.html": "x"}))
    eq(r.status, 404, str(r))
    eq(r.code, "site_not_found")
    eq(api("POST", "/api/sites", body={"name": f"dup-{RUN}"}).status, 201)
    dup = api("POST", "/api/sites", body={"name": f"dup-{RUN}"})
    eq(dup.status, 409)
    eq(dup.code, "site_exists")


@test
def t11_concurrent_deploys():
    name = f"concurrent-{RUN}"
    create_site(name)
    rnd = random.Random(1)
    words = ["".join(rnd.choice("abcdefghij") for _ in range(8)) for _ in range(5000)]
    js = " ".join(rnd.choice(words) for _ in range(600_000)).encode()  # ~5 MB; slow at Brotli 11
    results = []

    def go(i):
        results.append(deploy(manifest(name), make_zip({"index.html": f"c{i}", "engine.js": js + str(i).encode()})))

    threads = [threading.Thread(target=go, args=(i,)) for i in range(2)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    eq(sorted(r.status for r in results), [201, 409], str(results))
    eq([r.code for r in results if r.status == 409], ["deploy_in_progress"])


@test
def t12_restart_preserves_sites():
    cmd = os.environ.get("GAMEHOST_TEST_RESTART_CMD")
    if not cmd:
        raise Skip("GAMEHOST_TEST_RESTART_CMD not set")
    subprocess.run(cmd, shell=True, check=True)
    deadline = time.time() + 60
    while time.time() < deadline:
        try:
            if request("GET", API_HOST, "/healthz", timeout=2).status == 200:
                break
        except OSError:
            pass
        time.sleep(0.5)
    eq(site_get(f"basic-{RUN}").body, b"<html>hello v1</html>")
    eq(site_get(f"coi-on-{RUN}").headers.get("cross-origin-opener-policy"), "same-origin")
    check = os.environ.get("GAMEHOST_TEST_TMP_CHECK_CMD")
    if check:
        out = subprocess.run(check, shell=True, capture_output=True, text=True, check=True).stdout.strip()
        eq(out, "", "/data/tmp after restart")


@test
def t13_unknown_subdomain():
    eq(site_get(f"nope-{RUN}").status, 404)
    eq(request("GET", "something.else.example", "/").status, 404)


@test
def t15_previews():
    name = f"prev-{RUN}"
    tok = create_site(name)
    eq(deploy(manifest(name), make_zip({"index.html": "prod"}), token=tok).status, 201)
    r = deploy(manifest(name), make_zip({"index.html": "preview"}), token=tok, preview="feature-1")
    eq(r.status, 201, str(r))
    eq(r.json()["preview"], "feature-1")
    eq(site_get(f"{name}--feature-1").body, b"preview")
    eq(site_get(name).body, b"prod")
    eq(deploy(manifest(name), make_zip({"index.html": "x"}), token=tok, preview="Bad--Label").code, "preview_label_invalid")
    detail = api("GET", f"/api/sites/{name}", token=tok).json()
    eq([p["label"] for p in detail["previews"]], ["feature-1"])
    eq(api("DELETE", f"/api/sites/{name}/previews/feature-1", token=tok).status, 200)
    eq(site_get(f"{name}--feature-1").status, 404)
    eq(api("DELETE", f"/api/sites/{name}/previews/feature-1", token=tok).status, 404)


@test
def t16_delete_site():
    name = f"del-{RUN}"
    create_site(name)
    eq(deploy(manifest(name), make_zip({"index.html": "x"})).status, 201)
    eq(deploy(manifest(name), make_zip({"index.html": "p"}), preview="pr").status, 201)
    eq(api("DELETE", f"/api/sites/{name}").status, 200)
    eq(site_get(name).status, 404)
    eq(site_get(f"{name}--pr").status, 404)
    eq(api("GET", f"/api/sites/{name}").status, 404)


@test
def t99_auth_rate_limit():
    # Runs last: it blocks this client IP for a minute.
    statuses = [api("GET", "/api/sites", token=f"gh_wrong{i}").status for i in range(12)]
    assert statuses[:4] == [401] * 4, statuses
    eq(statuses[-1], 429, str(statuses))
    eq(api("GET", "/api/sites").status, 429, "even a valid token is refused while the IP is blocked")


def main():
    only = sys.argv[1:]
    failed = 0
    for fn in TESTS:
        if only and not any(o in fn.__name__ for o in only):
            continue
        start = time.time()
        try:
            fn()
            print(f"PASS {fn.__name__} ({time.time() - start:.1f}s)", flush=True)
        except Skip as s:
            print(f"SKIP {fn.__name__}: {s}", flush=True)
        except Exception:
            failed += 1
            print(f"FAIL {fn.__name__}", flush=True)
            traceback.print_exc()
    print("FAILED" if failed else "ALL PASSED", f"({failed} failures)")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
