#!/usr/bin/env ruby
# migrate-qlik.rb — ONE-SHOT, single-process orchestrator for the qlik-to-sigma
# pipeline. Runs the whole phased workflow in one Ruby process to cut agent
# turns / token cost, WITHOUT turning the migration into a black box: every
# phase prints a visible header + concise result, and the genuine human decision
# points are surfaced as a structured OPEN QUESTIONS block (exit 10) rather than
# silently auto-resolved.
#
# This script does NOT re-implement any phase — it chains the existing scripts:
#   qlik-discover.py            (Phase 1 — Qlik MODEL via qlik-cli Engine+REST)
#   convertQlikToSigma()        (Phase 2 — the sigma-data-model-mcp converter, via node shim)
#   reconcile-columns.py + gen-denorm-sql.py  (Phase 3 — denorm SQL element from the LOAD script)
#   POST /v2/dataModels/spec    (Phase 3 — converter star + denorm element)
#   POST /v2/workbooks/spec     (Phase 4 — master + KPIs/charts from charts.json)
#   put-layout.rb               (Phase 5 — auto-laid-out 24-col grid)
#   GET /v2/workbooks/{id}/columns (Phase 6 — formula-resolution parity guard)
#
# The genuine Qlik decision points (and ONLY these) are surfaced at the
# checkpoint: master-measure expressions with no clean Sigma equivalent (Set
# Analysis / Aggr / Dual / selection-state), Section Access, DirectQuery vs
# in-memory, and charts with no native Sigma kind. Mechanical steps (reconcile,
# denorm SQL, POST, layout, parity) are NEVER asked about.
#
# Usage:
#   ruby scripts/migrate-qlik.rb \
#     --app <qlikAppId> --connection <SIGMA_CONNECTION_ID> \
#     [--database CSA] [--schema TJ] [--context sigma-migration] \
#     [--folder <SIGMA_FOLDER_ID>] [--out DIR] [--answers '<json>'] [--yes]
#
# Exit codes: 0 = done (PARITY PASS); 10 = decisions needed (OPEN QUESTIONS printed,
# no Sigma objects created); 3 = built but PARITY FAIL; other = error.
require 'json'
require 'optparse'
require 'fileutils'
require 'open3'
require 'securerandom'
require 'set'

HERE = __dir__
$LOAD_PATH.unshift File.expand_path('vendor/lib', HERE)

opts = { context: 'sigma-migration', database: 'CSA', schema: 'TJ' }
OptionParser.new do |o|
  o.on('--app ID')        { |v| opts[:app]      = v }
  o.on('--connection ID') { |v| opts[:conn]     = v }
  o.on('--database DB')   { |v| opts[:database] = v }
  o.on('--schema S')      { |v| opts[:schema]   = v }
  o.on('--context CTX')   { |v| opts[:context]  = v }
  o.on('--folder ID')     { |v| opts[:folder]   = v }
  o.on('--out DIR')       { |v| opts[:out]      = File.expand_path(v) }
  o.on('--answers JSON')  { |v| opts[:answers]  = v }
  o.on('--yes')           {     opts[:yes]      = true }
end.parse!

abort 'missing --app'        unless opts[:app]
abort 'missing --connection' unless opts[:conn]

# Locate the sigma-data-model-mcp converter build (exports convertQlikToSigma).
MCP_DIR = ENV['QLIK_MCP_DIR'] || %w[
  /Users/tjwells/Desktop/sigma-data-model-mcp
  /Users/tjwells/sigma-data-model-mcp
].find { |d| File.exist?(File.join(d, 'build', 'qlik.js')) }

name_slug = opts[:app].gsub(/[^A-Za-z0-9_-]/, '-')
WORK = opts[:out] || File.expand_path("~/qlik-migration/#{name_slug}")
FileUtils.mkdir_p(WORK)

def hdr(n, total, title)
  puts
  puts "── Phase #{n}/#{total} · #{title} ──"
end

def run!(cmd, env: {})
  out, st = Open3.capture2e(env, *cmd)
  out.each_line { |l| puts "   #{l.rstrip}" } unless out.strip.empty?
  abort "FATAL: command failed (#{st.exitstatus}): #{cmd.join(' ')}" unless st.success?
  out
