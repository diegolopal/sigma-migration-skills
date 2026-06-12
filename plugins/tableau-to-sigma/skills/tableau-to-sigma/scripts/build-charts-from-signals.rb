#!/usr/bin/env ruby
# Build Sigma chart-element specs from parse-twb-layout.rb output + view CSVs +
# a master-column map.
#
# The agent's job is the data model + master table (deciding which DM columns
# the master needs, naming them, wiring Lookup/Coalesce as needed). This
# script's job is the chart layer: translating each Tableau chart zone into a
# Sigma element using the new parser signals (chart_kind, sort, aggregations,
# channels, filters) so chart kind / aggregator / sort match the source instead
# of relying on agent defaults.
#
# Usage:
#   ruby scripts/build-charts-from-signals.rb \
#     --tableau-dir /tmp/<name> \
#     --layout /tmp/<name>/dashboard-layout.json \
#     --master-map /tmp/<name>/master-columns.json \
#     --master-element-id master \
#     --out /tmp/<name>/chart-specs.json
#
# Inputs:
#   --tableau-dir       directory with get-workbook.json + views/<viewId>.csv
#   --layout            parse-twb-layout.rb output (per-dashboard zone list)
#   --master-map        JSON: regex-string → { id, name } mapping CSV header tokens
#                       to master-table column IDs. Example:
#                       { "(?i)region":      { "id": "m-region",  "name": "Region" },
#                         "(?i)gross revenue": { "id": "m-gross-rev", "name": "Gross Revenue" } }
#   --master-element-id ID of the master table in the workbook (default "master")
#   --out               output JSON: array of chart-element specs ready to embed
#                       in a workbook spec's pages[].elements[]
#
# Per chart zone, the script reads the matching view CSV's first two headers
# (dim + measure). It then:
#   - Maps each header to a master column using the regex map.
#   - Picks the Sigma element `kind` from chart_kind (with `automatic` → bar
#     fallback + a warning to verify against the PNG).
#   - Reads zone.sort: emits xAxis.sort iff Tableau had a <sort>. Otherwise
#     leaves xAxis unsorted (Sigma renders natural categorical / date order).
#   - Reads zone.aggregations: applies the right Sigma aggregator. Tableau
#     "Sum"→Sum, "Avg"→Avg, "Min"→Min, "Max"→Max, "Median"→Median,
#     "CountD"→CountDistinct, "None"→raw column (no agg), "User"→already-
#     aggregated calc field formula (use as-is via the master column).
#   - Reads zone.channels.color: if present, build one yAxis per category in
#     the master column's distinct values (best-effort — agent should fill in
#     the real category list when they know it; we emit a TODO marker).
#   - Skips action filters ("[Action (Foo)]") — those are cross-chart dashboard
#     actions, not value filters.
#
# Output: array of element specs. Drop into pages[].elements[] in the workbook
# spec and POST via post-and-readback.rb.

require 'json'
require 'csv'
require 'date'
require 'optparse'
require_relative 'learned-rules'

opts = { master_id: 'master' }
OptionParser.new do |p|
  p.on('--tableau-dir DIR')         { |v| opts[:tab] = v }
  p.on('--layout PATH')             { |v| opts[:layout] = v }
  p.on('--meta PATH', 'parse-twb-layout sister meta file (worksheets+shared_filters)') { |v| opts[:meta] = v }
  p.on('--master-map PATH')         { |v| opts[:mmap] = v }
  p.on('--master-element-id ID')    { |v| opts[:master_id] = v }
  p.on('--controls PATH', 'JSON file: array of control specs to emit alongside the chart elements') { |v| opts[:controls] = v }
  p.on('--title STR',     'Dashboard title text element to emit (e.g., "Orders Dashboard")')         { |v| opts[:title] = v }
  p.on('--page-per-worksheet', 'Emit one Sigma page per Tableau worksheet (ignore dashboard layout)') { opts[:pages_mode] = :worksheet }
  p.on('--page-per-dashboard', 'Emit ONE Sigma page per Tableau DASHBOARD (multi-dashboard workbooks - bead ptrt)') { opts[:pages_mode] = :dashboard }
  p.on('--auto-controls', 'Auto-emit Sigma controls from shared-view filters in --meta')              { opts[:auto_controls] = true }
  p.on('--out PATH')                { |v| opts[:out] = v }
end.parse!
%i[tab layout mmap out].each { |k| abort("missing --#{k.to_s.tr('_','-')}") unless opts[k] }

# ---- chart_kind → Sigma element kind ----
SIGMA_KIND = {
  'bar'           => 'bar-chart',
  'line'          => 'line-chart',
  'area'          => 'area-chart',
  'pie'           => 'pie-chart',
  'scatter'       => 'scatter-chart',
  'combo'         => 'combo-chart',
  'map-region'    => 'region-map',
  'map-point'     => 'point-map',
  'pivot-table'   => 'pivot-table',
  'table'         => 'table',
  'kpi'           => 'kpi-chart',
  'table-or-text' => 'table',         # legacy parser output — kept for back-compat
  'automatic'     => 'bar-chart',     # fallback; agent verifies against PNG
  'other'         => 'bar-chart'
}.freeze

# ---- Tableau derivation → Sigma aggregation function name ----
SIGMA_AGG = {
  'Sum'    => 'Sum',
  'Avg'    => 'Avg',
  'Min'    => 'Min',
  'Max'    => 'Max',
  'Median' => 'Median',
  'CountD' => 'CountDistinct',
  'Count'  => 'CountIf(IsNotNull(%s))',  # special — see render_agg below
  'None'   => nil,                       # no aggregation; raw column ref
  'User'   => nil                        # user-defined calc — already aggregated
}.freeze

# ---- Date truncation derivations ----
DATE_TRUNC = {
  'Year-Trunc'   => 'year',
  'Quarter-Trunc'=> 'quarter',
  'Month-Trunc'  => 'month',
  'Week-Trunc'   => 'week',
  'Day-Trunc'    => 'day',
  'Hour-Trunc'   => 'hour'
}.freeze

# Tableau relative-date offset window (first-period..last-period, in periods
# relative to now — e.g. first=-2,last=0 = "last 3 months") → explicit
# [startDate, endDate] bounds. Returns [nil, nil] for periods we don't bound
# (caller falls back to a pass-through relative filter).
#
# NOTE (bead z135, 2026-06-10): this is only the FALLBACK for offset windows.
# "This <period>" (first=0,last=0) filters are emitted as Sigma
# `mode: "current"` + `unit: <period>` — E2E re-verified that mode:current DOES
# filter the chart-data SQL when the control's `filters` target wiring is
# present, so the old hardcode-the-bounds workaround (which froze the filter
# and broke at period rollover) is no longer used for current-period filters.
def relative_period_bounds(period, first = 0, last = 0, now = Time.now)
  first = first.to_i
  last  = last.to_i
  case period.to_s.downcase
  when 'year'
    ["#{now.year + first}-01-01T00:00:00Z", "#{now.year + last}-12-31T23:59:59Z"]
  when 'quarter'
    q0 = Date.new(now.year, ((now.month - 1) / 3) * 3 + 1, 1)
    s  = q0 >> (3 * first)
    e  = (q0 >> (3 * last + 3)) - 1
    [s.strftime('%Y-%m-%dT00:00:00Z'), e.strftime('%Y-%m-%dT23:59:59Z')]
  when 'month'
    m0 = Date.new(now.year, now.month, 1)
    s  = m0 >> first
    e  = (m0 >> (last + 1)) - 1
    [s.strftime('%Y-%m-%dT00:00:00Z'), e.strftime('%Y-%m-%dT23:59:59Z')]
  else
    [nil, nil]
  end
end

# Back-compat alias — current period only.
def current_period_bounds(period, now = Time.now)
  relative_period_bounds(period, 0, 0, now)
end

def render_agg(agg, master_col_ref)
  return master_col_ref if agg.nil?
  if agg.include?('%s')
    agg.sub('%s', master_col_ref)
  else
    "#{agg}(#{master_col_ref})"
  end
end

# Tableau "User"-aggregated calc fields (derivation=User) are already-aggregated
# expressions like `SUM([Returns]) / COUNT([Order Id])` — wrapping them in
# another Sum() against a master column that doesn't exist emits an
# unresolvable `Sum([Master/X])` (bead k3kk). Decompose the Tableau formula
# directly into a Sigma formula against the master table instead. Returns nil
# when the formula contains anything beyond simple aggregates + arithmetic
# (the caller falls back and warns loudly).
USER_AGG_FN = {
  'SUM' => 'Sum', 'AVG' => 'Avg', 'MIN' => 'Min', 'MAX' => 'Max',
  'MEDIAN' => 'Median'
}.freeze

def translate_user_agg_formula(formula, mmap, columns_by_guid = {})
  s = formula.to_s.gsub(/\s+/, ' ').strip
  return nil if s.empty?
  # Resolve Tableau-internal GUID refs ([d3b60b0e-…]) to their captions first —
  # worksheet calc formulas reference columns by GUID, not caption.
  s = s.gsub(/\[([0-9a-f\-]{36})\]/i) do
    info = columns_by_guid[Regexp.last_match(1)]
    info && info['caption'] ? "[#{info['caption']}]" : "[#{Regexp.last_match(1)}]"
  end
  # IIF(c, t, e) → If(c, t, e) so guarded ratios (divide-by-zero protection)
  # survive the decomposition.
  s = s.gsub(/\bIIF\s*\(/i, 'If(')
  out = s.gsub(/\b(SUM|AVG|MIN|MAX|MEDIAN|COUNTD|COUNT)\s*\(\s*\[([^\]]+)\]\s*\)/i) do
    agg = Regexp.last_match(1).upcase
    col = Regexp.last_match(2)
    m   = map_column(col, mmap)
    ref = "[Master/#{m ? m['name'] : col}]"
    case agg
    when 'COUNT'  then "CountIf(IsNotNull(#{ref}))"
    when 'COUNTD' then "CountDistinct(#{ref})"
    else "#{USER_AGG_FN[agg]}(#{ref})"
    end
  end
  # ZN(expr) → Coalesce(expr, 0). One nesting level of parens is enough for
  # ZN(Sum([x]))-style wrappers; loop to handle repeated occurrences.
  while out =~ /\bZN\s*\(((?:[^()]|\([^()]*(?:\([^()]*\)[^()]*)*\))*)\)/i
    out = out.sub(Regexp.last_match(0), "Coalesce(#{Regexp.last_match(1)}, 0)")
  end
  # Validate: after stripping translated calls + refs, only arithmetic glue may
  # remain — otherwise the formula has constructs we can't safely auto-emit.
  residue = out.dup
  residue.gsub!(/\[Master\/[^\]]+\]/, '1')
  residue.gsub!(/\b(Sum|Avg|Min|Max|Median|CountDistinct|CountIf|IsNotNull|Coalesce|If)\b/, '')
  return nil unless residue =~ %r{\A[\s()+\-*/.,\d!=<>]*\z}
  out
end

# Row-level (non-aggregated) Tableau worksheet calc → Sigma formula over master
# columns (bead 3w4d: KPIs like "Avg. Days Since Order" aggregate a row-level
# DATEDIFF calc). Resolves GUID refs to captions, renames the common Tableau
# date/logic functions, rewrites bare refs to [Master/...]. Returns nil when
# the result still contains constructs we can't vouch for.
def translate_row_level_calc(formula, mmap, columns_by_guid = {})
  s = formula.to_s.gsub(/\s+/, ' ').strip
  return nil if s.empty?
  s = s.gsub(/\[([0-9a-f\-]{36})\]/i) do
    info = columns_by_guid[Regexp.last_match(1)]
    info && info['caption'] ? "[#{info['caption'].strip}]" : Regexp.last_match(0)
  end
  return nil if s =~ /\[[0-9a-f\-]{36}\]/i # unresolved GUID ref
  s = s.gsub(/\bDATEDIFF\s*\(\s*'([^']+)'\s*,/i) { "DateDiff(\"#{Regexp.last_match(1)}\", " }
  s = s.gsub(/\bDATEADD\s*\(\s*'([^']+)'\s*,/i)  { "DateAdd(\"#{Regexp.last_match(1)}\", " }
  s = s.gsub(/\bDATETRUNC\s*\(\s*'([^']+)'\s*,/i) { "DateTrunc(\"#{Regexp.last_match(1)}\", " }
  s = s.gsub(/\bDATEPART\s*\(\s*'([^']+)'\s*,/i) { "DatePart(\"#{Regexp.last_match(1)}\", " }
  s = s.gsub(/\bTODAY\s*\(\s*\)/i, 'Today()')
  s = s.gsub(/\bNOW\s*\(\s*\)/i, 'Now()')
  s = s.gsub(/\bIIF\s*\(/i, 'If(')
  s = s.gsub(/\bIFNULL\s*\(/i, 'Coalesce(')
  s = s.gsub(/\bABS\s*\(/i, 'Abs(')
  s = s.gsub(/'([^']*)'/) { %("#{Regexp.last_match(1)}") } # remaining single-quoted strings
  out = s.gsub(/\[([^\/\]]+)\]/) do
    cap = Regexp.last_match(1).strip
    m = map_column(cap, mmap)
    "[Master/#{m ? m['name'] : cap}]"
  end
  residue = out.dup
  residue.gsub!(/"(?:\\.|[^"\\])*"/, '1')
  residue.gsub!(/\[Master\/[^\]]+\]/, '1')
  residue.gsub!(/\b(DateDiff|DateAdd|DateTrunc|DatePart|Today|Now|If|Coalesce|Abs)\b/, '')
  return nil unless residue =~ %r{\A[\s()+\-*/.,\d!=<>]*\z}
  out
end

# Worksheet-local DIMENSION calc -> Sigma formula over master columns
# (bead z1d0: "Channel Group" CASE / "High Value Flag" IF-chain dims used to
# fall back to an unresolvable raw header). Handles:
#   CASE [col] WHEN "a" THEN "b" ... [ELSE e] END -> Switch([Master/col], ...)
#   IF c THEN r [ELSEIF c2 THEN r2]* [ELSE e] END -> nested If(...)
# Returns nil when the construct isn't recognized.
def translate_dim_calc(formula, mmap, columns_by_guid = {})
  s = formula.to_s.gsub(/\s+/, ' ').strip
  return nil if s.empty?
  s = s.gsub(/\[([0-9a-f\-]{36})\]/i) do
    info = columns_by_guid[Regexp.last_match(1)]
    info && info['caption'] ? "[#{info['caption'].strip}]" : Regexp.last_match(0)
  end
  return nil if s =~ /\[[0-9a-f\-]{36}\]/i
  master_ref = lambda do |str|
    str.gsub(/\[([^\/\]]+)\]/) do
      cap = Regexp.last_match(1).strip
      m = map_column(cap, mmap)
      "[Master/#{m ? m['name'] : cap}]"
    end
  end
  if (m = s.match(/\ACASE\s+(\[[^\]]+\])\s+(WHEN\b.*?)\s*\bEND\z/i))
    subject = master_ref.call(m[1])
    body = m[2]
    pairs = body.scan(/WHEN\s+(.+?)\s+THEN\s+(.+?)(?=\s+WHEN\b|\s+ELSE\b|\z)/i)
    else_m = body.match(/\bELSE\b\s+(.+)\z/i)
    return nil if pairs.empty?
    parts = [subject]
    pairs.each { |a, b| parts << a.strip << b.strip }
    parts << else_m[1].strip if else_m
    return "Switch(#{parts.join(', ')})"
  end
  if (m = s.match(/\AIF\s+(.+)\s+END\z/i))
    body = m[1]
    segs = body.split(/\s+ELSEIF\s+/i)
    else_expr = nil
    if (em = segs.last.match(/(.*)\s+ELSE\s+(.+)\z/i))
      segs[-1] = em[1]
      else_expr = em[2].strip
    end
    conds = []
    segs.each do |seg|
      cm = seg.match(/\A(.+?)\s+THEN\s+(.+)\z/i)
      return nil unless cm
      conds << [cm[1].strip, cm[2].strip]
    end
    expr = else_expr || 'Null'
    conds.reverse_each { |c, r| expr = "If(#{c}, #{r}, #{expr})" }
    return master_ref.call(expr.gsub(/\bAND\b/, 'and').gsub(/\bOR\b/, 'or').gsub(/\bNOT\b/, 'not'))
  end
  nil
