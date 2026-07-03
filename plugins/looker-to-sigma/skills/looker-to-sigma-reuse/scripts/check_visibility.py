#!/usr/bin/env python3
"""Check visibility of elements in a Sigma Data Model.

Shows which elements are visible (usable as workbook source) vs hidden,
and lists relationships from each visible element.

Usage:
    python3 check_visibility.py --dm-id <data_model_id>

Requires: SIGMA_API_TOKEN and SIGMA_BASE_URL environment variables.
"""

import argparse
import json
import os
import re
import sys
import urllib.request

BASE_URL = os.environ.get("SIGMA_BASE_URL", "https://aws-api.sigmacomputing.com")
TOKEN = os.environ.get("SIGMA_API_TOKEN", "")


def get_token():
    if TOKEN:
        return TOKEN
    import base64
    client_id = os.environ.get("SIGMA_CLIENT_ID", "")
    client_secret = os.environ.get("SIGMA_CLIENT_SECRET", "")
    if not client_id or not client_secret:
        print("ERROR: Set SIGMA_API_TOKEN or SIGMA_CLIENT_ID + SIGMA_CLIENT_SECRET", file=sys.stderr)
        sys.exit(1)
    data = "grant_type=client_credentials".encode()
    req = urllib.request.Request(
        f"{BASE_URL}/v2/auth/token",
        data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    creds = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
    req.add_header("Authorization", f"Basic {creds}")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read()).get("access_token", "")


def get_dm_spec(dm_id, token):
    """GET the DM spec as raw YAML text."""
    req = urllib.request.Request(
        f"{BASE_URL}/v2/dataModels/{dm_id}/spec",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/yaml"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8")


def parse_elements(spec_text):
    """Parse elements from YAML spec to extract id, name, visibility, relationships."""
    elements = []
    current = None

    for line in spec_text.split("\n"):
        # New element
        m = re.match(r"      - id: (.+)", line)
        if m:
            if current:
                elements.append(current)
            current = {
                "id": m.group(1).strip(),
                "name": "",
                "visible": True,
                "relationships": [],
                "source_path": [],
            }
            continue

        if current is None:
            continue

        # Element name
        m = re.match(r"        name: (.+)", line)
        if m and not current["name"]:
            current["name"] = m.group(1).strip()

        # Visibility
        if "visibleAsSource: false" in line:
            current["visible"] = False

        # Source path
        m = re.match(r"            - (.+)", line)
        if m and "path" in spec_text[max(0, spec_text.find(line) - 100):spec_text.find(line)]:
            current["source_path"].append(m.group(1).strip())

        # Relationship target
        m = re.match(r"            targetElementId: (.+)", line)
        if m:
            current["relationships"].append({"targetId": m.group(1).strip(), "targetName": ""})

    if current:
        elements.append(current)

    # Resolve relationship target names
    id_to_name = {e["id"]: e["name"] for e in elements}
    for e in elements:
        for rel in e["relationships"]:
            rel["targetName"] = id_to_name.get(rel["targetId"], rel["targetId"])

    return elements


def main():
    parser = argparse.ArgumentParser(description="Check DM element visibility")
    parser.add_argument("--dm-id", required=True, help="Sigma Data Model ID")
    args = parser.parse_args()

    token = get_token()
    spec_text = get_dm_spec(args.dm_id, token)
    elements = parse_elements(spec_text)

    print("=== DATA MODEL ELEMENT VISIBILITY ===\n")

    visible = [e for e in elements if e["visible"]]
    hidden = [e for e in elements if not e["visible"]]

    print(f"VISIBLE elements ({len(visible)}) -- safe to use as workbook source:")
    for e in visible:
        print(f"  * {e['name']} (id: {e['id']})")
        if e["relationships"]:
            print(f"    Relationships to:")
            for rel in e["relationships"]:
                target_vis = "VISIBLE" if any(h["id"] == rel["targetId"] and h["visible"] for h in elements) else "hidden"
                print(f"      -> {rel['targetName']} ({target_vis})")
    print()

    print(f"HIDDEN elements ({len(hidden)}) -- access via relationships only:")
    for e in hidden:
        print(f"  x {e['name']} (id: {e['id']})")
    print()

    if visible:
        print("=== RECOMMENDED SOURCE ===")
        best = max(visible, key=lambda e: len(e["relationships"]))
        print(f"Use: {best['name']} (id: {best['id']})")
        print(f"  Has {len(best['relationships'])} relationships to access hidden element columns")
        print(f"  Formula pattern: [{best['name']}/<RelTargetName>/<Column Display Name>]")


if __name__ == "__main__":
    main()
