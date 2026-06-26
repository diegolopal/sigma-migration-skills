#!/usr/bin/env ruby
# frozen_string_literal: true
# test-pbi-timeintel-route.rb — regression test for lib/pbi_timeintel_route.rb.
# Offline: no API, no creds. Run: ruby scripts/test-pbi-timeintel-route.rb
#
# Pins the live KitchenSink run-2 cross-fact mis-route: the prior-year SAFETY
# measure "PY Incident Count" was bound to the ABSENCE "Hours YTD" column because
# the fallback router scanned every synthesized time-intel element regardless of
# which fact it belonged to.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'pbi_timeintel_route'

$fail = 0
def ok(name, cond); puts((cond ? "  ok  " : "FAIL  ") + name); $fail += 1 unless cond; end

R = PbiTimeIntelRoute

# fact_of: a View denormalizes a fact; a plain table passes through.
ok('fact_of strips " View"',            R.fact_of('ABSENCE_RECORDS View') == 'ABSENCE_RECORDS')
ok('fact_of case-insensitive on View',  R.fact_of('Safety_Incidents view') == 'Safety_Incidents')
ok('fact_of leaves a plain table',      R.fact_of('SAFETY_INCIDENTS') == 'SAFETY_INCIDENTS')
ok('fact_of handles nil',               R.fact_of(nil) == '')

# same_fact?: only the SAME fact may share a time-intel element.
ok('SAFETY measure vs ABSENCE ti → NOT same fact (the run-2 bug)',
   R.same_fact?('SAFETY_INCIDENTS', 'ABSENCE_RECORDS') == false)
ok('SAFETY measure vs SAFETY ti → same fact',
   R.same_fact?('SAFETY_INCIDENTS', 'SAFETY_INCIDENTS') == true)
ok('whitespace/case tolerant',
   R.same_fact?('Order Fact', 'ORDER  FACT') == true)
ok('empty fact never matches',
   R.same_fact?('SAFETY_INCIDENTS', '') == false)

# --- routing simulation: mirror the gate in migrate-powerbi.rb. Only same-fact
# elements are considered; a SAFETY prior-year measure with only ABSENCE elements
# must find NO target (→ unresolved → honest coverage degradation).
TI = [
  { 'name' => 'YTD Absence Hours', 'fact' => 'ABSENCE_RECORDS',
    'cols' => [{ 'name' => 'Hours YTD', 'formula' => 'CumulativeSum([Hours])' }] },
  { 'name' => 'PY Absence Hours',  'fact' => 'ABSENCE_RECORDS',
    'cols' => [{ 'name' => 'Hours (Prior Year)', 'formula' => 'DateLookback([Hours],[Year],1,"year")' }] },
].freeze

def route(measure_table, ti_elements)
  ti_elements.find { |te| PbiTimeIntelRoute.same_fact?(measure_table, te['fact']) }
end

ok('PY Incident Count (SAFETY) routes to NO absence element',
   route('SAFETY_INCIDENTS', TI).nil?)
ok('an ABSENCE prior-year measure still routes to its own fact',
   route('ABSENCE_RECORDS', TI)&.fetch('name') == 'YTD Absence Hours')

puts $fail.zero? ? "\nall pbi-timeintel-route tests passed" : "\n#{$fail} FAILED"
exit($fail.zero? ? 0 : 1)
