#!/usr/bin/env ruby
# build-workbook-from-quicksight.rb
# Build a Sigma workbook that mirrors a QuickSight analysis, bound to the
# data model produced by the convert phase.
#
# Architecture (matches the Qlik/PowerBI builders):
#   - a master "table" element on a Data page, source = {dataModelId, elementId, kind:"data-model"},
#     surfacing the columns the dashboard needs via [Custom SQL/RAW] (or a translated calc-field expr);
#   - one dashboard page whose chart elements source the master via {elementId, kind:"table"}
#     and reference master columns as [<MasterName>/<Col>] with the QuickSight aggregation.
#
# Key behaviours (beads-sigma-nc6g / woaa / 23xu):
#   - the master sources the DM element whose columns COVER the charted columns (the
#     denormalized join element), NOT a hardcoded pages[0].elements[0];
#   - QuickSight window/table-calc functions (runningSum/percentOfTotal/rank/difference/…)
#     are NOT passed through as live Sigma formulas — they are neutralized to Null (the
#     original expr goes into the column description);
#   - a dataset FilterOperation surfaced by convert-model (dm-filters.json) is APPLIED as a
#     real element-level list filter on the master, so downstream aggregates honor it;
#   - GaugeChartVisual -> kpi-chart, FunnelChartVisual -> bar-chart, TreeMapVisual -> bar-chart
#     (Sigma has no native gauge/funnel/treemap kind; this mirrors the PBI builder's mapping).
#
# Usage:
#   ruby scripts/build-workbook-from-quicksight.rb \
#     --analysis DISCOVER_DIR/analysis.json --dm-readback /tmp/dm-readback.json \
#     [--dm-spec /tmp/dm-spec.json] [--filters /tmp/dm-filters.json] \
#     --folder-id ID --out /tmp/wb-spec.json
require 'json'
require 'optparse'
require 'securerandom'
require 'set'

opts = {}
OptionParser.new do |o|
  o.on('--analysis F') { |v| opts[:an] = v }
  o.on('--dm-readback F') { |v| opts[:rb] = v }
  o.on('--dm-spec F') { |v| opts[:dmspec] = v }
  o.on('--filters F') { |v| opts[:filters] = v }
  o.on('--folder-id ID') { |v| opts[:folder] = v }
  o.on('--master-name NAME') { |v| opts[:mname] = v }
  o.on('--out F') { |v| opts[:out] = v }
end.parse!
%i[an rb out].each { |k| abort "missing --#{k}" unless opts[k] }

an = JSON.parse(File.read(opts[:an]))
defn = an['Definition']
rb = JSON.parse(File.read(opts[:rb]))
dm_id = rb['dataModelId']

def disp(raw); raw.to_s.gsub(/[_.]/, ' ').split.map { |w| w[0..0].upcase + w[1..-1].to_s.downcase }.join(' '); end

# ---- derive the columns the dashboard actually references (raw col names) ----
def visual_cols(inner)
  out = []
  walk = lambda do |o|
    if o.is_a?(Hash)
      if (c = o['Column']) && c.is_a?(Hash) && c['ColumnName']
        out << c['ColumnName']
      end
      o.each_value { |v| walk.call(v) }
    elsif o.is_a?(Array)
      o.each { |v| walk.call(v) }
    end
  end
  walk.call(inner['ChartConfiguration'] || {})
  out
end

calc_names = {}
(defn['CalculatedFields'] || []).each { |c| calc_names[c['Name']] = c['Expression'] }

needed_raw = []
defn['Sheets'].each do |sh|
  (sh['Visuals'] || []).each do |v|
    _, inner = v.first
    needed_raw.concat(visual_cols(inner))
  end
end
needed_raw.uniq!
# calc fields resolve to raw columns inside their expressions; expand
needed_resolved = needed_raw.flat_map do |n|
  if calc_names.key?(n)
    calc_names[n].to_s.scan(/\{([^}]+)\}/).flatten.map(&:strip)
  else
    [n]
  end
end.uniq

# ---- pick the DM element whose columns COVER the charted columns ----
# Use the dm-spec (has column display names) to score coverage; fall back to the
# dm-readback element list when no dm-spec is provided. (beads-sigma-nc6g point 4)
dm_spec = opts[:dmspec] && File.exist?(opts[:dmspec]) ? JSON.parse(File.read(opts[:dmspec])) : nil
needed_disp = needed_resolved.map { |c| disp(c) }.to_set

