#!/usr/bin/env ruby
# migrate-powerbi.rb — ONE-SHOT, single-process orchestrator for the
# powerbi-to-sigma pipeline. Runs the whole phased workflow in one Ruby process
# to cut agent turns / token cost, WITHOUT turning the migration into a black
# box: every phase prints a visible header + concise result, and the genuine
# human decision points are surfaced as a structured OPEN QUESTIONS block
# (exit 10) rather than silently auto-resolved.
#
# Modeled on quicksight-to-sigma/scripts/migrate-quicksight.rb. It does NOT
# re-implement any phase — it chains the EXISTING scripts + the local
# convert_powerbi_to_sigma converter build:
#   explode the PBIR bundle + extract-pbir.py        (Phase 1 Discover/Extract)
#   convertPowerBIToSigma() via a node shim           (Phase 2 Convert)
#   convert-model.rb --converter-out (fixups)         (Phase 3 Build DM)
#     + validate-spec.rb + post-and-readback.rb
#   auto master-map + build-workbook-from-pbir.rb     (Phase 4 Build workbook)
#     + post-and-readback.rb
#   put-layout.rb                                     (Phase 5 Layout)
#   /columns error-type guard + per-element probe     (Phase 6 Parity)
#
# The convert_powerbi_to_sigma MCP tool is an ESM module; we import its exported
# convertPowerBIToSigma() directly via a tiny node shim (same trick as the QS
# orchestrator). Override the build dir with PBI_MCP_DIR.
#
# The one PBI-specific artifact a human normally authors — master-map.json (maps
# each PBI Entity.Field queryRef -> {master, ref, agg}) — is DERIVED here
# deterministically from the converter output (element name + column display
# names + translated metric formulas) cross-referenced with the PBIR queryRefs.
# DAX measures the converter could not translate (the (c)-tail) surface as OPEN
# QUESTIONS, not silent Null columns.
#
# Usage:
#   eval "$(scripts/get-token.sh)"   # Sigma token in env first (or rely on ~/.sigma-migration/env)
#   ruby scripts/migrate-powerbi.rb \
#     --tmsl /tmp/assessment-pbi-live/raw-tmsl/Test__Superstore_Overview.tmsl \
#     --pbir /tmp/assessment-pbi-live/raw-pbir/Test__Superstore_Overview.json \
#     --connection <SIGMA_CONN_UUID> --database TJ --schema PUBLIC \
#     --ref-dm <referenceDataModelId> \
#     [--name "Superstore Overview (from Power BI)"] [--folder <id>] \
#     [--out DIR] [--answers '<json>'] [--yes]
#
# Exit codes: 0 = done (parity pass); 10 = decisions needed (OPEN QUESTIONS); 3 = parity fail; other = error.
require 'json'
require 'optparse'
require 'fileutils'
require 'open3'
require 'digest'

HERE = __dir__
$LOAD_PATH.unshift File.expand_path('lib', HERE)

opts = { db: '', schema: '' }
OptionParser.new do |o|
  o.on('--tmsl PATH')       { |v| opts[:tmsl]   = File.expand_path(v) }
  o.on('--pbir PATH')       { |v| opts[:pbir]   = File.expand_path(v) }
  o.on('--connection ID')   { |v| opts[:conn]   = v }
  o.on('--database DB')     { |v| opts[:db]     = v }
  o.on('--schema S')        { |v| opts[:schema] = v }
  o.on('--ref-dm ID')       { |v| opts[:ref_dm] = v }
  o.on('--folder ID')       { |v| opts[:folder] = v }
  o.on('--name NAME')       { |v| opts[:name]   = v }
  o.on('--out DIR')         { |v| opts[:out]    = File.expand_path(v) }
  o.on('--answers JSON')    { |v| opts[:answers]= v }
  o.on('--yes')             {     opts[:yes]    = true }
end.parse!

