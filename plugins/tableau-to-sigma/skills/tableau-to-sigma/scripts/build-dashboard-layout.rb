#!/usr/bin/env ruby
# Build a Sigma layout XML that mirrors a Tableau dashboard's zone grid for
# dashboard-fidelity conversion mode (Phase 0b).
#
# Output: a layout XML with two pages —
#   1. <Page id="page-data">: hidden master element spanning the page
#   2. <Page id="<overview-page-id>">: title + N controls + N chart tiles
#      positioned at grid cells derived from each Tableau zone's x/y/w/h%.
#
# Crucially: walks each chart row left-to-right and STRETCHES each chart's
# right edge to meet the next chart's left edge so there are no empty columns
# between adjacent tiles (Tableau dashboards often have separate legend/filter
# zones between two tiles that Sigma doesn't render; without this step, those
# gaps stay visible).
#
# Usage:
#   ruby scripts/build-dashboard-layout.rb \
#     --layout /tmp/<name>/dashboard-layout.json \
#     --wb-ids /tmp/<name>/wb-ids.json \
#     --out /tmp/<name>/layout.xml
#
# Optional:
#   --page-cols N    Sigma grid columns (default 24)
#   --page-rows N    visible rows BEFORE row scaling (default 32)
#   --row-scale F    multiply the chart band's row count (default 1.5).
#                    Tableau zone h% mapped 1:1 onto a 32-row Sigma page makes
#                    tiles too short — Sigma suppresses axis labels / pie slice
#                    labels below ~5-6 grid rows (bead tkkv; the looker builder
#                    uses ROW_SCALE=2, tableau E2E found 1.43× sufficient —
#                    default 1.5 preserves proportions while clearing the
#                    label-suppression threshold). Pass --row-scale 1 to get
#                    the old un-scaled mapping.
#   --rename PAIR    "Tableau name=Sigma name" (repeatable) — same flag as the
#                    parity scripts. A chart tile renamed during conversion
#                    otherwise fails the zone→element name match and silently
#                    drops out of the layout (bead ddbq).
#   --chart-y0 PCT   top of the chart band as Tableau %  (default 29.7)
#   --chart-y1 PCT   bottom of the chart band as Tableau % (default 100.0)
#   --chart-row0 N   first grid row of the chart band     (default 6)

require 'json'
require 'optparse'
require_relative 'lib/layout'
include SigmaLayout

opts = { page_cols: 24, page_rows: 32, row_scale: 1.5, chart_y0: 29.7,
         chart_y1: 100.0, chart_row0: 6, renames: {} }
OptionParser.new do |p|
  p.on('--layout PATH')        { |v| opts[:layout] = v }
  p.on('--wb-ids PATH')        { |v| opts[:wb_ids] = v }
  p.on('--out PATH')           { |v| opts[:out] = v }
  p.on('--page-cols N',  Integer) { |v| opts[:page_cols] = v }
  p.on('--page-rows N',  Integer) { |v| opts[:page_rows] = v }
  p.on('--row-scale F',  Float, 'row-height multiplier (default 1.5; min label-safe ~1.43)') { |v| opts[:row_scale] = v }
  p.on('--rename PAIR', 'Tableau-name=Sigma-name (repeat) — matches the parity scripts\' flag') do |v|
    from, to = v.split('=', 2)
    abort("--rename expects 'Tableau name=Sigma name', got #{v.inspect}") if from.nil? || to.nil? || from.empty? || to.empty?
    opts[:renames][from] = to
  end
  p.on('--chart-y0 PCT', Float)   { |v| opts[:chart_y0] = v }
  p.on('--chart-y1 PCT', Float)   { |v| opts[:chart_y1] = v }
  p.on('--chart-row0 N', Integer) { |v| opts[:chart_row0] = v }
end.parse!
%i[layout wb_ids out].each { |k| abort("missing --#{k.to_s.tr('_','-')}") unless opts[k] }

# Row scaling (bead tkkv): scale the page's row count so each chart band tile
# gets proportionally more rows. Title (rows 1-3) and controls (rows 3-6) keep
# their fixed positions; only the chart band [chart_row0..page_rows] stretches.
opts[:page_rows] = (opts[:page_rows] * opts[:row_scale]).round if opts[:row_scale] != 1.0

dash_layout = JSON.parse(File.read(opts[:layout]))
wb_ids      = JSON.parse(File.read(opts[:wb_ids]))

