#!/usr/bin/env ruby
# frozen_string_literal: true
# test-pbi-element-match.rb — regression test for lib/pbi_element_match.rb.
# Offline: no API, no creds. Run: ruby scripts/test-pbi-element-match.rb
#
# Pins the live KitchenSink contract run-2 failure: a DM POST floated the nameless
# DimDate Custom SQL element to the FRONT of the readback, so a positional index
# bound it to SAFETY_INCIDENTS and overwrote that master's 8 base columns with 4
# date-hierarchy cols → POST "Dependency not found: 'safety_incidents/year'".
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'pbi_element_match'

$fail = 0
def ok(name, cond); puts((cond ? "  ok  " : "FAIL  ") + name); $fail += 1 unless cond; end

# --- run-2 ground truth (names + ids), exactly as captured from dm-raw.json /
# dm-readback.json. CONVERTER order has the nameless SQL element at idx 3; the
# POSTED READBACK floats it to idx 0 and assigns fresh ids.
CONV = [
  { 'name' => 'EMPLOYEES',            'id' => 'c-emp' },
  { 'name' => 'ABSENCE_RECORDS',      'id' => 'c-abs' },
  { 'name' => 'SAFETY_INCIDENTS',     'id' => 'c-saf' },
  { 'name' => nil,                    'id' => 'ilkqRTsLzU' }, # DimDate spine (nameless)
  { 'name' => 'EMPLOYEES View',       'id' => 'c-empv' },
  { 'name' => 'ABSENCE_RECORDS View', 'id' => 'c-absv' },
  { 'name' => 'SAFETY_INCIDENTS View','id' => 'c-safv' },
  { 'name' => 'YTD Absence Hours',    'id' => 'c-ytd' },
  { 'name' => 'PY Absence Hours',     'id' => 'c-py' },
  { 'name' => 'Dense Rank DEPARTMENT','id' => 'c-dr1' },
  { 'name' => 'Dense Rank DEPARTMENT 2', 'id' => 'c-dr2' },
].freeze

READBACK = [
  { 'name' => nil,                    'id' => 'WdTXIPR-xf' }, # POST floated nameless to front
  { 'name' => 'EMPLOYEES',            'id' => 'HIg5RXBtF6' },
  { 'name' => 'ABSENCE_RECORDS',      'id' => 'GCkMYGTS2s' },
  { 'name' => 'SAFETY_INCIDENTS',     'id' => 'ayk9b6xcXm' },
  { 'name' => 'EMPLOYEES View',       'id' => 'Q8zpKF0Ul8' },
  { 'name' => 'ABSENCE_RECORDS View', 'id' => 'CaKAtlAm53' },
  { 'name' => 'SAFETY_INCIDENTS View','id' => 'ytfP0hb3HP' },
  { 'name' => 'YTD Absence Hours',    'id' => 'OQ3ZWIc1Fv' },
  { 'name' => 'PY Absence Hours',     'id' => '_HfO_10O0y' },
  { 'name' => 'Dense Rank DEPARTMENT','id' => 'u3gEIc9Otk' },
  { 'name' => 'Dense Rank DEPARTMENT 2', 'id' => 'J1BMo5DGVx' },
].freeze

pairing = PbiElementMatch.pair(CONV, READBACK)

# The bug: nameless converter element (idx 3) must NOT bind to SAFETY_INCIDENTS.
nameless_dmel = pairing[3]
ok('nameless converter element pairs to the nameless readback element',
   nameless_dmel && nameless_dmel['id'] == 'WdTXIPR-xf')
ok('nameless converter element does NOT hijack SAFETY_INCIDENTS (the run-2 bug)',
   nameless_dmel && nameless_dmel['name'].to_s.empty?)

# The real SAFETY_INCIDENTS converter element keeps its own DM element.
saf = pairing[2]
ok('SAFETY_INCIDENTS pairs to its own readback element (ayk9b6xcXm)',
   saf && saf['id'] == 'ayk9b6xcXm' && saf['name'] == 'SAFETY_INCIDENTS')

# Every NAMED converter element pairs to the like-named readback element.
named_ok = CONV.each_with_index.all? do |cel, i|
  next true if PbiElementMatch.nameless?(cel)
  pairing[i] && pairing[i]['name'] == cel['name']
end
ok('every named converter element pairs to its like-named readback element', named_ok)

# No two converter elements collapse onto the same readback element (1:1).
ids = pairing.map { |d| d && d['id'] }
ok('pairing is 1:1 — no readback element claimed twice', ids.compact.uniq.length == ids.compact.length)

# --- second fixture: no reorder + a single nameless at the end still works.
CONV2 = [{ 'name' => 'FACT', 'id' => 'a' }, { 'name' => nil, 'id' => 'b' }]
RB2   = [{ 'name' => 'FACT', 'id' => 'A' }, { 'name' => nil, 'id' => 'B' }]
p2 = PbiElementMatch.pair(CONV2, RB2)
ok('trailing nameless element binds to the nameless readback', p2[1]['id'] == 'B')
ok('named FACT still binds by name', p2[0]['id'] == 'A')

puts $fail.zero? ? "\nall pbi-element-match tests passed" : "\n#{$fail} FAILED"
exit($fail.zero? ? 0 : 1)
