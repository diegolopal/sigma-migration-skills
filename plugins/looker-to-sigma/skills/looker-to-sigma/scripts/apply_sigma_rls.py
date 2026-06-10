#!/usr/bin/env python3
"""Phase 1.5 (RLS decision gate) — apply a Looker RLS finding to Sigma, scripted.

Sigma user attributes are FULLY API-supported (confirmed live 2026-06-10):
  - GET  /v2/user-attributes            list (reuse-first)
  - POST /v2/user-attributes            create
  - POST /v2/user-attributes/{id}/users assign a value to a member
And the Sigma RLS row-filter is fully spec-expressible (NOT UI-only): a boolean
calc column `CurrentUserAttributeText("<attr>") = [<Field>]` on the base element
plus an element `filters` entry `{kind:list, mode:include, values:[true]}`.

This script does the whole flow, REUSE-FIRST and SAFE-BY-DEFAULT:
  1. attribute   GET /v2/user-attributes → print a match if one already exists
                 (by name, case-insensitive) before creating anything.
  2. provision   --create  → POST /v2/user-attributes when nothing reusable exists.
                 --assign   → POST /v2/user-attributes/{id}/users (needs --member-id
                 + --value) to assign the attribute value to a member.
  3. apply       --field <DisplayName> (+ --element-id/--dm-id) → print the RLS
                 calc-column + element-filter spec snippet; with --apply, PATCH it
                 into the DM element's spec (GET/PUT /v2/dataModels/{id}/spec).

By default this only READS and PRINTS a plan — it mutates ONLY when you pass an
explicit --create / --assign / --apply flag. Mirrors post_dm.py: reads
$SIGMA_BASE_URL / $SIGMA_API_TOKEN from env (eval "$(scripts/get-token.sh)").
Dependency-free (stdlib only).

Live-validated: this exact flow produced exact 3-way parity (Looker-restricted ==
Sigma-restricted == warehouse: $38,906.82 / 220 rows, region=West).

Usage:
  eval "$(scripts/get-token.sh)"
  # reuse-first lookup only (default, read-only):
  python3 apply_sigma_rls.py --attr region
  # create the attribute if missing:
  python3 apply_sigma_rls.py --attr region --value West --create
  # assign a value to the querying member:
  python3 apply_sigma_rls.py --attr region --value West --member-id <id> --assign
  # print the RLS spec snippet for a DM element (plan only):
  python3 apply_sigma_rls.py --attr region --field Region --element-id <eid>
  # ...and PATCH it into the DM element spec:
  python3 apply_sigma_rls.py --attr region --field Region --element-id <eid> \
      --dm-id <dataModelId> --apply
"""
import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

BASE = os.environ.get("SIGMA_BASE_URL")
TOK = os.environ.get("SIGMA_API_TOKEN")


