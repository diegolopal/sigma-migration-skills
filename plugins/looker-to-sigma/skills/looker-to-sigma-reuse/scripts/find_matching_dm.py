#!/usr/bin/env python3
"""Search Sigma for Data Models matching a Looker explore's tables.

Usage:
    python3 find_matching_dm.py --tables "dim_sl_accounts_scd,fact_account_usage"
    python3 find_matching_dm.py --explore "fact_account_usage"

Requires: SIGMA_API_TOKEN and SIGMA_BASE_URL environment variables.
Use with cortex secret run to inject credentials.
"""

import argparse
import json
import os
import sys
import urllib.request

BASE_URL = os.environ.get("SIGMA_BASE_URL", "https://aws-api.sigmacomputing.com")
TOKEN = os.environ.get("SIGMA_API_TOKEN", "")

# Common DATAWAREHOUSE -> ANALYTICS_DB table name mappings
TABLE_MAP = {
    "dim_sl_accounts_scd": "SNAPSHOT_DIM_SALESLOFT__USERS",
    "dim_sl_accounts_daily": "SNAPSHOT_DIM_SALESLOFT__USERS",
    "dim_sl_teams_scd": "SNAPSHOT_DIM_SALESLOFT__TEAMS",
    "dim_sl_teams_daily": "SNAPSHOT_DIM_SALESLOFT__TEAMS",
    "fact_account_usage": "RPT_SALESLOFT__TEAM_USAGE",
    "fact_teams_usage": "RPT_SALESLOFT__TEAM_USAGE",
    "dim_sl_crm_sync_settings_scd": "STG_MELODY__CRM_SYNC_SETTINGS",
    "dim_sfdc_accounts_scd": "SNAPSHOT_DIM__ACCOUNTS",
    "dim_sfdc_accounts_daily": "SNAPSHOT_DIM__ACCOUNTS",
}


def get_token():
    """Get token from env or exchange credentials."""
    if TOKEN:
        return TOKEN
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
    import base64
    creds = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
    req.add_header("Authorization", f"Basic {creds}")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read()).get("access_token", "")


def sigma_get(path, token):
    req = urllib.request.Request(
        f"{BASE_URL}{path}",
        headers={"Authorization": f"Bearer {token}"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def search_dms(query, token):
    """Search Sigma for data models matching a query."""
    encoded = urllib.parse.quote(query)
    try:
        resp = sigma_get(f"/v2/search?query={encoded}&entityTypes=dataModel&limit=10", token)
        return resp.get("entries", resp.get("results", []))
    except Exception as e:
        print(f"  Search error for '{query}': {e}", file=sys.stderr)
        return []


def map_table_names(tables):
    """Map DATAWAREHOUSE table names to ANALYTICS_DB equivalents."""
    mapped = []
    for t in tables:
        t_lower = t.lower().strip()
        if t_lower in TABLE_MAP:
            mapped.append(TABLE_MAP[t_lower])
        else:
            mapped.append(t.upper())
    return mapped


def main():
    parser = argparse.ArgumentParser(description="Find Sigma DMs matching Looker explore tables")
    parser.add_argument("--tables", help="Comma-separated Looker table names")
    parser.add_argument("--explore", help="Looker explore name")
    args = parser.parse_args()

    if not args.tables and not args.explore:
        parser.error("Provide --tables and/or --explore")

    token = get_token()
    import urllib.parse

    search_terms = []
    if args.explore:
        search_terms.append(args.explore.replace("_", " "))

    if args.tables:
        tables = [t.strip() for t in args.tables.split(",")]
        analytics_tables = map_table_names(tables)
        for t in analytics_tables:
            search_terms.append(t.replace("_", " ").replace("SNAPSHOT ", "").replace("STG ", "").replace("RPT ", ""))

    all_results = {}
    for term in search_terms:
        print(f"Searching: '{term}'...", file=sys.stderr)
        results = search_dms(term, token)
        for r in results:
            dm_id = r.get("inodeId", r.get("id", ""))
            if dm_id not in all_results:
                all_results[dm_id] = {
                    "id": dm_id,
                    "name": r.get("name", ""),
                    "url": r.get("url", ""),
                    "description": r.get("description", "")[:200],
                    "match_count": 0,
                    "matched_terms": [],
                }
            all_results[dm_id]["match_count"] += 1
            all_results[dm_id]["matched_terms"].append(term)

    ranked = sorted(all_results.values(), key=lambda x: x["match_count"], reverse=True)

    print("\n=== MATCHING SIGMA DATA MODELS ===\n")
    for i, dm in enumerate(ranked[:10], 1):
        print(f"{i}. {dm['name']} (matches: {dm['match_count']})")
        print(f"   ID: {dm['id']}")
        print(f"   URL: {dm['url']}")
        print(f"   Matched on: {', '.join(dm['matched_terms'])}")
        if dm["description"]:
            print(f"   Description: {dm['description']}")
        print()


if __name__ == "__main__":
    main()
