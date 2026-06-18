<!-- See CONTRIBUTING.md. Keep one PR = one plugin (or one isolated shared-lib change). -->

## What & why

<!-- One-paragraph summary. Link the bead: beads-sigma-XXXX -->

## Scope

- Plugin(s) touched:
- [ ] This PR touches exactly one plugin **or** is an isolated shared-lib change (not both)

## Checklist

- [ ] `ruby tools/check-shared.rb` — green (shared libs edited via `shared/` + `tools/sync-shared.rb`, never a copy)
- [ ] `ruby tools/lint-skills.rb` — green (mandatory gates documented; new gaps justified in the baseline)
- [ ] `./corpus/run-corpus.sh --check` — green; affected case reconverted if a converter/builder changed
- [ ] Phase numbers unchanged (or new skill added to `docs/phase-schema.md`)
- [ ] No unrelated working-tree changes swept in (`git status` is clean of other sessions' WIP)

## If this changes a shared lib

- [ ] Edited the canonical copy under `shared/` and ran `tools/sync-shared.rb`
- [ ] This is a standalone PR (no feature work mixed in)

## If this adds a converter

- [ ] Scaffolded with `tools/new-skill.rb`; marketplace entry + AGENTS.md row + corpus case added