end

def disp(c)
  c.split('_').map { |w| w.empty? ? w : w[0].upcase + w[1..].downcase }.join(' ')
end

def sid(p = '')
  "#{p}#{SecureRandom.alphanumeric(8).downcase}"
end

TOTAL = 6

# ---------------------------------------------------------------------------
# Phase 1 — Discover (qlik-cli: load script, master measures/dims, charts)
# ---------------------------------------------------------------------------
hdr(1, TOTAL, 'Discover')
disc_cmd = ['python3', File.join(HERE, 'qlik-discover.py'),
            '--app', opts[:app], '--context', opts[:context], '--out', WORK]
run!(disc_cmd)

conv_input = JSON.parse(File.read(File.join(WORK, 'converter-input.json')))
charts     = JSON.parse(File.read(File.join(WORK, 'charts.json')))
measures   = JSON.parse(File.read(File.join(WORK, 'measures.json')))

# App metadata (Section Access / DirectQuery / app name) via the REST item record.
app_meta = {}
begin
  items, = Open3.capture2('qlik', 'item', 'ls', '--resourceType', 'app', '--limit', '200',
                          '--context', opts[:context])
  rec = (JSON.parse(items) rescue []).find { |i| i['resourceId'] == opts[:app] }
  app_meta = (rec && rec['resourceAttributes']) || {}
rescue StandardError
end
app_name = app_meta['name'] || conv_input['appName'] || opts[:app]

# A "real" rebuildable chart = has both a dimension and a measure (KPIs have only measures).
real_charts = charts.select { |c| (c['measures'] || []).any? && (c['dimensions'] || []).any? }
kpi_charts  = charts.select { |c| c['vizType'] == 'kpi' || ((c['measures'] || []).any? && (c['dimensions'] || []).empty?) }
vsumm = charts.group_by { |c| c['vizType'] }.map { |k, v| v.size > 1 ? "#{k}×#{v.size}" : k }.join(', ')
puts "   app '#{app_name}': #{conv_input['tables'].size} table(s), #{measures.size} master measure(s), " \
     "#{charts.size} object(s) (#{vsumm}); #{real_charts.size} rebuildable chart(s)"
puts "   sectionAccess=#{app_meta.fetch('hasSectionAccess', '?')}  directQuery=#{app_meta.fetch('isDirectQueryMode', '?')}"

