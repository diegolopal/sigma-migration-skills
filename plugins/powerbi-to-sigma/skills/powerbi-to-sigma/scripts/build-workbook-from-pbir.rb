#!/usr/bin/env ruby
# build-workbook-from-pbir.rb — map normalized PBIR signals -> Sigma workbook spec.
#
# Power BI analog of tableau-to-sigma's build-charts-from-signals.rb. Input is
# extract-pbir.py's signals.json (per-visual kind + role bindings + position).
# Output is a complete Sigma workbook spec (Data page of hidden masters + a
# page of chart elements) ready for POST /v2/workbooks/spec via
# post-and-readback.rb, plus a 24-col grid layout string for put-layout.rb.
#
# It applies the measure-translation patterns documented in
# refs/measure-patterns.md:
#   - line charts default to a SINGLE series (no color split) unless a Series/
#     Legend role is bound (beads-sigma-c07);
#   - PBI measure refs ("EMPLOYEES.Total Salary") map to a measure formula via a
#     measure-map (Sum/Count/CountDistinct/…); dimensions map to bare/master refs;
#   - kpi/bar/line/pie/donut/table/pivot-table element shapes per spec-fixups.md.
#
# Usage:
#   ruby scripts/build-workbook-from-pbir.rb \
#     --signals /tmp/pbir/signals.json \
#     --master-map /tmp/pbir/master-map.json \
#     --data-model <dataModelId> \
#     --out /tmp/pbir/workbook-spec.json \
#     --layout-out /tmp/pbir/layout.xml \
#     [--name "Workforce KitchenSink (from Power BI)"] \
#     [--folder-id <uuid>]
#
# master-map.json shape — maps each PBI "Entity" to a Data-page master table and
# each "Entity.Field" queryRef to {ref, agg}. `ref` is the Sigma column path
# (e.g. "[EMP/Annual Salary]"); `agg` is the Sigma aggregator name for measures
# (Sum/Count/CountDistinct/Avg/Min/Max) or null for a dimension. Example:
#   {
#     "masters": {
#       "EMP": {"id":"master-emp","element_id":"<dmElementId>","data_model":"<dmId>",
#               "columns":[{"id":"me-salary","name":"Annual Salary","formula":"[EMPLOYEES/Annual Salary]"}, ...]}
#     },
#     "fields": {
#       "EMPLOYEES.DEPARTMENT":   {"master":"EMP","ref":"[EMP/Department]","agg":null},
#       "EMPLOYEES.Total Salary": {"master":"EMP","ref":"[EMP/Annual Salary]","agg":"Sum"},
#       "EMPLOYEES.Headcount":    {"master":"EMP","ref":"[EMP/Employee Id]","agg":"Count"},
#       "SAFETY_INCIDENTS.Incident Count": {"master":"INC","ref":"[INC/Incident Id]","agg":"CountDistinct"}
#     }
#   }
#
# The master-map is the one PBI-specific artifact the agent authors (it encodes
# the DM element ids + the DAX-measure→Sigma-aggregator decisions). Everything
# else is mechanical. Idempotent: deterministic ids from visual_id, re-runnable.

require 'json'
require 'optparse'

opts = {}
OptionParser.new do |p|
  p.on('--signals PATH')     { |v| opts[:sig] = v }
  p.on('--master-map PATH')  { |v| opts[:mmap] = v }
  p.on('--data-model ID')    { |v| opts[:dm] = v }
  p.on('--out PATH')         { |v| opts[:out] = v }
  p.on('--layout-out PATH')  { |v| opts[:layout_out] = v }
  p.on('--name NAME')        { |v| opts[:name] = v }
  p.on('--folder-id ID')     { |v| opts[:folder] = v }
end.parse!
%i[sig mmap out].each { |k| abort("missing --#{k.to_s.tr('_','-')}") unless opts[k] }

signals = JSON.parse(File.read(opts[:sig]))
mmap    = JSON.parse(File.read(opts[:mmap]))
fields  = mmap['fields'] || {}
masters = mmap['masters'] || {}

