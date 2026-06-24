# sigma-authoring — vendored from `twells89/sigma-skills`

The skills under `skills/` (`sigma-workbooks`, `sigma-data-models`,
`custom-sql-to-data-model`) are **vendored copies** of the canonical
`twells89/sigma-skills` repo. They live here so the migration converters'
hard dependency on `sigma-workbooks` (the canonical Sigma spec reference) ships
in the **same marketplace** — installing any converter, install this too.

- **Source of truth:** https://github.com/twells89/sigma-skills (edit there)
- **Vendored at:** sigma-skills `3d4d812`

## Refresh

Re-vendor when the canonical skills change:

```sh
SRC=/path/to/sigma-skills    # a fresh clone of twells89/sigma-skills
for s in sigma-workbooks sigma-data-models custom-sql-to-data-model; do
  rm -rf "plugins/sigma-authoring/skills/$s"
  cp -R "$SRC/$s" "plugins/sigma-authoring/skills/$s"
done
# then update the "Vendored at" SHA above and commit
```

Do NOT edit these copies directly — changes belong upstream in `sigma-skills`,
then re-vendor here.