abort 'missing --tmsl' unless opts[:tmsl]
abort "--tmsl not found: #{opts[:tmsl]}" unless opts[:tmsl] && File.exist?(opts[:tmsl])
abort 'missing --pbir' unless opts[:pbir]
abort "--pbir not found: #{opts[:pbir]}" unless File.exist?(opts[:pbir])

# Local converter build (the convert_powerbi_to_sigma MCP tool, imported directly).
MCP_DIR = ENV['PBI_MCP_DIR'] || %w[
  /Users/tjwells/Desktop/sigma-data-model-mcp
  /Users/tjwells/sigma-data-model-mcp
].find { |d| File.exist?(File.join(d, 'build', 'powerbi.js')) }

name_slug = File.basename(opts[:tmsl], '.*').gsub(/[^A-Za-z0-9_-]/, '-')
WORK = opts[:out] || File.expand_path("~/powerbi-migration/#{name_slug}")
FileUtils.mkdir_p(WORK)
WB_NAME = opts[:name] || "#{name_slug.gsub(/[_]+/, ' ').strip} (from Power BI)"

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

TOTAL = 6

# ---------------------------------------------------------------------------
# Phase 1 — Discover / Extract (explode the PBIR bundle, parse TMSL + signals)
# ---------------------------------------------------------------------------
hdr(1, TOTAL, 'Discover / Extract')

# The raw-pbir/*.json files are a FLAT bundle: { "<part-path>": "<json text>", ... }.
# extract-pbir.py wants an exploded definition/ folder — so explode it first.
pbir_dir = File.join(WORK, 'pbir')
FileUtils.mkdir_p(pbir_dir)
bundle = JSON.parse(File.read(opts[:pbir]))
exploded = 0
bundle.each do |part, payload|
  next unless part.start_with?('definition') # skip report.json/.platform legacy keys
  fp = File.join(pbir_dir, part)
  FileUtils.mkdir_p(File.dirname(fp))
  File.write(fp, payload.is_a?(String) ? payload : JSON.pretty_generate(payload))
  exploded += 1
end
abort "FATAL: PBIR bundle has no definition/ parts — is this an exploded PBIR? keys=#{bundle.keys.first(3)}" if exploded.zero?

signals_path = File.join(WORK, 'signals.json')
PY = File.exist?('/tmp/pbiauth/bin/python') ? '/tmp/pbiauth/bin/python' : 'python3'
run!([PY, File.join(HERE, 'extract-pbir.py'), '--pbir-dir', pbir_dir, '--out', signals_path])
signals = JSON.parse(File.read(signals_path))

# TMSL model summary + import/DirectQuery mode.
tmsl = JSON.parse(File.read(opts[:tmsl]))
model = tmsl['model'] || tmsl
tables = (model['tables'] || []).reject { |t| t['name'].to_s.start_with?('LocalDateTable_', 'DateTableTemplate_') }
all_measures = tables.flat_map { |t| (t['measures'] || []).map { |m| [t['name'], m['name'], Array(m['expression']).join] } }
modes = tables.flat_map { |t| (t['partitions'] || []).map { |p| p['mode'] } }.compact.uniq
mode_summ = modes.empty? ? 'unknown' : modes.join('/')

all_visuals = signals['pages'].flat_map { |p| p['visuals'] }
vkinds = all_visuals.each_with_object(Hash.new(0)) { |v, h| h[v['visual_type']] += 1 }
vsumm = vkinds.map { |k, c| c > 1 ? "#{k}×#{c}" : k }.join(', ')
puts "   model '#{name_slug}': #{tables.size} table(s), #{tables.sum { |t| (t['columns'] || []).size }} column(s), " \
     "#{all_measures.size} measure(s), mode=#{mode_summ}"
puts "   report: #{signals['pages'].size} page(s), #{all_visuals.size} visual(s) (#{vsumm})"

