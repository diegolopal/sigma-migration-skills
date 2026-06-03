# Qlik connection — qlik-cli

Discovery uses **qlik-cli** (official; reaches both the REST API and the Engine/qix
API — the Engine API is required for sheet/chart defs, the data model, and the load
script, which plain REST can't return).

## Install
GitHub release binary (brew tap was empty): download `qlik-Darwin-x86_64.tar.gz`
from `qlik-oss/qlik-cli` releases → `~/.local/bin/qlik` (runs via Rosetta on arm64).

## Auth — context
```bash
# API key (simplest, acts as you):
qlik context create <ctx> --server https://<tenant>.<region>.qlikcloud.com --api-key '<KEY>'
# OR OAuth M2M (service identity):
qlik context create <ctx> --server https://<tenant>… --oauth-client-id <ID> --oauth-client-secret <SECRET>
qlik context use <ctx>
qlik item ls --resourceType app --limit 20   # connectivity check
```
Create an API key under Profile settings → API keys; an M2M OAuth client under
Administration → OAuth (Web client, ✅ Machine-to-machine, consent → **Trusted**).
**Never put the secret in chat — create the context in your own terminal.**

## Two M2M gotchas (cost real time on the first engagement)
1. **Visibility:** a plain M2M client is a service identity — it only sees content
   in **spaces it's a member of**, never personal-space apps. If `item ls` is empty,
   grant the client a space role (or move apps to a shared space).
2. **Reload:** a plain M2M client **cannot reload** an app that loads via a space
   data-connection — the reload fails `Connector <name> not found` even with a
   producer role (a real-user reload of the same app works). Connection injection
   needs a real-user context. Fix: reload as a real user (UI/API-key context) or use
   an **M2M-impersonation** client. *Discovery/extraction is unaffected — only reload.*

## Discovery commands
```bash
qlik app script get  -a <appId>              # load script (the data-model source of truth)
qlik app object ls   -a <appId>              # sheets + chart objects (NOT master items)
qlik app object get  <objId> -a <appId>      # full props: qHyperCubeDef / qMeasure / qDim
```
Master measures/dimensions aren't listed by `object ls`; read by id with `object get`,
or enumerate via an Engine `MeasureList`/`DimensionList` session object.