best = nil
if dm_spec
  spec_els = (dm_spec['pages'] || []).flat_map { |pg| pg['elements'] || [] }
  scored = spec_els.map do |el|
    names = (el['columns'] || []).map { |c| c['name'] }.compact.to_set
    cover = needed_disp.count { |d| names.include?(d) }
    [cover, (el['columns'] || []).size, el['name']]
  end
  # most coverage; tie-break on more columns (the denormalized view wins)
  top = scored.max_by { |cover, ncols, _| [cover, ncols] }
  best = top && top[2]
end

rb_els = (rb['pages'] || []).flat_map { |pg| pg['elements'] || [] }
dm_el_obj =
  if best
    rb_els.find { |e| e['name'] == best } || rb_els.first
  else
    # no dm-spec: pick the readback element with the most columns isn't available,
    # so prefer the last (synthesized join element is appended last) else first.
    rb_els.last || rb_els.first
  end
abort 'no DM elements in readback' unless dm_el_obj
dm_el = dm_el_obj['id']
DMEL = dm_el_obj['name'] || 'Custom SQL'   # DM element name — master refs cols as [DMEL/Col]
M = opts[:mname] || 'Orders'               # master element name (used in [M/Col] refs from charts)

def nid(p = 'el'); "#{p}-" + SecureRandom.hex(5); end
NUM = ->(fs) { { 'kind' => 'number', 'formatString' => fs } }
AGG = { 'SUM' => 'Sum', 'AVERAGE' => 'Avg', 'MIN' => 'Min', 'MAX' => 'Max',
        'COUNT' => 'Count', 'DISTINCT_COUNT' => 'CountDistinct', 'MEDIAN' => 'Median' }

# QuickSight window / table-calc function names (must match convert-model.rb). A
# calc field using any of these can't be a live Sigma formula — neutralize to Null.
QS_WINDOW_FUNCS = %w[
  runningSum runningAvg runningCount runningMax runningMin
  percentOfTotal percentDifference difference
  rank denseRank percentileRank
  lag lead firstValue lastValue
  windowSum windowAvg windowCount windowMax windowMin
  movingSum movingAverage
].freeze
def qs_window_func?(expr)
  e = expr.to_s
  QS_WINDOW_FUNCS.any? { |fn| e =~ /(?<![A-Za-z0-9_])#{Regexp.escape(fn)}\s*\(/ }
end

# minimal QuickSight-expr → Sigma-formula translator for calc fields referenced by visuals
def qs_expr_to_sigma(expr, dmel)
  s = expr.to_s.dup
  s = s.gsub(/\{([^}]+)\}/) { "[#{dmel}/#{disp(Regexp.last_match(1).strip)}]" }
  s = s.gsub('<>', '!=')
  s = s.gsub(/\bifelse\s*\(/i, 'If(')
  s = s.gsub(/'([^']*)'/) { "\"#{Regexp.last_match(1)}\"" }
  s
end

calc = {}
(defn['CalculatedFields'] || []).each { |c| calc[c['Name']] = c['Expression'] }

def field_role(f)
  if (mf = f['NumericalMeasureField'])
    [:meas, mf['Column']['ColumnName'], (mf.dig('AggregationFunction', 'SimpleNumericalAggregation') || 'SUM')]
  elsif (mf = f['CategoricalMeasureField'])
    [:meas, mf['Column']['ColumnName'], 'COUNT']
  elsif (df = f['CategoricalDimensionField'])
    [:dim, df['Column']['ColumnName'], nil]
  elsif (df = f['DateDimensionField'])
    [:dim, df['Column']['ColumnName'], nil]
  end
end