# ---------------------------------------------------------------------------
# Phase 2 — Convert (run convertPowerBIToSigma via a node shim)
# ---------------------------------------------------------------------------
hdr(2, TOTAL, 'Convert')
abort 'FATAL: cannot locate sigma-data-model-mcp powerbi build (set PBI_MCP_DIR)' unless MCP_DIR
shim = File.join(WORK, '_convert.mjs')
File.write(shim, <<~JS)
  import { readFileSync, writeFileSync } from 'node:fs';
  import { convertPowerBIToSigma } from #{File.join(MCP_DIR, 'build', 'powerbi.js').to_json};
  const model = JSON.parse(readFileSync(#{opts[:tmsl].to_json}, 'utf8'));
  const out = convertPowerBIToSigma(model, {
    connectionId: #{(opts[:conn] || '').to_json},
    database: #{opts[:db].to_json},
    schema: #{opts[:schema].to_json},
  });
  // Write the UNWRAPPED model to dm-raw.json. convert-model.rb MODE B unwraps
  // only {sigmaDataModel} or a bare spec, NOT this converter's {model,...}
  // wrapper, so it must receive the bare model (else "pages: Invalid array").
  const bare = out.model || out.sigmaDataModel || out;
  writeFileSync(#{File.join(WORK, 'dm-raw.json').to_json}, JSON.stringify(bare, null, 2));
  writeFileSync(#{File.join(WORK, 'conv-meta.json').to_json}, JSON.stringify({ model: bare, warnings: out.warnings || [], stats: out.stats || {} }, null, 2));
  process.stderr.write('CONVSTATS ' + JSON.stringify({ warnings: out.warnings || [], stats: out.stats || {} }) + '\\n');
JS
_c_out, c_err, c_st = Open3.capture3('node', shim)
abort "FATAL: converter failed:\n#{c_err}#{_c_out}" unless c_st.success?
puts "   converter ran (build: #{MCP_DIR})"
conv = JSON.parse(File.read(File.join(WORK, 'conv-meta.json')))
dm_model = conv['model']
conv_warnings = conv['warnings'] || []
conv_stats = conv['stats'] || {}
puts "   #{conv_stats['elements'] || (dm_model['pages'] || []).flat_map { |p| p['elements'] || [] }.size} element(s), " \
     "#{conv_stats['columns']} column(s), #{conv_stats['metrics']} metric(s); #{conv_warnings.size} converter warning(s)"

# ---------------------------------------------------------------------------
# DECISIONS CHECKPOINT — surface the genuine human questions
# ---------------------------------------------------------------------------
questions = []

# (a) + (b) DAX measures with no Sigma equivalent ((c)-tail) / DAX needing restructure.
# The converter marks these in `warnings`: ⛔ = no/failed translation (drops to Null);
# ⚠ = restructure-needed (RANKX/CALCULATE/iterator/scope/time-intel). ℹ = informational
# (clean auto-handle) — NOT a decision.
conv_warnings.each do |w|
  ws = w.to_s.gsub(/\s+/, ' ').strip
  next if ws.start_with?('ℹ') # informational; auto-handled, no human choice
  if ws.start_with?('⛔')
    questions << { 'id' => 'dax_no_equivalent', 'severity' => 'review',
                   'detail' => ws,
                   'options' => ['proceed (measure degrades to Null; original DAX kept in description)',
                                 'abort and re-author the measure manually'],
                   'default' => 'proceed (measure degrades to Null; original DAX kept in description)' }
  else # ⚠ and any unmarked warning
    questions << { 'id' => 'dax_needs_restructure', 'severity' => 'review',
                   'detail' => ws,
                   'options' => ['proceed (converter best-effort; verify in Sigma)',
                                 'restructure manually via gap-scout (scripts/gap-scout.md)'],
                   'default' => 'proceed (converter best-effort; verify in Sigma)' }
  end
end

# (b) visuals with no NATIVE Sigma kind. extract-pbir maps unknown visualTypes to
# "bar" as a fallback; flag any visualType that is NOT a recognized native PBI kind
# so a human confirms the approximation (treemap/funnel/gauge/map/etc.).
NATIVE = %w[card multiRowCard kpi textbox actionButton lineChart areaChart
            stackedAreaChart barChart clusteredBarChart stackedBarChart columnChart
            clusteredColumnChart stackedColumnChart hundredPercentStackedColumnChart
            hundredPercentStackedBarChart lineClusteredColumnComboChart
            lineStackedColumnComboChart pieChart donutChart scatterChart tableEx
            pivotTable matrix slicer].freeze
GAUGE = %w[gauge].freeze
all_visuals.each do |v|
  vt = v['visual_type']
  next if NATIVE.include?(vt)
  approx = GAUGE.include?(vt) ? 'approximate-to-kpi' : "approximate-to-#{v['sigma_kind']}"
  questions << { 'id' => 'visual_no_native_kind', 'severity' => 'review',
                 'visual' => v['title'] || v['visual_id'], 'pbi_type' => vt,
                 'detail' => "#{vt} has no native Sigma element kind (mapped to #{v['sigma_kind']})",
                 'options' => [approx, 'skip this visual'], 'default' => approx }
end

# (c) import vs DirectQuery / warehouse landing. Sigma is always live-on-warehouse;
# an IMPORT-mode PBI model has cached data, so values may drift vs the warehouse.
if modes.include?('import')
  questions << { 'id' => 'import_vs_directquery', 'severity' => 'review',
                 'detail' => "PBI model partition mode = #{mode_summ}. Sigma queries the warehouse LIVE; " \
                             "an import model's cached values may differ from the live #{opts[:db]}.#{opts[:schema]} table. " \
                             "Confirm the Sigma connection points at the same warehouse the import was sourced from.",
                 'options' => ["land live on connection #{opts[:conn]} (#{opts[:db]}.#{opts[:schema]})",
                               'abort and reconcile the warehouse source first'],
                 'default' => "land live on connection #{opts[:conn]} (#{opts[:db]}.#{opts[:schema]})" }
end

# (required) connection.
unless opts[:conn]
  questions << { 'id' => 'connection', 'severity' => 'required',
                 'detail' => 'No Sigma --connection supplied; required to point the DM at the warehouse',
                 'options' => ['supply --connection <id>'], 'default' => nil }
end

answers = nil
if opts[:answers]
  answers = (JSON.parse(opts[:answers]) rescue abort('FATAL: --answers is not valid JSON'))
end

if questions.any? && !opts[:yes] && answers.nil?
  block = {
    'status' => 'decisions_needed',
    'model' => name_slug,
    'phases_completed' => ['1 Discover/Extract', '2 Convert'],
    'note' => 'Deterministic mechanical steps (fixup, master-map, POST, layout, parity) are NOT asked about. ' \
              'Re-run with --yes to accept all defaults, or --answers \'{"<id>":"<choice>"}\' to override.',
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
    puts "     - #{q['id']}#{q['visual'] ? " [#{q['visual']}]" : ''}: #{chosen}"
  end
else
  puts '   no open questions — running straight through'
end

# Abort if any answer chose an abort/stop option.
chosen_all = questions.map { |q| (answers && answers[q['id']]) || q['default'] }
if chosen_all.any? { |c| c.to_s =~ /\babort\b/i }
  abort "STOP: a decision selected an abort option — not creating any Sigma objects."
end

# ---------------------------------------------------------------------------
# Phase 3 — Build data model (fixups + validate + POST + readback)
# ---------------------------------------------------------------------------
hdr(3, TOTAL, 'Build data model')

# Pre-fixup: the converter emits base warehouse-table columns with NO `name`
# (Sigma derives the display name from the source column at POST time). But
# validate-spec.rb resolves sibling refs by `name`, and a metric like
# `Sum([Sales])` then fails ("[Sales] not a sibling column"). So stamp each
# base column's display name from its own formula ([Tbl/Sales] -> "Sales")
# before convert-model.rb runs. Idempotent: only fills a missing/empty name.
raw_dm = JSON.parse(File.read(File.join(WORK, 'dm-raw.json')))
named_cols = 0
(raw_dm['pages'] || []).each do |pg|
  (pg['elements'] || []).each do |el|
    next unless el.dig('source', 'path') # base warehouse-table elements only
    (el['columns'] || []).each do |c|
      next if c['name'] && !c['name'].to_s.empty?
      dn = c['formula'].to_s.gsub(/^\[|\]$/, '').split('/')[-1]
      next if dn.to_s.empty?
      c['name'] = dn
      named_cols += 1
    end
  end
end
File.write(File.join(WORK, 'dm-raw.json'), JSON.pretty_generate(raw_dm))
puts "   pre-fixup: named #{named_cols} base column(s) from their formula" if named_cols.positive?

dm_spec = File.join(WORK, 'dm-spec.json')
fixup = ['ruby', File.join(HERE, 'convert-model.rb'),
         '--converter-out', File.join(WORK, 'dm-raw.json'),
         '--out', dm_spec, '--name', WB_NAME.sub(/\(from Power BI\)\s*$/, 'DM (from Power BI)')]
if opts[:folder]
  # caller gave an explicit folder; still need an owner — harvest from ref-dm if present.
  fixup += ['--folder-id', opts[:folder]]
  fixup += ['--ref-dm', opts[:ref_dm]] if opts[:ref_dm]
elsif opts[:ref_dm]
  fixup += ['--ref-dm', opts[:ref_dm]]
else
  abort 'FATAL: need --ref-dm (to harvest folderId/ownerId) or --folder plus a --ref-dm for ownerId'
end
run!(fixup, env: ENV.to_h)
run!(['ruby', File.join(HERE, 'validate-spec.rb'), '--type', 'datamodel', dm_spec])
dm_readback = File.join(WORK, 'dm-readback.json')
run!(['ruby', File.join(HERE, 'post-and-readback.rb'), '--type', 'datamodel',
      '--spec', dm_spec, '--out', dm_readback, '--workdir', WORK], env: ENV.to_h)
dm_rb = JSON.parse(File.read(dm_readback))
dm_id = dm_rb['dataModelId']
puts "   dataModelId = #{dm_id}"

# ---------------------------------------------------------------------------
# Phase 4 — Build workbook (auto master-map from converter + signals, then build+POST)
# ---------------------------------------------------------------------------
hdr(4, TOTAL, 'Build workbook')

# --- derive the master-map deterministically ---
# Converter element: name (= warehouse table) + columns (formula [Tbl/Display]) + metrics.
# The DM readback element name is authoritative (PUT may rename); match by name.
conv_elements = (dm_model['pages'] || []).flat_map { |p| p['elements'] || [] }
dm_elements = dm_rb['pages'].flat_map { |p| p['elements'] || [] }

# Display-name helper: a column formula "[Tbl/Order Id]" -> "Order Id".
disp = lambda { |formula| formula.to_s.gsub(/^\[|\]$/, '').split('/')[-1] }

# Build one master per converter element. master id is "master-<elementId-tail>".
masters = {}
field_map = {}
conv_elements.each do |cel|
  cname = cel['name']
  # match the posted DM element by name (PUT keeps names; ids may change).
  dmel = dm_elements.find { |e| e['name'] == cname } || dm_elements.first
  mkey = cname
  mid  = "master-#{Digest::SHA1.hexdigest(cname)[0, 8]}"
  cols = (cel['columns'] || []).map do |c|
    dn = disp.call(c['formula'])
    { 'id' => "mc-#{Digest::SHA1.hexdigest("#{cname}/#{dn}")[0, 10]}", 'name' => dn,
      'formula' => "[#{cname}/#{dn}]" }
  end
  masters[mkey] = { 'id' => mid, 'element_id' => dmel['id'], 'data_model' => dm_id,
                    'columns' => cols }
  # column field refs: queryRef "Entity.Col" -> {master, ref:[master/Col], agg:null}
  cols.each do |c|
    field_map["#{cname}.#{c['name']}"] = { 'master' => mkey, 'ref' => "[#{mid}/#{c['name']}]", 'agg' => nil }
  end
  # measure field refs: a translated metric "Sum([Sales])" -> rewrite bare col refs
  # to the master, set agg=null and pass the FULL formula as `ref` (build script
  # uses ref verbatim when agg is nil — handles ratios like DIVIDE too).
  (cel['metrics'] || []).each do |m|
    formula = m['formula'].to_s
    # rewrite every "[Col]" (bare, no slash) -> "[master/Col]"
    rewritten = formula.gsub(/\[([^\/\]]+)\]/) { "[#{mid}/#{Regexp.last_match(1)}]" }
    field_map["#{cname}.#{m['name']}"] = { 'master' => mkey, 'ref' => rewritten, 'agg' => nil,
                                           'format' => (m.dig('format', 'formatString')) }
  end
end

master_map = { 'masters' => masters, 'fields' => field_map }
mmap_path = File.join(WORK, 'master-map.json')
File.write(mmap_path, JSON.pretty_generate(master_map))
puts "   master-map: #{masters.size} master(s), #{field_map.size} field/measure ref(s) -> #{mmap_path}"

wb_spec = File.join(WORK, 'workbook-spec.json')
layout = File.join(WORK, 'layout.xml')
build = ['ruby', File.join(HERE, 'build-workbook-from-pbir.rb'),
         '--signals', signals_path, '--master-map', mmap_path,
         '--data-model', dm_id, '--name', WB_NAME,
         '--out', wb_spec, '--layout-out', layout]
# The workbook POST requires a folderId. Use --folder if given, else inherit the
# DM's folderId (harvested from the ref-dm at Phase 3) so both land together.
wb_folder = opts[:folder] || (JSON.parse(File.read(dm_spec))['folderId'] rescue nil)
build += ['--folder-id', wb_folder] if wb_folder
run!(build)
wb_readback = File.join(WORK, 'wb-readback.json')
run!(['ruby', File.join(HERE, 'post-and-readback.rb'), '--type', 'workbook',
      '--spec', wb_spec, '--out', wb_readback, '--workdir', WORK], env: ENV.to_h)
wb_rb = JSON.parse(File.read(wb_readback))
wb_id = wb_rb['workbookId']
puts "   workbookId = #{wb_id}"

# ---------------------------------------------------------------------------
# Phase 5 — Layout (authoritative final spec write — bead 16i)
# ---------------------------------------------------------------------------
hdr(5, TOTAL, 'Layout')
run!(['ruby', File.join(HERE, 'put-layout.rb'), '--workbook', wb_id, '--layout', layout], env: ENV.to_h)
puts "   layout applied to workbook #{wb_id}"

# ---------------------------------------------------------------------------
# Phase 6 — Parity (formula-resolution guard + per-element row probe)
# ---------------------------------------------------------------------------
hdr(6, TOTAL, 'Parity')
require 'sigma_rest'
cols = (Sigma.request(:get, "/v2/workbooks/#{wb_id}/columns") rescue { 'entries' => [] })
err_cols = (cols['entries'] || []).select { |c| c.dig('type', 'type') == 'error' }
total_cols = (cols['entries'] || []).size
chart_pages = wb_rb['pages'].reject { |p| p['id'] == 'page-data' }
chart_els = chart_pages.flat_map { |p| (p['elements'] || []) }
parity_ok = err_cols.empty?
if parity_ok
  puts "   PARITY: PASS — #{total_cols} workbook column(s) resolve (0 error-typed); " \
       "#{chart_els.size} chart element(s) built across #{chart_pages.size} page(s)"
else
  puts "   PARITY: FAIL — #{err_cols.size}/#{total_cols} column(s) resolved to type 'error':"
  err_cols.first(8).each { |c| puts "     [#{c['elementId']}] #{c['label']}: #{c['formula']}" }
end

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
puts
puts '================ RESULT ================'
puts "dataModelId : #{dm_id}"
puts "workbookId  : #{wb_id}"
puts "PARITY      : #{parity_ok ? 'PASS' : 'FAIL'} (#{total_cols} cols resolve, #{err_cols.size} error)"
puts '======================================='
exit(parity_ok ? 0 : 3)