# Page lookups
data_page  = wb_ids['pages'].find { |p| p['name'] == 'Data' }
abort('no "Data" page in wb-ids') unless data_page
master_el  = data_page['elements'].first

# Multi-dashboard workbooks (bead ptrt): ONE Sigma page per Tableau dashboard,
# each with its own container-banded layout. Pair each dashboard to the page
# with the same name; when the workbook has a single non-Data page (legacy
# single-dashboard flow), pair the first dashboard to it.
content_pages = wb_ids['pages'].reject { |p| p['name'] == 'Data' || p['name'].nil? }
content_pages = [wb_ids['pages'][1]].compact if content_pages.empty?
abort('no overview page (non-Data) in wb-ids') if content_pages.empty?

page_for_dash = {}
dash_layout.each do |d|
  pg = content_pages.find { |p| p['name'] == d['dashboard'] }
  pg ||= content_pages.first if dash_layout.length == 1
  if pg.nil?
    warn "WARN: no Sigma page matched dashboard #{d['dashboard'].inspect} — dashboard skipped from layout"
    next
  end
  page_for_dash[d['dashboard']] = pg
end
abort('no dashboard↔page pairs resolved') if page_for_dash.empty?

def chart_pos(z, opts)
  y0 = z['y_pct'] || 0
  h  = z['h_pct'] || 0
  y1 = y0 + h
  remaining_rows = opts[:page_rows] - (opts[:chart_row0] - 1)
  span = (opts[:chart_y1] - opts[:chart_y0]).to_f
  span = 1.0 if span <= 0
  row_start = (opts[:chart_row0] + (y0 - opts[:chart_y0]) / span * remaining_rows).round
  row_end   = (opts[:chart_row0] + (y1 - opts[:chart_y0]) / span * remaining_rows).round
  # Sigma rejects non-positive grid positions ("Invalid element position").
  # Clamp into the legal band [chart_row0 .. page_rows+1] and guarantee a span.
  max_row   = opts[:page_rows] + 1
  row_start = [[row_start, opts[:chart_row0]].max, max_row - 1].min
  row_end   = [[row_end,   row_start + 1].max,      max_row].min
  row_end   = row_start + 1 if row_end <= row_start
  col_start = [1,  (1 + (z['x_pct'] || 0) / 100.0 * opts[:page_cols]).round].max
  col_end   = [opts[:page_cols] + 1, (1 + ((z['x_pct'] || 0) + (z['w_pct'] || 0)) / 100.0 * opts[:page_cols]).round].min
  col_end   = col_start + 1 if col_end <= col_start
  [col_start, col_end, row_start, row_end]
end