# QuickSight visual type -> Sigma element kind.
#
# Sigma's REAL workbook chart kinds (confirmed against the public OpenAPI element
# union — /v2/workbooks/spec): kpi-chart, bar-chart, line-chart, area-chart,
# pie-chart, donut-chart, scatter-chart, combo-chart, table, pivot-table, AND the
# three geographic kinds point-map / region-map / geography-map. There is NO native
# histogram, heat-map, treemap, waterfall, box-plot, radar, sankey, or word-cloud
# kind (verified: those names do not appear anywhere in the element union).
#
# Approximations (no native kind, mirror the PBI builder, beads-sigma-1zh9):
#   gauge -> kpi-chart (single value); funnel/treemap -> bar-chart (category+measure).
# Geographic (NEW — region-map shape verified to round-trip via live POST+readback
# + MCP query parity on the D17 DM, 2026-06-06): QuickSight FilledMapVisual and
# GeospatialMapVisual both map to Sigma region-map when their geo field is a region
# NAME (state/country/city/zip); GeospatialMapVisual maps to point-map only when it
# carries real latitude+longitude fields (handled in the dispatch). LayerMapVisual
# (multi-layer) has no clean single-element equivalent -> dropped with a warning.
KIND = { 'KPIVisual' => 'kpi-chart', 'BarChartVisual' => 'bar-chart',
         'LineChartVisual' => 'line-chart', 'PieChartVisual' => 'pie-chart',
         'ComboChartVisual' => 'combo-chart', 'ScatterPlotVisual' => 'scatter-chart',
         'TableVisual' => 'table', 'PivotTableVisual' => 'pivot-table',
         'GaugeChartVisual' => 'kpi-chart', 'FunnelChartVisual' => 'bar-chart',
         'TreeMapVisual' => 'bar-chart',
         'FilledMapVisual' => 'region-map', 'GeospatialMapVisual' => 'region-map' }

# QuickSight visual types Sigma has NO equivalent for. We deliberately do NOT build
# these; instead the builder records a clear per-visual warning (vs. silently
# emitting nothing). Reason text is surfaced to STDERR + a sidecar warnings file.
QS_UNSUPPORTED = {
  'HeatMapVisual'       => 'Sigma has no heat-map element kind',
  'HistogramVisual'     => 'Sigma has no histogram element kind (auto-binning); re-author as a binned bar-chart in Sigma',
  'BoxPlotVisual'       => 'Sigma has no box-plot element kind',
  'WaterfallVisual'     => 'Sigma has no waterfall element kind',
  'SankeyDiagramVisual' => 'Sigma has no sankey element kind',
  'WordCloudVisual'     => 'Sigma has no word-cloud element kind',
  'RadarChartVisual'    => 'Sigma has no radar/spider element kind',
  'LayerMapVisual'      => 'Sigma has no multi-layer map element kind (single-layer point/region-map only)',
  'InsightVisual'       => 'QuickSight ML insight (forecast/anomaly/narrative) — no Sigma equivalent',
  'CustomContentVisual' => 'QuickSight custom content (iframe/HTML/image embed) — re-author as a Sigma image/embed element',
  'PluginVisual'        => 'QuickSight third-party plugin visual (e.g. Highcharts) — no Sigma equivalent',
  'EmptyVisual'         => 'QuickSight placeholder (no chart configured) — nothing to build'
}.freeze
build_warnings = []

master_cols = {}   # colname(raw or calc) -> {id, formula, name}
def fmt_for(name)
  case name
  when /margin|pct|percent|ratio|rate/i then '.1%'
  when /revenue|profit|cost|sales|amount|price|discount/i then '$,.0f'
  else ',.0f'
  end
end

# Infer a Sigma region-map regionType from the geo dimension's (raw) column name.
# Sigma regionType enum (OpenAPI): country, us-state, us-county, us-zipcode,
# us-cbsa, us-postal-place, ca-province. Default to us-postal-place for free
# city/place names (the most permissive name-based bucket).
def region_type_for(rawname)
  n = rawname.to_s.downcase
  return 'country'         if n =~ /country|nation/
  return 'us-state'        if n =~ /\bstate\b|province_state|^st$/
  return 'us-county'       if n =~ /county/
  return 'us-zipcode'      if n =~ /zip|postal_?code|postcode/
  return 'us-cbsa'         if n =~ /cbsa|metro/
  return 'ca-province'     if n =~ /province/
  'us-postal-place'  # city / place name
end

# Does a Geospatial field-well carry an explicit latitude / longitude pair? If so
# the QuickSight geo visual should become a Sigma point-map; otherwise (a region
# NAME like state/city) it becomes a region-map.
def latlong_pair(geo_roles)
  lat = geo_roles.find { |r| r[1].to_s =~ /lat(itude)?/i }
  lon = geo_roles.find { |r| r[1].to_s =~ /lon(g|gitude)?/i }
  (lat && lon) ? [lat, lon] : nil
end

