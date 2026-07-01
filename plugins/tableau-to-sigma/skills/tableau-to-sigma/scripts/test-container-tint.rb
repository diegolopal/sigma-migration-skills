#!/usr/bin/env ruby
# Regression test for B2 (gap beads-sigma-ubr5.6): container background tints.
# A Tableau dashboard zone with a <zone-style> fill (a region-card tint) must
# become a Sigma GridContainer with style.backgroundColor + borderRadius. Before
# this the layout builder emitted every container plain (no fill).
#
# End-to-end through the ACTUAL parse-twb-layout.rb + build-dashboard-layout.rb
# (no Tableau/Sigma calls): a tinted layout-flow container (8-digit-alpha teal
# #07b4a24e + teal border) wrapping a chart → assert the emitted container spec
# (in <out>.elements.json) carries backgroundColor + borderColor + borderRadius.
#
# Usage:  ruby scripts/test-container-tint.rb

require 'json'
require 'tmpdir'

DIR    = __dir__
PARSER = File.join(DIR, 'parse-twb-layout.rb')
BUILD  = File.join(DIR, 'build-dashboard-layout.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook>
    <datasources>
      <datasource caption='Sales' name='federated.x'>
        <column caption='Region' name='[Region]' datatype='string' role='dimension' />
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Sales by Region'><table><view><datasource-dependencies datasource='federated.x' /></view></table></worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='Regions'>
        <zones>
          <zone id='1' type-v2='layout-basic' x='0' y='0' w='100000' h='100000'>
            <zone id='2' type-v2='layout-flow' param='vert' x='0' y='0' w='50000' h='100000'>
              <zone-style>
                <format attr='background-color' value='#07b4a24e' />
                <format attr='border-color' value='#07b4a2' />
              </zone-style>
              <zone id='3' name='Sales by Region' x='0' y='0' w='50000' h='100000' />
            </zone>
          </zone>
        </zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

containers = []
Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb')
  lay = File.join(d, 'layout.json')
  out = File.join(d, 'layout.xml')
  File.write(twb, TWB)
  abort 'parse-twb-layout failed' unless system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)

  wb_ids = { 'pages' => [
    { 'name' => 'Data', 'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'Data' }] },
    { 'name' => 'Regions', 'elements' => [{ 'id' => 'el-chart', 'kind' => 'bar-chart', 'name' => 'Sales by Region' }] }
  ] }
  wbf = File.join(d, 'wb-ids.json')
  File.write(wbf, JSON.dump(wb_ids))
  system('ruby', BUILD, '--layout', lay, '--wb-ids', wbf, '--out', out, out: File::NULL, err: File::NULL)

  ef = "#{out}.elements.json"
  if File.exist?(ef)
    sidecar = JSON.parse(File.read(ef))
    sidecar.each_value { |els| containers.concat(els.select { |e| e['kind'] == 'container' }) }
  end
end

tinted = containers.find { |c| c.dig('style', 'backgroundColor') == '#07b4a24e' }
check(!tinted.nil?, "a container carries the zone tint backgroundColor '#07b4a24e' (8-digit alpha, verbatim)", fails)
check(tinted && tinted.dig('style', 'borderRadius') == 'round', "tinted container has borderRadius: round", fails)
check(tinted && tinted.dig('style', 'borderColor') == '#07b4a2', "tinted container carries borderColor from the zone", fails)
# The dark page-header container (HEADER_STYLE) must remain distinct from the tint.
check(containers.any? { |c| c.dig('style', 'backgroundColor') == '#0F172A' },
      "page header container still emitted (unaffected)", fails)

puts
if fails.empty?
  puts 'ALL PASS — B2 container tint emit'
  exit 0
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
