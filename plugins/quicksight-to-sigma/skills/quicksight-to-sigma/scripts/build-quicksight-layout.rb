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
GRID = 36.0                              # QuickSight max grid width (fallback only)
SIG = 24                                 # Sigma grid width

# QuickSight does NOT use a fixed 36-column grid. A sheet's effective grid width is
# whatever the widest row of tiles adds up to — commonly 12, 18, 24, or 36 depending
# on how the author sized things. Scaling every layout by a hardcoded 36 squeezes a
# 12-wide D4 into the left third of the Sigma page. Infer the real width as the max
# (ColumnIndex + ColumnSpan) across the sheet's elements, so relative widths + the
# overall span are preserved when we scale to Sigma's 24 columns.
def infer_grid_width(els)
  edges = els.map { |e| (e['ColumnIndex'] || 0) + (e['ColumnSpan'] || 0) }
  w = edges.compact.max.to_f
  w >= 1 ? w : GRID
end

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
    # Honor QuickSight's explicit ColumnIndex/RowIndex/ColumnSpan/RowSpan, scaling the
    # columns by the sheet's INFERRED grid width (not a hardcoded 36) so the relative
    # widths + the dashboard's overall horizontal extent are faithfully reproduced.
    # Rows are kept in QS row-units (RowIndex/RowSpan map 1:1 to Sigma grid rows), which
    # preserves relative heights + vertical arrangement. (beads-sigma — QS grid width)
    grid_w = infer_grid_width(els)
    els.each do |e|
      eid = v2e[e['ElementId']]; next unless eid
      c0, c1 = scale_cols(e['ColumnIndex'] || 0, e['ColumnSpan'] || (grid_w / 2), grid_w)
      r0 = (e['RowIndex'] || 0) + 1
      r1 = r0 + (e['RowSpan'] || 8)
      placed << [eid, c0, c1, r0, r1]
    end
  else
    # auto-flow by span: wrap when the running column exceeds the inferred grid width
    grid_w = infer_grid_width(els)
    grid_w = GRID if grid_w <= 0
    col = 0; row = 1; row_h = 0
    els.each do |e|
      eid = v2e[e['ElementId']]; next unless eid
      span = e['ColumnSpan'] || (grid_w / 2)
      col = 0 if col + span > grid_w
      row += row_h if col.zero? && row_h.positive?
      c0, c1 = scale_cols(col, span, grid_w)
      h = (e['RowSpan'] || 12)
      placed << [eid, c0, c1, row, row + h]
      col += span; row_h = [row_h, h].max
      if col >= grid_w
        col = 0; row += row_h; row_h = 0
      end
    end
  end
elsif (sb = cfg['SectionBasedLayout'])
  # QuickSight paginated/section layout (header/body/footer). Sigma has no page-section
  # concept; flatten every section's free-form sub-elements into a single stacked column
  # in document order so the report's vertical sequence is preserved. (D16 paginated)
  sects = []
  sects.concat(sb['HeaderSections'] || [])
  sects.concat(sb['BodySections'] || [])
  sects.concat(sb['FooterSections'] || [])
  row = 1
  sects.each do |sec|
    sec_els = (sec.dig('Content', 'Layout', 'FreeFormLayout', 'Elements') || sec['Elements'] || [])
    cw = sec_els.map { |e| num(e['XAxisLocation']) + num(e['Width']) }.max
    cw = 1.0 if cw.nil? || cw <= 0
    sec_els.each do |e|
      eid = v2e[e['ElementId']]; next unless eid
      c0, c1 = scale_cols(num(e['XAxisLocation']), num(e['Width']), cw)
      h = [(num(e['Height']) / 40.0).round, 4].max
      placed << [eid, c0, c1, row, row + h]
      row += h
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
