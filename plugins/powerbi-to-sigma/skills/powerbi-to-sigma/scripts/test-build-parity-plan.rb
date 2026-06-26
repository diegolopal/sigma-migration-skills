#!/usr/bin/env ruby
# test-build-parity-plan.rb — unit test for build-parity-plan.rb (raw-mode helper,
# handoff FIX 1). Offline: reads a synthetic spec via --workbook-spec, never the API.
# Canonical in shared/scripts. Run: ruby scripts/test-build-parity-plan.rb
require 'json'
require 'tmpdir'
require 'rbconfig'

BPP  = File.join(__dir__, 'build-parity-plan.rb')
RUBY = RbConfig.ruby
$fail = 0
def ok(name, cond); puts((cond ? "  ok  " : "FAIL  ") + name); $fail += 1 unless cond; end

SPEC = { 'pages' => [{ 'elements' => [
  { 'id' => 'el-master', 'kind' => 'table', 'visibleAsSource' => false, 'columns' => [{ 'id' => 'm1', 'name' => 'X' }] },
  { 'id' => 'el-ctl', 'kind' => 'list-control', 'columns' => [{ 'id' => 'c1', 'name' => 'Region' }] },
  { 'id' => 'el-txt', 'kind' => 'text', 'columns' => [] },
  { 'id' => 'el-kpi', 'kind' => 'kpi-chart', 'name' => 'Net Revenue',
    'columns' => [{ 'id' => 'v1', 'name' => 'Net Revenue' }], 'value' => { 'columnId' => 'v1' } },
  { 'id' => 'el-bar', 'kind' => 'bar-chart', 'name' => 'Sales by Region',
    'columns' => [{ 'id' => 'x1', 'name' => 'Region' }, { 'id' => 'y1', 'name' => 'Sales' }, { 'id' => 'h1', 'name' => 'Hidden' }],
    'xAxis' => { 'columnId' => 'x1' }, 'yAxis' => { 'columnIds' => [{ 'columnId' => 'y1' }] } },
] }] }

Dir.mktmpdir do |d|
  File.write(File.join(d, 'spec.json'), JSON.generate(SPEC))
  out = File.join(d, 'parity-plan.json')
  emit = File.join(d, 'wb-readback.json')
  st = system(RUBY, BPP, '--workbook-id', 'WB', '--workbook-spec', File.join(d, 'spec.json'),
              '--out', out, '--emit-spec', emit, out: File::NULL, err: File::NULL)
  ok('exit 0', st)
  plan = JSON.parse(File.read(out))['charts']
  names = plan.map { |c| c['sigma_element_id'] }.sort
  ok('only the 2 visible charts (master/control/text excluded)', names == %w[el-bar el-kpi])
  bar = plan.find { |c| c['sigma_element_id'] == 'el-bar' }
  ok('plotted channels only (hidden filter h1 excluded)', bar['sigma_columns'].sort == %w[x1 y1])
  kpi = plan.find { |c| c['sigma_element_id'] == 'el-kpi' }
  ok('kpi value column captured', kpi['sigma_columns'] == ['v1'])
  ok('emit-spec wrote wb-readback {pages:[...]}', JSON.parse(File.read(emit)).key?('pages'))
end

# zero chartable elements → exit 2
Dir.mktmpdir do |d|
  File.write(File.join(d, 'spec.json'), JSON.generate('pages' => [{ 'elements' => [{ 'id' => 't', 'kind' => 'text', 'columns' => [] }] }]))
  st = system(RUBY, BPP, '--workbook-id', 'WB', '--workbook-spec', File.join(d, 'spec.json'),
              '--out', File.join(d, 'p.json'), out: File::NULL, err: File::NULL)
  ok('zero charts → exit 2', !st && $?.exitstatus == 2)
end

puts $fail.zero? ? "\nall build-parity-plan tests passed" : "\n#{$fail} FAILED"
exit($fail.zero? ? 0 : 1)
