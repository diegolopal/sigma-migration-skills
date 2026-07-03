#!/usr/bin/env ruby
# End-to-end test for B4 (gap ubr5.8) styled static text: parse → build-charts →
# build-dashboard-layout (no Tableau/Sigma calls). A dashboard text zone that
# carries run-level formatting must (1) be EMITTED by build-charts as a Sigma
# `text` element (id "text-<zoneid>") with a color/size-span body, and (2) be
# PLACED by the layout stage at the text zone's own geometry — while the
# dedicated title element still owns the header band (header pinning: a bare
# first-text-element match would otherwise grab the styled text once it exists).
#
# Usage:  ruby scripts/test-styled-text-layout.rb

require 'json'
require 'rexml/document'
require 'tmpdir'

DIR    = __dir__
PARSER = File.join(DIR, 'parse-twb-layout.rb')
CHARTS = File.join(DIR, 'build-charts-from-signals.rb')
LAYOUT = File.join(DIR, 'build-dashboard-layout.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# A dashboard whose <zones> root container holds a chart, a Region filter (forces
# the container-tree layout path), and a styled text zone (bold label + hard
# break + muted annotation) mirroring the benchmark's region-card annotations.
TWB = <<~XML
  <?xml version='1.0' encoding='utf-8' ?>
  <workbook>
    <datasources>
      <datasource caption='ORDER_FACT' name='federated.fact'>
        <connection class='federated'>
          <named-connections>
            <named-connection name='snow'><connection class='snowflake' dbname='CSA' schema='TJ' /></named-connection>
          </named-connections>
          <relation connection='snow' name='ORDER_FACT' table='[TJ].[ORDER_FACT]' type='table' />
        </connection>
        <column caption='Gross Revenue' name='[m-gr]' datatype='real' role='measure' type='quantitative' />
        <column caption='Region' name='[m-reg]' datatype='string' role='dimension' type='nominal' />
      </datasource>
    </datasources>
    <worksheets>
      <worksheet name='Sales by Region'>
        <table>
          <view>
            <datasource-dependencies datasource='federated.fact'>
              <column caption='Gross Revenue' name='[m-gr]' datatype='real' role='measure' type='quantitative' />
              <column caption='Region' name='[m-reg]' datatype='string' role='dimension' type='nominal' />
              <column-instance column='[m-reg]' derivation='None' name='[none:m-reg:nk]' pivot='key' type='nominal' />
              <column-instance column='[m-gr]' derivation='Sum' name='[sum:m-gr:qk]' pivot='key' type='quantitative' />
            </datasource-dependencies>
          </view>
          <rows>[federated.fact].[sum:m-gr:qk]</rows>
          <cols>[federated.fact].[none:m-reg:nk]</cols>
          <pane><mark class='Bar' /></pane>
        </table>
      </worksheet>
    </worksheets>
    <dashboards>
      <dashboard name='Story'>
        <zones>
          <zone id='1' type-v2='layout-basic' x='0' y='0' w='100000' h='100000'>
            <zone id='2' type-v2='layout-flow' param='vert' x='0' y='0' w='30000' h='100000'>
              <zone id='3' type-v2='filter' param='[federated.fact].[none:m-reg:nk]' x='0' y='0' w='30000' h='20000' />
              <zone id='6' type-v2='text' x='0' y='20000' w='30000' h='15000'>
                <formatted-text>
                  <run bold='true' fontcolor='#1f8a70' fontsize='13'>Total Job Losses</run>
                  <run>Æ&#10;</run>
                  <run fontcolor='#666666' fontsize='10'>40% of U.S. total</run>
                </formatted-text>
              </zone>
            </zone>
            <zone id='5' name='Sales by Region' x='30000' y='0' w='70000' h='100000' />
          </zone>
        </zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

MASTER_MAP = {
  '(?i)^Gross Revenue$' => { 'id' => 'm-gr',  'name' => 'Gross Revenue' },
  '(?i)^Region$'        => { 'id' => 'm-reg', 'name' => 'Region' }
}

specs = nil
charts_log = ''
build_log = ''
xml_doc = nil
Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb')
  lay = File.join(d, 'layout.json')
  mm  = File.join(d, 'master-map.json')
  File.write(twb, TWB)
  File.write(mm, JSON.dump(MASTER_MAP))
  # get-workbook view list + empty CSV (chart rebuilds from .twb signals).
  File.write(File.join(d, 'get-workbook.json'),
             JSON.dump('views' => { 'view' => [{ 'id' => 'v1', 'name' => 'Sales by Region' }] }))
  Dir.mkdir(File.join(d, 'views'))
  File.write(File.join(d, 'views', 'v1.csv'), '')
  abort 'parse-twb-layout failed' unless system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)

  out = File.join(d, 'specs.json')
  charts_log = `ruby #{CHARTS} --tableau-dir #{d} --layout #{lay} --meta #{lay.sub(/\.json$/, '-meta.json')} --master-map #{mm} --master-element-id master --title Story --out #{out} 2>&1`
  specs = JSON.parse(File.read(out)) if File.exist?(out)

  # Synthesize the workbook readback (wb-ids) from the emitted flat element list:
  # a Data page (master table) + the dashboard page carrying every emitted
  # element's id/kind/name — exactly what build-dashboard-layout consumes.
  flat = specs.is_a?(Array) ? specs : (specs['elements'] || [])
  page_els = flat.map { |e| { 'id' => e['id'], 'kind' => e['kind'], 'name' => e['name'] } }
  wb_ids = { 'pages' => [
    { 'name' => 'Data',  'elements' => [{ 'id' => 'master', 'kind' => 'table', 'name' => 'Data' }] },
    { 'name' => 'Story', 'elements' => page_els }
  ] }
  wbf = File.join(d, 'wb-ids.json')
  lxml = File.join(d, 'layout.xml')
  File.write(wbf, JSON.dump(wb_ids))
  build_log = `ruby #{LAYOUT} --layout #{lay} --wb-ids #{wbf} --out #{lxml} 2>&1`
  if File.exist?(lxml)
    body = File.read(lxml).sub(/\A<\?xml[^>]*\?>\s*/, '')
    xml_doc = REXML::Document.new("<Root>#{body}</Root>")
  end
