#!/usr/bin/env ruby
# Regression test for Phase-1 B4 styled-text extraction in parse-twb-layout.rb.
# A Tableau dashboard text/title zone carries its content as run-level formatted
# text — one <run> per style span, with U+00C6 (Æ) as the in-text line-break
# sentinel (the actual newline rides alongside as &#10;):
#
#   <zone type-v2='text' …><formatted-text>
#     <run bold='true' fontcolor='#1b1b1b' fontsize='24'>Job Losses</run>
#     <run bold='true' fontsize='16'>Æ </run>          ← whitespace spacer (keeps run spacing)
#     <run fontcolor='#333333'>from Deportations</run>
#     <run>Æ&#10;</run>                                ← hard line break
#     <run fontcolor='#333333'>Estimating the job loss …</run>
#   </formatted-text></zone>
#
# Asserts, end-to-end through the ACTUAL parse-twb-layout.rb (no Tableau/Sigma
# calls), that the parser now surfaces these signals (previously dropped — text
# zones had no `name`, so `caption` was nil and nothing backed them):
#   1. flat `zones`: a text zone carries a structured `text_runs` array with
#      per-run text / color / font_size / bold.
#   2. the Æ+newline sentinel run is flagged break=true (paragraph separator).
#   3. an Æ+whitespace spacer run keeps its literal whitespace text (inter-run
#      spacing is preserved, not swallowed).
#   4. a zone-style text-align=center surfaces as text_align (left is omitted —
#      it is Sigma's default and 400s if forced).
#   5. a short single-run text zone with a solid fill is flagged is_pill.
#   6. a left-aligned / unstyled text zone does NOT carry text_align.
#   7. the nested `zone_tree` text node also carries text_runs.
#   8. a chart zone does NOT get text_runs (extraction is text/title-only).
#
# Usage:  ruby scripts/test-styled-text-extraction.rb

require 'json'
require 'tmpdir'

DIR    = __dir__
PARSER = File.join(DIR, 'parse-twb-layout.rb')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Mirrors the "Job Loss from Mass Deportations" benchmark: a multi-run hero
# title/subtitle text zone, a center-aligned "Learn More" pill (single run +
# fill), a plain credit line, and a chart zone (must stay text_runs-free).
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
            <zone id='10' type-v2='text' x='0' y='0' w='50000' h='15000'>
              <formatted-text>
                <run bold='true' fontcolor='#1b1b1b' fontsize='24'>Job Losses</run>
                <run bold='true' fontsize='16'>Æ </run>
                <run fontcolor='#333333' fontsize='12'>from Deportations</run>
                <run>Æ&#10;</run>
                <run fontcolor='#333333'>Estimating the job loss.</run>
              </formatted-text>
            </zone>
            <zone id='11' type-v2='text' x='50000' y='0' w='15000' h='6000'>
              <zone-style>
                <format attr='background-color' value='#fbe7a8' />
                <format attr='text-align' value='center' />
              </zone-style>
              <formatted-text>
                <run bold='true' fontcolor='#333333'>Learn More</run>
              </formatted-text>
            </zone>
            <zone id='12' type-v2='text' x='0' y='90000' w='50000' h='4000'>
              <formatted-text>
                <run fontcolor='#b4b4b4' fontsize='8'>Data: EPI.org | Design: @DatavizChimdi</run>
              </formatted-text>
            </zone>
            <zone id='5' name='Sales by Region' x='0' y='20000' w='100000' h='60000' />
          </zone>
        </zones>
      </dashboard>
    </dashboards>
  </workbook>
XML

layout = nil
Dir.mktmpdir do |d|
  twb = File.join(d, 'wb.twb')
  lay = File.join(d, 'layout.json')
  File.write(twb, TWB)
  abort 'parse-twb-layout failed' unless system('ruby', PARSER, twb, lay, out: File::NULL, err: File::NULL)
  layout = JSON.parse(File.read(lay))
end

dash  = (layout || []).find { |x| x['dashboard'] == 'Regions' }
zones = (dash && dash['zones']) || []

# ---- 1. hero text zone: structured runs with text / color / size / bold ----
z10  = zones.find { |z| z['id'] == '10' }
runs = z10 && z10['text_runs']
check(runs.is_a?(Array) && runs.size == 5,
      "flat zones: hero text zone yields a text_runs array (got #{runs && runs.size} runs)", fails)
r0 = runs && runs[0]
check(r0 && r0['text'] == 'Job Losses' && r0['color'] == '#1b1b1b' && r0['font_size'] == 24 && r0['bold'] == true,
      "flat zones: first run keeps text/color/font_size/bold (got #{r0.inspect})", fails)

# ---- 2. Æ+newline sentinel run is flagged break=true -----------------------
brk = runs && runs.find { |r| r['break'] }
check(brk && brk['text'].include?("\n"),
      "flat zones: Æ+newline run flagged break=true with the newline (got #{brk.inspect})", fails)

# ---- 3. Æ+whitespace spacer keeps its literal whitespace text --------------
spacer = runs && runs[1]
check(spacer && spacer['text'] == ' ' && spacer['break'] != true,
      "flat zones: Æ+whitespace spacer keeps literal ' ' and is not a break (got #{spacer.inspect})", fails)

# ---- 4. zone-style text-align=center surfaces; sentinel Æ is stripped -------
check(z10 && z10['text_runs'].none? { |r| r['text'].include?("Æ") },
      'flat zones: the Æ sentinel char is stripped from every run text', fails)
z11 = zones.find { |z| z['id'] == '11' }
check(z11 && z11['text_align'] == 'center',
      "flat zones: zone-style text-align=center → text_align (got #{z11 && z11['text_align'].inspect})", fails)

# ---- 5. short single-run + fill → is_pill ----------------------------------
check(z11 && z11['is_pill'] == true,
      "flat zones: single-run text zone with a fill is flagged is_pill (got #{z11 && z11['is_pill'].inspect})", fails)

# ---- 6. plain/left text zone carries no text_align -------------------------
z12 = zones.find { |z| z['id'] == '12' }
check(z12 && z12['text_runs'] && z12['text_align'].nil?,
      "flat zones: left/default-aligned credit zone has runs but no text_align (got #{z12 && z12['text_align'].inspect})", fails)
check(z12 && z12['is_pill'].nil?,
      "flat zones: credit zone (no fill) is not a pill (got #{z12 && z12['is_pill'].inspect})", fails)

# ---- 7. nested zone_tree text node also carries runs -----------------------
tree = (dash && dash['zone_tree']) || []
def find_zone(nodes, id)
  nodes.each do |n|
    return n if n['id'] == id
    r = find_zone(n['children'] || [], id)
    return r if r
  end
  nil
end
t10 = find_zone(tree, '10')
check(t10 && t10['text_runs'].is_a?(Array) && t10['text_runs'].size == 5,
      "zone_tree: nested text node carries text_runs (got #{t10 && t10['text_runs']&.size})", fails)

# ---- 8. a chart zone does NOT get text_runs --------------------------------
z5 = zones.find { |z| z['id'] == '5' }
check(z5 && z5['text_runs'].nil?,
      "flat zones: chart zone is not given text_runs (got #{z5 && z5['text_runs'].inspect})", fails)

puts
if fails.empty?
  puts 'ALL PASS — Phase-1 B4 styled-text extraction works'
  exit 0
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