def master_ref(colname, calc, master_cols, dmel)
  return master_cols[colname] if master_cols[colname]
  if calc.key?(colname)
    if qs_window_func?(calc[colname])
      # neutralize: a window/table-calc field can't be a live Sigma calc column.
      formula = 'Null'; nm = colname
      master_cols[colname] = { 'id' => "m-#{SecureRandom.hex(4)}", 'formula' => formula, 'name' => nm,
                               'description' => "QuickSight table-calc (neutralized — re-author in Sigma): #{calc[colname]}",
                               '_window' => true }
      return master_cols[colname]
    end
    formula = qs_expr_to_sigma(calc[colname], dmel); nm = colname
  else
    formula = "[#{dmel}/#{disp(colname)}]"; nm = disp(colname)
  end
  master_cols[colname] = { 'id' => "m-#{SecureRandom.hex(4)}", 'formula' => formula, 'name' => nm }
end

def dim_col(role, calc, mc, dmel, m)
  ref = master_ref(role[1], calc, mc, dmel); id = nid('d')
  [{ 'id' => id, 'formula' => "[#{m}/#{ref['name']}]", 'name' => ref['name'] }, id]
end

def meas_col(role, calc, mc, dmel, m)
  _, col, agg = role; ref = master_ref(col, calc, mc, dmel); id = nid('m')
  # a neutralized window calc field can't be aggregated as a live formula either
  if ref['_window']
    return [{ 'id' => id, 'formula' => 'Null', 'name' => ref['name'],
              'description' => ref['description'] }, id]
  end
  [{ 'id' => id, 'formula' => "#{AGG[agg] || 'Sum'}([#{m}/#{ref['name']}])", 'name' => ref['name'],
     'format' => NUM.(fmt_for(ref['name'])) }, id]
end