end

# ---- 1. build-charts EMITTED the styled text element -----------------------
flat  = specs && (specs.is_a?(Array) ? specs : (specs['elements'] || []))
txt   = flat && flat.find { |e| e['id'] == 'text-6' }
check(txt && txt['kind'] == 'text', "build-charts emitted text zone as element id 'text-6' (got #{txt && txt['kind'].inspect})", fails)
body  = txt && txt['body'].to_s
check(body.include?('<span style="color: #1f8a70; font-size: 13px">**Total Job Losses**</span>'),
      "emitted body carries the bold label span (got #{body.inspect})", fails)
check(body.include?("\n\n") && body.include?('40% of U.S. total'),
      'emitted body keeps the hard-break paragraph + annotation', fails)
# the title element is separate and header-bound
title = flat && flat.find { |e| e['id'] == 'title-text' }
check(title && title['kind'] == 'text', 'the dashboard title-text element is still emitted separately', fails)

# ---- 2. layout PLACED the text element at its zone geometry ----------------
gcs = xml_doc ? xml_doc.elements.to_a('//GridContainer') : []
def descendant_el_ids(gc)
  gc.elements.to_a('.//LayoutElement').map { |le| le.attributes['elementId'] }
end
all_placed = gcs.flat_map { |g| descendant_el_ids(g) }.uniq
check(all_placed.include?('text-6'), "layout placed the styled-text element 'text-6' (placed: #{all_placed.inspect})", fails)
check(build_log.include?('container-tree layout'), 'layout took the container-tree path', fails)

# text-6 lives INSIDE the same rail container as the Region control (its Tableau
# container), not loose at page root.
rail_gc = gcs.find do |g|
  ids = descendant_el_ids(g)
  ids.include?('text-6') && g.elements.to_a('.//GridContainer').empty?
end
check(!rail_gc.nil?, "styled text 'text-6' placed inside its Tableau container (the rail)", fails)

# ---- 3. header pinning: the title element owns the header, NOT the text -----
# The header band is the container wrapping the title-text element; text-6 must
# not be the one wrapped in the dark HEADER_STYLE band.
hdr = gcs.find { |g| descendant_el_ids(g) == ['title-text'] }
check(!hdr.nil?, 'header band wraps the dedicated title-text element', fails)
check(all_placed.count('text-6') >= 1 && !(hdr && descendant_el_ids(hdr).include?('text-6')),
      'the styled-text element is NOT mistaken for the header title', fails)

puts
if fails.empty?
  puts 'ALL PASS — B4 styled text: emitted by build-charts + placed at zone geometry by the layout (header pinned)'
  exit 0
else
  puts "FAILURES (#{fails.length}):"
  fails.each { |f| puts "  - #{f}" }
  puts "\n--- build-charts log (tail) ---\n#{charts_log.to_s.lines.last(8).join}"
  puts "\n--- layout log (tail) ---\n#{build_log.to_s.lines.last(8).join}"
  exit 1
end
