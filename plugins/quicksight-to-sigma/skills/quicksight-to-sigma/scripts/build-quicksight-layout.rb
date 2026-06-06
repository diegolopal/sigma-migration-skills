#!/usr/bin/env ruby
# build-quicksight-layout.rb
# Emit a Sigma layout XML for a QuickSight-derived workbook, faithfully mapping the
# QuickSight sheet layout to Sigma's 24-col grid (1-based grid lines).
#
# Handles:
#   - GridLayout (TILED) with explicit ColumnIndex/RowIndex/ColumnSpan/RowSpan (36-col grid)
#   - GridLayout auto-flow (spans only, no indices) → flow left-to-right, wrap by span
#   - FreeFormLayout (pixel X/Y/W/H) → normalized to the bounding box
#   - fallback: 2-per-row flow when no layout info is present
#
# Usage:
#   ruby scripts/build-quicksight-layout.rb --analysis DISCOVER_DIR/analysis.json \
#        --map /tmp/wb-spec.map.json --out /tmp/layout.xml
require 'json'
require 'optparse'
require_relative 'lib/layout'
include SigmaLayout

opts = {}
OptionParser.new do |o|
  o.on('--analysis F') { |v| opts[:an] = v }
  o.on('--map F') { |v| opts[:map] = v }
  o.on('--out F') { |v| opts[:out] = v }
end.parse!
%i[an map out].each { |k| abort "missing --#{k}" unless opts[k] }

defn = JSON.parse(File.read(opts[:an]))['Definition']
map = JSON.parse(File.read(opts[:map]))
v2e = map['visualToElement']             # QS VisualId -> Sigma element id
GRID = 36.0                              # QuickSight grid width
SIG = 24                                 # Sigma grid width

def num(s) # "120px" / "50%" / 120 -> float
  s.to_s.gsub(/[^0-9.\-]/, '').to_f
end

def scale_cols(x, w, canvas)
  c0 = (x.to_f / canvas * SIG).round + 1
  c1 = ((x.to_f + w.to_f) / canvas * SIG).round + 1
  c0 = 1 if c0 < 1
  c1 = c0 + 1 if c1 <= c0
  c1 = SIG + 1 if c1 > SIG + 1
  [c0, c1]
end

placed = []   # [elId, c0, c1, r0, r1]
sheet = defn['Sheets'][0] || {}
cfg = (sheet['Layouts'] || [{}])[0].fetch('Configuration', {})

if (g = cfg['GridLayout'])
  els = g['Elements'] || []
  explicit = els.any? { |e| !e['ColumnIndex'].nil? }
  if explicit
    els.each do |e|
      eid = v2e[e['ElementId']]; next unless eid
      c0, c1 = scale_cols(e['ColumnIndex'] || 0, e['ColumnSpan'] || 12, GRID)
      r0 = (e['RowIndex'] || 0) + 1
      r1 = r0 + (e['RowSpan'] || 8)
      placed << [eid, c0, c1, r0, r1]
    end
  else
    # auto-flow by span across the 36-col grid
    col = 0; row = 1; row_h = 0
    els.each do |e|
      eid = v2e[e['ElementId']]; next unless eid
      span = e['ColumnSpan'] || 18
      col = 0 if col + span > GRID
      row += row_h if col.zero? && row_h.positive?
      c0, c1 = scale_cols(col, span, GRID)
      h = (e['RowSpan'] || 12)
      placed << [eid, c0, c1, row, row + h]
      col += span; row_h = [row_h, h].max
      if col >= GRID
        col = 0; row += row_h; row_h = 0
      end
    end
  end
elsif (f = cfg['FreeFormLayout'])
  els = f['Elements'] || []
  cw = els.map { |e| num(e['XAxisLocation']) + num(e['Width']) }.max || 1.0
  ch_unit = 40.0 # ~px per Sigma row
  els.each do |e|
    eid = v2e[e['ElementId']]; next unless eid
    c0, c1 = scale_cols(num(e['XAxisLocation']), num(e['Width']), cw <= 0 ? 1 : cw)
    r0 = (num(e['YAxisLocation']) / ch_unit).round + 1
    r1 = r0 + [(num(e['Height']) / ch_unit).round, 4].max
    placed << [eid, c0, c1, r0, r1]
  end
end

# fallback: 2-per-row flow over whatever elements we have a mapping for
if placed.empty?
  col = 1; row = 1
  v2e.each_value do |eid|
    if col > 13
      col = 1; row += 12
    end
    placed << [eid, col, col + 12, row, row + 12]
    col += 12
  end
end

# Collision guard (D15 free-form overlap → Sigma rejects "Element collisions").
# Two elements collide when their column AND row ranges both overlap. If ANY pair
# collides, fall back to a clean stacked layout: full-width rows in placement
# order, each a fixed height. (beads-sigma — free-form overlap)
def collides?(a, b)
  _, ac0, ac1, ar0, ar1 = a
  _, bc0, bc1, br0, br1 = b
  (ac0 < bc1 && bc0 < ac1) && (ar0 < br1 && br0 < ar1)
end
overlap = placed.combination(2).any? { |a, b| collides?(a, b) }
if overlap
  STDERR.puts "layout: detected element collisions in free-form layout — collapsing #{placed.size} elements to stacked rows"
  row = 1; row_h = 12
  placed = placed.map do |eid, _c0, _c1, _r0, _r1|
    r0 = row; row += row_h
    [eid, 1, SIG + 1, r0, r0 + row_h]
  end
end

dash_children = placed.map { |eid, c0, c1, r0, r1| le(eid, c0, c1, r0, r1) }
data_page = page_xml('page-data', le(map['masterElementId'], 1, 25, 1, 15))
dash_page = page_xml(map['dashPageId'], *dash_children)

File.write(opts[:out], assemble(data_page, dash_page))
STDERR.puts "layout: #{placed.size} elements mapped from QuickSight #{cfg.keys.first || 'flow-fallback'} → #{opts[:out]}"
placed.each { |eid, c0, c1, r0, r1| STDERR.puts "  #{eid}  col #{c0}-#{c1}  row #{r0}-#{r1}" }