def api(method, path, body=None):
    if not BASE or not TOK:
        sys.exit("SIGMA_BASE_URL / SIGMA_API_TOKEN unset — run: eval \"$(scripts/get-token.sh)\"")
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        BASE + path, data=data, method=method,
        headers={"Authorization": "Bearer " + TOK, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read().decode()
    except urllib.error.HTTPError as e:
        print("HTTP", e.code, method, path, "->", e.read().decode()[:1000], file=sys.stderr)
        raise
    try:
        return json.loads(raw)
    except Exception:
        return raw  # spec endpoints return YAML


def _short_id(prefix="rls"):
    """A short, deterministic-enough id for a calc column / filter."""
    import hashlib
    return prefix + "-" + hashlib.md5(prefix.encode() + os.urandom(4)).hexdigest()[:8]


# --- 1. reuse-first attribute lookup --------------------------------------
def find_attribute(name):
    """Return the existing user-attribute entry matching `name` (case-insensitive), else None."""
    res = api("GET", "/v2/user-attributes?limit=200")
    entries = res.get("entries", res.get("data", [])) if isinstance(res, dict) else []
    for e in entries:
        if (e.get("name") or "").lower() == name.lower():
            return e
    return None


def list_attributes():
    res = api("GET", "/v2/user-attributes?limit=200")
    return res.get("entries", res.get("data", [])) if isinstance(res, dict) else []


# --- 3. RLS spec snippet --------------------------------------------------
def rls_spec_snippet(attr, field, element_id):
    """The verified row-filter shape: a boolean calc column + an element list filter showing only True."""
    col_id = _short_id("rlscol")
    filt_id = _short_id("rlsf")
    calc = {
        "id": col_id,
        "name": f"RLS {attr}",
        "formula": f'CurrentUserAttributeText("{attr}") = [{field}]',
    }
    filt = {
        "id": filt_id,
        "columnId": col_id,
        "kind": "list",
        "mode": "include",
        "values": [True],
    }
    return {
        "elementId": element_id,
        "calcColumn": calc,
        "filter": filt,
        "_note": (
            f'Add calcColumn to element "{element_id}" columns, and `filter` to that '
            f"element's filters[]. CurrentUserAttributeText(\"{attr}\") = [{field}] is the "
            "user-attribute mode; team mode = CurrentUserInTeam([...]); email mode = "
            "[Email] = CurrentUserEmail()."
        ),
    }


def apply_to_dm(dm_id, element_id, calc, filt):
    """PATCH the calc column + filter into the DM element's spec (GET → mutate → PUT)."""
    spec = api("GET", f"/v2/dataModels/{dm_id}/spec")
    if not isinstance(spec, dict):
        # spec endpoints can return YAML; we can't safely mutate that here.
        sys.exit("DM spec came back non-JSON (YAML) — cannot auto-PATCH; apply the snippet by hand.")
    # The spec shape nests elements under the model; search for the element by id.
    found = _inject(spec, element_id, calc, filt)
    if not found:
        sys.exit(f"element id {element_id} not found in DM {dm_id} spec — check --element-id")
    res = api("PUT", f"/v2/dataModels/{dm_id}/spec", spec)
    print("PUT /v2/dataModels/%s/spec ->" % dm_id,
          json.dumps(res)[:300] if isinstance(res, dict) else str(res)[:300])


def _inject(node, element_id, calc, filt):
    """Recursively find an element dict whose id == element_id; add calc col + filter. Returns True if injected."""
    if isinstance(node, dict):
        if node.get("id") == element_id and ("columns" in node or "kind" in node or "source" in node):
            cols = node.setdefault("columns", [])
            if not any(c.get("id") == calc["id"] for c in cols if isinstance(c, dict)):
                cols.append(calc)
            filters = node.setdefault("filters", [])
            filters.append(filt)
            return True
        for v in node.values():
            if _inject(v, element_id, calc, filt):
                return True
    elif isinstance(node, list):
        for v in node:
            if _inject(v, element_id, calc, filt):
                return True
    return False


def main():
    ap = argparse.ArgumentParser(description="Apply a Looker RLS finding to Sigma (safe-by-default).")
    ap.add_argument("--attr", required=True, help="Sigma user-attribute name (e.g. region)")
    ap.add_argument("--value", help="attribute value (for --create defaultValue / --assign)")
    ap.add_argument("--description", help="description when creating the attribute")
    ap.add_argument("--member-id", help="Sigma memberId to assign the value to (with --assign)")
    ap.add_argument("--field", help="DM column display name to filter on (e.g. Region) — for the RLS snippet")
    ap.add_argument("--element-id", help="DM element id the RLS calc col + filter attach to")
    ap.add_argument("--dm-id", help="dataModelId (with --apply, to PATCH the element spec)")
    ap.add_argument("--create", action="store_true", help="create the user attribute if no reusable match")
    ap.add_argument("--assign", action="store_true", help="assign --value to --member-id")
    ap.add_argument("--apply", action="store_true", help="PATCH the RLS calc col + filter into the DM element spec")
    a = ap.parse_args()

    # --- 1. reuse-first --------------------------------------------------
    existing = find_attribute(a.attr)
    attr_id = None
    if existing:
        attr_id = existing.get("userAttributeId") or existing.get("id")
        print(f"REUSE: user attribute '{a.attr}' already exists "
              f"(id={attr_id}, default={existing.get('defaultValue')}) — reusing, NOT creating.")
    else:
        print(f"No existing Sigma user attribute named '{a.attr}'.")
        if a.create:
            body = {"name": a.attr}
            if a.description:
                body["description"] = a.description
            if a.value is not None:
                body["defaultValue"] = {"val": a.value, "type": "string"}
            res = api("POST", "/v2/user-attributes", body)
            attr_id = res.get("userAttributeId") or res.get("id") if isinstance(res, dict) else None
            print(f"CREATED user attribute '{a.attr}' (id={attr_id}).")
        else:
            print("  (plan only — pass --create to create it.)")

    # --- 2. assign -------------------------------------------------------
    if a.assign:
        if not attr_id:
            sys.exit("--assign needs an attribute id — create/reuse it first (no id resolved).")
        if not a.member_id or a.value is None:
            sys.exit("--assign requires --member-id and --value.")
        body = {"assignments": [{"userId": a.member_id, "value": {"val": a.value, "type": "string"}}]}
        res = api("POST", f"/v2/user-attributes/{attr_id}/users", body)
        print(f"ASSIGNED '{a.attr}'={a.value} to member {a.member_id}: "
              + (json.dumps(res)[:200] if isinstance(res, dict) else str(res)[:200]))
    elif a.value is not None and a.member_id:
        print(f"  (plan: would assign '{a.attr}'={a.value} to member {a.member_id} — pass --assign.)")

    # --- 3. RLS spec snippet --------------------------------------------
    if a.field:
        if not a.element_id:
            print("\nNOTE: --field given without --element-id; printing the formula only.")
            print(f'  calc column formula: CurrentUserAttributeText("{a.attr}") = [{a.field}]')
        else:
            snip = rls_spec_snippet(a.attr, a.field, a.element_id)
            print("\nRLS spec snippet (verified shape — boolean calc col + element list filter on True):")
            print(json.dumps(snip, indent=2))
            if a.apply:
                if not a.dm_id:
                    sys.exit("--apply requires --dm-id.")
                apply_to_dm(a.dm_id, a.element_id, snip["calcColumn"], snip["filter"])
            else:
                print("  (plan only — pass --apply --dm-id <id> to PATCH it into the DM element spec.)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
