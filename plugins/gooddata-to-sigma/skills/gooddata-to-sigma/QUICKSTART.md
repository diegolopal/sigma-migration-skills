# gooddata-to-sigma — quickstart

## 1. Credentials

Create a GoodData API token (GoodData UI → personal access tokens, or the
organization API). Then either export or drop a `~/.gooddata_env`:

```bash
export GOODDATA_HOST='https://<org>.cloud.gooddata.com'
export GOODDATA_TOKEN='<api-token>'
export GOODDATA_WORKSPACE='<workspace-id>'   # optional default
```

## 2. Discover (validate auth first)

```bash
cd skills/gooddata-to-sigma/scripts
eval "$(./get-token.sh)"
python3 discover.py --list                       # list workspaces
python3 discover.py --workspace <id>             # → workspace_layout.json + summary
```

The summary prints dataset/metric/insight/dashboard counts, a MAQL-keyword
histogram (sizes the translation effort), and an insight-type histogram.

## 3. Sigma side

Set up Sigma API credentials via the **sigma-api** skill, then follow the phases
in `SKILL.md`. Data-model authoring uses **sigma-data-models**; workbook
authoring uses **sigma-workbooks**. Parity runs against the same warehouse
GoodData reads.

## Status

Spike + scaffold only. The converter (LDM→DM mapper, MAQL translator,
insight/dashboard→workbook builder, parity scripts) is **not built yet** — see
`refs/design-notes.md` for the build order. First milestone: a live trial
workspace through Phase 1.