elements = []
vis_map = {}
defn['Sheets'].each do |sh|
  (sh['Visuals'] || []).each do |v|
    vtype, inner = v.first
    title = (inner.dig('Title', 'FormatText', 'PlainText') || (inner.is_a?(Hash) ? inner['VisualId'] : nil) || vtype)
    kind = KIND[vtype]
    unless kind
      reason = QS_UNSUPPORTED[vtype] || "unrecognized QuickSight visual type '#{vtype}'"
      build_warnings << { 'visual' => title, 'type' => vtype, 'reason' => reason }
      STDERR.puts "  ! skipped #{vtype} (#{title}): #{reason}"
      next
    end
    eid = nid
    vis_map[inner['VisualId']] = eid
    kind = 'donut-chart' if vtype == 'PieChartVisual' && inner.dig('ChartConfiguration', 'DonutOptions')
    fw = (inner['ChartConfiguration'] || {})['FieldWells'] || {}
    w = fw.values.find { |x| x.is_a?(Hash) } || fw
    rol = ->(key) { (w[key] || []).map { |f| field_role(f) }.compact }
    base = { 'id' => eid, 'kind' => kind, 'name' => title, 'source' => { 'elementId' => 'master', 'kind' => 'table' } }
    el = nil

    case kind
    when 'kpi-chart'
      # KPI + Gauge both surface a single value
      vals = rol.('Values'); (next if vals.empty?)
      c, cid = meas_col(vals[0], calc, master_cols, DMEL, M)
      el = base.merge('columns' => [c.merge('name' => title)], 'value' => { 'columnId' => cid })
    when 'bar-chart', 'line-chart', 'area-chart'
      # funnel/treemap land here too: their dim is in Category/Groups, measure in Values/Sizes
      dims = rol.('Category'); dims = rol.('Groups') if dims.empty?
      vals = rol.('Values'); vals = rol.('Sizes') if vals.empty?
      (next if dims.empty? || vals.empty?)
      dc, did = dim_col(dims[0], calc, master_cols, DMEL, M); cols = [dc]; ycids = []
      vals.each { |mv| c, id = meas_col(mv, calc, master_cols, DMEL, M); cols << c; ycids << id }
      el = base.merge('columns' => cols, 'xAxis' => { 'columnId' => did }, 'yAxis' => { 'columnIds' => ycids })
    when 'pie-chart', 'donut-chart'
      dims = rol.('Category'); vals = rol.('Values'); (next if dims.empty? || vals.empty?)
      dc, did = dim_col(dims[0], calc, master_cols, DMEL, M); mc2, mid = meas_col(vals[0], calc, master_cols, DMEL, M)
      el = base.merge('columns' => [dc, mc2], 'color' => { 'id' => did }, 'value' => { 'id' => mid })
    when 'combo-chart'
      dims = rol.('Category'); bars = rol.('BarValues'); lines = rol.('LineValues')
      (next if dims.empty? || (bars.empty? && lines.empty?))
      dc, did = dim_col(dims[0], calc, master_cols, DMEL, M); cols = [dc]; ycids = []
      bars.each  { |mv| c, id = meas_col(mv, calc, master_cols, DMEL, M); cols << c; ycids << id }
      lines.each { |mv| c, id = meas_col(mv, calc, master_cols, DMEL, M); cols << c; ycids << { 'columnId' => id, 'type' => 'line' } }
      el = base.merge('columns' => cols, 'xAxis' => { 'columnId' => did }, 'yAxis' => { 'columnIds' => ycids })
    when 'scatter-chart'
      xs = rol.('XAxis'); ys = rol.('YAxis'); cat = rol.('Category'); (next if xs.empty? || ys.empty?)
      xc, xid = meas_col(xs[0], calc, master_cols, DMEL, M); yc, yid = meas_col(ys[0], calc, master_cols, DMEL, M)
      el = base.merge('columns' => [xc, yc], 'xAxis' => { 'columnId' => xid }, 'yAxis' => { 'columnIds' => [yid] })
      if cat.any?
        dc, did = dim_col(cat[0], calc, master_cols, DMEL, M); el['columns'] << dc; el['color'] = { 'by' => 'category', 'column' => did }
      end
    when 'table'
      dims = rol.('GroupBy'); vals = rol.('Values'); cols = []; gids = []; cids = []
      dims.each { |d| c, id = dim_col(d, calc, master_cols, DMEL, M); cols << c; gids << id }
      vals.each { |mv| c, id = meas_col(mv, calc, master_cols, DMEL, M); cols << c; cids << id }
      (next if cols.empty?)
      el = base.merge('columns' => cols)
      el['groupings'] = [{ 'id' => nid('g'), 'groupBy' => gids, 'calculations' => cids }] unless gids.empty?
    when 'pivot-table'
      rows = rol.('Rows'); pcols = rol.('Columns'); vals = rol.('Values'); cols = []; rids = []; coids = []; vids = []
      rows.each  { |d| c, id = dim_col(d, calc, master_cols, DMEL, M); cols << c; rids << id }
      pcols.each { |d| c, id = dim_col(d, calc, master_cols, DMEL, M); cols << c; coids << id }
      vals.each  { |mv| c, id = meas_col(mv, calc, master_cols, DMEL, M); cols << c; vids << id }
      (next if rids.empty? || vids.empty?)
      el = base.merge('columns' => cols, 'rowsBy' => rids.map { |i| { 'id' => i } }, 'values' => vids)
      el['columnsBy'] = coids.map { |i| { 'id' => i } } unless coids.empty?
    when 'region-map', 'point-map'
      # QuickSight FilledMap/GeospatialMap: Geospatial holds the geo field(s),
      # Values holds the measure that fills/sizes the map. (Colors is optional and
      # rendered automatically by Sigma from the measure, so it is not a separate well.)
      geo  = rol.('Geospatial')
      vals = rol.('Values')
      (next if geo.empty?)
      pair = latlong_pair(geo)
      cols = []
      if pair
        # real lat/long -> point-map
        latc, latid = meas_col([:meas, pair[0][1], 'AVERAGE'], calc, master_cols, DMEL, M)
        lonc, lonid = meas_col([:meas, pair[1][1], 'AVERAGE'], calc, master_cols, DMEL, M)
        # carry lat/long as dimension-style refs (no aggregation) for the point geometry
        latc = { 'id' => latid, 'formula' => latc['formula'].sub(/^Avg\(/, '').sub(/\)$/, ''), 'name' => latc['name'] }
        lonc = { 'id' => lonid, 'formula' => lonc['formula'].sub(/^Avg\(/, '').sub(/\)$/, ''), 'name' => lonc['name'] }
        cols << latc << lonc
        vals.each { |mv| c, _ = meas_col(mv, calc, master_cols, DMEL, M); cols << c }
        el = base.merge('kind' => 'point-map', 'columns' => cols,
                        'latitude' => { 'id' => latid }, 'longitude' => { 'id' => lonid })
      else
        # geo NAME (state/city/country/zip) -> region-map
        dc, did = dim_col(geo[0], calc, master_cols, DMEL, M); cols << dc
        vals.each { |mv| c, _ = meas_col(mv, calc, master_cols, DMEL, M); cols << c }
        el = base.merge('kind' => 'region-map', 'columns' => cols,
                        'region' => { 'id' => did, 'regionType' => region_type_for(geo[0][1]) })
      end
    end
    elements << el if el
  end