SIGMA_KIND = {
  'kpi' => 'kpi-chart', 'bar' => 'bar-chart', 'line' => 'line-chart',
  'area' => 'area-chart', 'combo' => 'combo-chart', 'scatter' => 'scatter-chart',
  'pie' => 'pie-chart', 'donut' => 'donut-chart',
  'table' => 'table', 'pivot-table' => 'pivot-table', 'text' => 'text',
  'control' => 'control'
}.freeze

# PBI role -> (dim_role?, value_role?) per visual kind handled below.
def field_spec(queryref, fields)
  fields[queryref] || { 'master' => nil, 'ref' => "[#{queryref}]", 'agg' => nil }
end

# PBI numeric format string (from signals 'formats' or master-map field 'format')
# -> Sigma column format hash. Best-effort; only emits when a format is known.
# Sigma column format shape is { kind, formatString } (matches the converter's
# metric.format output). NOT { type, ... } — POST rejects a missing `kind`.
# Sigma format strings are d3-format syntax (e.g. ",.0f", "$,.0f", ".1%"),
# NOT Excel masks ("#,##0") — the latter is rejected as "Invalid number format
# string". Matches the converter's metric.format output (",.0f").
PBI_FMT = {
  'currency' => { 'format' => { 'kind' => 'number', 'formatString' => '$,.0f' } },
  'percent'  => { 'format' => { 'kind' => 'number', 'formatString' => '.1%' } },
  'comma'    => { 'format' => { 'kind' => 'number', 'formatString' => ',.1f' } },
  'integer'  => { 'format' => { 'kind' => 'number', 'formatString' => ',.0f' } }
}.freeze
def sigma_format(hint)
  return nil if hint.nil? || hint.to_s.empty?
  h = hint.to_s
  return PBI_FMT['currency'] if h =~ /\$|currency|USD/i
  return PBI_FMT['percent']  if h =~ /%|percent/i
  return PBI_FMT['integer']  if h =~ /^#,?#?0$|integer|whole/i
  return PBI_FMT['comma']    if h =~ /#,##0|,/
  nil
end

# Apply a resolved format onto a column hash (mutates + returns it).
def apply_fmt(col, queryref, fields, vfmts)
  hint = (fields[queryref] || {})['format'] || (vfmts || {})[queryref]
  f = sigma_format(hint)
  col.merge!(f) if f
  col
end

def measure_formula(fs)
  agg = fs['agg']
  return fs['ref'] if agg.nil? || (agg.respond_to?(:empty?) && agg.empty?)
  # Multi-arg aggregator support (bead 14w c): PercentileCont(col, 0.9), etc.
  # Two encodings are honored, both keeping the extra arg(s) verbatim:
  #   1. fs['agg'] contains a '?' placeholder -> substitute the column ref.
  #      e.g. agg="PercentileCont(?, 0.9)" -> "PercentileCont([EMP/Salary], 0.9)"
  #   2. fs['agg_args'] is an array of extra args appended after the column ref.
  #      e.g. agg="PercentileCont", agg_args=["0.9"] -> "PercentileCont([EMP/Salary], 0.9)"
  # We never fabricate an aggregator from a measure *label* — the agg comes only
  # from the master-map's explicit decision.
  if agg.to_s.include?('?')
    agg.to_s.gsub('?', fs['ref'])
  elsif fs['agg_args'].is_a?(Array) && !fs['agg_args'].empty?
    "#{agg}(#{([fs['ref']] + fs['agg_args']).join(', ')})"
  else
    "#{agg}(#{fs['ref']})"
  end
end

# Deterministic, collision-free short id from a PBIR visual id. PBIR visual ids
# often share a long common prefix (e.g. a1b2c3d4e5f60001 / ...0002), so a naive
# prefix-truncate collides. Take a stable suffix of the sanitized id plus a short
# hash of the full id to guarantee uniqueness across visuals.
require 'digest'
def short(id)
  clean = id.to_s.gsub(/[^a-zA-Z0-9]/, '')
  h = Digest::SHA1.hexdigest(id.to_s)[0, 6]
  "#{clean[-6, 6] || clean}#{h}"
end