end

# ---- FIXED-LOD / grain-aware two-stage aggregation --------------------------
# Tableau `{FIXED [dims] : AGG([m])}` (and Avg-of-a-dim-table-measure, which
# Tableau evaluates at the dim table's native grain under relationship
# semantics) CANNOT be expressed as a single workbook formula: Sigma evaluates
# chart formulas at the source's base row grain, and window functions silently
# error in master/DM calc columns (feedback_sigma_window_functions). The
# verified translation (LODPROBE2, 2026-06-11) is a HIDDEN TWO-LEVEL GROUPED
# helper element on the Data page (the PR #65 / ry0n machinery):
#   level 2 (inner)  = the FIXED dims, computing the LOD aggregate
#   level 1 (outer)  = the dims the chart plots (or a constant for KPIs),
#                      computing the SECOND-stage aggregate over the inner
#                      group values (Sigma grouping calcs aggregate over child
#                      GROUP values, not base rows — verified)
# The chart sources the helper and references the outer calc via Max(): a
# chart re-aggregates a grouped source at BASE grain (group calcs replicated
# per row, window-style — verified), and Max over replicated identical values
# is exact.
# ⚠ Carried chart dims join the OUTER grouping — exact iff they are
# functionally dependent on (coarser than) the FIXED dims (e.g. Customer
# Segment per Customer Id). The emitted warning documents this assumption.
def parse_fixed_lod(formula, columns_by_guid = {})
  s = formula.to_s.gsub(/\s+/, ' ').strip
  m = s.match(/\A\{\s*FIXED\s+(\[[^\]]+\](?:\s*,\s*\[[^\]]+\])*)\s*:\s*(SUM|AVG|MIN|MAX|MEDIAN|COUNTD|COUNT)\s*\(\s*\[([^\]]+)\]\s*\)\s*\}\z/i)
  return nil unless m
  resolve = lambda do |ref|
    if ref =~ /\A[0-9a-f\-]{36}\z/i
      info = columns_by_guid[ref]
      info && info['caption'] && info['caption'].strip
    else
      ref.strip
    end
  end
  dims = m[1].scan(/\[([^\]]+)\]/).flatten.map { |d| resolve.call(d) }
  meas = resolve.call(m[3])
  return nil if dims.empty? || dims.any?(&:nil?) || meas.nil?
  { 'dims' => dims, 'agg' => m[2].upcase, 'measure' => meas }
end

# Strip the aggregation/date-part prefix off a Tableau CSV header so it can be
# matched against a worksheet calc name ("Avg. Customer LTV LOD" -> "Customer
# LTV LOD"). Mirrors auto-parity-plan's header_base.
def header_base(h)
  h.to_s.strip
   .sub(/^(?:sum|avg|average|min|max|median|distinct count|count) of /i, '')
   .sub(/^(?:avg|sum|min|max|med|cnt|ctd)\.\s*/i, '')
   .sub(/^(?:second|minute|hour|day|week|month|quarter|year) of /i, '')
   .strip
end

LOD_INNER_AGG = {
  'SUM' => 'Sum', 'AVG' => 'Avg', 'MIN' => 'Min', 'MAX' => 'Max',
  'MEDIAN' => 'Median', 'COUNTD' => 'CountDistinct',
  'COUNT' => 'CountIf(IsNotNull(%s))'
}.freeze

# Build the hidden two-level grouped helper element for a FIXED LOD (see the
# block comment above). Returns [element_hash, src_name, stage2_col_name].
#   value_name:    display name of the LOD value ("Customer LTV LOD")
#   value_formula: the inner aggregate over master refs ("Sum([Master/Net Revenue])")
#   inner_keys:    [{'name','formula'}] — the FIXED dims (master refs)
#   outer_dims:    [{'name','formula'}] — chart dims carried downstream; empty
#                  for KPIs (a constant "All Rows" key keeps the outer level)
#   stage2_agg:    Sigma agg template for the second stage ('Avg' or '%s' form)
def build_two_stage_helper(el_id:, master_id:, value_name:, value_formula:,
                           inner_keys:, outer_dims:, stage2_agg:)
  src_id = "#{el_id}-lod-src"
  src_name = "#{value_name} Source (#{el_id.sub(/^el-(kpi-)?/, '')})"
  stage2_name = "#{value_name} 2nd Stage"
  outer = outer_dims.empty? ? [{ 'name' => 'All Rows', 'formula' => '1' }] : outer_dims
  outer_cols = outer.each_with_index.map do |d, i|
    { 'id' => "#{src_id}-d#{i}", 'name' => d['name'], 'formula' => d['formula'] }
  end
  inner_cols = inner_keys.each_with_index.map do |k, i|
    { 'id' => "#{src_id}-k#{i}", 'name' => k['name'], 'formula' => k['formula'] }
  end
  value_col  = { 'id' => "#{src_id}-v", 'name' => value_name, 'formula' => value_formula }
  stage2_col = { 'id' => "#{src_id}-s2", 'name' => stage2_name,
                 'formula' => render_agg(stage2_agg, "[#{value_name}]") }
  element = {
    'id' => src_id, 'kind' => 'table', 'name' => src_name,
    'source' => { 'kind' => 'table', 'elementId' => master_id },
    'columns' => outer_cols + inner_cols + [value_col, stage2_col],
    'groupings' => [
      { 'id' => "#{src_id}-g1", 'groupBy' => outer_cols.map { |c| c['id'] },
        'calculations' => [stage2_col['id']] },
      { 'id' => "#{src_id}-g2", 'groupBy' => inner_cols.map { |c| c['id'] },
        'calculations' => [value_col['id']] }
    ],
    'visibleAsSource' => false
  }
  [element, src_name, stage2_name]
end

# Build the hidden DIM-GRAIN passthrough helper for an aggregate of a dim-table
# measure (grain annotation on the master-map entry — see mechanical-specs
# derive_master). The helper sources the DIM ELEMENT of the data model itself
# (NOT the fact master): Tableau's relationship semantics aggregate a dim-table
# column over the dim table's OWN rows, including entities with no fact match —
# a fact-side group-by can never reproduce that (verified: AvgLTR 11418.65 over
# 25 CUSTOMER_DIM rows vs 10480.53 fact-side). The source elementId is a
# placeholder ("__DM_ELEMENT__:<name>") — migrate-tableau resolves it against
# the posted DM readback (build-charts runs before it knows live element ids).
# Returns [element_hash, src_name].
def build_dim_grain_helper(el_id:, grain:, columns:)
  src_id = "#{el_id}-grain-src"
  src_name = "#{grain['element']} Grain (#{el_id.sub(/^el-(kpi-)?/, '')})"
  cols = columns.each_with_index.map do |name, i|
    { 'id' => "#{src_id}-c#{i}", 'name' => name, 'formula' => "[#{grain['element']}/#{name}]" }
  end
  element = {
    'id' => src_id, 'kind' => 'table', 'name' => src_name,
    'source' => { 'kind' => 'data-model', 'elementId' => "__DM_ELEMENT__:#{grain['element']}" },
    'columns' => cols,
    'visibleAsSource' => false
  }
  [element, src_name]
end

# Translate the Tableau column reference inside aggregations dict to a clean key
# we can look up. Tableau uses internal IDs like "[33b6c718-9b55-3dc0-9698-…]"
# OR friendly names like "[NET_REVENUE]". We strip the brackets for matching.
def strip_brackets(s)
  s.to_s.sub(/^\[/, '').sub(/\]$/, '')
end

# Match a CSV header (e.g., "Gross Revenue", "Distinct count of Order Id") to
# a master-table column using regex map.
def map_column(header, mmap)
  # Strip leading/trailing whitespace from the header before matching. Tableau
  # column captions sometimes carry trailing whitespace (e.g., "Order Date ")
  # from the source .twb XML — `(?i)^order date$` won't match it without this.
  h = header.to_s.strip
  mmap.each do |pat, info|
    return info if Regexp.new(pat).match?(h)
  end
  nil
end

# Resolve which Sigma column a Tableau <sort column="..."> targets: the chart's
# dim or its measure. Tableau sort columns look like
# `[federated.X].[none:REGION:nk]` or `[sum:NET_REVENUE:qk]` — pull the middle
# token of the last bracket segment and fuzzy-match against the dim names.
# A sort on the dim itself = alphabetic/natural dim sort; anything else
# (field sort on the measure, unresolvable) sorts by the measure, which was
# the previous hardcoded behaviour.
def sort_target_column_id(sort_info, dim, dim_hdr, dim_col_id, meas_col_id)
  raw   = sort_info['column'].to_s
  inner = raw[/\[([^\[\]]+)\]\z/, 1].to_s
  token = (inner.split(':')[1] || inner).downcase.gsub(/\W+/, '')
  return meas_col_id if token.empty?
  dim_keys = [dim && dim['name'], dim_hdr].compact
                                          .map { |x| x.to_s.downcase.gsub(/\W+/, '') }
                                          .reject(&:empty?)
  return dim_col_id if dim_keys.any? { |k| token == k || token.include?(k) || k.include?(token) }
  meas_col_id
end

# Pick the best aggregation for a header. CSV headers often hint at the
# aggregation ("Sum of X" / "Distinct count of X" / etc.).
def infer_csv_agg(header)
  case header.to_s.strip
  # Tableau CSV headers use BOTH the long form ("Avg of X") and the dotted
  # short form ("Avg. Days To Ship") — the short form previously fell through
  # to the Sum default and mis-aggregated every "Avg. X" measure (bead z1d0).
  when /^sum(\.\s*| of )/i           then 'Sum'
  when /^(avg|average)(\.\s*| of )/i then 'Avg'
  when /^min(\.\s*| of )/i           then 'Min'
  when /^max(\.\s*| of )/i           then 'Max'
  when /^med(ian)?(\.\s*| of )/i     then 'Median'
  when /\bdistinct count\b/i         then 'CountD'
  when /^(ctd|cntd)(\.\s*| of )/i    then 'CountD'
  when /\bcount\b/i                  then 'Count'
  else nil
  end
end

# ---- Load inputs ----
layout = JSON.parse(File.read(opts[:layout]))
mmap   = JSON.parse(File.read(opts[:mmap]))
meta   = opts[:meta] ? JSON.parse(File.read(opts[:meta])) : { 'worksheets' => {}, 'shared_filters' => [] }
# Customer-learned rules (~/.tableau-to-sigma/learned-rules.yaml). Empty list
# is normal for first-time customers — rules accumulate as the gap-scout
# subagent validates translations.
LEARNED_RULES = LearnedRules.load
warn "loaded #{LEARNED_RULES.length} customer-learned rule(s) from #{LearnedRules.rules_path}" if LEARNED_RULES.any?
gw     = JSON.parse(File.read(File.join(opts[:tab], 'get-workbook.json')))
views  = gw.dig('views', 'view') || []
views  = [views] unless views.is_a?(Array)
view_by_name = views.each_with_object({}) { |v, h| h[v['name']] = v }