end

# strip the private _window marker before emit
master_cols.each_value { |c| c.delete('_window'); c.delete('description') if c['formula'] != 'Null' }

master = { 'id' => 'master', 'name' => M, 'kind' => 'table', 'visibleAsSource' => false,
           'source' => { 'dataModelId' => dm_id, 'elementId' => dm_el, 'kind' => 'data-model' },
           'columns' => master_cols.values }

# ---- apply surfaced dataset filter(s) (beads-sigma-23xu FilterOperation) ----
# convert-model writes the QS predicate(s) to dm-filters.json. We translate a simple
# {COL}='VALUE' equality predicate into a Sigma element-level list filter on the
# master, so every downstream aggregate honors it. The filtered column is added to
# the master if it isn't already projected.
filters_path = opts[:filters] || File.join(File.dirname(File.expand_path(opts[:an])), 'dm-filters.json')
applied_filters = []
if File.exist?(filters_path)
  fdata = JSON.parse(File.read(filters_path)) rescue {}
  (fdata['filters'] || []).each do |pred|
    m = pred.to_s.match(/\{([^}]+)\}\s*=\s*'([^']*)'/) || pred.to_s.match(/\{([^}]+)\}\s*=\s*"([^"]*)"/)
    next unless m
    raw_col = m[1].strip; val = m[2]
    ref = master_ref(raw_col, calc, master_cols, DMEL)
    # master_cols may have been re-read; ensure the col is on the master
    unless master.fetch('columns').any? { |c| c['id'] == ref['id'] }
      master['columns'] << master_cols[raw_col]
    end
    applied_filters << { 'id' => "flt-#{SecureRandom.hex(4)}", 'kind' => 'list',
                         'columnId' => ref['id'], 'values' => [val] }
  end
  master['filters'] = applied_filters unless applied_filters.empty?
end
# refresh master columns (master_ref may have added the filter column)
master['columns'] = master_cols.values

spec = { 'name' => (an['Name'] || 'QuickSight Migration') + ' (from QuickSight)',
         'schemaVersion' => 1,
         'pages' => [{ 'id' => 'page-data', 'name' => 'Data', 'elements' => [master] },
                     { 'id' => 'page-dash', 'name' => (an['Name'] || 'Dashboard'), 'elements' => elements }] }
spec['folderId'] = opts[:folder] if opts[:folder]

File.write(opts[:out], JSON.pretty_generate(spec))
map_out = opts[:out].sub(/\.json$/, '') + '.map.json'
File.write(map_out, JSON.pretty_generate('dashPageId' => 'page-dash', 'masterElementId' => 'master', 'visualToElement' => vis_map))

# Persist a machine-readable per-visual warning manifest for any QuickSight visual
# Sigma can't recreate (sankey/radar/box-plot/waterfall/word-cloud/histogram/heat-map/
# layer-map/insight-ML/custom-content/plugin). This is the (c)-tail record — a clear
# "dropped, here's why" rather than a silent omission.
warn_out = opts[:out].sub(/\.json$/, '') + '.warnings.json'
File.write(warn_out, JSON.pretty_generate('warnings' => build_warnings))

STDERR.puts "workbook spec: master sources DM element \"#{DMEL}\" (#{dm_el}); #{elements.size} chart elements, #{master_cols.size} master cols#{applied_filters.empty? ? '' : "; #{applied_filters.size} filter(s) applied"} → #{opts[:out]} (+ #{map_out})"
elements.each { |e| STDERR.puts "  - #{e['kind']}: #{e['name']}" }
unless build_warnings.empty?
  STDERR.puts "#{build_warnings.size} visual(s) dropped (no Sigma equivalent) → #{warn_out}"
  build_warnings.each { |w| STDERR.puts "  ! #{w['type']}: #{w['reason']}" }
end
