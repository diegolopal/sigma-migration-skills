#!/usr/bin/env ruby
# frozen_string_literal: true
# Unit test for the manual-path JSON-spec ingestion binding (MechanicalSpecs.
# bind_manual_wb_spec) — proves the agent-authored --wb-spec placeholders bind to
# the live readback ids, and that an unresolved DM-element ref aborts loudly
# (no silent misbind). See migrate-tableau.rb --dm-spec/--wb-spec.
require 'json'
require_relative 'mechanical-specs'

failures = 0
def check(desc, ok)
  puts "#{ok ? 'ok  ' : 'FAIL'} - #{desc}"
  ok
end

dm_els = [
  { 'name' => 'Order Fact View', 'id' => 'el-fact-123' },
  { 'name' => 'Customer Dim',    'id' => 'el-cust-456' }
]

wb = {
  'name' => 'Manual WB',
  'pages' => [
    { 'id' => 'p1', 'name' => 'Dash', 'elements' => [
      { 'id' => 'k1', 'kind' => 'kpi-chart',
        'source' => { 'kind' => 'data-model', 'dataModelId' => '__DM_ID__', 'elementId' => '__DM_ELEMENT__:__FACT__' } },
      { 'id' => 't1', 'kind' => 'table',
        'source' => { 'kind' => 'data-model', 'dataModelId' => '__DM_ID__', 'elementId' => '__DM_ELEMENT__:Customer Dim' } }
    ] }
  ]
}

bound = MechanicalSpecs.bind_manual_wb_spec(wb, dm_id: 'dm-789', fact_eid: 'el-fact-123', dm_els: dm_els)
els = bound['pages'][0]['elements']
failures += 1 unless check('__DM_ID__ → live dataModelId', els[0]['source']['dataModelId'] == 'dm-789')
failures += 1 unless check('__DM_ELEMENT__:__FACT__ → fact_eid', els[0]['source']['elementId'] == 'el-fact-123')
failures += 1 unless check('__DM_ELEMENT__:<name> → readback id (case-insensitive)', els[1]['source']['elementId'] == 'el-cust-456')
failures += 1 unless check('input spec is not mutated in place', wb['pages'][0]['elements'][0]['source']['dataModelId'] == '__DM_ID__')

# Unresolved element reference must raise (loud, no silent misbind).
raised = begin
  MechanicalSpecs.bind_manual_wb_spec(
    { 'pages' => [{ 'elements' => [{ 'source' => { 'elementId' => '__DM_ELEMENT__:No Such Element' } }] }] },
    dm_id: 'dm-789', fact_eid: 'el-fact-123', dm_els: dm_els)
  false
rescue RuntimeError => e
  e.message.include?('No Such Element')
end
failures += 1 unless check('unresolved __DM_ELEMENT__ raises with the missing name', raised)

# A spec with no placeholders is returned unchanged.
plain = { 'pages' => [{ 'elements' => [{ 'source' => { 'elementId' => 'literal-id' } }] }] }
failures += 1 unless check('non-placeholder values pass through untouched',
                           MechanicalSpecs.bind_manual_wb_spec(plain, dm_id: 'x', fact_eid: 'y', dm_els: dm_els) == plain)

puts(failures.zero? ? "\nALL PASS" : "\n#{failures} FAILURE(S)")
exit(failures.zero? ? 0 : 1)
