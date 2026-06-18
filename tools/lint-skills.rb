#!/usr/bin/env ruby
# frozen_string_literal: true
#
# lint-skills.rb — conformance gate for migration skills (bead: skill-governance).
#
# Every converter SKILL.md must document the mandatory arc gates (see
# docs/phase-schema.md). This greps each skill for high-signal evidence of each
# gate and fails the PR if a NEW skill (or an edit) drops one. Known, accepted
# gaps are recorded in tools/skill-lint-baseline.json so they show as tracked
# WARNINGS rather than failures — clear that backlog by fixing the skill and
# removing the baseline entry.
#
#   ruby tools/lint-skills.rb            # lint; non-zero on un-baselined gap
#
# Creds-free, stdlib-only — safe for the corpus-check workflow.

require 'json'

ROOT = File.expand_path('..', __dir__)
Dir.chdir(ROOT)

baseline_path = 'tools/skill-lint-baseline.json'
BASELINE = File.exist?(baseline_path) ? JSON.parse(File.read(baseline_path)) : {}

# Each rule: id, description, and a regex whose presence in SKILL.md is the
# evidence the gate exists. Patterns are deliberately broad (any documented
# phrasing counts) — the goal is "did the author drop a whole gate", not style.
CONVERTER_RULES = [
  ['reuse-check',     'C3 reuse-check (avoid DM sprawl)',     /find-or-pick|reuse|pick (an?|existing).*(data model|\bdm\b)/i],
  ['post-dm-readback','C5 POST DM + read back real ids',      /read[- ]?back/i],
  ['layout-last',     'C7 layout applied as the LAST write',  /apply-layout|put-layout|layout\.xml|last write|newspaper layout|layout.*(last|after)/i],
  ['parity-gate',     'C8 parity hard gate',                  /parit/i],
  ['security-rls',    'C9 RLS/CLS detection',                 /\bRLS\b|\bCLS\b|row.?level security|column.?level security|security:/i],
]

# Repo-level: the canonical Rosetta stone (docs/phase-schema.md) maps each
# converter's local phase numbers to the C1–C10 arc. Its mapping-table column
# headers are the exact skill dir names, so a converter missing from the doc is
# a converter nobody can cross-reference. New skills MUST be added there.
PHASE_SCHEMA = 'docs/phase-schema.md'

# Skills that are NOT full converters and are exempt from the converter ruleset.
def classify(dir)
  base = File.basename(dir)
  return :assessment if base.end_with?('-assessment')
  return :bridge     if base.end_with?('-to-cdw')   # data-landing, builds no workbook
  return :converter  if base.end_with?('-to-sigma')
  :other
end

skills = Dir.glob('plugins/*/skills/*').select { |d| File.file?("#{d}/SKILL.md") }.sort

fails = []   # [skill, rule_id, desc]
warns = []   # [skill, rule_id, desc, reason]
ok = 0

schema_body = File.exist?(PHASE_SCHEMA) ? File.read(PHASE_SCHEMA) : ''

skills.each do |dir|
  next unless classify(dir) == :converter
  body = File.read("#{dir}/SKILL.md")
  name = File.basename(dir)
  checks = CONVERTER_RULES.map { |id, desc, pat| [id, desc, body.match?(pat)] }
  # repo-level coverage check folded in per-skill so it reports against the skill
  checks << ['phase-schema-coverage', 'listed in docs/phase-schema.md mapping', schema_body.include?(name)]
  checks.each do |id, desc, present|
    next if present
    reason = BASELINE.dig(name, id)
    if reason
      warns << [name, id, desc, reason]
    else
      fails << [name, id, desc]
    end
  end
  ok += 1
end

unless warns.empty?
  puts "Tracked baseline gaps (WARN — fix and remove from #{baseline_path}):"
  warns.each { |n, id, desc, r| puts "  ~ #{n}: #{desc}\n      #{r}" }
  puts
end

if fails.empty?
  puts "OK: #{ok} converter SKILL.md files document all mandatory gates (#{warns.size} tracked baseline gaps)."
  exit 0
end

puts "SKILL CONFORMANCE FAILURE"
puts "A converter SKILL.md is missing a mandatory gate (docs/phase-schema.md)."
puts "Fix the skill, or — if genuinely N/A — add it to #{baseline_path} with a reason."
puts
fails.each { |n, id, desc| puts "  FAIL  #{n}: missing #{id} — #{desc}" }
puts
puts "failures: #{fails.size}"
exit 1