# Resolve which master a visual sources from (first bound field's master).
def visual_master(rec, fields)
  rec['bindings'].each_value do |refs|
    refs.each do |qr|
      m = (fields[qr] || {})['master']
      return m if m
    end
  end
  nil
end

# Build chart element from a normalized visual record.
def build_element(rec, fields, masters)
  kind = SIGMA_KIND[rec['sigma_kind']] || 'bar-chart'
  vid  = rec['visual_id']
  eid  = "el-#{short(vid)}"
  vfmts = rec['formats'] || {}
  # bead 14w(e): element name comes from the PBI visual title, not the raw id.
  title = rec['title'].to_s.strip
  name  = title.empty? ? vid : title

  if kind == 'text'
    body = rec['text'] ? "## #{rec['text']}" : '## '
    return { 'id' => eid, 'kind' => 'text', 'body' => body }
  end

  master = visual_master(rec, fields)
  master_id = master && masters[master] ? masters[master]['id'] : nil
  el = { 'id' => eid, 'kind' => kind, 'name' => name }
  el['source'] = { 'elementId' => master_id, 'kind' => 'table' } if master_id
  cols = []
  b = rec['bindings']

  case kind
  when 'control'
    # bead 14w(a): a PBI slicer -> a Sigma control (list/value filter), NOT a
    # bar chart. The control's targets/source are wired in the workbook UI or a
    # follow-up; here we emit a faithful list control bound to the sliced column.
    qr = (b['Values'] || b['Category'] || b['Fields'] || []).first
    fs = field_spec(qr, fields)
    cid = "#{eid}-ctl"
    cols << { 'id' => cid, 'formula' => fs['ref'], 'name' => (qr || 'Filter').split('.').last }
    el['kind'] = 'control'
    el['controlType'] = 'list-values'
    el['columnId'] = cid
    el.delete('source') # controls bind to a column, not a chart source
    el['source'] = { 'elementId' => master_id, 'kind' => 'table' } if master_id
  when 'kpi-chart'
    qr = (b['Values'] || b['Y'] || []).first
    fs = field_spec(qr, fields)
    cid = "#{eid}-v"
    col = { 'id' => cid, 'formula' => measure_formula(fs), 'name' => (qr || 'Value').split('.').last }
    apply_fmt(col, qr, fields, vfmts)
    cols << col
    el['value'] = { 'id' => cid }
  when 'bar-chart', 'line-chart', 'area-chart'
    dim = (b['Category'] || b['Axis'] || b['X'] || []).first
    meas = (b['Y'] || b['Values'] || [])
    series = (b['Series'] || b['Legend'] || []).first
    dfs = field_spec(dim, fields)
    dcid = "#{eid}-x"
    cols << { 'id' => dcid, 'formula' => dfs['ref'], 'name' => (dim || 'Dim').split('.').last }
    ycids = []
    meas.each_with_index do |qr, i|
      fs = field_spec(qr, fields)
      cid = "#{eid}-y#{i}"
      col = { 'id' => cid, 'formula' => measure_formula(fs), 'name' => qr.split('.').last }
      apply_fmt(col, qr, fields, vfmts)
      cols << col
      ycids << cid
    end
    el['xAxis'] = { 'columnId' => dcid }
    el['yAxis'] = { 'columnIds' => ycids }
    # PBI *Bar* visuals are horizontal; *Column* visuals vertical. Sigma keeps the
    # same xAxis(category)/yAxis(value) binding and flips rendering via this flag.
    # Only "horizontal" is a valid value — vertical = omit (Sigma default).
    el['orientation'] = 'horizontal' if kind == 'bar-chart' && rec['orientation'] == 'horizontal'
    # Stacking fidelity: emit explicitly so a multi-series clustered PBI chart does
    # NOT inherit Sigma's stacked default. PBI clustered->"none", stacked->"stacked",
    # 100%-stacked->"100".
    el['stacking'] = rec['stacking'] if kind == 'bar-chart' && rec['stacking']
    # c07: default to single series. Only split by color when PBI bound a
    # Series/Legend role. Never auto-color a line by a dimension that PBI did
    # not legend (see refs/measure-patterns.md §1 + §4).
    if series
      sfs = field_spec(series, fields)
      scid = "#{eid}-c"
      cols << { 'id' => scid, 'formula' => sfs['ref'], 'name' => series.split('.').last }
      el['color'] = { 'by' => 'category', 'column' => scid }
    end
  when 'scatter-chart'
    # bead 14w(b): scatter -> xAxis (measure), yAxis (measure), point category for
    # color/detail. PBI scatter binds X + Y (both measures) and a Category/Details.
    xqr = (b['X'] || b['Values'] || []).first
    yqr = (b['Y'] || []).first
    detail = (b['Category'] || b['Details'] || b['Legend'] || []).first
    xfs = field_spec(xqr, fields); yfs = field_spec(yqr, fields)
    xcid = "#{eid}-x"; ycid = "#{eid}-y"
    cx = { 'id' => xcid, 'formula' => measure_formula(xfs), 'name' => (xqr || 'X').split('.').last }
    cy = { 'id' => ycid, 'formula' => measure_formula(yfs), 'name' => (yqr || 'Y').split('.').last }
    apply_fmt(cx, xqr, fields, vfmts); apply_fmt(cy, yqr, fields, vfmts)
    cols << cx << cy
    el['xAxis'] = { 'columnId' => xcid }
    el['yAxis'] = { 'columnIds' => [ycid] }
    if detail
      dfs = field_spec(detail, fields)
      dcid = "#{eid}-d"
      cols << { 'id' => dcid, 'formula' => dfs['ref'], 'name' => detail.split('.').last }
      el['color'] = { 'by' => 'category', 'column' => dcid }
    end
  when 'pie-chart', 'donut-chart'
    dim = (b['Category'] || b['Legend'] || []).first
    val = (b['Values'] || b['Y'] || []).first
    dfs = field_spec(dim, fields); vfs = field_spec(val, fields)
    dcid = "#{eid}-c"; vcid = "#{eid}-v"
    cols << { 'id' => dcid, 'formula' => dfs['ref'], 'name' => (dim || 'Dim').split('.').last }
    cv = { 'id' => vcid, 'formula' => measure_formula(vfs), 'name' => (val || 'Value').split('.').last }
    apply_fmt(cv, val, fields, vfmts)
    cols << cv
    el['color'] = { 'id' => dcid }
    el['value'] = { 'id' => vcid }
  when 'table'
    # A plain table with measure columns renders FLAT/ungrouped unless it has a
    # grouping whose `calculations` lists the measure col ids (bead 14w(f)).
    # The first non-aggregated (dimension) column becomes the groupBy; every
    # aggregated column id goes into that grouping's calculations[].
    group_id = nil; calc_ids = []
    (b['Values'] || []).each_with_index do |qr, i|
      fs = field_spec(qr, fields)
      cid = "#{eid}-c#{i}"
      is_dim = fs['agg'].to_s.empty?
      col = { 'id' => cid, 'formula' => is_dim ? fs['ref'] : measure_formula(fs),
              'name' => qr.split('.').last }
      apply_fmt(col, qr, fields, vfmts) unless is_dim
      cols << col
      if is_dim
        group_id ||= cid
      else
        calc_ids << cid
      end
    end
    if group_id && !calc_ids.empty?
      el['groupings'] = [{ 'id' => "#{eid}-g", 'groupBy' => [group_id], 'calculations' => calc_ids }]
    end
  when 'pivot-table'
    rows = (b['Rows'] || b['Category'] || [])
    colsby = (b['Columns'] || [])   # bead 14w(d): PBI Columns role -> pivot columnsBy
    vals = (b['Values'] || [])
    rowids = []
    rows.each_with_index do |qr, i|
      fs = field_spec(qr, fields); cid = "#{eid}-r#{i}"
      cols << { 'id' => cid, 'formula' => fs['ref'], 'name' => qr.split('.').last }
      rowids << cid
    end
    colids = []
    colsby.each_with_index do |qr, i|
      fs = field_spec(qr, fields); cid = "#{eid}-col#{i}"
      cols << { 'id' => cid, 'formula' => fs['ref'], 'name' => qr.split('.').last }
      colids << cid
    end
    valids = []
    vals.each_with_index do |qr, i|
      fs = field_spec(qr, fields); cid = "#{eid}-v#{i}"
      col = { 'id' => cid, 'formula' => measure_formula(fs), 'name' => qr.split('.').last }
      apply_fmt(col, qr, fields, vfmts)
      cols << col
      valids << cid
    end
    # rowsBy + values REQUIRED or the pivot collapses to one grand-total cell
    # (memory: feedback_sigma_pivot_rowsby_columnsby). columnsBy is the PBI
    # Columns role (bead 14w(d)) — without it a Rows×Columns matrix flattens.
    el['rowsBy'] = rowids.map { |id| { 'id' => id } }
    el['columnsBy'] = colids.map { |id| { 'id' => id } } unless colids.empty?
    el['values'] = valids
  end

  el['columns'] = cols
  el