# Translate a Tableau format-value string (already parsed by the parser's
# translate_format) into a Sigma format hash. Done here so we don't fork the
# parser logic — we just call into it via a duplicated minimal translator.
def tableau_format_to_sigma(s)
  return nil if s.nil? || s.empty?
  segments = s.split(';')
  pos = segments[0] || s
  neg = segments[1]
  prefix = (neg && neg.include?('(') && neg.include?(')')) ? '(' : ''
  if (m = pos.match(/^p\d*(?:\.(\d+))?%$/i))
    decimals = (m[1] || '').length
    return { 'kind' => 'number', 'formatString' => "#{prefix},.#{decimals}%" }
  end
  if (m = pos.match(/^C\d+(?:\.(\d+))?%?$/))
    decimals = (m[1] || '').length
    return { 'kind' => 'number', 'formatString' => "#{prefix}$,.#{decimals}f", 'currencySymbol' => '$' }
  end
  if pos =~ /^c?["\\]*\$/ || pos.start_with?('$')
    decimals = (pos.match(/\.(0+)/) || [])[1].to_s.length
    return { 'kind' => 'number', 'formatString' => "#{prefix}$,.#{decimals}f", 'currencySymbol' => '$' }
  end
  if pos =~ /^[#,0]+(?:\.(0+))?$/
    decimals = ($1 || '').length
    return { 'kind' => 'number', 'formatString' => "#{prefix},.#{decimals}f" }
  end
  if s =~ /yyyy|MMM|MM|dd|HH/
    f = s.gsub('yyyy','%Y').gsub('yy','%y').gsub('MMMM','%B').gsub('MMM','%b').gsub('MM','%m')
         .gsub('dd','%d').gsub('HH','%H').gsub('mm','%M').gsub('ss','%S')
    return { 'kind' => 'datetime', 'formatString' => f }
  end
  nil
end

# Sigma formulas reference controls by `controlId` in brackets, NOT by display
# name. This helper computes the controlId the auto-controls block will emit
# for a given parameter caption so the translated Switch/If formulas match.
def param_control_ref(caption)
  "[ctl-param-#{caption.downcase.gsub(/\W+/, '-').sub(/-$/, '')}]"
end

# ---- Tableau table-calc translators ---------------------------------------
# Translate Tableau table-calculation functions to their Sigma equivalents.
# Returns the translated formula, plus a hint about Sigma-specific caveats
# (e.g., "window functions silently error in grouping-table charts — add to a
# non-grouping context or Custom SQL DM element").
#
# Function mappings (Sigma names):
#   INDEX()                  → RowNumber()
#   LOOKUP(expr, n)          → Lag(expr, n)  (positive n) / Lead(expr, -n) (neg)
#   LOOKUP(expr, 0)          → expr  (zero offset is identity)
#   RANK(expr [, 'desc'])    → Rank(expr [, "desc"])
#   RANK_DENSE(expr)         → RankDense(expr)
#   RANK_UNIQUE(expr)        → RowNumber() within ranked partition
#   RANK_PERCENTILE(expr)    → RankPercentile(expr)
#   TOTAL(SUM(x))            → Sum(x)  (Sigma metric on master without dim group)
#   SIZE()                   → Count(*) OVER ()  — no direct Sigma fn; warn
#   FIRST()                  → RowNumber() - 1   (Tableau FIRST returns 0-indexed)
#   LAST()                   → no direct equiv; needs Count-RowNumber pattern
#   ZN(x)                    → Coalesce(x, 0)
#   COUNTD(x)                → CountDistinct(x)
#   IIF(c, t, e)             → If(c, t, e)
#   IFNULL(x, y)             → Coalesce(x, y)
def translate_tableau_tc(formula)
  return [nil, nil] if formula.nil? || formula.empty?
  s = formula.dup
  hints = []
  changed = false

  # Order matters — apply table-calc translations BEFORE simple renames so the
  # match patterns (LOOKUP / TOTAL(COUNTD()) etc.) see the original Tableau
  # syntax.

  # INDEX() → RowNumber()
  if s.gsub!(/\bINDEX\s*\(\s*\)/, 'RowNumber()')
    hints << 'INDEX()→RowNumber()'; changed = true
  end

  # LOOKUP(expr, 0) — drop the wrapper. Use a balanced-paren match.
  while s =~ /\bLOOKUP\s*\(\s*((?:[^,()]|\([^()]*\)|\([^()]*\([^()]*\)[^()]*\))+?)\s*,\s*0\s*\)/
    s = s.sub($~[0], $1)
    hints << 'LOOKUP(x, 0)→x'; changed = true
  end
  # LOOKUP(expr, -n) → Lead(expr, n)
  while s =~ /\bLOOKUP\s*\(\s*((?:[^,()]|\([^()]*\)|\([^()]*\([^()]*\)[^()]*\))+?)\s*,\s*-(\d+)\s*\)/
    s = s.sub($~[0], "Lead(#{$1}, #{$2})")
    hints << 'LOOKUP(x, -n)→Lead(x, n)'; changed = true
  end
  # LOOKUP(expr, n) where n >= 1 → Lag(expr, n)
  while s =~ /\bLOOKUP\s*\(\s*((?:[^,()]|\([^()]*\)|\([^()]*\([^()]*\)[^()]*\))+?)\s*,\s*(\d+)\s*\)/
    s = s.sub($~[0], "Lag(#{$1}, #{$2})")
    hints << 'LOOKUP(x, n)→Lag(x, n)'; changed = true
  end

  # TOTAL(SUM(x)) → Sum(x); TOTAL(COUNTD(x)) → CountDistinct(x); TOTAL(AVG(x))
  if s.gsub!(/\bTOTAL\s*\(\s*SUM\s*\(((?:[^()]|\([^()]*\))+)\)\s*\)/, 'Sum(\1)')
    hints << 'TOTAL(SUM(x))→Sum(x) (non-grouping context)'; changed = true
  end
  if s.gsub!(/\bTOTAL\s*\(\s*COUNTD\s*\(((?:[^()]|\([^()]*\))+)\)\s*\)/, 'CountDistinct(\1)')
    hints << 'TOTAL(COUNTD(x))→CountDistinct(x) (non-grouping context)'; changed = true
  end
  if s.gsub!(/\bTOTAL\s*\(\s*AVG\s*\(((?:[^()]|\([^()]*\))+)\)\s*\)/, 'Avg(\1)')
    hints << 'TOTAL(AVG(x))→Avg(x) (non-grouping context)'; changed = true
  end

  # RANK([col], 'desc') / RANK([col]) / RANK_DENSE / RANK_PERCENTILE
  if s.gsub!(/\bRANK\s*\(\s*((?:[^,()]|\([^()]*\))+?)\s*,\s*'(asc|desc)'\s*\)/, 'Rank(\1, "\2")')
    hints << "RANK→Rank"; changed = true
  end
  if s.gsub!(/\bRANK\s*\(\s*((?:[^,()]|\([^()]*\))+?)\s*\)/, 'Rank(\1)')
    hints << "RANK→Rank"
    changed = true
  end
  if s.gsub!(/\bRANK_DENSE\s*\(\s*((?:[^,()]|\([^()]*\))+?)\s*\)/, 'RankDense(\1)')
    hints << "RANK_DENSE→RankDense"; changed = true
  end
  if s.gsub!(/\bRANK_PERCENTILE\s*\(\s*((?:[^,()]|\([^()]*\))+?)\s*\)/, 'RankPercentile(\1)')
    hints << "RANK_PERCENTILE→RankPercentile"; changed = true
  end

  # Simple renames done AFTER table-calc rewrites so the table-calc patterns
  # match the original Tableau spelling.
  if s.gsub!(/\bZN\s*\(/, 'Coalesce(')
    # ZN takes one arg; pair the matching close-paren and append `, 0`. Walk
    # the string and balance parens to find the right `)`.
    out = String.new
    i = 0
    while i < s.length
      if s[i, 9] == 'Coalesce(' && (i == 0 || s[i - 1] !~ /\w/)
        out << 'Coalesce('
        depth = 1
        j = i + 9
        while j < s.length && depth > 0
          depth += 1 if s[j] == '('
          depth -= 1 if s[j] == ')'
          break if depth == 0
          j += 1
        end
        out << s[i + 9...j] << ', 0)'
        i = j + 1
      else
        out << s[i]
        i += 1
      end
    end
    s = out
    changed = true
  end
  if s.gsub!(/\bIIF\s*\(/, 'If(')
    changed = true
  end
  if s.gsub!(/\bIFNULL\s*\(/, 'Coalesce(')
    changed = true
  end
  if s.gsub!(/\bCOUNTD\s*\(/, 'CountDistinct(')
    changed = true
  end

  # SIZE() — no direct Sigma equivalent for partition size at the formula level.
  # Leave as-is and warn so the agent rewrites manually (commonly Count(*)+OVER).
  if s.include?('SIZE()')
    hints << 'SIZE() has no direct Sigma equivalent — rewrite as Count(*) in a non-grouping context or Custom SQL'
  end

  # FIRST() / LAST() — special.
  if s.include?('FIRST()')
    hints << 'FIRST() → RowNumber() - 1 (Tableau FIRST is 0-indexed first row)'
  end
  if s.include?('LAST()')
    hints << 'LAST() → no direct Sigma equivalent — use a Count() - RowNumber() pattern or Custom SQL'
  end

  # LOD calcs — Tableau's `{FIXED [dim] : AGG([m])}` family.
  # Translation strategy (Sigma):
  #   {FIXED [dims] : AGG([m])}   → AUTO-BUILT when plotted as a chart/KPI
  #                                 measure: hidden two-level grouped helper
  #                                 element (inner = FIXED dims computing the
  #                                 LOD aggregate, outer = chart dims computing
  #                                 the 2nd-stage aggregate) — see
  #                                 parse_fixed_lod/build_two_stage_helper.
  #   {FIXED : SUM([m])}          → unscoped `Sum([m])` (workbook-level scalar)
  #   {INCLUDE [dim] : SUM([m])}  → add [dim] to chart grouping and just use Sum
  #   {EXCLUDE [dim] : SUM([m])}  → remove [dim] from chart grouping, use Sum
  # INCLUDE/EXCLUDE need the chart's grouping context — surfaced as manual
  # hints, not auto-emitted.
  if s =~ /\{\s*FIXED\s+\[([^\]]+)\]\s*:\s*(SUM|AVG|MIN|MAX|COUNT|COUNTD)\s*\(\[([^\]]+)\]\)\s*\}/i
    dim, agg, m = $1, $2.upcase, $3
    hints << "FIXED LOD → auto-built as a hidden grouped helper element when plotted (inner grain = [#{dim}], " \
             "#{agg}(#{m}); 2nd-stage agg at chart grain) ⚠ carried chart dims must be functionally dependent on the FIXED dims"
    changed = true
  end
  if s =~ /\{\s*FIXED\s*:\s*(SUM|AVG|MIN|MAX|COUNT|COUNTD)\s*\(\[([^\]]+)\]\)\s*\}/i
    agg, m = $1.upcase, $2
    sigma_agg = { 'SUM' => 'Sum', 'AVG' => 'Avg', 'MIN' => 'Min', 'MAX' => 'Max',
                  'COUNT' => 'Count', 'COUNTD' => 'CountDistinct' }[agg]
    hints << "FIXED-no-dim LOD → workbook scalar metric #{sigma_agg}([Master/#{m}]) (no group by)"
    changed = true
  end
  if s =~ /\{\s*INCLUDE\s+\[([^\]]+)\]\s*:\s*(SUM|AVG)\s*\(\[([^\]]+)\]\)\s*\}/i
    dim, agg, m = $1, $2.upcase, $3
    hints << "INCLUDE LOD on [#{dim}] → add [Master/#{dim}] to chart grouping, use plain #{agg}([Master/#{m}])"
    changed = true
  end
  if s =~ /\{\s*EXCLUDE\s+\[([^\]]+)\]\s*:\s*(SUM|AVG)\s*\(\[([^\]]+)\]\)\s*\}/i
    dim, agg, m = $1, $2.upcase, $3
    hints << "EXCLUDE LOD on [#{dim}] → remove [Master/#{dim}] from chart grouping, use plain #{agg}([Master/#{m}])"
    changed = true
  end

  return [nil, nil] unless changed
  hints.uniq!
  hints << 'NOTE: Sigma window functions (Rank/Lag/Lead/Cumulative*) silently error in grouping-table charts and DM-element calc cols — add to a workbook-master non-grouping context OR a Custom SQL DM element' if hints.any? { |h| h =~ /Rank|Lag|Lead|RowNumber/ }
  [s, hints.join('; ')]
end

# ---- Parameter / CASE translator ------------------------------------------
# Tableau CASE-on-parameter:
#   CASE [Parameters].[Analysis Type]
#     WHEN "Customer Type" THEN [CUSTOMER_TYPE]
#     WHEN "Overall"       THEN "Overall"
#     WHEN "Region"        THEN [REGION_NAME]
#     ELSE "Country"
#   END
# Sigma:
#   Switch([Analysis Type], "Customer Type", [Customer Type], "Overall",
#          "Overall", "Region", [Region Name], "Country")
#
# We accept the slightly-loose form Tableau uses (`Case` token-case insensitive,
# bracket refs for parameter and for dim columns, mixed quoted strings).
def translate_case_on_param(formula, param_captions)
  return nil unless formula =~ /\bCASE\b/i
  # Strip newlines + collapse spaces
  s = formula.gsub(/\s+/, ' ').strip
  m = s.match(/\bCASE\b\s+(.*?)\s+(WHEN\b.*?)\s+\bEND\b/i)
  return nil unless m
  param_ref = m[1].strip   # the value being switched, e.g. [Parameters].[X] or [X]
  body = m[2]
  # Pull WHEN ... THEN ... pairs + optional ELSE
  pairs = body.scan(/WHEN\s+(.+?)\s+THEN\s+(.+?)(?=\s+WHEN\b|\s+ELSE\b|\z)/i).map { |a, b| [a.strip, b.strip] }
  else_match = body.match(/\bELSE\b\s+(.+)\z/i)
  else_expr = else_match && else_match[1].strip
  return nil if pairs.empty?
  # Normalise parameter reference: prefer the human caption when we know it,
  # otherwise strip [Parameters].[...] wrapping.
  param_caption = nil
  if (mm = param_ref.match(/\[Parameters?(?:\s*\([^)]*\))?\]\s*\.\s*\[([^\]]+)\]/i))
    param_caption = mm[1]
  elsif (mm = param_ref.match(/\[([^\]]+)\]/))
    param_caption = mm[1] if param_captions.include?(mm[1])
  end
  return nil unless param_caption
  parts = [param_control_ref(param_caption)]
  pairs.each { |when_val, then_val| parts << when_val; parts << then_val }
  parts << else_expr if else_expr
  "Switch(#{parts.join(', ')})"
end

# Translate IF/ELSEIF chains on a parameter ref:
#   IF [Param] = "A" THEN x ELSEIF [Param] = "B" THEN y ELSE z END
# → Switch([Param], "A", x, "B", y, z)
def translate_if_chain_on_param(formula, param_captions)
  s = formula.gsub(/\s+/, ' ').strip
  return nil unless s =~ /\bIF\b.*\bEND\b/i
  return nil unless param_captions.any? { |cap| s.include?("[#{cap}]") }
  m = s.match(/\bIF\b\s+(.+?)\s+\bEND\b/i)
  return nil unless m
  body = m[1]
  # Pull `<cond> THEN <result>` segments delimited by ELSEIF
  segs = body.scan(/(.+?)\s+THEN\s+(.+?)(?=\s+ELSEIF\b|\s+ELSE\b|\z)/i).map { |c, r| [c.strip, r.strip] }
  else_match = body.match(/\bELSE\b\s+(.+)\z/i)
  else_expr = else_match && else_match[1].strip
  return nil if segs.empty?
  # All conditions must be `[Param] = "..."` for the same parameter
  param_caption = nil
  cases = []
  segs.each do |cond, result|
    cm = cond.match(/\[([^\]]+)\]\s*=\s*("[^"]*"|'[^']*'|\S+)/)
    return nil unless cm
    p_cap = cm[1]
    return nil unless param_captions.include?(p_cap)
    param_caption ||= p_cap
    return nil unless p_cap == param_caption
    val = cm[2]
    val = val.gsub("'", '"') if val.start_with?("'")
    cases << val << result
  end
  parts = [param_control_ref(param_caption)] + cases
  parts << else_expr if else_expr
  "Switch(#{parts.join(', ')})"
end

# Pick the Tableau format for a given header against a worksheet's formats dict.
# Match by best-effort: field ref contains a column GUID OR a friendly name
# fragment that overlaps with the header.
def pick_tableau_format(formats, header)
  return nil if formats.nil? || formats.empty?
  hkey = header.to_s.downcase.gsub(/\W+/, '')
  formats.each do |field, val|
    body = field.to_s.downcase
    # Friendly-name match: format key looks like `[usr:Return Rate:qk]`. Pull
    # the human chunk and compare to header.
    inner = body.scan(/\[([^\]]+)\]/).flatten.last.to_s
    parts = inner.split(':')
    friendly = parts.length >= 3 ? parts[1].to_s.gsub(/\W+/, '') : ''
    if !friendly.empty? && (friendly == hkey || hkey.include?(friendly) || friendly.include?(hkey))
      sigma = tableau_format_to_sigma(val)
      return sigma if sigma
    end
  end
  nil
end

# ---- Pivot-table emission --------------------------------------------------
# Tableau crosstab worksheets (mark=Text or mark=Square with dims on both
# Rows AND Cols shelves, OR the Measure Names crosstab pattern) translate to
# a Sigma `pivot-table` element with `rowsBy` / `columnsBy` / `values` arrays,
# NOT a plain `table`. Without this, parse-twb-layout's `pivot-table` chart_kind
# would fall through to the default table builder and lose the pivot shape.
#
# Resolves shelf fields via the parser's columns_by_guid lookup + the master-
# column regex map. Returns the element hash, or nil if shelf info is unusable
# (caller falls back to the standard table/chart flow with a warning).
SHELF_AGG_FOR_PREFIX = {
  'sum' => 'Sum', 'avg' => 'Avg', 'min' => 'Min', 'max' => 'Max',
  'median' => 'Median', 'count' => 'CountIf(IsNotNull(%s))',
  'countd' => 'CountDistinct', 'cntd' => 'CountDistinct'
}.freeze
SHELF_TRUNC_FOR_PREFIX = {
  'yr' => 'year', 'qr' => 'quarter', 'mn' => 'month',
  'wk' => 'week', 'dy' => 'day', 'hr' => 'hour'
}.freeze

def resolve_shelf_field(field, meta, mmap)
  guid = field['guid']
  cap_for_field = nil
  if guid
    info = (meta['columns_by_guid'] || {})[guid]
    cap_for_field = info && info['caption']
  end
  cap_for_field ||= field['raw'].to_s
                                 .sub(/^\[[^\]]+\]\./, '')
                                 .gsub(/^\[|\]$/, '')
                                 .sub(/^[a-z]+:/i, '')
                                 .sub(/:[a-z]+$/i, '')
  m = map_column(cap_for_field, mmap)
  m ||= { 'id' => "m-#{cap_for_field.downcase.gsub(/\W+/, '-')}", 'name' => cap_for_field }
  [m, cap_for_field]
end

