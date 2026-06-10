# Fixtures — offline input sets

## retail-orders/
A complete Phase-1 discovery output for the **Retail Orders (Qlik)** demo app
(CSA.TJ star schema, sanitized demo data), captured live 2026-06-10 with
`scripts/qlik-discover.py`. Includes `converter-out.json` (the
convert_qlik_to_sigma result) so the offline path needs neither qlik-cli, the
node converter build, nor network access.

| file | producer | consumed by |
|---|---|---|
| `script.qvs` | `qlik app script get` | reconcile-columns.py |
| `measures.json` / `dimensions.json` | Engine MeasureList/DimensionList | build-sigma-dm.py |
| `charts.json` | object properties (dims/measures/labels/formats/sort) | build-sigma-workbook.py |
| `layout.json` | per-sheet cell grids (col/row/colspan/rowspan) | build-sigma-workbook.py (layout) |
| `app-meta.json` | REST item record (lastReloadTime, Section Access, DirectQuery) | freshness preflight |
| `snapshot.json` | `qlik app eval` of every sheet KPI + Max(date) | freshness preflight |
| `converter-input.json` | discovery | convert_qlik_to_sigma |
| `converter-out.json` | convert_qlik_to_sigma | build-sigma-dm.py |

## Offline smoke (no Qlik tenant, no Sigma org, no network)

```bash
ruby scripts/migrate-qlik.rb \
  --from-discovery fixtures/retail-orders \
  --connection 00000000-0000-0000-0000-000000000000 \
  --dry-run --yes --out /tmp/qlik-smoke
```

Expected: all 6 phases run; `/tmp/qlik-smoke/` gains `dm-spec.json` (7 elements:
6 repointed star tables + denorm SQL element with 13 metrics), `wb-spec.json`
(6 pages, 35 elements, 15 KPIs), `layout.xml` (6 `<Page>` grids), and
`element-map.json`; exit code 0. Nothing is POSTed.
