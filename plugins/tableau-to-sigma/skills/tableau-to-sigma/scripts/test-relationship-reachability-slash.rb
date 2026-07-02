#!/usr/bin/env ruby
# frozen_string_literal: true
# Regression test for relationship_reachability_violations (2026-07-01).
# Deterministic + offline.
#
# Guards the false-positive class: a real Snowflake column whose NAME contains a
# literal '/' (e.g. "Margin Pct H/L") makes a 2-segment
# [Element/Column] ref look like a 3-segment [Base/REL/Field] relationship path.
# The reachability guard split on '/' and flagged "Margin Pct
# T" as a missing relationship, failing an otherwise-clean conversion.
#
# The fix: if the tail after the base names a real COLUMN on the base element,
# it's a column ref, not a relationship path — no violation. Genuine unreachable
# relationships must still be caught.
#
# Usage:  ruby scripts/test-relationship-reachability-slash.rb

require_relative 'mechanical-specs'

fails = []
def check(c, m, fails) fails << m unless c; puts "  #{c ? 'PASS' : 'FAIL'}  #{m}"; end

# Base element with a slash-bearing column and a few real relationships (mirrors
# the incident: an extract-backed element whose rels are CUSTOMER/PRODUCT/…).
SLASH_COL = 'Margin Pct H/L'
base = {
  'id' => 'e-sales', 'name' => 'SALES',
  'source' => { 'kind' => 'warehouse-table', 'path' => %w[DB PUBLIC SALES] },
  'columns' => [
    { 'id' => 'c-slash', 'name' => SLASH_COL },
    { 'id' => 'c-amt',   'name' => 'Amount' }
  ],
  'relationships' => [
    { 'name' => 'CUSTOMER' }, { 'name' => 'PRODUCT' },
    { 'name' => 'REGION' },    { 'name' => 'ORDER DATE' }
  ]
}

def model_with(base, formula)
  { 'pages' => [{ 'elements' => [
    base,
    { 'id' => 'e-derived', 'name' => 'Derived',
      'source' => { 'kind' => 'table', 'elementId' => 'e-sales' },
      'columns' => [{ 'id' => 'd0', 'name' => 'D0', 'formula' => formula }] }
  ] }] }
end

puts 'Part A — slash-bearing column ref is NOT a false relationship violation'
v = MechanicalSpecs.relationship_reachability_violations(model_with(base, "[SALES/#{SLASH_COL}]"))
check(v.empty?, "no violation for [SALES/#{SLASH_COL}] (got #{v.inspect})", fails)

puts 'Part B — a genuine unreachable relationship is STILL flagged'
v = MechanicalSpecs.relationship_reachability_violations(model_with(base, '[SALES/Ghost Rel/Some Col]'))
check(v.any? { |s| s.include?('Ghost Rel') },
      "flags [SALES/Ghost Rel/Some Col] as unreachable (got #{v.inspect})", fails)

puts 'Part C — a valid relationship path is not flagged'
v = MechanicalSpecs.relationship_reachability_violations(model_with(base, '[SALES/CUSTOMER/Name]'))
check(v.empty?, "no violation for a real relationship path (got #{v.inspect})", fails)

puts
if fails.empty?
  puts 'ALL PASS — slash-column false positive fixed, real violations still caught'
  exit 0
else
  puts "FAILURES (#{fails.length}):"; fails.each { |f| puts "  - #{f}" }; exit 1
end