def build_pivot_element(z, meta, mmap, opts, warnings)
  cap = z['caption']
  el_id = "el-#{cap.downcase.gsub(/\W+/, '-')[0..40]}".sub(/-$/, '')
  rows_shelf = z['rows_shelf'] || {}
  cols_shelf = z['cols_shelf'] || {}

  cols_array = []
  rows_by    = []
  cols_by    = []
  values_arr = []
  seen_ids   = {}

  add_col = lambda do |field, target|
    m, _cap = resolve_shelf_field(field, meta, mmap)
    base = "p-#{el_id}-#{target}-#{(m['name'] || 'x').downcase.gsub(/\W+/, '-')}"
    col_id = base
    n = 1
    while seen_ids[col_id]
      col_id = "#{base}-#{n}"
      n += 1
    end
    seen_ids[col_id] = true

    deriv = field['derivation'].to_s.downcase
    formula =
      if field['role'] == 'measure'
        agg = SHELF_AGG_FOR_PREFIX[deriv] || 'Sum'
        if agg.include?('%s')
          agg.sub('%s', "[Master/#{m['name']}]")
        else
          "#{agg}([Master/#{m['name']}])"
        end
      elsif field['role'] == 'dim' && SHELF_TRUNC_FOR_PREFIX[deriv]
        %(DateTrunc("#{SHELF_TRUNC_FOR_PREFIX[deriv]}", [Master/#{m['name']}]))
      else
        "[Master/#{m['name']}]"
      end

    col_obj = { 'id' => col_id, 'name' => m['name'], 'formula' => formula }
    if field['role'] == 'measure'
      tab_fmt = pick_tableau_format(z['formats'], m['name'])
      col_obj['format'] = tab_fmt if tab_fmt
      col_obj['format'] ||= m['format'] if m['format'].is_a?(Hash)
      col_obj['format'] ||= { 'kind' => 'number', 'formatString' => ',.0f' }
    elsif SHELF_TRUNC_FOR_PREFIX[deriv]
      col_obj['format'] = { 'kind' => 'datetime', 'formatString' => '%b %Y' }
    end
    cols_array << col_obj
    case target
    when :row   then rows_by    << { 'id' => col_id }
    when :col   then cols_by    << { 'id' => col_id }
    when :value then values_arr << col_id
    end
  end

  (rows_shelf['fields'] || []).each do |f|
    add_col.call(f, :row)   if f['role'] == 'dim'
    add_col.call(f, :value) if f['role'] == 'measure'
  end
  (cols_shelf['fields'] || []).each do |f|
    add_col.call(f, :col)   if f['role'] == 'dim'
    add_col.call(f, :value) if f['role'] == 'measure'
  end

  # Measure-Names pattern: shelves carry the placeholder but the actual
  # measures live in z['measures']. Materialize them here.
  if values_arr.empty? && (z['measures'] || []).any?
    z['measures'].each do |m|
      add_col.call({
        'role'       => 'measure',
        'derivation' => (m['derivation'] || 'Sum').to_s.downcase,
        'raw'        => m['column'],
        'guid'       => guid_from_text(m['column'].to_s)
      }, :value)
    end
  end

  if values_arr.empty? || (rows_by.empty? && cols_by.empty?)
    warnings << "'#{cap}' is flagged as a Tableau crosstab but shelves did not yield rows+cols+values — falling back to flat table"
    return nil
  end

  {
    'id'        => el_id,
    'kind'      => 'pivot-table',
    'name'      => cap,
    'source'    => { 'kind' => 'table', 'elementId' => opts[:master_id] },
    'columns'   => cols_array,
    'values'    => values_arr,
    'rowsBy'    => rows_by,
    'columnsBy' => cols_by
  }
end

# Minimal GUID-from-text helper for shelf measures whose `column` reads like
# `[federated.X].[sum:GUID:qk]` or just `[GUID]`. Mirrors the parser helper.
def guid_from_text(s)
  return nil if s.nil? || s.empty?
  m = s.match(/\[(?:[a-z\-]+:)?([0-9a-f\-]{36})(?::[a-z]+)?\]/i)
  m && m[1]
end

# ---- KPI emission ---------------------------------------------------------
# Tableau "scorecard" / "big number" tiles — mark=Text or mark=Square with a
# single measure and no dimensions — translate to a Sigma kpi-chart element.
# Without this, the chart_kind=kpi worksheet would fall through to the
# CSV-driven flat-table flow and quietly produce nothing usable.
# See beads-sigma-bw3.
def build_kpi_element(z, meta, mmap, opts, warnings, data_elements = [])
  cap = z['caption']
  el_id = "el-kpi-#{cap.downcase.gsub(/\W+/, '-')[0..38]}".sub(/-$/, '')

  rows_shelf = z['rows_shelf'] || {}
  cols_shelf = z['cols_shelf'] || {}

  # Find the KPI's measure: first from shelves (preferred — explicit derivation),
  # then fall back to the worksheet's `measures` array (when the measure is on
  # the Marks card via Text/Color/Size encoding rather than a shelf).
  measure_field = nil
  (rows_shelf['fields'] || []).each { |f| measure_field ||= f if f['role'] == 'measure' }
  (cols_shelf['fields'] || []).each { |f| measure_field ||= f if f['role'] == 'measure' }
  if measure_field.nil? && (z['measures'] || []).any?
    m = z['measures'].first
    measure_field = {
      'role'       => 'measure',
      'derivation' => (m['derivation'] || 'Sum').to_s.downcase,
      'raw'        => m['column'],
      'guid'       => guid_from_text(m['column'].to_s)
    }
  end

  if measure_field.nil?
    warnings << "'#{cap}' is flagged as KPI but no measure resolved from shelves or worksheet — skipping"
    return nil
  end

  master, field_cap = resolve_shelf_field(measure_field, meta, mmap)
  deriv = measure_field['derivation'].to_s.downcase
  norm = ->(x) { x.to_s.gsub(/^\[|\]$/, '').strip.downcase }

  source_eid = opts[:master_id]
  two_stage_formula = nil
  ws_calc_lod = (z['calculations'] || []).find { |c| norm.call(c['name']) == norm.call(field_cap) }
  lod = ws_calc_lod && parse_fixed_lod(ws_calc_lod['formula'], meta['columns_by_guid'] || {})
  if lod
    # FIXED-LOD KPI → two-level helper (constant outer key), Max() the outer calc.
    map_name = ->(capn) { (m = map_column(capn, mmap)) ? m['name'] : capn }
    inner_keys = lod['dims'].map { |d| n = map_name.call(d); { 'name' => n, 'formula' => "[Master/#{n}]" } }
    meas_name = map_name.call(lod['measure'])
    value_formula = render_agg(LOD_INNER_AGG[lod['agg']], "[Master/#{meas_name}]")
    stage2 = SHELF_AGG_FOR_PREFIX[deriv] || 'Avg'
    helper, src_name, s2_name = build_two_stage_helper(
      el_id: el_id, master_id: opts[:master_id], value_name: field_cap.to_s.strip,
      value_formula: value_formula, inner_keys: inner_keys, outer_dims: [], stage2_agg: stage2)
    data_elements << helper
    source_eid = helper['id']
    two_stage_formula = "Max([#{src_name}/#{s2_name}])"
    warnings << "'#{cap}' KPI measure '#{field_cap}' is a FIXED LOD ({FIXED #{lod['dims'].join(', ')} : #{lod['agg']}(#{lod['measure']})}) — " \
                "auto-built hidden grouped helper '#{src_name}' (inner grain = FIXED dims, 2nd-stage #{stage2}) ⚠ verify in Sigma"
  elsif %w[avg average].include?(deriv) && master['formula'].nil? && master['grain'] && ws_calc_lod.nil?
    # Grain-aware average (bead AvgLTR): Avg of a dim-table measure — Tableau
    # evaluates it at the DIM table's native grain (all dim rows, incl. entities
    # with no fact match). Source the DM dim element directly via a hidden
    # passthrough helper; a chart re-aggregates an UNGROUPED source at its base
    # grain, so a plain Avg over the helper is exact.
    helper, src_name = build_dim_grain_helper(el_id: el_id, grain: master['grain'],
                                              columns: [master['name'].to_s.strip])
    data_elements << helper
    source_eid = helper['id']
    two_stage_formula = "Avg([#{src_name}/#{master['name'].to_s.strip}])"
    warnings << "'#{cap}' KPI measure '#{field_cap}' averages a #{master['grain']['element']} column — Tableau evaluates this at the " \
                "dim table's native grain (relationship semantics), so the KPI sources the DM '#{master['grain']['element']}' element " \
                "via hidden helper '#{src_name}' instead of the row-grain master ⚠ verify in Sigma"
  end

  # Formula resolution priority (bead 3w4d — calc-measure KPIs used to drop):
  #   1. master-map entry with a verbatim aggregate `formula` (DM metrics like
  #      Return Rate / Gross Margin Pct / Revenue Per Order)
  #   2. User-aggregated worksheet calc → decompose (SUM(a)/COUNTD(b) etc.)
  #   3. row-level worksheet calc (DATEDIFF(...)) → translate, wrap in the
  #      shelf aggregation (Avg/Sum/...)
  #   4. plain master column wrapped in the shelf aggregation
  formula = two_stage_formula || master['formula']
  ws_calc = (z['calculations'] || []).find { |c| norm.call(c['name']) == norm.call(field_cap) }
  if formula.nil? && ws_calc && %w[usr user].include?(deriv)
    formula = translate_user_agg_formula(ws_calc['formula'], mmap, meta['columns_by_guid'] || {})
    warnings << "'#{cap}' KPI measure '#{field_cap}' is a Tableau User-aggregated calc — decomposed: #{formula[0..120]}" if formula
  end
  if formula.nil? && ws_calc
    body = translate_row_level_calc(ws_calc['formula'], mmap, meta['columns_by_guid'] || {})
    if body
      agg = SHELF_AGG_FOR_PREFIX[deriv] || 'Sum'
      formula = agg.include?('%s') ? agg.sub('%s', "(#{body})") : "#{agg}((#{body}))"
      warnings << "'#{cap}' KPI measure '#{field_cap}' is a row-level Tableau calc — translated + #{agg =~ /%s/ ? 'CountIf' : agg}-aggregated: #{formula[0..120]}"
    end
  end
  if formula.nil?
    agg_template = SHELF_AGG_FOR_PREFIX[deriv] || 'Sum'
    formula =
      if agg_template.include?('%s')
        agg_template.sub('%s', "[Master/#{master['name'].to_s.strip}]")
      else
        "#{agg_template}([Master/#{master['name'].to_s.strip}])"
      end
    if ws_calc
      warnings << "'#{cap}' KPI measure '#{field_cap}' is a Tableau calc that could not be auto-decomposed — emitted #{formula} which will only resolve if the master carries that column"
    end
  end

  measure_col_id = "k-#{el_id}"
  measure_col = {
    'id'      => measure_col_id,
    'name'    => master['name'].to_s.strip,
    'formula' => formula
  }

  # Format: prefer Tableau format string for this measure, then master-map
  # format, then heuristic by name.
  tab_fmt = pick_tableau_format(z['formats'], master['name'])
  measure_col['format'] = tab_fmt if tab_fmt
  measure_col['format'] ||= master['format'] if master['format'].is_a?(Hash)
  measure_col['format'] ||=
    case master['name'].downcase
    when /(revenue|profit|cost|sales|amount|spend)/
      { 'kind' => 'number', 'formatString' => '$,.0f', 'currencySymbol' => '$' }
    when /(rate|margin|pct|percent|ratio)/
      { 'kind' => 'number', 'formatString' => ',.1%' }
    else
      { 'kind' => 'number', 'formatString' => ',.0f' }
    end

  element = {
    'id'      => el_id,
    'kind'    => 'kpi-chart',
    'name'    => cap,
    'source'  => { 'kind' => 'table', 'elementId' => source_eid },
    'columns' => [measure_col],
    # value.columnId, NOT value.id — the live API 400s with
    # "value.columnId: Invalid string: undefined" (bead 3w4d; same fix as
    # qlik-to-sigma scout-validate + refs/sigma-build-gotchas.md).
    'value'   => { 'columnId' => measure_col_id }
  }

  # If the Tableau worksheet had Show Mark Labels on (typical for KPIs since
  # the number IS the chart), we don't need a separate dataLabel — kpi-chart
  # always renders the value. No-op.

  element
end

# A workbook may have multiple dashboards; iterate all and concatenate elements.
# Drop the chart_kind=automatic warnings to stderr so the caller can act on them.
elements = []
data_elements = [] # hidden helper elements (scatter grouped sources — bead z1d0)
warnings = []

layout.each do |dash|
  dash['zones'].each do |z|
    next unless z['kind'] == 'chart'
    cap = z['caption']
    next if cap.nil? || cap.empty?

    # Pivot-table fast path: Tableau crosstabs (chart_kind=pivot-table from
    # parse-twb-layout) emit a Sigma pivot-table element with rowsBy/columnsBy/
    # values derived from shelf info — independent of the view CSV shape.
    # Falls through to the CSV-driven flat-table path if shelves can't be
    # resolved cleanly (logged via warnings).
    if z['chart_kind'] == 'pivot-table'
      pivot_el = build_pivot_element(z, meta, mmap, opts, warnings)
      if pivot_el
        pivot_el['_worksheet'] = cap
        pivot_el['_dashboard'] = dash['dashboard']
        elements << pivot_el
        warnings << "'#{cap}' auto-emitted as Sigma pivot-table from Tableau crosstab (rows/cols shelves) — verify dim placement"
        next
      end
      # else: fall through to flat-table flow
    end

    # KPI fast path: Tableau scorecards (chart_kind=kpi) emit a Sigma kpi-chart
    # with a single measure as value. Without this, the worksheet would fall
    # into the CSV-driven 2-column flow which requires headers.length >= 2 and
    # silently drops single-measure tiles. beads-sigma-bw3.
    if z['chart_kind'] == 'kpi'
      kpi_el = build_kpi_element(z, meta, mmap, opts, warnings, data_elements)
      if kpi_el
        kpi_el['_worksheet'] = cap
        kpi_el['_dashboard'] = dash['dashboard']
        elements << kpi_el
        warnings << "'#{cap}' auto-emitted as Sigma kpi-chart from Tableau scorecard (single aggregated measure, no dims) — verify value formula"
        next
      end
      # else: fall through with the warning already logged
    end

    view = view_by_name[cap]
    if view.nil?
      warnings << "no Tableau view matched '#{cap}'"
      next
    end
    csv_path = File.join(opts[:tab], 'views', "#{view['id']}.csv")
    unless File.exist?(csv_path)
      warnings << "missing CSV for '#{cap}' at #{csv_path}"
      next
    end
    rows = CSV.read(csv_path)
    if rows.empty?
      # LOUD on purpose (bead gjhe): an empty/0-byte view CSV used to silently
      # drop the zone — the dashboard shipped with N-1 charts and every gate
      # still passed because the missing chart never entered the parity plan.
      warnings << "ZONE DROPPED: '#{cap}' — view CSV at #{csv_path} is EMPTY (0 bytes / 0 rows) " \
                  "but the zone exists in the dashboard. NO Sigma chart was built for it. " \
                  "Re-fetch the view data (fetch-view-data.rb) or build the chart by hand — " \
                  "the Phase-6 tile census will report this zone as unmatched."
      next
    end
    headers = rows.shift
    if headers.length < 2
      warnings << "ZONE DROPPED: '#{cap}' — view CSV has only #{headers.length} column(s); " \
                  "need dim + measure. NO Sigma chart was built for this zone — " \
                  "the Phase-6 tile census will report it as unmatched."
      next
    end

    dim_hdr  = headers[0].to_s.strip
    meas_hdr = headers[1].to_s.strip

    # Multi-channel detection (bead z1d0): a 3-column CSV whose SECOND column
    # is another dimension (non-numeric data) is a stacked/colored chart
    # (color dim + x dim + measure) — NEVER aggregate the string dim. Tableau
    # exports the COLOR (inner) dim first, the axis dim second.
    color_hdr = nil
    dim_csv_idx = 0
    color_csv_idx = nil
    if headers.length >= 3 && %w[bar line area automatic other].include?(z['chart_kind'].to_s)
      second_vals = rows.first(20).map { |r| r[1] }.compact
      second_is_dim = second_vals.any? &&
                      second_vals.none? { |v| begin Float(v.to_s.gsub(',', '')); true; rescue StandardError; false; end }
      if second_is_dim
        h0 = headers[0].to_s.strip
        h1 = headers[1].to_s.strip
        # Which of the two dims is the color channel? Resolve the Tableau color
        # encoding column to a caption and match; fall back to "first = color".
        color_cap = nil
        if (cc = z.dig('channels', 'color', 'column'))
          g = guid_from_text(cc.to_s)
          info = g ? (meta['columns_by_guid'] || {})[g] : nil
          color_cap = (info && info['caption']) ||
                      cc.to_s.sub(/^\[[^\]]+\]\./, '').gsub(/^\[|\]$/, '').sub(/^[a-z]+:/i, '').sub(/:[a-z]+$/i, '')
        end
        if color_cap && h1.casecmp?(color_cap.to_s.strip)
          color_hdr = h1
          dim_hdr = h0
          color_csv_idx = 1
          dim_csv_idx = 0
        else
          color_hdr = h0
          dim_hdr = h1
          color_csv_idx = 0
          dim_csv_idx = 1
        end
        meas_hdr = headers[2].to_s.strip
        warnings << "'#{cap}' 3-channel chart: x=#{dim_hdr.inspect} color=#{color_hdr.inspect} measure=#{meas_hdr.inspect} (color channel #{color_cap ? "resolved from Tableau encoding '#{color_cap}'" : 'defaulted to first CSV dim'})"
      end
    end

    dim  = map_column(dim_hdr,  mmap)
    meas = map_column(meas_hdr, mmap)
    find_ws_calc = lambda do |hdr|
      (z['calculations'] || []).find { |c| c['name'].to_s.gsub(/^\[|\]$/, '').strip.casecmp?(hdr.to_s.strip) }
    end
    if dim.nil?
      wc = find_ws_calc.call(dim_hdr)
      tf = wc && (translate_dim_calc(wc['formula'], mmap, meta['columns_by_guid'] || {}) ||
                  translate_row_level_calc(wc['formula'], mmap, meta['columns_by_guid'] || {}))
      if tf
        dim = { 'id' => "m-#{dim_hdr.downcase.gsub(/\W+/, '-')}", 'name' => dim_hdr, 'formula' => tf }
        warnings << "'#{cap}' dim '#{dim_hdr}' is a worksheet-local Tableau calc — translated inline: #{tf[0..140]}"
      else
        warnings << "no master column matched dim header '#{dim_hdr}' for '#{cap}' — falling back to raw header"
        dim = { 'id' => "m-#{dim_hdr.downcase.gsub(/\W+/, '-')}", 'name' => dim_hdr }
      end
    end
    if meas.nil?
      warnings << "no master column matched measure header '#{meas_hdr}' for '#{cap}'"
      meas = { 'id' => "m-#{meas_hdr.downcase.gsub(/\W+/,'-')}", 'name' => meas_hdr }
    end
    color_dim = nil
    if color_hdr
      color_dim = map_column(color_hdr, mmap)
      if color_dim.nil?
        wcc = (z['calculations'] || []).find { |c| c['name'].to_s.gsub(/^\[|\]$/, '').strip.casecmp?(color_hdr.to_s.strip) }
        tfc = wcc && (translate_dim_calc(wcc['formula'], mmap, meta['columns_by_guid'] || {}) ||
                      translate_row_level_calc(wcc['formula'], mmap, meta['columns_by_guid'] || {}))
        if tfc
          color_dim = { 'id' => "m-#{color_hdr.downcase.gsub(/\W+/, '-')}", 'name' => color_hdr, 'formula' => tfc }
          warnings << "'#{cap}' color dim '#{color_hdr}' is a worksheet-local Tableau calc — translated inline: #{tfc[0..140]}"
        else
          warnings << "no master column matched color header '#{color_hdr}' for '#{cap}' — falling back to raw header"
          color_dim = { 'id' => "m-#{color_hdr.downcase.gsub(/\W+/,'-')}", 'name' => color_hdr }
        end
      end
    end

    # Decide the Sigma aggregator. Priority:
    #   1. parse-twb-layout.rb's aggregations dict (most authoritative — comes
    #      from Tableau's column-instance derivation)
    #   2. CSV header naming heuristic ("Sum of X" → Sum)
    #   3. Default Sum for numeric, no-agg for text
    agg_label = nil
    (z['aggregations'] || {}).each do |col_ref, deriv|
      stripped = strip_brackets(col_ref)
      if stripped.casecmp(meas['name']).zero? ||
         stripped.casecmp(meas_hdr).zero? ||
         meas_hdr.downcase.include?(stripped.downcase[0..15])
        agg_label = deriv
        break
      end
    end
    agg_label ||= infer_csv_agg(meas_hdr)
    agg_label ||= 'Sum'
    sigma_agg = SIGMA_AGG[agg_label] || 'Sum'

    # derivation=User → the measure IS a Tableau calc field that's already
    # aggregated (typically a ratio like SUM(a)/COUNT(b)). Wrapping it in
    # Sum([Master/X]) is unresolvable when no master column carries the ratio —
    # decompose the calc formula into a direct Sigma formula instead (bead k3kk).
    user_agg_formula = nil
    if agg_label == 'User' && meas['formula'].nil?
      norm = ->(x) { x.to_s.gsub(/^\[|\]$/, '').strip.downcase }
      user_calc = (z['calculations'] || []).find do |c|
        n = norm.call(c['name'])
        !n.empty? && (n == norm.call(meas['name']) || n == norm.call(meas_hdr) ||
                      norm.call(meas_hdr).include?(n))
      end
      user_agg_formula = user_calc &&
                         translate_user_agg_formula(user_calc['formula'], mmap,
                                                    meta['columns_by_guid'] || {})
      if user_agg_formula
        warnings << "'#{cap}' measure '#{meas['name']}' is a Tableau User-aggregated calc — emitted its decomposed Sigma formula directly: #{user_agg_formula[0..140]}"
      else
        # Fall back to the CSV-header aggregation hint ("Avg. X" → Avg), not a
        # raw column ref (which Sigma's yAxis silently Sum()s — bead z1d0).
        sigma_agg = SIGMA_AGG[infer_csv_agg(meas_hdr) || 'Sum'] || 'Sum'
        warnings << "'#{cap}' measure '#{meas['name']}' has Tableau aggregation=User but its calc formula could not be auto-decomposed — falling back to #{sigma_agg}([Master/#{meas['name']}]), which is only correct if a master column (or --master-col placeholder) carries that value"
      end
    end

    # Decide if the dimension is a date that needs DateTrunc. The parser's
    # aggregations dict surfaces Month-Trunc / Year-Trunc / etc. on the date col.
    dim_trunc = nil
    (z['aggregations'] || {}).each do |col_ref, deriv|
      stripped = strip_brackets(col_ref)
      if DATE_TRUNC.key?(deriv) &&
         (stripped.casecmp(dim['name']).zero? || dim_hdr.downcase.include?('date'))
        dim_trunc = DATE_TRUNC[deriv]
        break
      end
    end
    # Header-derived fallback: Tableau CSV date headers carry the grain
    # ("Month of Order Date" / "Week of Order Date") even when the
    # column-instance derivation didn't resolve (bead ovud).
    if dim_trunc.nil? && (hm = dim_hdr.match(/^(second|minute|hour|day|week|month|quarter|year) of /i))
      dim_trunc = hm[1].downcase
    end

    el_id = "el-#{cap.downcase.gsub(/\W+/, '-')[0..40]}".sub(/-$/, '')

    # If the dim column is aliased in Tableau (raw → display mapping), wrap the
    # master ref in a Switch() so the chart displays the friendly labels.
    aliases_for_dim = (meta['column_aliases'] || {})[dim['name']] ||
                      (meta['column_aliases'] || {})[dim_hdr]
    dim_formula = if dim['formula']                     # explicit formula override
                    dim['formula']
                  elsif aliases_for_dim && !aliases_for_dim.empty?
                    parts = ["[Master/#{dim['name']}]"]
                    aliases_for_dim.each { |a| parts << a['key'].inspect; parts << a['value'].inspect }
                    parts << "[Master/#{dim['name']}]"  # default: pass through raw value
                    "Switch(#{parts.join(', ')})"
                  elsif dim_trunc == 'week'
                    # Tableau weeks start SUNDAY (default date-options); Sigma's
                    # DateTrunc("week") follows the warehouse week start (Monday
                    # on Snowflake). Sigma Weekday() returns 1=Sunday, so the
                    # Sunday-start bucket is convention-free arithmetic (s6fo:
                    # weekly-grain parity compares the underlying date value).
                    %(DateAdd("day", 1 - Weekday([Master/#{dim['name']}]), DateTrunc("day", [Master/#{dim['name']}])))
                  elsif dim_trunc
                    %(DateTrunc("#{dim_trunc}", [Master/#{dim['name']}]))
                  else
                    "[Master/#{dim['name']}]"
                  end
    # If the measure mapping carries a `formula` key, that's a workbook-level
    # calc like Return Rate = Sum(...)/Count(...). Use it verbatim. Otherwise
    # wrap the master-table column with the Sigma aggregator picked above.
    measure_formula = if meas['formula']
                        meas['formula']
                      elsif user_agg_formula
                        user_agg_formula
                      else
                        render_agg(sigma_agg, "[Master/#{meas['name']}]")
                      end

    dim_col_obj = { 'id' => "x-#{el_id}", 'name' => dim['name'], 'formula' => dim_formula }
    if dim_trunc
      dim_col_obj['format'] = { 'kind' => 'datetime',
                                'formatString' => dim_trunc == 'week' ? '%b %d, %Y' : '%b %Y' }
    end
    color_col_obj = nil
    if color_dim
      color_col_obj = { 'id' => "c-#{el_id}", 'name' => color_dim['name'],
                        'formula' => color_dim['formula'] || "[Master/#{color_dim['name']}]" }
    end

    # ---- Two-stage aggregation (FIXED LOD / grain-aware average) ------------
    # See the parse_fixed_lod block comment. Both cases retarget the chart at a
    # hidden helper element; every downstream block that wraps the column
    # formulas (null-dim IsNotNull, sort, dataLabel) keeps working because the
    # column OBJECTS keep their ids/names — only formulas + source change.
    chart_source_eid = opts[:master_id]
    if meas['formula'].nil? && user_agg_formula.nil?
      lod_calc = (z['calculations'] || []).find do |c|
        c['name'].to_s.gsub(/^\[|\]$/, '').strip.casecmp?(header_base(meas_hdr))
      end
      lod_parse = lod_calc && parse_fixed_lod(lod_calc['formula'], meta['columns_by_guid'] || {})
      if lod_parse
        # FIXED LOD → two-level grouped helper: inner = FIXED dims computing
        # the LOD aggregate, outer = the chart's plotted dims computing the
        # second-stage aggregate; chart Max()es the replicated outer calc.
        map_name = ->(capn) { (mm = map_column(capn, mmap)) ? mm['name'] : capn }
        inner_keys = lod_parse['dims'].map { |d| n = map_name.call(d); { 'name' => n, 'formula' => "[Master/#{n}]" } }
        lod_meas = map_name.call(lod_parse['measure'])
        value_name = header_base(meas_hdr)
        outer_dims = [{ 'name' => dim['name'], 'formula' => dim_formula }]
        outer_dims << { 'name' => color_col_obj['name'], 'formula' => color_col_obj['formula'] } if color_col_obj
        stage2 = (SIGMA_AGG[agg_label] unless %w[None User].include?(agg_label.to_s)) || 'Avg'
        helper, src_name, s2_name = build_two_stage_helper(
          el_id: el_id, master_id: opts[:master_id], value_name: value_name,
          value_formula: render_agg(LOD_INNER_AGG[lod_parse['agg']], "[Master/#{lod_meas}]"),
          inner_keys: inner_keys, outer_dims: outer_dims, stage2_agg: stage2)
        data_elements << helper
        chart_source_eid = helper['id']
        dim_col_obj['formula'] = "[#{src_name}/#{dim['name']}]"
        color_col_obj['formula'] = "[#{src_name}/#{color_col_obj['name']}]" if color_col_obj
        measure_formula = "Max([#{src_name}/#{s2_name}])"
        warnings << "'#{cap}' measure '#{meas_hdr}' is a FIXED LOD ({FIXED #{lod_parse['dims'].join(', ')} : " \
                    "#{lod_parse['agg']}(#{lod_parse['measure']})}) — auto-built hidden grouped helper '#{src_name}' " \
                    "(inner grain = FIXED dims, 2nd-stage #{stage2} at chart grain) ⚠ exact iff the chart dims are " \
                    'functionally dependent on the FIXED dims — verify in Sigma'
      elsif sigma_agg == 'Avg' && meas['grain'] &&
            dim['formula'].nil? && dim_trunc.nil? && (aliases_for_dim.nil? || aliases_for_dim.empty?) &&
            dim['grain'] && dim['grain']['element'] == meas['grain']['element'] &&
            (color_dim.nil? || (color_dim['grain'] && color_dim['grain']['element'] == meas['grain']['element']))
        # Grain-aware average over a dim-table measure, plotted by dims that
        # live on the SAME dim element → source the dim element at its native
        # grain (ungrouped passthrough); the chart's Avg is then per-entity.
        names = [dim['name'], meas['name']]
        names << color_dim['name'] if color_dim
        helper, src_name = build_dim_grain_helper(el_id: el_id, grain: meas['grain'], columns: names.uniq)
        data_elements << helper
        chart_source_eid = helper['id']
        dim_col_obj['formula'] = "[#{src_name}/#{dim['name']}]"
        color_col_obj['formula'] = "[#{src_name}/#{color_col_obj['name']}]" if color_col_obj
        measure_formula = "Avg([#{src_name}/#{meas['name']}])"
        warnings << "'#{cap}' averages a #{meas['grain']['element']} column — Tableau evaluates this at the dim table's " \
                    "native grain (relationship semantics); chart sources the DM '#{meas['grain']['element']}' element via " \
                    "hidden helper '#{src_name}' ⚠ verify in Sigma"
      elsif sigma_agg == 'Avg' && meas['grain']
        warnings << "'#{cap}' averages dim-table column '#{meas['name']}' (#{meas['grain']['element']}) but its chart dims " \
                    'are not plain columns of that dim element — left at row grain; values may diverge from Tableau ' \
                    '(relationship semantics average at the dim grain). Verify or restructure manually.'
      end
    end

    meas_col_obj = { 'id' => "y-#{el_id}", 'name' => meas['name'], 'formula' => measure_formula }
    # Format priority:
    #   1. explicit `format` on the master-map entry
    #   2. Tableau's own format string for this measure (zone.formats — only set
    #      when --meta was provided)
    #   3. heuristic by header name
    meas_col_obj['format'] = meas['format'] if meas['format'].is_a?(Hash)
    if meas_col_obj['format'].nil?
      tab_fmt = pick_tableau_format(z['formats'], meas_hdr) ||
                pick_tableau_format(z['formats'], meas['name'])
      meas_col_obj['format'] = tab_fmt if tab_fmt
    end
    if meas_col_obj['format'].nil?
      meas_col_obj['format'] =
        case meas['name'].downcase
        when /(revenue|profit|cost|sales|amount|spend)/
          { 'kind' => 'number', 'formatString' => '$,.0f', 'currencySymbol' => '$' }
        when /(rate|margin|pct|percent|ratio)/
          { 'kind' => 'number', 'formatString' => ',.1%' }
        else
          { 'kind' => 'number', 'formatString' => ',.0f' }
        end
    end
    # Allow `format` on map entries to be either a Sigma format object OR a
    # bare formatString string for convenience.
    if meas['format'].is_a?(String)
      meas_col_obj['format'] = { 'kind' => 'number', 'formatString' => meas['format'] }
    end

    kind = SIGMA_KIND[z['chart_kind']] || 'bar-chart'
    if z['chart_kind'] == 'automatic'
      warnings << "'#{cap}' has chart_kind=automatic — defaulted to bar-chart; verify against PNG"
    end

    # Scatter fast path (bead z1d0, ported from the PBI builder's verified
    # ry0n fix): Sigma's scatter xAxis is a GROUPING axis — binding an
    # AGGREGATE makes it evaluate per source row and the chart plots raw rows.
    # Pre-aggregate in a HIDDEN grouped source table on the Data page (dim +
    # x/y aggregates grouped by the dim), then point the scatter at it with
    # ALL-RAW column refs. The detail dim MUST stay on color:{by:category} —
    # points sharing an x merge to a null y without it.
    if kind == 'scatter-chart' && headers.length >= 3
      meas2_hdr = headers[2].to_s.strip
      meas2 = map_column(meas2_hdr, mmap) ||
              { 'id' => "m-#{meas2_hdr.downcase.gsub(/\W+/, '-')}", 'name' => meas2_hdr }
      # Tableau scatter: Cols shelf = X measure, Rows shelf = Y measure. The
      # CSV column order is not axis order — resolve via the shelves; fall
      # back to CSV order [dim, y, x] (matches Tableau's export convention).
      shelf_cap = lambda do |shelf|
        f = (shelf || {})['fields']&.find { |x| x['role'] == 'measure' }
        f && resolve_shelf_field(f, meta, mmap).last.to_s.strip
      end
      x_cap = shelf_cap.call(z['cols_shelf'])
      y_cap = shelf_cap.call(z['rows_shelf'])
      m_for = lambda do |hdr_cap|
        h = hdr_cap.to_s.sub(/^(?:sum|avg|average|min|max|median|distinct count|count) of /i, '')
                   .sub(/^(?:avg|sum|min|max|med|cnt|ctd)\.\s*/i, '').strip
        [[meas, meas_hdr], [meas2, meas2_hdr]].find do |(_, mh)|
          mh.to_s.sub(/^(?:sum|avg|average|min|max|median|distinct count|count) of /i, '')
            .sub(/^(?:avg|sum|min|max|med|cnt|ctd)\.\s*/i, '').strip.casecmp?(h)
        end
      end
      x_pair = (x_cap && m_for.call(x_cap)) || [meas2, meas2_hdr]
      y_pair = (y_cap && m_for.call(y_cap)) || ([[meas, meas_hdr], [meas2, meas2_hdr]] - [x_pair]).first
      agg_for = lambda do |mm, hdr|
        next mm['formula'] if mm['formula'] # verbatim aggregate from master-map
        a = SIGMA_AGG[infer_csv_agg(hdr) || 'Sum'] || 'Sum'
        render_agg(a, "[Master/#{mm['name']}]")
      end
      src_id   = "#{el_id}-src"
      src_name = "#{cap} Source"
      gd = "#{src_id}-d"
      gx = "#{src_id}-x"
      gy = "#{src_id}-y"
      data_elements << {
        'id' => src_id, 'kind' => 'table', 'name' => src_name,
        'source' => { 'kind' => 'table', 'elementId' => opts[:master_id] },
        'columns' => [
          { 'id' => gd, 'name' => dim['name'], 'formula' => dim['formula'] || "[Master/#{dim['name']}]" },
          { 'id' => gx, 'name' => x_pair[0]['name'], 'formula' => agg_for.call(x_pair[0], x_pair[1]) },
          { 'id' => gy, 'name' => y_pair[0]['name'], 'formula' => agg_for.call(y_pair[0], y_pair[1]) }
        ],
        'groupings' => [{ 'id' => "#{src_id}-g", 'groupBy' => [gd], 'calculations' => [gx, gy] }],
        'visibleAsSource' => false
      }
      money_fmt = { 'kind' => 'number', 'formatString' => '$,.0f', 'currencySymbol' => '$' }
      num_fmt = ->(n) { n.to_s.downcase =~ /(revenue|profit|cost|sales|amount|spend)/ ? money_fmt : { 'kind' => 'number', 'formatString' => ',.0f' } }
      element = {
        'id' => el_id, 'kind' => 'scatter-chart', 'name' => cap,
        'source' => { 'kind' => 'table', 'elementId' => src_id },
        'columns' => [
          { 'id' => "c-#{el_id}", 'name' => dim['name'], 'formula' => "[#{src_name}/#{dim['name']}]" },
          { 'id' => "x-#{el_id}", 'name' => x_pair[0]['name'], 'formula' => "[#{src_name}/#{x_pair[0]['name']}]", 'format' => num_fmt.call(x_pair[0]['name']) },
          { 'id' => "y-#{el_id}", 'name' => y_pair[0]['name'], 'formula' => "[#{src_name}/#{y_pair[0]['name']}]", 'format' => num_fmt.call(y_pair[0]['name']) }
        ],
        'xAxis' => { 'columnId' => "x-#{el_id}" },
        'yAxis' => { 'columnIds' => ["y-#{el_id}"] },
        'color' => { 'by' => 'category', 'column' => "c-#{el_id}" }
      }
      unless rows.any? { |r| r[0].nil? || r[0].to_s.strip.empty? }
        element['columns'] << { 'id' => "nn-c-#{el_id}", 'name' => "#{dim['name']} Not Null",
                                'formula' => "IsNotNull([#{src_name}/#{dim['name']}])" }
        element['filters'] = [{ 'id' => "flt-#{el_id}-nn", 'columnId' => "nn-c-#{el_id}",
                                'kind' => 'list', 'mode' => 'include',
                                'selectionMode' => 'multiple', 'values' => [true] }]
      end
      element['_worksheet'] = cap
      element['_dashboard'] = dash['dashboard']
      elements << element
      warnings << "'#{cap}' scatter pre-aggregated via hidden grouped source '#{src_name}' (x=#{x_pair[0]['name']}, y=#{y_pair[0]['name']}, detail=#{dim['name']}) — raw refs on axes, color=detail (PBI ry0n design)"
      next
    end

    # Dual-axis / combo detection: if Tableau marked this worksheet as
    # synchronized-axes OR there are 2+ measures in the pane AND the view CSV
    # has a second measure column, emit a combo-chart with two yAxis groups.
    extra_meas_col = nil
    if z['dual_axis'] && headers.length >= 3
      meas2_hdr = headers[2]
      meas2 = map_column(meas2_hdr, mmap) ||
              { 'id' => "m-#{meas2_hdr.downcase.gsub(/\W+/,'-')}", 'name' => meas2_hdr }
      meas2_formula = meas2['formula'] || render_agg(sigma_agg, "[Master/#{meas2['name']}]")
      extra_meas_col = {
        'id'      => "y2-#{el_id}",
        'name'    => meas2['name'],
        'formula' => meas2_formula,
        'format'  => meas2['format'].is_a?(Hash) ? meas2['format'] :
                     ({ 'kind' => 'number', 'formatString' => ',.0f' })
      }
      kind = 'combo-chart' unless %w[pie-chart donut-chart].include?(kind)
      # Sigma combo-chart dual-axis IS persisted in the spec — the secondary
      # axis is implied by yAxis.columnIds entries in object form
      # (`{columnId, type}`) vs bare-string form. Bare strings go to the
      # primary (left) axis; object-form entries go to the secondary (right)
      # axis with the specified mark type. Verified 2026-05-22 against
      # UI-built workbook readback (workbookUrlId 5xKqmuAXGooHxRgFrdk6VY).
      # The right axis is auto-scaled by default; custom right-axis scale
      # configuration (log/min/max/zero) is unverified — yAxis.format only
      # governs the left axis.
      warnings << "'#{cap}' detected as dual-axis (synchronized=true or 2+ measures) — emitted as combo-chart with secondary measure on right axis (yAxis.columnIds object form). Right axis is auto-scaled; if Tableau had a custom right-axis range, configure manually in the Sigma editor."
    end

    element = {
      'id'      => el_id,
      'kind'    => kind,
      'name'    => cap,
      'source'  => { 'kind' => 'table', 'elementId' => chart_source_eid },
      'columns' => [dim_col_obj, meas_col_obj]
    }
    element['columns'] << extra_meas_col if extra_meas_col
    if color_col_obj && !%w[pie-chart donut-chart table pivot-table].include?(kind)
      element['columns'] << color_col_obj
      element['color'] = { 'by' => 'category', 'column' => color_col_obj['id'] }
    end

    # Null-dim exclusion (Tableau↔Sigma join-semantics parity): Sigma DM
    # relationships are LEFT joins, so fact rows without a dim match surface a
    # NULL dim bucket that the Tableau view excluded. When the Tableau CSV has
    # NO null dim values, mirror the exclusion with a verified bool-filter
    # (IsNotNull calc column + include:[true] list filter — the spec shape from
    # reference_sigma_rls_cls_spec_shape). A no-null dataset makes this a
    # harmless no-op.
    null_excl_filters = []
    # Charts only: a table/pivot RENDERS every column, so the helper column
    # would show up as a visible "X Not Null" column (and crosstabs keep their
    # null buckets in Tableau anyway).
    null_excl_kinds = %w[bar-chart line-chart area-chart combo-chart pie-chart donut-chart scatter-chart]
    [[dim_csv_idx, dim_col_obj], [color_csv_idx, color_col_obj]].each do |(ci, cobj)|
      next unless null_excl_kinds.include?(kind)
      next if ci.nil? || cobj.nil?
      next if rows.any? { |r| r[ci].nil? || r[ci].to_s.strip.empty? } # Tableau kept nulls
      nn_id = "nn-#{cobj['id']}"
      element['columns'] << { 'id' => nn_id, 'name' => "#{cobj['name']} Not Null",
                              'formula' => "IsNotNull(#{cobj['formula'] || "[Master/#{cobj['name']}]"})" }
      null_excl_filters << { 'columnId' => nn_id, 'kind' => 'list', 'mode' => 'include',
                             'selectionMode' => 'multiple', 'values' => [true] }
    end
    unless null_excl_filters.empty?
      warnings << "'#{cap}' null-dim exclusion: #{null_excl_filters.size} IsNotNull filter(s) emitted (Tableau view shows no null dim bucket; Sigma LEFT joins would)"
    end

    # Reference lines / bands / trendlines from Tableau → Sigma `refMarks`.
    # Verified shape (from a UI-built workbook readback, 2026-05-21):
    #   refMarks:
    #     - type: line | band
    #       axis: series | series2 | axis
    #       value:
    #         { type: constant, value: <number> }     # constant threshold
    #         { type: formula,  formula: "<expr>" }   # any Sigma formula
    #       label:
    #         { visibility: shown|hidden, text?: "..." }
    #
    # Docs (charts.md) suggested bare numbers / strings for `value` but the
    # live API only accepts the wrapped object form. `value.type: column` is
    # also rejected — use `formula` with a column ref instead.
    ref_emit, trend_emit, ref_skip = [], [], []
    if z['ref_marks'] && !z['ref_marks'].empty? && %w[bar-chart line-chart area-chart combo-chart scatter-chart].include?(kind)
      meas_name = meas_col_obj['name']
      tab_to_sigma_agg = { 'average' => 'Avg', 'median' => 'Median', 'max' => 'Max', 'min' => 'Min', 'sum' => 'Sum', 'count' => 'Count' }
      # Trendline shape verified 2026-05-22 against a UI-built workbook
      # (workbookUrlId 5xKqmuAXGooHxRgFrdk6VY). Only `linear` is canonically
      # verified; other Tableau model-types are passed through under the same
      # name (Sigma docs list logarithmic/exponential/polynomial/quadratic/power)
      # and will surface a per-element WARN to verify visually.
      tab_to_sigma_model = {
        'linear'      => 'linear',
        'logarithmic' => 'logarithmic',
        'exponential' => 'exponential',
        'polynomial'  => 'polynomial',
        'power'       => 'power'
      }
      z['ref_marks'].each do |rm|
        case rm['kind']
        when 'line'
          # Skip band-styled lines (fill/percentage bands) — they need the band shape, not line.
          if rm['band_values'] || rm['fill_below'] == 'true' || rm['fill_above'] == 'true' || rm['percentage_bands'] == 'true'
            ref_skip << rm
            next
          end
          fagg = tab_to_sigma_agg[rm['formula']]
          if fagg
            label_text = rm['label_type'] == 'custom' ? rm['label'] : "#{fagg} #{meas_name}"
            ref_emit << {
              'type'  => 'line',
              'axis'  => 'series',
              'value' => { 'type' => 'formula', 'formula' => "#{fagg}([Master/#{meas_name}])" },
              'label' => { 'visibility' => 'shown', 'text' => label_text }.compact
            }
          else
            ref_skip << rm
          end
        when 'trendline'
          model = tab_to_sigma_model[rm['model'].to_s] || 'linear'
          trend_emit << {
            'columnId' => meas_col_obj['id'],
            'model'    => model,
            'label'    => { 'visibility' => 'shown' },
            'value'    => { 'visibility' => 'shown' }
          }
        when 'band', 'distribution'
          # Bands need the {type:band} variant which we haven't verified.
          ref_skip << rm
        end
      end
      element['refMarks']   = ref_emit   unless ref_emit.empty?
      element['trendlines'] = trend_emit unless trend_emit.empty?
      if !ref_skip.empty?
        skip_counts = ref_skip.each_with_object(Hash.new(0)) { |r, h| h[r['kind']] += 1 }
        skip_kinds = skip_counts.map { |k, n| "#{n}× #{k}" }.join(', ')
        warnings << "'#{cap}' has #{ref_skip.size} Tableau reference mark(s) not auto-emitted (#{skip_kinds}) — bands/distributions need manual review (beads-sigma-7ak)"
      end
      if !ref_emit.empty?
        warnings << "'#{cap}' auto-emitted #{ref_emit.size} Sigma refMarks from Tableau reference marks — verify visual fidelity"
      end
      if !trend_emit.empty?
        models_used = trend_emit.map { |t| t['model'] }.uniq
        non_linear = models_used - ['linear']
        msg = "'#{cap}' auto-emitted #{trend_emit.size} Sigma trendline(s) (model: #{models_used.join(', ')})"
        msg += " — only `linear` is canonically verified; visually verify #{non_linear.join('/')} fits" unless non_linear.empty?
        warnings << msg
      end
    end

    if kind == 'table'
      # Tableau text-table → Sigma grouped ("level") table. WITHOUT `groupings`,
      # a table with dim + Sum(...) columns renders one row per SOURCE row (no
      # roll-up). And on a grouped table the sort MUST nest inside the grouping
      # entry — element-level sort 400s with "Sort column not found" (verified
      # shape, see qlik-to-sigma refs/sigma-build-gotchas.md; bead f972).
      grouping = {
        'id'           => "g-#{el_id}",
        'groupBy'      => [dim_col_obj['id']],
        'calculations' => [meas_col_obj['id']]
      }
      if z['sort']
        dir = z.dig('sort', 'direction').to_s
        grouping['sort'] = [{
          'columnId'  => sort_target_column_id(z['sort'], dim, dim_hdr, dim_col_obj['id'], meas_col_obj['id']),
          'direction' => (dir =~ /desc/i) ? 'descending' : 'ascending'
        }]
        warnings << "'#{cap}' Tableau sort carried into groupings[0].sort (grouped-table sorts must nest inside the grouping — element-level sort 400s)"
      end
      element['groupings'] = [grouping]
    elsif kind == 'pie-chart' || kind == 'donut-chart'
      element['color'] = { 'id' => dim_col_obj['id'] }
      element['value'] = { 'id' => meas_col_obj['id'] }
      if z['sort']
        dir = z.dig('sort', 'direction').to_s
        element['color']['sort'] = {
          'by'        => sort_target_column_id(z['sort'], dim, dim_hdr, dim_col_obj['id'], meas_col_obj['id']),
          'direction' => (dir =~ /desc/i) ? 'descending' : 'ascending'
        }
        warnings << "'#{cap}' Tableau sort carried into pie color.sort"
      end
    else
      # Breaking-change-2026-05-21: xAxis takes singular `columnId` (string),
      # yAxis takes plural `columnIds` (array on the object — NOT array of
      # objects). The old `xAxis: {id: ...}` / `yAxis: [{id: ...}]` shape
      # is rejected by the live API on new POSTs.
      x_axis = { 'columnId' => dim_col_obj['id'] }
      # Sort: only set when Tableau explicitly sorted. parse-twb-layout emits
      # nil when there's no <sort> on the worksheet — leave Sigma's xAxis
      # unsorted in that case (natural order matches Tableau's default).
      if z['sort']
        dir = z.dig('sort', 'direction').to_s
        sigma_dir = (dir =~ /desc/i) ? 'descending' : 'ascending'
        x_axis['sort'] = {
          'by'        => sort_target_column_id(z['sort'], dim, dim_hdr, dim_col_obj['id'], meas_col_obj['id']),
          'direction' => sigma_dir
        }
      end
      element['xAxis'] = x_axis
      # Combo-chart: yAxis.columnIds is a mixed array — bare strings default to
      # bar; { columnId, type: 'line' } objects override the series type.
      # For non-combo: just bare strings.
      y_column_ids = [meas_col_obj['id']]
      if extra_meas_col
        y_column_ids << (kind == 'combo-chart' ?
          { 'columnId' => extra_meas_col['id'], 'type' => 'line' } :
          extra_meas_col['id'])
      end
      element['yAxis'] = { 'columnIds' => y_column_ids }

      # Axis format (log scale, fixed min/max). parse-twb-layout extracts these
      # from Tableau's <style-rule element='axis'><encoding attr='space' ...>
      # nodes per worksheet. Sigma side shape verified 2026-05-22:
      #   format: { scale: { type: log | linear, domain: {min, max}, zero } }
      # Tableau→Sigma scope mapping: rows→yAxis, cols→xAxis. class='0' is
      # primary, class='1' is secondary (dual-axis right side, currently
      # unverified from Sigma side — emit primary only for now).
      (z['axis_formats'] || []).each do |af|
        next unless af['class'].to_s == '0'  # primary only
        target = af['scope'] == 'rows' ? 'yAxis' : 'xAxis'
        scale = {}
        scale['type']   = 'log' if af['scale'] == 'log'
        if af['range_type'] == 'fixed' && af['min'] && af['max']
          scale['domain'] = { 'min' => af['min'], 'max' => af['max'] }
        end
        next if scale.empty?
        element[target] ||= {}
        element[target]['format'] ||= {}
        element[target]['format']['scale'] = scale
        warnings << "'#{cap}' auto-emitted #{target}.format.scale from Tableau axis override (scale=#{af['scale']}, range=#{af['range_type']}) — verify visual fidelity"
      end
    end

    # Surface action filters (they get skipped — these are cross-chart actions,
    # not value filters)
    action_filters = (z['filters'] || []).select { |f|
      f['column'].to_s.include?('[Action (') || f['column'].to_s.start_with?('[Action ')
    }
    if action_filters.any?
      warnings << "'#{cap}' has #{action_filters.size} Tableau action filter(s) — skipped (cross-chart actions, not value filters)"
    end

    # If channels.color is set, that's a multi-series signal. Emit a TODO note
    # so the agent can fan-out the yAxis with one If() per category. We don't
    # auto-fan because we don't have a reliable categorical-values list here.
    if z.dig('channels', 'color', 'column') && color_col_obj.nil? && kind != 'pie-chart'
      warnings << "'#{cap}' has a color channel on #{z['channels']['color']['column']} — chart is single-series; agent should fan-out yAxis with one If() per category (see refs/workbook-layout.md \"Multi-series chart patterns\")"
    end

    # Data labels — verified canonical shape 2026-05-22 against UI-built workbook
    # (workbookUrlId 5xKqmuAXGooHxRgFrdk6VY): minimum required is just
    #   dataLabel: { labels: shown }
    # Two Tableau signals trigger this:
    #   1. Label or Text encoding channel on the worksheet (drag-to-shelf)
    #   2. Worksheet-level "Show Mark Labels" toggle, surfaced by parse-twb-layout
    #      from <pane><style><style-rule element='mark'>
    #             <format attr='mark-labels-show' value='true'/>
    #      (verified against "Orders Conversion Test" workbook, 2026-05-22)
    if %w[bar-chart line-chart area-chart combo-chart scatter-chart pie-chart donut-chart].include?(kind)
      has_label_channel = z.dig('channels', 'label', 'column') || z.dig('channels', 'text', 'column')
      has_mark_labels   = z['mark_labels_show'] == true
      if has_label_channel || has_mark_labels
        element['dataLabel'] = { 'labels' => 'shown' }
        src = has_label_channel ? 'Label/Text encoding' : 'worksheet "Show Mark Labels" toggle'
        warnings << "'#{cap}' auto-emitted dataLabel:{labels:shown} from Tableau #{src} — verify formatting (Sigma defaults are minimal)"
      end
    end

    # Per-chart value filters (skip action filters — already warned above).
    # Translate each non-action filter into a Sigma element-level filter spec
    # using the parser's normalized fields (column_caption, kind, members,
    # period_type, etc.). We map the caption → master column via the same
    # regex map used for dim/measure.
    value_filters = (z['filters'] || []).reject { |f| f['is_action'] }
    el_filters = null_excl_filters
    # Element filters must reference a column ON THE TARGET ELEMENT (bead 320u)
    # — the master-namespace ids ("m-region") don't exist on the chart and the
    # POST rejects them. Reuse the chart's own column when the filter targets
    # the plotted dim/measure; otherwise add a hidden passthrough column.
    el_filter_col_for = lambda do |m|
      hit = (element['columns'] || []).find { |c| c['name'].to_s.strip.casecmp?(m['name'].to_s.strip) }
      return hit['id'] if hit
      # A helper-sourced chart (FIXED LOD / dim-grain) cannot reach master
      # columns the helper does not carry — surface it instead of emitting a
      # ref that error-types at POST.
      if chart_source_eid != opts[:master_id]
        warnings << "value filter on '#{cap}' targets '#{m['name']}' but the chart sources a two-stage helper that " \
                    'does not carry that column — filter NOT emitted; add the column to the helper manually if needed'
        return nil
      end
      fid = "f-#{el_id}-#{m['name'].to_s.downcase.gsub(/\W+/, '-')}"
      unless (element['columns'] || []).any? { |c| c['id'] == fid }
        element['columns'] << { 'id' => fid, 'name' => m['name'],
                                'formula' => m['formula'] || "[Master/#{m['name']}]" }
      end
      fid
    end
    value_filters.each do |f|
      fcap = f['column_caption'] || f['raw_param']
      m = fcap ? map_column(fcap, mmap) : nil
      if m.nil?
        warnings << "value filter on '#{cap}' targets '#{fcap}' — no master column matched, skipping"
        next
      end
      case f['kind']
      when 'list'
        # A Tableau categorical filter with NO members = "All" (the member list
        # is only materialized for explicit selections). An empty Sigma
        # include-list would filter out EVERY row — skip it (bead 320u).
        if (f['members'] || []).empty?
          warnings << "'#{cap}' quick filter on '#{fcap}' has no explicit members (Tableau 'All') — no Sigma element filter emitted"
          next
        end
        fcol = el_filter_col_for.call(m)
        next if fcol.nil? # helper-sourced chart, column unreachable (warned in el_filter_col_for)
        el_filters << {
          'columnId' => fcol,
          'kind' => 'list', 'mode' => 'include', 'selectionMode' => 'multiple',
          'values' => f['members'], 'includeNulls' => 'never'
        }
      when 'relative-date'
        # Tableau first-period=0, last-period=0 + period-type=year means
        # "this <period>" → Sigma mode:"current" + unit:<period>. E2E
        # re-verified 2026-06-10 (bead z135) that mode:current filters the
        # chart-data SQL — it rolls over automatically instead of freezing.
        # Offset windows (first/last ≠ 0, e.g. "last 3 months") fall back to
        # explicit between-bounds (frozen — re-run to refresh).
        period   = (f['period_type'] || 'year').downcase
        inc_null = (f['include_null'].to_s == 'true' ? 'always' : 'never')
        fcol = el_filter_col_for.call(m)
        next if fcol.nil? # helper-sourced chart, column unreachable (warned in el_filter_col_for)
        if f['first_period'].to_i.zero? && f['last_period'].to_i.zero?
          el_filters << {
            'columnId' => fcol, 'kind' => 'date-range', 'mode' => 'current',
            'unit' => period, 'includeNulls' => inc_null
          }
          warnings << "'#{cap}' relative-date 'this #{period}' → element filter mode:current unit:#{period} (rolls over automatically; verified to filter chart-data SQL, bead z135)"
        else
          start_d, end_d = relative_period_bounds(period, f['first_period'], f['last_period'])
          if start_d
            el_filters << {
              'columnId' => fcol, 'kind' => 'date-range', 'mode' => 'between',
              'startDate' => start_d, 'endDate' => end_d,
              'includeNulls' => inc_null
            }
            warnings << "'#{cap}' relative-date window #{f['first_period']}..#{f['last_period']} #{period}s → element filter mode:between (#{start_d[0..9]}..#{end_d[0..9]}); FROZEN — re-run to refresh"
          else
            el_filters << {
              'columnId' => fcol, 'kind' => 'date-range', 'mode' => 'relative',
              'unit' => period, 'count' => 1,
              'includeNulls' => inc_null
            }
            warnings << "'#{cap}' relative-date '#{period}' kept as mode:relative (no bounds computable for '#{period}') — verify it filters the SQL"
          end
        end
      when 'number-range'
        fcol = el_filter_col_for.call(m)
        next if fcol.nil? # helper-sourced chart, column unreachable (warned in el_filter_col_for)
        el_filters << {
          'columnId' => fcol, 'kind' => 'number-range', 'mode' => 'between',
          'min' => f['min'], 'max' => f['max'], 'includeNulls' => 'never'
        }
      end
    end
    # Every element filter needs a unique `id` (the live /v2/workbooks/.../spec
    # readback shows `id: flt-<element>-<n>`); the API rejects filters without it.
    el_filters.each_with_index { |nf, i| nf['id'] = "flt-#{el_id}-#{i}" }
    element['filters'] = el_filters unless el_filters.empty?

    # Surface Tableau-side calculated fields the worksheet uses, and auto-
    # translate the ones we know how to handle (parameter-driven Switch).
    # Otherwise emit a translation hint so the agent can wire it up by hand.
    param_caps = (meta['parameters'] || []).map { |p| p['caption'] }.compact
    (z['calculations'] || []).each do |c|
      formula = c['formula'].to_s
      next if formula.empty?
      next if formula =~ /\A\s*(SUM|COUNT|AVG|MIN|MAX)\(\[[^\]]+\]\)\s*\z/
      next if formula =~ /\A\s*\[[^\]]+\]\s*\z/

      # Try parameter-driven translations first (CASE / IF chain on param).
      translated = translate_case_on_param(formula, param_caps) ||
                   translate_if_chain_on_param(formula, param_caps)
      if translated
        # Drop the calc onto the chart element as an inline calc column. The
        # column id is derived from the calc name (strip brackets) so it's
        # stable across re-runs.
        calc_name = c['name'].to_s.gsub(/^\[|\]$/, '')
        calc_id   = "calc-#{calc_name.downcase.gsub(/\W+/, '-')[0..40]}".sub(/-$/, '')
        element['columns'] << {
          'id'      => calc_id,
          'name'    => calc_name,
          'formula' => translated
        }
        warnings << "'#{cap}' parameter-driven calc #{c['name']} → translated to Switch: #{translated[0..120]}"
        next
      end

      # Try customer-learned rules FIRST — these are translations the scout
      # subagent has validated against this customer's Sigma site. Anything
      # here is known-to-work in their context, so it wins over built-in
      # heuristics. Source: ~/.tableau-to-sigma/learned-rules.yaml (user home,
      # never clobbered by skill updates).
      lr_translated, lr_hint = LearnedRules.apply(LEARNED_RULES, formula)
      if lr_translated
        warnings << "'#{cap}' learned-rule applied to #{c['name']} → Sigma:  #{lr_translated[0..160]}  [#{lr_hint}]"
        next
      end

      # Try table-calc / common-fn translations (INDEX/LOOKUP/TOTAL/RANK/ZN/etc.).
      tc_translated, tc_hint = translate_tableau_tc(formula)
      if tc_translated
        warnings << "'#{cap}' Tableau table-calc #{c['name']} → Sigma:  #{tc_translated[0..160]}  [#{tc_hint}]"
        next
      end

      hint = if formula =~ /\bIIF\(.*=.*0.*,\s*SUM.*\/\s*SUM/
               'ratio calc — translate as `Sum(num) / NullIf(Sum(den), 0)` on master OR via Custom SQL'
             elsif formula =~ /\bIF\b.*\bELSEIF\b.*\bEND\b/i
               'IF/ELSEIF chain — translate to nested Sigma If(...) or Switch(...) on master'
             elsif formula =~ /\bCASE\b/i
               'CASE statement — translate to Sigma Switch(value, when1, then1, ...) on master'
             elsif formula =~ /\bSUM\(.*\)\s*\/\s*COUNT\(/i
               'ratio calc — translate as `Sum(...) / Count(...)` (or CountIf for NotNull) on master'
             elsif formula =~ /\[Parameters?\]\.|\[Parameters?\s+\(/
               'parameter-driven calc — translate to Sigma control + Switch()/If() formula'
             else
               'calc — translate to Sigma formula and add as a master column or workbook calc'
             end
      warnings << "'#{cap}' uses Tableau calc #{c['name']}: #{hint}. Formula: #{formula[0..120]}"
    end

    # Stamp with worksheet + dashboard so the page emitters can group.
    element['_worksheet'] = cap
    element['_dashboard'] = dash['dashboard']
    elements << element
  end
end

# ---- Title text element ----
# If --title given, emit a text element. If --title omitted AND the parser
# found a title/text zone, infer the dashboard name from the parser output.
auto_title = nil
if opts[:title].nil?
  layout.each do |dash|
    next unless dash['zones'].any? { |z| %w[title text].include?(z['kind']) && (z['y_pct'] || 100) < 10 }
    auto_title = dash['dashboard']
    break
  end
end
title_text = opts[:title] || auto_title

extras = []
if title_text
  extras << {
    'id'   => 'title-text',
    'kind' => 'text',
    # White span: build-dashboard-layout.rb wraps this element in the DARK
    # header band (HEADER_STYLE) — a plain body renders dark-on-dark
    # (phase-e layout-quality screenshot-checklist catch).
    'body' => %(# <span style="color: #FFFFFF">#{title_text}</span>)
  }
end

# ---- Auto-generated parameter controls (--auto-controls) ------------------
# Tableau parameters become Sigma controls. The control's name matches the
# parameter caption so any translated `Switch([Param Caption], ...)` formula
# resolves to this control.
param_controls = []
if opts[:auto_controls]
  # Determine which parameter captions are actually referenced by any worksheet
  # calc. Tableau workbooks often define orphan parameters (defined but not used
  # by any calc field) — emitting controls for those clutters the dashboard
  # with widgets that filter nothing. Skip them.
  referenced_caps = (meta['worksheets'] || {}).values
    .flat_map { |w| (w['calculations'] || []).flat_map { |c| c['parameter_refs'] || [] } }
    .uniq
  (meta['parameters'] || []).each_with_index do |p, i|
    cap = p['caption'].to_s.strip
    next if cap.empty?
    unless referenced_caps.include?(cap)
      warnings << "parameter '#{cap}' is defined in Tableau but not referenced by any worksheet calc — skipped auto-control (orphan parameter)"
      next
    end
    slug = cap.downcase.gsub(/\W+/, '-').sub(/-$/, '')
    spec = {
      'id'        => "el-param-#{slug}",
      'kind'      => 'control',
      'controlId' => "ctl-param-#{slug}",
      'name'      => cap,
      'includeNulls' => 'when-no-value-is-selected'
    }
    if p['param_domain'] == 'list'
      spec['controlType']   = 'segmented'
      spec['source'] = {
        'kind' => 'manual', 'valueType' => 'text',
        'values' => p['members'] || [], 'labels' => []
      }
      spec['value'] = p['default_value']
    elsif p['param_domain'] == 'range' && %w[integer real].include?(p['datatype'])
      # Numeric range parameter → Sigma `number-range` control (discovered by
      # gap-scout 2026-05-20, beads-sigma-ebw). Two-handle slider; the single-
      # value Tableau parameter is rendered as a range with handles initially
      # collapsed to the default. `mode` and `values` don't round-trip on
      # readback but the workbook renders correctly (known Sigma quirk).
      spec['controlType'] = 'number-range'
      spec['mode']        = 'between'
      min = p['min'] ? (p['datatype'] == 'real' ? p['min'].to_f : p['min'].to_i) : nil
      max = p['max'] ? (p['datatype'] == 'real' ? p['max'].to_f : p['max'].to_i) : nil
      spec['values']      = [min, max].compact if min && max
      warnings << "parameter '#{cap}' is a numeric range — emitted as number-range control (Sigma 2-handle slider; Tableau's single-handle UX needs manual post-publish tweak)"
    elsif p['param_domain'] == 'range' && %w[date datetime].include?(p['datatype'])
      spec['controlType'] = 'date-range'
      spec['mode'] = 'between'
    else
      # Generic fallback — text input
      spec['controlType'] = 'text'
      spec['value'] = p['default_value']
    end
    param_controls << spec
  end
end

# ---- Auto-generated controls from shared-view filters (--auto-controls) ----
auto_controls = []
if opts[:auto_controls]
  (meta['shared_filters'] || []).each_with_index do |f, i|
    next if f['is_action']
    cap = f['column_caption']
    if cap.nil?
      warnings << "shared filter ##{i} has no resolvable column_caption (raw_param=#{f['raw_param']}) — skipping auto-control"
      next
    end
    m = map_column(cap, mmap)
    if m.nil?
      warnings << "shared filter on '#{cap}' has no master-map entry — add a regex to master-columns.json"
      next
    end
    slug = cap.downcase.gsub(/\W+/, '-').sub(/-$/, '')
    spec = {
      'id'           => "el-ctl-#{slug}",
      'kind'         => 'control',
      'controlId'    => "ctl-#{slug}",
      'name'         => cap.strip,
      'includeNulls' => 'when-no-value-is-selected'
    }
    case f['kind']
    when 'list'
      spec['controlType']   = 'list'
      spec['mode']          = 'include'
      spec['selectionMode'] = 'multiple'
      spec['values']        = []  # default to all; user adjusts in UI
      spec['source'] = {
        'kind'     => 'source',
        'source'   => { 'kind' => 'table', 'elementId' => opts[:master_id] },
        'columnId' => m['id']
      }
      spec['filters'] = [{
        'source'   => { 'kind' => 'table', 'elementId' => opts[:master_id] },
        'columnId' => m['id']
      }]
    when 'relative-date'
      # Tableau "this year" / "this month" / "this quarter" → Sigma date-range
      # control with `mode: "current"` + `unit: <period>`. E2E re-verified
      # 2026-06-10 (bead z135): mode:current DOES filter the chart-data SQL
      # when the control's `filters` target wiring is present — the earlier
      # "render-time only" finding that drove hardcoded between-bounds was
      # wrong, and the hardcoded dates froze the filter (broke at rollover).
      # mode:between is kept ONLY for genuinely fixed/offset windows
      # (first/last period ≠ 0, e.g. "last 3 months"), which Sigma has no
      # verified rolling-control shape for yet.
      spec['controlType'] = 'date-range'
      period = (f['period_type'] || 'year').downcase
      spec['filters'] = [{
        'source'   => { 'kind' => 'table', 'elementId' => opts[:master_id] },
        'columnId' => m['id']
      }]
      if f['first_period'].to_i.zero? && f['last_period'].to_i.zero?
        spec['mode'] = 'current'
        spec['unit'] = period
        warnings << "shared filter '#{cap}' relative-date 'this #{period}' → date-range control mode:current unit:#{period} (rolls over automatically; no frozen dates)"
      else
        start_d, end_d = relative_period_bounds(period, f['first_period'], f['last_period'])
        if start_d
          spec['mode']      = 'between'
          spec['startDate'] = start_d
          spec['endDate']   = end_d
          warnings << "shared filter '#{cap}' relative-date window #{f['first_period']}..#{f['last_period']} #{period}s → mode:between (#{start_d[0..9]}..#{end_d[0..9]}); FROZEN — re-run to refresh"
        else
          spec['mode'] = 'current'
          spec['unit'] = period
          warnings << "shared filter '#{cap}' relative-date '#{period}' window not boundable — emitted mode:current unit:#{period}; verify the window manually"
        end
      end
    when 'number-range'
      spec['controlType'] = 'range-slider'
      spec['filters'] = [{
        'source'   => { 'kind' => 'table', 'elementId' => opts[:master_id] },
        'columnId' => m['id']
      }]
    end
    auto_controls << spec
  end
end

# ---- Filter controls ----
# Caller supplies the column targets explicitly via --controls. We don't try
# to infer the column from filter zone metadata because the Tableau filter
# shelf doesn't reliably tell us which dimension it filters in this XML.
if opts[:controls]
  controls = JSON.parse(File.read(opts[:controls]))
  controls.each_with_index do |c, i|
    spec = {
      'id'          => "el-ctl-#{c['name'] ? c['name'].downcase.gsub(/\W+/, '-') : "f#{i}"}",
      'kind'        => 'control',
      'controlId'   => "ctl-#{c['name'] ? c['name'].downcase.gsub(/\W+/, '-') : "f#{i}"}",
      'name'        => c['name'] || "Filter #{i + 1}",
      'controlType' => c['type'] || 'list',
      'includeNulls' => 'when-no-value-is-selected',
      'filters' => [
        {
          'source'   => { 'kind' => 'table', 'elementId' => opts[:master_id] },
          'columnId' => c['column']
        }
      ]
    }
    case spec['controlType']
    when 'list'
      spec['mode'] = c['mode'] || 'include'
      spec['selectionMode'] = c['selectionMode'] || 'multiple'
      spec['values'] = c['values'] || []
      spec['source'] = {
        'kind'     => 'source',
        'source'   => { 'kind' => 'table', 'elementId' => opts[:master_id] },
        'columnId' => c['column']
      }
    when 'date-range'
      spec['mode'] = c['mode'] || 'between'
      if c['default']
        d = c['default']
        spec['startDate'] = d['startDate'] if d['startDate']
        spec['endDate']   = d['endDate']   if d['endDate']
        spec['unit']      = d['unit']      if d['unit']
        spec['mode']      = d['mode']      if d['mode']
      end
    when 'segmented'
      spec['source'] = c['source'] || {
        'kind' => 'manual', 'valueType' => 'text', 'values' => c['values'] || [], 'labels' => []
      }
      spec['value'] = c['value']
    end
    extras << spec
  end
end

all_extras = extras + param_controls + auto_controls

# ---- Output mode ----
#   Default       → flat array of elements (legacy behaviour). Extras first.
#   --page-per-worksheet → emit { pages: [{name, elements:[]}] }. One page per
#                          worksheet that has a chart, with the shared-filter
#                          auto-controls AND a title text duplicated onto each
#                          page so the customer sees the same filter set on
#                          every page (Tableau dashboard-level filter semantics).
if opts[:pages_mode] == :worksheet
  pages = []
  by_ws = elements.group_by { |e| e['_worksheet'] }
  by_ws.each do |ws_name, els|
    els.each { |e| e.delete('_worksheet'); e.delete('_dashboard') }
    page_extras = []
    if title_text
      page_extras << {
        'id'   => "title-text-#{ws_name.downcase.gsub(/\W+/,'-')[0..30]}".sub(/-$/, ''),
        'kind' => 'text',
        'body' => "## #{ws_name}"
      }
    end
    # Auto-controls duplicated per page. Both `id` and `controlId` need to be
    # workbook-globally unique (Sigma rejects duplicates). We track per-page
    # controlId rewrites so any param-driven Switch() formula on this page's
    # charts can be rewritten to reference the suffixed controlId.
    ws_slug = ws_name.downcase.gsub(/\W+/, '-')[0..20]
    ctl_rewrites = {}
    (param_controls + auto_controls).each do |c|
      dup = JSON.parse(c.to_json)
      original_cid = dup['controlId']
      dup['id']        = "#{dup['id']}-#{ws_slug}"
      dup['controlId'] = "#{dup['controlId']}-#{ws_slug}"
      ctl_rewrites[original_cid] = dup['controlId']
      page_extras << dup
    end
    # Rewrite Switch / If formulas on this page's chart calc columns.
    els.each do |el|
      (el['columns'] || []).each do |col|
        f = col['formula'].to_s
        ctl_rewrites.each do |from, to|
          f = f.gsub("[#{from}]", "[#{to}]")
        end
        col['formula'] = f
      end
    end
    pages << {
      'name'     => ws_name,
      'elements' => page_extras + els
    }
  end
  File.write(opts[:out], JSON.pretty_generate({ 'pages' => pages }))
  warn "wrote #{opts[:out]} (page-per-worksheet: #{pages.size} pages, #{auto_controls.size} auto-controls per page)"
elsif opts[:pages_mode] == :dashboard
  # One Sigma page per Tableau DASHBOARD (bead ptrt) — the fat-workbook fix:
  # 4 dashboards must become 4 laid-out pages, each with its own title text and
  # its own copy of the dashboard-global controls (ids suffixed for global
  # uniqueness, control refs in calc formulas rewritten per page).
  dash_order = layout.map { |d| d['dashboard'] }
  by_dash = elements.group_by { |e| e['_dashboard'] }
  pages = []
  dash_order.each do |dash_name|
    els = by_dash[dash_name]
    next if els.nil? || els.empty?
    els.each { |e| e.delete('_worksheet'); e.delete('_dashboard') }
    d_slug = dash_name.to_s.downcase.gsub(/\W+/, '-')[0..30].sub(/-$/, '')
    page_extras = [{
      'id'   => "title-#{d_slug}",
      'kind' => 'text',
      # White span: the layout builder wraps this in the DARK header band.
      'body' => %(# <span style="color: #FFFFFF">#{dash_name}</span>)
    }]
    ctl_rewrites = {}
    (param_controls + auto_controls).each do |c|
      dup = JSON.parse(c.to_json)
      original_cid = dup['controlId']
      dup['id']        = "#{dup['id']}-#{d_slug[0..20]}"
      dup['controlId'] = "#{dup['controlId']}-#{d_slug[0..20]}"
      ctl_rewrites[original_cid] = dup['controlId']
      page_extras << dup
    end
    els.each do |el|
      (el['columns'] || []).each do |col|
        f = col['formula'].to_s
        ctl_rewrites.each { |from, to| f = f.gsub("[#{from}]", "[#{to}]") }
        col['formula'] = f
      end
    end
    pages << { 'name' => dash_name, 'elements' => page_extras + els }
  end
  File.write(opts[:out], JSON.pretty_generate({ 'pages' => pages, 'data_elements' => data_elements }))
  warn "wrote #{opts[:out]} (page-per-dashboard: #{pages.size} page(s), #{data_elements.size} hidden data element(s), #{(param_controls + auto_controls).size} controls per page)"
else
  elements.each { |e| e.delete('_worksheet'); e.delete('_dashboard') }
  all_elements = all_extras + elements
  File.write(opts[:out], JSON.pretty_generate(all_elements))
  warn "wrote #{opts[:out]}  (#{all_elements.size} elements: #{all_extras.size} controls/text + #{elements.size} charts)"
  if data_elements.any?
    side = opts[:out].sub(/\.json$/, '-data-elements.json')
    File.write(side, JSON.pretty_generate(data_elements))
    warn "wrote #{side} (#{data_elements.size} HIDDEN data-page element(s) — scatter grouped sources; add them to the workbook's Data page)"
  end
end
warnings.each { |w| warn "  WARN  #{w}" }

# ---- Tableau dashboard actions companion file -----------------------------
# Action filters were translated into element-level filters when possible; the
# leftover Tableau-internal action wiring (which source-tile filters which
# target-tile set) is non-translatable without Sigma's cross-element wiring
# API. Emit a companion actions.md so the agent (or customer) can replicate
# the cross-chart interactivity by hand post-publish.
actions = []
(layout || []).each do |dash|
  (dash['zones'] || []).each do |z|
    next unless z['kind'] == 'chart'
    (z['filters'] || []).select { |f| f['is_action'] }.each do |af|
      # Tableau's action filter column looks like
      #   [federated.<id>].[Action (Region)]
      # Pull "Region" out as the dim that the action filters on.
      raw = (af['raw_param'] || af['column'] || '').to_s
      dim = (raw[/\[Action \(([^)]+)\)\]/, 1] || raw)
      actions << {
        'target'  => z['caption'],
        'source'  => dim,
        'column'  => dim
      }
    end
  end
end
unless actions.empty?
  actions_md_path = opts[:out].sub(/\.json$/, '-actions.md')
  md = String.new
  md << "# Tableau dashboard actions — post-publish setup\n\n"
  md << "Sigma cross-chart filtering replaces Tableau's filter actions. For each\n"
  md << "row below, in the published Sigma workbook: select the source element,\n"
  md << "open Actions → Add filter action, target the listed element on the named\n"
  md << "column.\n\n"
  md << "| Source dim | Target chart | Filter column |\n"
  md << "|---|---|---|\n"
  actions.uniq.each do |a|
    md << "| #{a['source']} | #{a['target']} | #{a['column']} |\n"
  end
  File.write(actions_md_path, md)
  warn "wrote #{actions_md_path} (#{actions.size} action entries)"
end
