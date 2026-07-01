#!/usr/bin/env ruby
# Regression test for D1 + Pass-7 canvas (gaps beads-sigma-ubr5.15 / .6): the
# workbook theme derived from the parsed layout. build-workbook-spec.rb turns the
# outermost zone fill into themeOverrides.colorOverrides.backgroundCanvas and the
# tinted region-card container fills into themeOverrides.categoricalScheme (the
# SOURCE mark palette — 8-digit-alpha tint #07b4a24e → base #07b4a2).
#
# Exercises the pure derive_theme(layout) helper directly (no live POST).
# Usage:  ruby scripts/test-theme-derivation.rb
require 'json'

DIR = __dir__
SRC = File.read(File.join(DIR, 'build-workbook-spec.rb'))
m = SRC.match(/^def derive_theme\b.*?\n^end$/m) or abort('could not extract derive_theme')
eval(m[0]) # rubocop:disable Security/Eval — test-only extraction of first-party code

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Mirrors the benchmark: a white-canvas dashboard, 4 region cards tinted with
# 8-digit-alpha region hues, plus a grey solid KPI card (must NOT enter the scheme).
LAYOUT = [{
  'dashboard' => 'Job Losses',
  'zone_tree' => [{
    'id' => '1', 'kind' => 'container', 'fill_color' => '#ffffff', 'children' => [
      { 'id' => 'kpi', 'kind' => 'container', 'fill_color' => '#e6e6e6' }, # grey solid → excluded
      { 'id' => 'south', 'kind' => 'container', 'caption' => 'South',    'fill_color' => '#07b4a24e' },
      { 'id' => 'west',  'kind' => 'container', 'caption' => 'West',     'fill_color' => '#e8519a4e' },
      { 'id' => 'ne',    'kind' => 'container', 'caption' => 'Northeast','fill_color' => '#827bb84e' },
      { 'id' => 'mw',    'kind' => 'container', 'caption' => 'Midwest',  'fill_color' => '#f28e2b4e' }
    ]
  }]
}]

theme = derive_theme(LAYOUT)

check(theme['backgroundCanvas'] == '#ffffff',
      "canvas = outermost zone fill (got #{theme['backgroundCanvas'].inspect})", fails)
check(theme['categoricalScheme'] == %w[#07b4a2 #e8519a #827bb8 #f28e2b],
      "categoricalScheme = source region bases, alpha stripped, in order (got #{theme['categoricalScheme'].inspect})", fails)
check(!(theme['categoricalScheme'] || []).include?('#e6e6e6'),
      "grey solid KPI-card fill excluded from the scheme", fails)

# No styled containers → no theme (Sigma defaults; never worse).
plain = derive_theme([{ 'dashboard' => 'X', 'zone_tree' => [
  { 'id' => '1', 'kind' => 'container', 'children' => [{ 'id' => 'c', 'kind' => 'chart' }] }
] }])
check(plain == {}, "unstyled dashboard → empty theme (got #{plain.inspect})", fails)

# Single tinted card → no categoricalScheme (needs the multi-member pattern).
one = derive_theme([{ 'dashboard' => 'X', 'zone_tree' => [
  { 'id' => '1', 'kind' => 'container', 'fill_color' => '#07b4a24e' }
] }])
check(one['categoricalScheme'].nil?, "single tinted container → no scheme (needs >=2)", fails)

# Dedup: same base at two alphas collapses to one scheme entry.
dup = derive_theme([{ 'dashboard' => 'X', 'zone_tree' => [
  { 'id' => 'a', 'kind' => 'container', 'fill_color' => '#07b4a24e' },
  { 'id' => 'b', 'kind' => 'container', 'fill_color' => '#07b4a21b' },
  { 'id' => 'c', 'kind' => 'container', 'fill_color' => '#e8519a4e' }
] }])
check(dup['categoricalScheme'] == %w[#07b4a2 #e8519a], "same base at 2 alphas dedups (got #{dup['categoricalScheme'].inspect})", fails)

puts
if fails.empty?
  puts 'ALL PASS — D1/Pass-7 theme derivation (canvas + region palette)'
  exit 0
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
