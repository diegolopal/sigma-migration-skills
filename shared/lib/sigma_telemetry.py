"""
Drop-in telemetry client for Sigma migration skills.

Usage:
    from sigma_telemetry import report_migration

    start = time.time()
    # ... do migration ...
    report_migration(
        tool="metabase-to-sigma",
        sigma_base="https://api.au.aws.sigmacomputing.com",
        client_id=os.environ["SIGMA_CLIENT_ID"],
        duration_seconds=int(time.time() - start),
        success=True,
    )
"""

import hashlib
import re
import time
import os
import urllib.request
import urllib.error
import json

TELEMETRY_ENDPOINT = "https://sigma-migration-telemetry.onrender.com/track"
SKILL_VERSION = "1.0"


def _region_from_base(sigma_base: str) -> str:
    """Extract region slug from Sigma API base URL."""
    if ".au." in sigma_base:  return "au"
    if ".eu." in sigma_base:  return "eu"
    if ".uk." in sigma_base:  return "uk"
    if ".ca." in sigma_base:  return "ca"
    return "us"


def _org_hash(client_id: str) -> str:
    """Anonymous org fingerprint: first 8 hex chars of SHA256(client_id)."""
    return hashlib.sha256(client_id.encode()).hexdigest()[:8]


def report_migration(
    tool: str,
    sigma_base: str,
    client_id: str,
    duration_seconds: int,
    success: bool,
    mode: str = "unknown",
    skill_version: str = SKILL_VERSION,
    endpoint: str = TELEMETRY_ENDPOINT,
    timeout: int = 5,
) -> bool:
    """
    Fire-and-forget anonymous usage ping. Never raises — a telemetry failure
    must never block or fail a migration.

    What is sent:
      - tool name (e.g. "metabase-to-sigma")
      - Sigma region (derived from API base URL, e.g. "au")
      - org_id_hash: SHA256 of your SIGMA_CLIENT_ID, first 8 chars
          → unique per org, not reversible to your credentials
      - migration duration in seconds
      - success flag
      - input mode: "live" (source API), "file" (raw export only),
          "both", or "unknown" — a coarse enum, no file names or content
      - skill version

    What is NOT sent:
      - workbook names, IDs, or URLs
      - SQL queries or column names
      - dashboard or card titles
      - user email or name
      - any customer data or warehouse content
    """
    payload = {
        "event":            "migration_complete",
        "tool":             tool,
        "sigma_region":     _region_from_base(sigma_base),
        "org_id_hash":      _org_hash(client_id),
        "duration_seconds": duration_seconds,
        "success":          success,
        "mode":             mode or "unknown",
        "skill_version":    skill_version,
    }

    print("\nReporting anonymous migration telemetry (no customer data sent):")
    for k, v in payload.items():
        if k != "event":
            print(f"  {k}: {v}")

    body = json.dumps(payload).encode("utf-8")
    # Returns True on HTTP 2xx, False on any skip/failure. NEVER raises — telemetry
    # must never block or fail a migration. The caller writes an honest marker
    # ("sent" vs "skipped") based on this return (handoff FIX 3).
    return _post(endpoint, body, timeout)


def _ssl_context():
    """Prefer certifi's CA bundle — stock macOS / homebrew-python urllib often
    fails CERTIFICATE_VERIFY_FAILED against the endpoint where curl succeeds
    (handoff FIX 4). Fall back to the default context if certifi isn't present."""
    try:
        import ssl
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        try:
            import ssl
            return ssl.create_default_context()
        except Exception:
            return None


def _post(endpoint, body, timeout):
    # 1) urllib with a certifi-backed SSL context.
    try:
        req = urllib.request.Request(
            endpoint, data=body,
            headers={"Content-Type": "application/json"}, method="POST",
        )
        ctx = _ssl_context()
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            if 200 <= resp.status < 300:
                print(f"  → telemetry sent ({resp.status})\n")
                return True
            print(f"  → telemetry endpoint returned {resp.status} — skipped\n")
            return False
    except Exception as e:
        first = str(e).splitlines()[0] if str(e) else type(e).__name__
        # 2) Fall back to curl — succeeds on boxes where python's CA store is broken.
        try:
            import subprocess
            r = subprocess.run(
                ["curl", "-sS", "-m", str(timeout), "-o", "/dev/null",
                 "-w", "%{http_code}", "-X", "POST",
                 "-H", "Content-Type: application/json", "--data-binary", "@-", endpoint],
                input=body, capture_output=True, timeout=timeout + 5,
            )
            code = (r.stdout or b"").decode("ascii", "ignore").strip()
            if code.startswith("2"):
                print(f"  → telemetry sent ({code}, via curl)\n")
                return True
            print(f"  → telemetry unavailable (urllib: {first}; curl HTTP {code or 'n/a'}) — skipped\n")
            return False
        except Exception as e2:
            print(f"  → telemetry unavailable (urllib: {first}; curl: {str(e2).splitlines()[0]}) — skipped\n")
            return False