end

# ---- assemble pages -------------------------------------------------------
data_elements = masters.map do |_name, m|
  {
    'id' => m['id'], 'kind' => 'table', 'name' => m['id'].sub(/^master-/, '').upcase[0, 6],
    'source' => { 'dataModelId' => (m['data_model'] || opts[:dm]),
                  'elementId' => m['element_id'], 'kind' => 'data-model' },
    'columns' => (m['columns'] || []),
    'visibleAsSource' => false
  }
end

content_pages = signals['pages'].map do |pg|
  els = pg['visuals'].map { |v| build_element(v, fields, masters) }
  { 'id' => "page-#{pg['page_id']}", 'name' => pg['page_title'], 'elements' => els }
end

# ---- 24-col grid layout (research/powerbi-visual-layout.md §4) -------------
# Built BEFORE the spec is assembled so the layout XML can be EMBEDDED into the
# workbook spec's top-level `layout` (bead 16i): a bare POST/PUT /workbooks/spec
# WITHOUT an embedded layout makes Sigma auto-generate a single-column stack
# that wipes any grid. Embedding it on every write means the layout survives the
# initial POST; put-layout.rb is still the authoritative FINAL write.
col_for = ->(x, w, pw) {
  unit = pw / 24.0
  cs = (x / unit).floor + 1
  ce = ((x + w - 1) / unit).floor + 2
  [[cs, 1].max, [ce, 25].min]
}
ROW_UNIT = 30.0
pages_xml = signals['pages'].map do |pg|
  pw = pg['page_w'] || 1280
  les = pg['visuals'].map do |v|
    cs, ce = col_for.call(v['x'], v['w'], pw)
    rs = (v['y'] / ROW_UNIT).floor + 1
    re = ((v['y'] + v['h']) / ROW_UNIT).ceil + 1
    eid = "el-#{short(v['visual_id'])}"
    %(  <LayoutElement elementId="#{eid}" gridColumn="#{cs} / #{ce}" gridRow="#{rs} / #{re}"/>)
  end.join("\n")
  %(<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="page-#{pg['page_id']}">\n#{les}\n</Page>)
end.join("\n")
layout_xml = %(<?xml version="1.0" encoding="utf-8"?>\n#{pages_xml}\n)

spec = {
  'name' => opts[:name] || signals.dig('pages', 0, 'page_title') || 'Power BI Import',
  'schemaVersion' => 1,
  'pages' => [{ 'id' => 'page-data', 'name' => 'Data', 'elements' => data_elements }] + content_pages,
  # bead 16i: embed the layout so the very first POST does not trigger Sigma's
  # single-column auto-layout (which would wipe put-layout.rb's grid).
  'layout' => layout_xml
}
spec['folderId'] = opts[:folder] if opts[:folder]

File.write(opts[:out], JSON.pretty_generate(spec))
warn "[build-workbook] wrote #{opts[:out]} (#{data_elements.size} master(s), " \
     "#{content_pages.sum { |p| p['elements'].size }} chart element(s); layout embedded)"

if opts[:layout_out]
  File.write(opts[:layout_out], layout_xml)
  warn "[build-workbook] wrote layout -> #{opts[:layout_out]}"
end
