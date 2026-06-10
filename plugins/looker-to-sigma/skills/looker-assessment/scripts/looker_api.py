#!/usr/bin/env python3
"""Minimal Looker API 4.0 client driven by ~/.looker/looker.ini (no SDK dep).

Usage:
  python3 looker_api.py whoami
  python3 looker_api.py get  /connections
  python3 looker_api.py post /connections '<json>'
  python3 looker_api.py put  /connections/<name>/test
  python3 looker_api.py raw  GET /lookml_models
"""
import json
import os
import sys
import urllib.parse
import urllib.request
from configparser import ConfigParser

INI = os.path.expanduser("~/.looker/looker.ini")


def _cfg():
    c = ConfigParser()
    c.read(INI)
    s = c["Looker"]
    base = s["base_url"].rstrip("/")
    if not base.endswith("/api/4.0"):
        base = base + "/api/4.0"
    return base, s["client_id"], s["client_secret"], s.getboolean("verify_ssl", True)


def _ctx(verify):
    import ssl
    if verify:
        return None
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def login():
    base, cid, csec, verify = _cfg()
    data = urllib.parse.urlencode({"client_id": cid, "client_secret": csec}).encode()
    req = urllib.request.Request(base + "/login", data=data, method="POST")
    with urllib.request.urlopen(req, context=_ctx(verify), timeout=30) as r:
        tok = json.load(r)["access_token"]
    return base, tok, verify


def call(method, path, body=None):
    base, tok, verify = login()
    if not path.startswith("/"):
        path = "/" + path
    url = base + path
    data = None
    headers = {"Authorization": "Bearer " + tok}
    if body is not None:
        data = body.encode() if isinstance(body, str) else json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, context=_ctx(verify), timeout=60) as r:
            raw = r.read().decode()
            code = r.status
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        code = e.code
    try:
        parsed = json.loads(raw)
    except Exception:
        parsed = raw
    return code, parsed


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "whoami"
    if cmd == "whoami":
        code, me = call("GET", "/user")
        _, roles = call("GET", "/user/roles")
        _, perms = call("GET", "/user/roles")  # placeholder
        print("HTTP", code)
        print("user:", me.get("display_name"), "| id", me.get("id"), "|", me.get("email"))
        if isinstance(roles, list):
            print("roles:", ", ".join(r.get("name", "?") for r in roles))
        else:
            print("roles raw:", roles)
    elif cmd == "raw":
        code, out = call(sys.argv[2].upper(), sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else None)
        print("HTTP", code)
        print(json.dumps(out, indent=2)[:6000])
    else:  # get/post/put/patch/delete
        code, out = call(cmd.upper(), sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
        print("HTTP", code)
        print(json.dumps(out, indent=2)[:8000] if not isinstance(out, str) else out[:8000])