# ---------------------------------------------------------------------------
# Phase 2 — Convert (run convertQlikToSigma via a node shim)
# ---------------------------------------------------------------------------
hdr(2, TOTAL, 'Convert')
abort 'FATAL: cannot locate sigma-data-model-mcp build (set QLIK_MCP_DIR)' unless MCP_DIR
shim = File.join(WORK, '_convert.mjs')
File.write(shim, <<~JS)
  import { readFileSync, writeFileSync } from 'node:fs';
  import { convertQlikToSigma } from #{File.join(MCP_DIR, 'build', 'qlik.js').to_json};
  const model = JSON.parse(readFileSync(#{File.join(WORK, 'converter-input.json').to_json}, 'utf8'));
  const out = convertQlikToSigma(model, {
    connectionId: #{opts[:conn].to_json},
    database: #{opts[:database].to_json},
    schema: #{opts[:schema].to_json},
  });
  writeFileSync(#{File.join(WORK, 'converter-out.json').to_json}, JSON.stringify(out, null, 2));
JS
c_out, c_err, c_st = Open3.capture3('node', shim)
abort "FATAL: converter failed:\n#{c_err}#{c_out}" unless c_st.success?
conv = JSON.parse(File.read(File.join(WORK, 'converter-out.json')))
conv_warnings = conv['warnings'] || []
cmodel = conv['model'] || conv['sigmaDataModel'] || conv
cstats = conv['stats'] || {}
puts "   converter ran (build: #{MCP_DIR})"
puts "   #{cstats['elements']} element(s), #{cstats['columns']} column(s), " \
     "#{cstats['metrics']} metric(s), #{cstats['relationships']} relationship(s); " \
     "#{conv_warnings.size} converter warning(s)"

# ---------------------------------------------------------------------------
# DECISIONS CHECKPOINT — surface the genuine Qlik human questions ONLY
# ---------------------------------------------------------------------------
questions = []

# (a) master-measure expressions the converter could not cleanly translate.
#     These are the converter's own drop/degrade warnings for Set Analysis (exotic),
#     Aggr(), Dual(), and selection-state P()/E() — each loses meaning in Sigma.
DEGRADE_RX = /Set Analysis|Aggr\(\)|Dual\(\)|selection-state|alternate.?state|no Sigma equivalent|no direct Sigma|stripped|column dropped/i
conv_warnings.select { |w| w.to_s =~ DEGRADE_RX }.each do |w|
  detail = w.to_s.gsub(/\s+/, ' ').strip
  mname = (detail =~ /"([^"]+)"/ ? $1 : nil)
  questions << { 'id' => 'measure_no_sigma_equiv', 'severity' => 'review',
                 'measure' => mname, 'detail' => detail,
                 'options' => ['proceed (measure best-effort/dropped; original Qlik expr kept in DM description)',
                               'abort and re-author this measure manually'],
                 'default' => 'proceed (measure best-effort/dropped; original Qlik expr kept in DM description)' }
end

# (b) Section Access — Sigma has no automatic import path for Qlik row-level security.
if app_meta['hasSectionAccess'] == true
  questions << { 'id' => 'section_access', 'severity' => 'required',
                 'detail' => 'Qlik app uses Section Access (row-level security). Sigma column/row-level ' \
                             'security must be re-authored manually (DM column security / workbook controls) — ' \
                             'it is NOT migrated automatically.',
                 'options' => ['proceed (migrate WITHOUT security; re-author in Sigma after)',
                               'abort until security is designed'],
                 'default' => 'proceed (migrate WITHOUT security; re-author in Sigma after)' }
end

# (c) DirectQuery vs in-memory — affects whether the Sigma connection is live/warehouse.
if app_meta['isDirectQueryMode'] == true
  questions << { 'id' => 'directquery_mode', 'severity' => 'review',
                 'detail' => 'Qlik app is in DirectQuery mode (queries the warehouse live rather than an ' \
                             'in-memory load). Confirm the Sigma --connection points at the SAME live warehouse ' \
                             'so parity holds; aggregations/row-counts differ from an in-memory snapshot otherwise.',
                 'options' => ["proceed (Sigma --connection #{opts[:conn]} IS the same warehouse)",
                               'abort and repoint the connection'],
                 'default' => "proceed (Sigma --connection #{opts[:conn]} IS the same warehouse)" }
end

# (d) charts with no native Sigma element kind. Native kinds we rebuild faithfully:
NATIVE = %w[barchart auto-chart kpi linechart table piechart combochart scatterplot].freeze
NATIVE_NAME = { 'barchart' => 'bar-chart', 'auto-chart' => 'bar-chart', 'linechart' => 'line-chart',
                'table' => 'table', 'kpi' => 'kpi-chart' }.freeze
# sheet/singlepublic/container objects aren't charts; skip silently.
SKIP_KINDS = %w[sheet singlepublic appprops LoadModel measure dimension masterobject sheetlist].freeze
real_charts.each do |c|
  vt = c['vizType']
  next if NATIVE.include?(vt) || SKIP_KINDS.include?(vt)
  questions << { 'id' => 'chart_no_native_kind', 'severity' => 'review',
                 'visual' => c['title'] || c['id'], 'qlik_type' => vt,
                 'detail' => "Qlik '#{vt}' has no native Sigma element kind",
                 'options' => ['approximate-to-bar (data migrates, render approximates)', 'skip this chart'],
                 'default' => 'approximate-to-bar (data migrates, render approximates)' }
end

# (e) folder not supplied
unless opts[:folder]
  questions << { 'id' => 'folder', 'severity' => 'required',
                 'detail' => 'No Sigma --folder supplied; DM + workbook will land in the first writable folder ' \
                             '(prefers a TEST/MIGRATION folder).',
                 'options' => ['supply --folder <id>', 'proceed into auto-resolved folder'],
                 'default' => 'proceed into auto-resolved folder' }
end

answers = nil
if opts[:answers]
  answers = (JSON.parse(opts[:answers]) rescue abort('FATAL: --answers is not valid JSON'))
end

if questions.any? && !opts[:yes] && answers.nil?
  block = {
    'status' => 'decisions_needed',
    'app' => app_name,
    'phases_completed' => ['1 Discover', '2 Convert'],
    'note' => 'Deterministic mechanical steps (reconcile, denorm SQL, POST, layout, parity) are NOT asked about. ' \
              "Re-run with --yes to accept all defaults, or --answers '{\"<id>\":\"<choice>\"}' to override.",
    'open_questions' => questions
  }
  puts
  puts '==================== OPEN QUESTIONS ===================='
  puts JSON.pretty_generate(block)
  puts '======================================================='
  puts
  puts "#{questions.size} decision(s) need a human. No Sigma objects were created."
  exit 10
end

if questions.any?
  puts
  puts "   decisions auto-resolved (#{opts[:yes] ? '--yes: defaults' : '--answers supplied'}):"
  questions.each do |q|
    chosen = (answers && answers[q['id']]) || q['default']
    label = q['measure'] || q['visual']
    puts "     - #{q['id']}#{label ? " [#{label}]" : ''}: #{chosen}"
  end
  # Honour an explicit abort answer.
  questions.each do |q|
    chosen = (answers && answers[q['id']]) || q['default']
    if chosen.to_s.start_with?('abort')
      puts "   '#{q['id']}' answered abort — stopping before any Sigma object is created."
      exit 10
    end
  end
else
  puts '   no open questions — running straight through'
end

# ---------------------------------------------------------------------------
# Phase 3 — Build data model (converter star + denorm SQL element, POST)
# ---------------------------------------------------------------------------
hdr(3, TOTAL, 'Build data model')
require 'sigma_rest'
# (i) reconcile the LOAD-script field→warehouse-column map, (ii) generate the
# denormalized SQL element — the bulletproof master for workbook charts.
reconcile = File.join(WORK, 'reconcile.json')
run!(['python3', File.join(HERE, 'reconcile-columns.py'),
      '--script', File.join(WORK, 'script.qvs'), '--out', reconcile])
denorm_out = File.join(WORK, 'denorm.json')
run!(['python3', File.join(HERE, 'gen-denorm-sql.py'),
      '--reconcile', reconcile, '--database', opts[:database], '--schema', opts[:schema],
      '--connection', opts[:conn], '--out', denorm_out])
denorm = JSON.parse(File.read(denorm_out))['element']
DENORM_ID = denorm['id']
# denorm columns: display-name → raw-alias (SQL output) lookup, for the workbook.
denorm_cols = denorm['columns'].map { |c| [c['name'], c['formula'][/\[Custom SQL\/(.+)\]/, 1]] }

# The converter's base warehouse-table elements carry the Qlik POST-RENAME field
# names as column display names (e.g. OrderFact.STORE_KEY) — but a warehouse-table
# element resolves columns against the REAL warehouse column names (ORDER_STORE_KEY),
# so those base elements can't resolve the renamed columns. The denormalized SQL
# element (built from reconcile.json) is the reconciled, self-contained master that
# DOES resolve every Qlik field. So the DM we ship = the denorm element, with the
# converter's translated metrics relocated onto it (their bare [Display] refs resolve
# against the denorm columns by display name). This is the proven build-sigma-dm.py
# pattern, generalized.
denorm_disp = denorm['columns'].map { |c| c['name'] }
denorm_disp_set = denorm_disp.map(&:downcase).to_set
degrade_titles = questions.select { |q| q['id'] == 'measure_no_sigma_equiv' }.map { |q| q['measure'] }.compact

# Collect translated metrics from the converter star; keep only those whose every
# bracketed [Display] ref resolves to a denorm column (so they don't error).
all_metrics = cmodel['pages'][0]['elements'].flat_map { |el| el['metrics'] || [] }
kept_metrics = []
dropped_metric_names = []
all_metrics.each do |m|
  refs = (m['formula'].to_s.scan(/\[([^\]]+)\]/).flatten).map { |r| r.split('/').last }
  if refs.all? { |r| denorm_disp_set.include?(r.downcase) }
    src_m = measures.find { |mm| mm['title'] == m['name'] }
    m['description'] ||= "Qlik: #{src_m['expr']}" if src_m && degrade_titles.include?(m['name'])
    kept_metrics << m
  else
    dropped_metric_names << m['name']
  end
end
denorm['metrics'] = kept_metrics if kept_metrics.any?
puts "   metrics: #{kept_metrics.size} hosted on denorm element" \
     "#{dropped_metric_names.empty? ? '' : "; #{dropped_metric_names.size} unresolved/dropped (#{dropped_metric_names.join(', ')})"}"

dm_model = { 'name' => "#{app_name} (Qlik→Sigma)", 'schemaVersion' => 1,
             'pages' => [{ 'id' => sid('pg'), 'name' => 'Page 1', 'elements' => [denorm] }] }
dm_spec_file = File.join(WORK, 'dm-spec.json')
File.write(dm_spec_file, JSON.pretty_generate(dm_model))

dm_body = dm_model.dup
dm_body['schemaVersion'] = 1
if opts[:folder]
  dm_body['folderId'] = opts[:folder]
else
  files = Sigma.request(:get, '/v2/files?typeFilters=folder&limit=200') rescue { 'entries' => [] }
  entries = files['entries'] || files['data'] || []
  pick = entries.find { |f| f['type'] == 'folder' && %w[TEST MIGRATION].any? { |k| f['name'].to_s.upcase.include?(k) } } ||
         entries.find { |f| f['type'] == 'folder' }
  dm_body['folderId'] = pick['id'] if pick
  puts "   folder (auto): #{pick && pick['name']} (#{dm_body['folderId']})"
end
dm_res = Sigma.request(:post, '/v2/dataModels/spec', body: dm_body.to_json)
DM_ID = dm_res['dataModelId'] || dm_res['id']
abort "FATAL: DM POST returned no id: #{dm_res.inspect}" unless DM_ID
# Sigma reassigns element ids on POST — read back the persisted denorm element id
# (it auto-names to "Custom SQL") rather than trusting the local pre-POST id.
dm_els = Sigma.request(:get, "/v2/dataModels/#{DM_ID}/elements") rescue { 'entries' => [] }
denorm_eid = (dm_els['entries'] || []).find { |e| e['type'] == 'table' }
denorm_eid = denorm_eid && (denorm_eid['elementId'] || denorm_eid['id'])
denorm_eid ||= DENORM_ID
puts "   dataModelId = #{DM_ID}  (denorm element #{denorm_eid}, #{denorm_cols.size} cols)"

# ---------------------------------------------------------------------------
# Phase 4 — Build workbook (master on denorm element + KPIs/charts from charts.json)
# ---------------------------------------------------------------------------
hdr(4, TOTAL, 'Build workbook')
# Raw-Qlik-field → denorm display-name resolver (charts.json refs raw load-script names).
raw_to_disp = {}
denorm_cols.each { |dn, raw| raw_to_disp[raw.upcase] = dn }
# also accept the display-name itself and the un-prefixed forms
denorm_cols.each { |dn, _raw| raw_to_disp[dn.upcase.gsub(' ', '_')] = dn }
def resolve_field(raw_to_disp, qlik_name)
  return nil unless qlik_name
  raw_to_disp[qlik_name.to_s.upcase] || raw_to_disp[qlik_name.to_s.upcase.gsub(' ', '_')]
end

# Translate a Qlik measure expr to a Sigma aggregate over the master, mapping its field.
def translate_measure(expr, raw_to_disp, master)
  e = expr.to_s.strip
  # Count(DISTINCT X)
  if (m = e.match(/\bCount\s*\(\s*DISTINCT\s+([A-Za-z0-9_]+)\s*\)/i))
    f = resolve_field(raw_to_disp, m[1]); return ["CountDistinct([#{master}/#{f}])", 'count'] if f
  end
  # Simple Set Analysis Sum({<F={v}>} X) → Sum(If([F]=v, [X]))
  if (m = e.match(/\bSum\s*\(\s*\{\s*<\s*([A-Za-z0-9_]+)\s*=\s*\{?([^}>]+)\}?\s*>\s*\}\s*([A-Za-z0-9_]+)\s*\)/i))
    cf = resolve_field(raw_to_disp, m[1]); xf = resolve_field(raw_to_disp, m[3])
    val = m[2].strip.gsub(/^'|'$/, '')
    return ["Sum(If([#{master}/#{cf}] = #{val =~ /\A-?\d+(\.\d+)?\z/ ? val : "\"#{val}\""}, [#{master}/#{xf}]))", 'sum'] if cf && xf
  end
  # plain Agg(FIELD)
  if (m = e.match(/\b(Sum|Avg|Count|Min|Max)\s*\(\s*([A-Za-z0-9_]+)\s*\)/i))
    f = resolve_field(raw_to_disp, m[2])
    return ["#{m[1].capitalize}([#{master}/#{f}])", m[1].downcase] if f
  end
  [nil, nil]
end

require 'securerandom'
MASTER = 'OFV'
NUMFMT = lambda do |kind, name|
  return { 'kind' => 'number', 'formatString' => ',.1%' } if name =~ /%|margin|rate/i
  return { 'kind' => 'number', 'formatString' => '$,.0f' } if name =~ /revenue|profit|amount|value|cost|price/i
  { 'kind' => 'number', 'formatString' => ',.0f' }
end

# Master table = every denorm column (so any chart field resolves).
master_cols = denorm_cols.map { |dn, _raw| { 'id' => sid('o'), 'name' => dn,
                                             'formula' => "[Custom SQL/#{dn}]" } }
master = { 'id' => 'm-ofv', 'name' => MASTER, 'kind' => 'table',
           'source' => { 'dataModelId' => DM_ID, 'elementId' => denorm_eid, 'kind' => 'data-model' },
           'columns' => master_cols }

elements = []
# KPI tiles from measure-only objects (dedup by title).
seen_kpi = {}
kpi_charts.each do |c|
  mexpr = (c['measures'] || []).first
  next unless mexpr
  f, _ = translate_measure(mexpr, raw_to_disp, MASTER)
  next unless f
  title = c['title'] || 'KPI'
  next if seen_kpi[title]
  seen_kpi[title] = true
  cid = sid('k')
  elements << { 'id' => sid('ek'), 'kind' => 'kpi-chart', 'name' => title,
                'source' => { 'elementId' => 'm-ofv', 'kind' => 'table' },
                'columns' => [{ 'id' => cid, 'formula' => f, 'name' => title, 'format' => NUMFMT.call(nil, title) }],
                'value' => { 'columnId' => cid } }
end
# Bar/line/table charts from dim+measure objects (dedup by title).
seen_chart = {}
real_charts.each do |c|
  title = c['title'] || c['vizType']
  next if seen_chart[title]
  dimraw = (c['dimensions'] || []).first
  dimraw = dimraw.first if dimraw.is_a?(Array)
  dimf = resolve_field(raw_to_disp, dimraw)
  next unless dimf
  ymids = []; cols = []
  x = sid('x'); cols << { 'id' => x, 'formula' => "[#{MASTER}/#{dimf}]", 'name' => dimf }
  (c['measures'] || []).each do |mexpr|
    mf, _ = translate_measure(mexpr, raw_to_disp, MASTER)
    next unless mf
    mname = mexpr.to_s[/\b([A-Za-z0-9_]+)\s*\)/, 1] || 'Measure'
    mname = resolve_field(raw_to_disp, mname) || mname
    y = sid('y'); cols << { 'id' => y, 'formula' => mf, 'name' => mname, 'format' => NUMFMT.call(nil, mname) }
    ymids << y
  end
  next if ymids.empty?
  seen_chart[title] = true
  kind = NATIVE_NAME[c['vizType']] || 'bar-chart'
  kind = 'table' if c['vizType'] == 'table'
  el = { 'id' => sid('ec'), 'kind' => kind, 'name' => title,
         'source' => { 'elementId' => 'm-ofv', 'kind' => 'table' }, 'columns' => cols }
  unless kind == 'table'
    el['xAxis'] = { 'columnId' => x }
    el['yAxis'] = { 'columnIds' => ymids }
  end
  elements << el
end

wb_spec = { 'name' => "#{app_name} → Sigma", 'schemaVersion' => 1 }
wb_spec['folderId'] = dm_body['folderId'] if dm_body['folderId']
wb_spec['pages'] = [
  { 'id' => 'page-data', 'name' => 'Data', 'elements' => [master] },
  { 'id' => 'page-overview', 'name' => 'Overview', 'elements' => elements }
]
wb_spec_file = File.join(WORK, 'wb-spec.json')
File.write(wb_spec_file, JSON.pretty_generate(wb_spec))
wb_res_raw = Sigma.request(:post, '/v2/workbooks/spec', body: wb_spec.to_json, accept: 'application/json')
WB_ID = wb_res_raw.is_a?(Hash) ? (wb_res_raw['workbookId'] || wb_res_raw['id']) : wb_res_raw[/workbookId:\s*(\S+)/, 1]
abort "FATAL: workbook POST returned no id: #{wb_res_raw.inspect}" unless WB_ID
puts "   workbookId = #{WB_ID}  (#{elements.count { |e| e['kind'] == 'kpi-chart' }} KPI(s), " \
     "#{elements.count { |e| e['kind'] != 'kpi-chart' }} chart(s))"

# ---------------------------------------------------------------------------
# Phase 5 — Layout (KPIs top row, charts 2-wide grid; PUT via put-layout.rb)
# ---------------------------------------------------------------------------
hdr(5, TOTAL, 'Layout')
kpis = elements.select { |e| e['kind'] == 'kpi-chart' }
chrt = elements.reject { |e| e['kind'] == 'kpi-chart' }
lines = ['<Page type="grid" gridTemplateColumns="repeat(24, 1fr)" gridTemplateRows="auto" id="page-overview">']
unless kpis.empty?
  w = 24 / kpis.size
  kpis.each_with_index do |e, i|
    c0 = 1 + i * w; c1 = i < kpis.size - 1 ? c0 + w : 25
    lines << %(  <LayoutElement elementId="#{e['id']}" gridColumn="#{c0} / #{c1}" gridRow="1 / 6"/>)
  end
end
row = 6
chrt.each_slice(2) do |pair|
  pair.each_with_index do |e, j|
    c0 = j.zero? ? 1 : 13
    c1 = (j.zero? && pair.size > 1) ? 13 : 25
    lines << %(  <LayoutElement elementId="#{e['id']}" gridColumn="#{c0} / #{c1}" gridRow="#{row} / #{row + 11}"/>)
  end
  row += 11
end
lines << '</Page>'
layout_xml = %(<?xml version="1.0" encoding="utf-8"?>\n) + lines.join("\n")
layout_file = File.join(WORK, 'layout.xml')
File.write(layout_file, layout_xml)
run!(['ruby', File.join(HERE, 'vendor', 'put-layout.rb'), '--workbook', WB_ID, '--layout', layout_file])
puts "   layout applied to workbook #{WB_ID}"

# ---------------------------------------------------------------------------
# Phase 6 — Parity (formula-resolution guard: no workbook column types as 'error')
# ---------------------------------------------------------------------------
hdr(6, TOTAL, 'Parity')
cols = Sigma.request(:get, "/v2/workbooks/#{WB_ID}/columns") rescue { 'entries' => [] }
entries = cols['entries'] || []
err_cols = entries.select { |c| c.dig('type', 'type') == 'error' }
total_cols = entries.size
parity_ok = err_cols.empty? && total_cols.positive?
if parity_ok
  puts "   PARITY: PASS — #{total_cols} workbook column(s) resolve (0 error-typed); " \
       "#{elements.size} element(s) across 2 page(s)"
else
  puts "   PARITY: FAIL — #{err_cols.size}/#{total_cols} column(s) resolved to type 'error':"
  err_cols.first(8).each { |c| puts "     [#{c['elementId']}] #{c['label']}: #{c['formula']}" }
end

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
puts
puts '================ RESULT ================'
puts "dataModelId : #{DM_ID}"
puts "workbookId  : #{WB_ID}"
puts "PARITY      : #{parity_ok ? 'PASS' : 'FAIL'} (#{total_cols} cols resolve, #{err_cols.size} error)"
puts "warnings    : #{conv_warnings.size} converter warning(s) (see #{File.join(WORK, 'converter-out.json')})" if conv_warnings.any?
puts '======================================='
exit(parity_ok ? 0 : 3)