# Build one container-banded page for a single dashboard. Returns
# [page_xml_string, extra_spec_elements, n_charts, n_bands, n_controls].
def build_page_for_dashboard(dashboard, page, opts)
  chart_zones = dashboard['zones'].select { |z| z['kind'] == 'chart' && z['caption'] }
  els_by_name = page['elements'].each_with_object({}) { |e, h| h[e['name']] = e if e['name'] }
  title_el = page['elements'].find { |e| e['kind'] == 'text' }
  ctl_els  = page['elements'].select { |e| e['kind'] == 'control' }

  # Per-dashboard copy of the band tuning — auto-fit must not leak between
  # dashboards (bead ptrt: the old script used dash_layout.first only).
  o = opts.dup

  # Auto-fit the chart band to the ACTUAL zone extents. The default
  # chart_y0=29.7 assumes a title/filter band at the top; a dashboard whose
  # charts start near y=0 would otherwise map to negative grid rows.
  zone_y0s = chart_zones.map { |z| (z['y_pct'] || 0).to_f }
  zone_y1s = chart_zones.map { |z| (z['y_pct'] || 0).to_f + (z['h_pct'] || 0).to_f }
  unless zone_y0s.empty?
    fit_y0 = zone_y0s.min
    fit_y1 = [zone_y1s.max, fit_y0 + 1].max
    if fit_y0 < o[:chart_y0]
      o[:chart_y0] = fit_y0
      o[:chart_y1] = fit_y1
    end
  end

  chart_layouts = chart_zones.map do |z|
    lookup_name = o[:renames][z['caption']] || z['caption']
    el = els_by_name[lookup_name]
    if el.nil?
      warn "WARN: no Sigma element matched zone caption #{z['caption'].inspect} on page #{page['name'].inspect}" \
           "#{lookup_name == z['caption'] ? " — if the tile was renamed, pass --rename #{z['caption'].inspect}'=<Sigma name>'" : " (renamed to #{lookup_name.inspect})"} — tile DROPPED from layout"
    end
    next nil unless el
    c1, c2, r1, r2 = chart_pos(z, o)
    { el_id: el['id'], c1: c1, c2: c2, r1: r1, r2: r2 }
  end.compact

  # Close horizontal gaps within each row (Tableau dashboards often have
  # separate legend/filter zones between chart tiles that Sigma doesn't render).
  rows = chart_layouts.group_by { |c| [c[:r1], c[:r2]] }
  rows.each_value do |row_charts|
    row_charts.sort_by! { |c| c[:c1] }
    row_charts.each_with_index do |c, i|
      next_c1 = i + 1 < row_charts.length ? row_charts[i + 1][:c1] : (o[:page_cols] + 1)
      c[:c2] = next_c1
    end
  end

  children = []
  extra_els = []
  ov_prefix = "band-#{page['id']}"

  # Header band: reuse the page's existing title text if present, else add one
  # (sidecar) named after the page (= the Tableau dashboard name).
  hdr_id = "#{ov_prefix}-hdr"
  extra_els << container_el(hdr_id, HEADER_STYLE.dup)
  if title_el
    children << header_band_xml(hdr_id, title_el['id'])
  else
    txt_id = "#{ov_prefix}-hdrtext"
    extra_els << header_text_el(txt_id, page['name'])
    children << header_band_xml(hdr_id, txt_id)
  end

  # Control band: dashboard-global controls side-by-side under the header.
  n = ctl_els.length
  ctl_rows = 0
  if n > 0
    ctl_rows = 3
    col_width = (o[:page_cols].to_f / n).round
    inner = ctl_els.each_with_index.map do |c, i|
      col_start = 1 + i * col_width
      col_end   = i == n - 1 ? o[:page_cols] + 1 : col_start + col_width
      le(c['id'], col_start, col_end, 1, 1 + ctl_rows)
    end.join("\n")
    ctl_id = "#{ov_prefix}-ctl"
    extra_els << container_el(ctl_id)
    children << gc(ctl_id, 1, o[:page_cols] + 1, 1 + HEADER_ROWS, 1 + HEADER_ROWS + ctl_rows, inner)
  end

  # Chart bands: cluster the zone-derived positions into row bands and shift
  # the whole chart area under the header + control bands.
  chart_items = chart_layouts.map { |c| [c[:el_id], c[:c1], c[:c2], c[:r1], c[:r2]] }
  bands = cluster_bands(chart_items)
  content_start = 1 + HEADER_ROWS + ctl_rows
  band_offset = bands.empty? ? 0 : content_start - bands.first.map { |i| i[3] }.min
  bands.each_with_index do |band, i|
    cid = "#{ov_prefix}-#{i + 1}"
    extra_els << container_el(cid)
    children << band_container_xml(cid, band, row_offset: band_offset)
  end

  [page_xml(page['id'], *children), extra_els, chart_layouts.length, bands.length, ctl_els.length]
end

data_page_xml = page_xml('page-data',
                         le(master_el['id'], 1, opts[:page_cols] + 1, 1, 21))

page_xmls = [data_page_xml]
sidecar = {}
totals = { charts: 0, bands: 0, controls: 0 }
dash_layout.each do |d|
  page = page_for_dash[d['dashboard']]
  next unless page
  pxml, extra_els, n_charts, n_bands, n_ctls = build_page_for_dashboard(d, page, opts)
  page_xmls << pxml
  sidecar[page['id']] = extra_els
  totals[:charts] += n_charts
  totals[:bands] += n_bands
  totals[:controls] += n_ctls
end

File.write(opts[:out], assemble(*page_xmls) + "\n")
File.write("#{opts[:out]}.elements.json", JSON.pretty_generate(sidecar))
puts "wrote #{opts[:out]} (#{page_for_dash.size} dashboard page(s): #{totals[:charts]} charts in #{totals[:bands]} band container(s), " \
     "#{totals[:controls]} controls, header bands, gap-closing applied, row-scale #{opts[:row_scale]}× → #{opts[:page_rows]} rows)"
puts "wrote #{opts[:out]}.elements.json (#{sidecar.values.sum(&:length)} container/header spec element(s) — put-layout.rb injects these)"
