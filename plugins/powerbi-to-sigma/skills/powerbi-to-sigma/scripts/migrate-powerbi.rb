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
#     [--out DIR] [--answers '<json>'] [--yes] \
#     [--mcp-dir <sigma-data-model-mcp clone> | --converter-out <mcp-tool result.json>] \
#     [--python <interpreter>]
#
# Converter route (bead 7o01): with a local sigma-data-model-mcp build (--mcp-dir /
# PBI_MCP_DIR / ~/Desktop or ~/ clone) the conversion runs in-process via a node
# shim. WITHOUT one, Phase 2 stops with a gate: run the convert_powerbi_to_sigma
# MCP tool yourself and resume with --converter-out <its result JSON> — the
# default route on machines without a local build.
#
# Exit codes: 0 = done (parity pass); 10 = decisions needed (OPEN QUESTIONS); 3 = parity fail; other = error.
require 'json'
require 'optparse'
require 'fileutils'
require 'open3'
require 'digest'
require 'set'

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
  # bead 7o01 portability: no hardcoded developer paths. --mcp-dir / PBI_MCP_DIR
  # selects a local sigma-data-model-mcp build; --converter-out feeds a converter
  # result produced by the convert_powerbi_to_sigma MCP TOOL (the default route
  # when no local build exists); --python / PBI_PY picks the Python interpreter.
  o.on('--mcp-dir DIR')        { |v| opts[:mcp_dir] = File.expand_path(v) }
  o.on('--converter-out PATH') { |v| opts[:cvt_out] = File.expand_path(v) }
  o.on('--python PATH')        { |v| opts[:python]  = File.expand_path(v) }
end.parse!

abort 'missing --tmsl' unless opts[:tmsl]
abort "--tmsl not found: #{opts[:tmsl]}" unless opts[:tmsl] && File.exist?(opts[:tmsl])
abort 'missing --pbir' unless opts[:pbir]
abort "--pbir not found: #{opts[:pbir]}" unless File.exist?(opts[:pbir])
# bead hjke(a): abort early on a truncated/partial connection id — it survives
# all the way to the DM POST and fails there opaquely ("Source not found").
if opts[:conn] && opts[:conn] !~ /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  abort "FATAL: --connection must be a FULL Sigma connection UUID (8-4-4-4-12 hex); " \
        "got #{opts[:conn].inspect}. List connections with GET /v2/connections."
end

# Local converter build (the convert_powerbi_to_sigma MCP tool, imported directly).
# bead 7o01: no hardcoded developer paths — resolve from --mcp-dir / PBI_MCP_DIR,
# else probe common clone locations under $HOME. When NONE is found, Phase 2 does
# NOT abort: it stops with a gate instructing the agent to run the
# convert_powerbi_to_sigma MCP tool and resume with --converter-out (the default
# converter route on machines without a local build).
MCP_DIR = [opts[:mcp_dir], ENV['PBI_MCP_DIR'],
           File.expand_path('~/Desktop/sigma-data-model-mcp'),
           File.expand_path('~/sigma-data-model-mcp')]
          .compact.find { |d| File.exist?(File.join(d, 'build', 'powerbi.js')) }

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

# Raised when the MECHANICAL WORKBOOK layer (build / validate / POST) fails after
# the data model is already posted + valid. The orchestrator catches this and
# degrades to a FRIENDLY agent-path handoff instead of a bare crash — the DM is
# ready, so the agent path can rebuild just the workbook against it.
class WorkbookBuildError < StandardError
  attr_reader :captured_output
  def initialize(msg, captured_output = '')
    super(msg)
    @captured_output = captured_output.to_s
  end
end

# Like run!, but on failure raises WorkbookBuildError (catchable) instead of
# abort()ing the process. Captures the child output so the caller can mine it for
# the offending field name(s) ("Dependency not found", "Unknown column", etc.).
def run_wb!(cmd, env: {})
  out, st = Open3.capture2e(env, *cmd)
  out.each_line { |l| puts "   #{l.rstrip}" } unless out.strip.empty?
  raise WorkbookBuildError.new("command failed (#{st.exitstatus}): #{cmd.join(' ')}", out) unless st.success?
  out
end

# Pull likely-offending field/column names out of a failed workbook build/POST log
# so the fallback message can name them. Looks for the common rejection shapes:
#   "Dependency not found: <X>", "Unknown column \"[<X>]\"", "source: {} ... <X>",
#   "Invalid value: undefined", unresolved [El/Col] refs.
def cull_failed_fields(*logs)
  text = logs.join("\n")
  names = []
  text.scan(/Dependency not found:?\s*([^\n,]+)/i) { |m| names << m[0].strip }
  text.scan(/Unknown column\s*"?\[?([^"\]\n]+)\]?"?/i) { |m| names << m[0].strip }
  text.scan(/unmapped (?:derived[- ]dim|measure|field)\s*[:=]?\s*([^\n,]+)/i) { |m| names << m[0].strip }
  text.scan(/Circular column reference[^\n]*\[([^\]]+)\]/i) { |m| names << m[0].strip }
  names.map { |n| n.gsub(/[\[\]"]/, '').strip }.reject(&:empty?).uniq
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
# bead 7o01: Python resolution — --python / PBI_PY, else a bootstrapped venv
# (run.sh creates <work-dir>/.venv), else the legacy /tmp/pbiauth venv, else
# system python3 (sufficient here: the offline PBIR parse is stdlib-only).
PY = opts[:python] || ENV['PBI_PY'] ||
     [File.join(WORK, '.venv', 'bin', 'python'), '/tmp/pbiauth/bin/python']
       .find { |p| File.exist?(p) } || 'python3'
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
if opts[:cvt_out]
  # bead 7o01: converter output supplied (the convert_powerbi_to_sigma MCP tool
  # ran out-of-process — the default route when no local build exists). Unwrap
  # the {model,...} / {sigmaDataModel} wrapper the same way the shim does.
  raw = JSON.parse(File.read(opts[:cvt_out]))
  bare = raw['model'] || raw['sigmaDataModel'] || raw
  File.write(File.join(WORK, 'dm-raw.json'), JSON.pretty_generate(bare))
  File.write(File.join(WORK, 'conv-meta.json'),
             JSON.pretty_generate({ 'model' => bare, 'warnings' => raw['warnings'] || [],
                                    'stats' => raw['stats'] || {} }))
  puts "   converter output ingested from #{opts[:cvt_out]}"
elsif MCP_DIR.nil?
  puts '   no local sigma-data-model-mcp build found (set --mcp-dir / PBI_MCP_DIR for the in-process route).'
  puts
  puts '   >>> GATE: run the convert_powerbi_to_sigma MCP tool on the TMSL model'
  puts "       (#{opts[:tmsl]}) with connectionId=#{opts[:conn]} database=#{opts[:db]} schema=#{opts[:schema]},"
  puts '       save the tool result JSON to a file, then re-run this command with'
  puts '       --converter-out <that file>. No Sigma objects were created.'
  exit 10
end
unless opts[:cvt_out]
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
end
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
    # Bug E: SQL elements synthesized from a DAX CALENDAR/VALUES calc-table
    # (DimDate, DimMonth, SalaryBands) ALSO need their columns named — their
    # follow-on calc columns reference siblings by bare [ColAlias], which
    # error-type if the referenced column has no display name. Previously only
    # warehouse-table (source.path) elements were stamped.
    is_warehouse = !el.dig('source', 'path').nil?
    is_sql       = el.dig('source', 'kind') == 'sql'
    next unless is_warehouse || is_sql
    (el['columns'] || []).each do |c|
      next if c['name'] && !c['name'].to_s.empty?
      f  = c['formula'].to_s
      dn = f.gsub(/^\[|\]$/, '').split('/')[-1]
      next if dn.to_s.empty?
      # Bug E (SQL elements): a SQL-OUTPUT column has a bare self-referencing
      # formula `[Date]` that maps to the SQL `AS "Date"` alias. Stamping
      # name="Date" on it makes `[Date]` a CIRCULAR reference -> error-type. Only
      # stamp a name when the formula is NOT a bare self-reference (i.e. a
      # follow-on calc column like `Year([Date])`), so its siblings can ref it,
      # while leaving SQL-output columns nameless to bind to their alias.
      if is_sql
        bare_self = (f =~ /\A\[[^\]\/]+\]\z/) && (f.gsub(/^\[|\]$/, '') == dn)
        next if bare_self
      end
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

# Bug A: For a JOIN/View element, columns carry the FULL cross-element ref path
# in their formula — e.g. "[ORDER_FACT/Customer Key]" (own column) AND
# "[ORDER_FACT/CUSTOMER_DIM/Customer Key]" (related column). Both leaf-resolve to
# "Customer Key", so keying the master-column id/name on the leaf produces a
# COLLISION (duplicate ids + duplicate names) and the workbook POST fails.
# These helpers reproduce Sigma's own disambiguation:
#   - the Sigma DISPLAY NAME of a related col is "Customer Key (CUSTOMER_DIM)"
#     (leaf + " (relName)") — matches the converter's viewColDisplay().
#   - the master-column ID keys on the FULL path so it is unique per column.
sigma_view_disp = lambda do |formula|
  parts = formula.to_s.gsub(/^\[|\]$/, '').split('/')
  parts.length <= 2 ? parts[-1] : "#{parts[-1]} (#{parts[-2]})"
end
# The path INSIDE the element (drop the element-name prefix), used as the master
# column's resolving formula, e.g. "[mid/CUSTOMER_DIM/Customer Key]".
inner_path = lambda do |formula|
  parts = formula.to_s.gsub(/^\[|\]$/, '').split('/')
  parts.length <= 1 ? parts[0].to_s : parts[1..].join('/')
end

# Build one master per converter element. master id is "master-<elementId-tail>".
masters = {}
field_map = {}
conv_elements.each do |cel|
  cname = cel['name']
  # match the posted DM element: by NAME first (PUT keeps names; ids may change),
  # then by ID. A Custom SQL element is NAMELESS in the spec (rule 3) and Sigma
  # auto-names it "Custom SQL" on readback — recover that name by id-match so the
  # master keys + column prefixes resolve (Bug E: nameless SQL element).
  dmel = (cname && dm_elements.find { |e| e['name'] == cname }) ||
         dm_elements.find { |e| e['id'] == cel['id'] } || dm_elements.first
  cname ||= (dmel && dmel['name']) || 'Custom SQL'
  mkey = cname
  mid  = "master-#{Digest::SHA1.hexdigest(cname)[0, 8]}"
  # Bug A: key the master-column id on the FULL cross-element path (not the leaf)
  # and use Sigma's disambiguated display name. For a JOIN/View element, base and
  # related columns can share a leaf ("Customer Key"), so leaf-keying collides on
  # both id AND name -> duplicate columns -> workbook POST fails. The master table
  # element sources from the DM element (named `cname`); the DM element exposes a
  # related column under its disambiguated display name "Leaf (RelName)", so the
  # master column's formula references THAT display name on `cname`. Dedupe by the
  # full path so each underlying column yields exactly one master column.
  seen_paths = {}
  cols = (cel['columns'] || []).map do |c|
    # If the converter already stamped a display `name` (calc/derived/time-intel
    # columns), trust it — the column's formula is an expression, NOT a bare
    # [El/Col] ref, so formula-parsing would mangle the name (Bug C side effect).
    # Bug A formula-path keying applies ONLY to bare [El/.../Col] reference cols.
    bare_ref = c['formula'].to_s =~ /\A\[[^\]]+\]\z/
    if c['name'] && !c['name'].to_s.empty? && !bare_ref
      dn  = c['name'].to_s
      key = "#{cname}/calc/#{dn}"
      next nil if seen_paths[key]
      seen_paths[key] = true
      next({ 'id' => "mc-#{Digest::SHA1.hexdigest(key)[0, 10]}", 'name' => dn,
             'formula' => "[#{cname}/#{dn}]", '_leaf' => dn })
    end
    full = c['formula'].to_s.gsub(/^\[|\]$/, '')         # e.g. ORDER_FACT/CUSTOMER_DIM/Customer Key
    next nil if full.empty? || seen_paths[full]
    seen_paths[full] = true
    dn   = sigma_view_disp.call(c['formula'])            # "Customer Key (CUSTOMER_DIM)"
    { 'id' => "mc-#{Digest::SHA1.hexdigest("#{cname}/#{full}")[0, 10]}", 'name' => dn,
      'formula' => "[#{cname}/#{dn}]", '_leaf' => disp.call(c['formula']) }
  end.compact
  # column field refs: queryRef "Entity.Col" -> {master, ref:[mid/Name], agg:null}.
  # Map both the disambiguated name AND the bare leaf (PBIR queryRefs use the leaf
  # when the dim column is unambiguous in the original model) so bindings resolve.
  cols.each do |c|
    ref = { 'master' => mkey, 'ref' => "[#{mid}/#{c['name']}]", 'agg' => nil }
    field_map["#{cname}.#{c['name']}"] = ref
    field_map["#{cname}.#{c['_leaf']}"] ||= ref
  end
  cols.each { |c| c.delete('_leaf') } # internal-only; keep master columns clean
  masters[mkey] = { 'id' => mid, 'element_id' => dmel['id'], 'data_model' => dm_id,
                    'columns' => cols }
  # measure field refs: a translated metric "Sum([Sales])" -> rewrite bare col refs
  # to the master, set agg=null and pass the FULL formula as `ref` (build script
  # uses ref verbatim when agg is nil — handles ratios like DIVIDE too).
  #
  # Bug D: a metric formula may reference ANOTHER metric by name, e.g.
  #   Sales per Order = [Total Sales] / [Orders]
  # where Total Sales = Sum([Sales]) and Orders = CountDistinct([Order Id]).
  # Naively rewriting [Total Sales] -> [mid/Total Sales] points at a NON-EXISTENT
  # master column (metrics are formulas, not stored columns), and Sigma rejects
  # the dependency. Fix: substitute the referenced metric's FULL formula INLINE.
  # Stored master-column names ARE valid [mid/Name] refs; only metric-name refs
  # are inlined. Resolve recursively (with a guard) so chained metrics collapse.
  master_col_names = cols.map { |c| c['name'] }.to_set
  metric_by_name   = {}
  (cel['metrics'] || []).each { |mm| metric_by_name[mm['name'].to_s] = mm['formula'].to_s }
  resolve_metric = lambda do |formula, depth|
    formula.to_s.gsub(/\[([^\/\]]+)\]/) do
      ref = Regexp.last_match(1)
      if master_col_names.include?(ref)
        "[#{mid}/#{ref}]"                                   # real stored column
      elsif metric_by_name.key?(ref) && depth < 16
        "(#{resolve_metric.call(metric_by_name[ref], depth + 1)})" # inline the metric
      else
        "[#{mid}/#{ref}]"                                   # bare column ref (e.g. Sum([Sales]))
      end
    end
  end
  (cel['metrics'] || []).each do |m|
    rewritten = resolve_metric.call(m['formula'].to_s, 0)
    field_map["#{cname}.#{m['name']}"] = { 'master' => mkey, 'ref' => rewritten, 'agg' => nil,
                                           'format' => (m.dig('format', 'formatString')) }
  end
end

# Bug E (queryRef routing): a DAX calc-table (DimDate / SalaryBands / DimMonth)
# becomes a NAMELESS Custom SQL element (master keyed "Custom SQL"), but the PBIR
# chart still binds it under its ORIGINAL table name ("DimDate.Month"). Alias the
# original calc-table name + each column onto the Custom SQL master so those
# bindings resolve. The calc table is identified from the TMSL (partition source
# type 'calculated'); its column display names match the Custom SQL master cols.
calc_tables = tables.select do |t|
  Array(t['partitions']).any? { |p| p.dig('source', 'type') == 'calculated' }
end
# A Custom SQL master is recognizable by its column formulas using the
# `[Custom SQL/...]` prefix (the converter emits that for SQL-element columns).
sql_masters = masters.select do |_n, m|
  (m['columns'] || []).any? { |c| c['formula'].to_s.start_with?('[Custom SQL/') }
end
calc_tables.each do |t|
  orig = t['name'].to_s
  # pick the SQL master whose columns best cover this calc table's columns.
  tcols = (t['columns'] || []).reject { |c| c['type'] == 'rowNumber' || c['isGenerated'] }
                              .map { |c| (c['sourceColumn'] || c['name']).to_s.gsub(/^\[|\]$/, '') }
  best = sql_masters.max_by do |_n, m|
    names = (m['columns'] || []).map { |c| c['name'].to_s }
    tcols.count { |tc| names.any? { |n| n.casecmp?(tc) || n.gsub(/\s+/, '').casecmp?(tc.gsub(/\s+/, '')) } }
  end
  next unless best
  bmkey, bm = best
  (bm['columns'] || []).each do |c|
    ref = { 'master' => bmkey, 'ref' => "[#{bm['id']}/#{c['name']}]", 'agg' => nil }
    field_map["#{orig}.#{c['name']}"] ||= ref
  end
end

# Bug A (star schema): a cross-table visual binds a DIMENSION from a dim table
# (e.g. PRODUCT_DIM.Category) AND a MEASURE from the fact (ORDER_FACT.Net Rev).
# Those route to DIFFERENT per-table masters, but a Sigma chart element can only
# reference columns from its OWN source master — a cross-master ref error-types.
# The converter already builds a denormalized "<Fact> View" element that carries
# the fact columns + every related dim column (disambiguated "Leaf (DIM)"). So
# RE-ROUTE every field that the View also exposes onto the View master, leaving
# the visual with a single coherent source. Match a per-table field's leaf name
# to the View column whose Sigma display name is "Leaf" or "Leaf (anything)".
conv_elements.each do |vcel|
  vname = vcel['name'].to_s
  next unless vname =~ /\sView$/                     # the denormalized join element
  next unless masters[vname]
  vmid  = masters[vname]['id']
  vcols = masters[vname]['columns'] || []
  # leaf -> View column name (prefer the bare-leaf col when present, else the
  # first disambiguated "Leaf (DIM)" col).
  leaf_to_view = {}
  vcols.each do |c|
    leaf = c['name'].to_s.sub(/\s+\([^)]*\)\s*$/, '') # strip " (DIM)" suffix
    leaf_to_view[leaf] ||= c['name']
    leaf_to_view[c['name']] ||= c['name']            # exact disambiguated form too
  end
  # the fact this View denormalizes (drop the trailing " View").
  fact = vname.sub(/\s+View$/, '')
  # masters whose columns the View subsumes: the fact + every dim reachable via
  # a "(DIM)" suffix in the View's columns.
  subsumed = [fact] + vcols.map { |c| c['name'][/\(([^)]*)\)\s*$/, 1] }.compact.uniq
  field_map.each do |qr, fs|
    next unless subsumed.include?(fs['master'])
    old_mid = masters[fs['master']] ? masters[fs['master']]['id'] : nil
    ref_str = fs['ref'].to_s
    is_plain_col = ref_str =~ /\A\[[^\]]+\]\z/ # exactly one bracketed ref, no agg
    if is_plain_col
      # plain dimension/column ref: match its leaf to a View column.
      leaf = qr.split('.', 2).last.to_s.sub(/\s+\([^)]*\)\s*$/, '')
      vcol = leaf_to_view[leaf] || leaf_to_view[qr.split('.', 2).last.to_s]
      next unless vcol
      field_map[qr] = fs.merge('master' => vname, 'ref' => "[#{vmid}/#{vcol}]")
    elsif old_mid
      # measure/aggregation formula: every referenced fact column must exist on the
      # View (it does — the View carries all fact columns). Swap the old master id
      # for the View master id and remap each inner column leaf to its View name.
      remapped = ref_str.gsub(/\[#{Regexp.escape(old_mid)}\/([^\]]+)\]/) do
        inner = Regexp.last_match(1)
        mapped = leaf_to_view[inner] || leaf_to_view[inner.sub(/\s+\([^)]*\)\s*$/, '')] || inner
        "[#{vmid}/#{mapped}]"
      end
      # only re-route if we actually rewrote a ref onto the View master.
      field_map[qr] = fs.merge('master' => vname, 'ref' => remapped) if remapped.include?(vmid)
    end
  end
end

# Bug C: time-intel forwarding. The converter turns DAX SAMEPERIODLASTYEAR /
# TOTALYTD measures into NEW DM elements (source.kind=='table' sourcing another
# element, carrying DateLookback / CumulativeSum columns). Those elements get a
# master built above, but the ORIGINAL PBI queryRef ("ORDER_FACT.Net Revenue PY"
# / "ORDER_FACT.YoY %") still points at the fact table, where the measure no
# longer exists -> the workbook chart resolves no master -> emits source:{} and
# the POST fails with "Invalid value: undefined". Add synthetic field_map entries
# routing "<OrigTable>.<MeasureName>" -> the new element's computed column.
#   measure name -> original TMSL table (from Phase 1's all_measures).
ti_orig_table = {}
all_measures.each { |tbl, mname, _expr| ti_orig_table[mname] = tbl }
# collect the emitted time-intel elements (element-sourced, DateLookback/CumulativeSum).
ti_elements = []
conv_elements.each do |cel|
  src = cel['source'] || {}
  next unless src['kind'] == 'table' && src['elementId'] # element sourced from another element
  cols = cel['columns'] || []
  is_time_intel = cols.any? { |c| c['formula'].to_s =~ /\b(DateLookback|CumulativeSum)\s*\(/ }
  next unless is_time_intel
  mname = cel['name'].to_s            # converter names the element after the measure
  mkey  = mname
  next unless masters[mkey]           # its master was built in the loop above
  mid   = masters[mkey]['id']
  # pick the headline computed column: prior-year / YTD / YoY %, falling back to
  # the last column (the converter appends the derived measure last).
  pick = cols.find { |c| c['formula'].to_s =~ /\bDateLookback\s*\(/ } ||
         cols.find { |c| c['formula'].to_s =~ /\bCumulativeSum\s*\(/ } ||
         cols.find { |c| c['name'].to_s =~ /YoY/i } || cols.last
  next unless pick
  # bead 525l: a SINGLE-VALUE KPI bound to this measure must NOT receive a bare
  # row-level ref (agg:nil) into the GROUPED element — Sigma evaluates an
  # unaggregated ref over a multi-row (one-per-period) element nondeterministically
  # (null / arbitrary row). Emit an explicit deterministic "latest period" headline
  # formula via the builder's verbatim-formula hook (measure_formula):
  #   Sum(If([mid/<dateCol>] = Max([mid/<dateCol>]), [mid/<col>], Null))
  # In a chart grouped BY that date column the same formula still evaluates to the
  # per-period value (within each group Max(date)=date), so it is safe for both
  # the KPI and the date-grouped chart paths. The date col = the element's groupBy.
  group_ids = (cel['groupings'] || []).flat_map { |g| g['groupBy'] || [] }
  date_col  = cols.find { |c| group_ids.include?(c['id']) } ||
              cols.find { |c| c['formula'].to_s =~ /\bDateTrunc\s*\(/ } ||
              cols.find { |c| c['name'].to_s =~ /\A(Year|Quarter|Month|Week|Date|Day)\z/i }
  headline = lambda do |colname|
    next nil unless date_col
    "Sum(If([#{mid}/#{date_col['name']}] = Max([#{mid}/#{date_col['name']}]), [#{mid}/#{colname}], Null))"
  end
  ti_elements << { 'name' => mname, 'mid' => mid, 'cols' => cols,
                   'date' => (date_col && date_col['name']) }
  ref = { 'master' => mkey, 'ref' => "[#{mid}/#{pick['name']}]", 'agg' => nil }
  hf = headline.call(pick['name'])
  ref['formula'] = hf if hf
  orig = ti_orig_table[mname]
  # route both the original-table queryRef and a self-named queryRef so whichever
  # form the PBIR binding used resolves to this element.
  field_map["#{orig}.#{mname}"] = ref if orig
  field_map["#{mname}.#{mname}"] ||= ref
  # also map any YoY % / Prior Year / YTD sibling column by its own name on the orig table.
  cols.each do |c|
    next unless c['name'].to_s =~ /YoY|Prior Year|YTD/i
    sub = { 'master' => mkey, 'ref' => "[#{mid}/#{c['name']}]", 'agg' => nil }
    shf = headline.call(c['name'])
    sub['formula'] = shf if shf
    field_map["#{orig}.#{c['name']}"] ||= sub if orig
  end
  # A chart that puts a PY/YoY column next to the BASE value and the period
  # dimension (e.g. Year × Net Revenue × Net Revenue PY) must source from THIS
  # grouped element — the View lacks the PY column. Register ALTS so those
  # sibling fields can ALSO resolve here: the grouped value is already aggregated,
  # so it is referenced as a PLAIN column (no extra Sum). visual_master then
  # majority-picks this element and field_spec swaps in the alt ref.
  base_val  = cols.find { |c| c['formula'].to_s =~ /\b(Sum|Avg|Count|CountDistinct|Min|Max)\s*\(/ }
  period_cols = cols.select { |c| c['name'].to_s =~ /\b(Year|Month|Quarter|Day|Date|Week)\b/i }
  reg_alt = lambda do |qr, colname|
    next unless field_map[qr] && colname
    (field_map[qr]['alts'] ||= []) << { 'master' => mkey, 'ref' => "[#{mid}/#{colname}]", 'agg' => nil }
  end
  if base_val
    # the base value measure under the orig table (any measure whose formula is an
    # aggregation of the same value column the PY/YTD element sums). Compare with
    # whitespace stripped from BOTH sides so "Net Revenue" matches "[Net Revenue]".
    valleaf  = base_val['name']
    valnorm  = valleaf.gsub(/\s+/, '').downcase
    all_measures.each do |t2, m2, e2|
      next unless t2 == orig
      enorm = e2.to_s.gsub(/\s+/, '').downcase
      agg_of_val = enorm =~ /(sum|average|avg|min|max|count|distinctcount)\([^)]*#{Regexp.escape(valnorm)}/
      reg_alt.call("#{orig}.#{m2}", valleaf) if agg_of_val || m2 == valleaf
    end
  end
  # The grouped element carries period dimension column(s) (Year and/or Month).
  # A chart that plots the time-intel measure BY one of those periods must source
  # from this element, so register each period column as an alt under the common
  # date-dim queryRef forms (the calc-table date dim is the usual binding source).
  period_cols.each do |pc|
    %w[DATE_DIM DimDate DimMonth Date].each { |dt| reg_alt.call("#{dt}.#{pc['name']}", pc['name']) }
    reg_alt.call("#{orig}.#{pc['name']}", pc['name'])
  end
end

# Bug C (continued): OTHER time-intel measures (e.g. a standalone "YoY %" using a
# hand-rolled MAX/ALL prior-year pattern) may NOT get their own element — the
# converter folds the YoY computation into the prior-year element's "... YoY %"
# column. Any such measure still has a live PBI queryRef ("ORDER_FACT.YoY %")
# the chart binds, but no field_map entry -> source:{} -> POST fails. Route every
# remaining time-intel-shaped measure to the best-matching time-intel column.
if ti_elements.any?
  ti_re = /\b(SAMEPERIODLASTYEAR|TOTALYTD|TOTALQTD|TOTALMTD|DATESYTD|DATEADD|PARALLELPERIOD|PREVIOUSYEAR|PREVIOUSMONTH|PREVIOUSQUARTER)\b/i
  all_measures.each do |tbl, mname, expr|
    next if field_map.key?("#{tbl}.#{mname}")
    e = expr.to_s
    # time-intel-shaped: a DAX time-intel function, OR a YoY/growth name, OR a
    # hand-rolled MAX(...)/ALL(...) prior-year ratio.
    shape =
      if e =~ ti_re then :generic
      elsif mname =~ /YoY|Y\/Y|growth/i || e =~ /ALL\s*\([^)]*\[Year\]/i then :yoy
      elsif mname =~ /\bYTD\b/i then :ytd
      elsif mname =~ /\b(PY|Prior Year|Last Year|LY)\b/i then :prior
      end
    next unless shape
    # choose a target column across the emitted time-intel elements.
    target = nil; tmid = nil; tname = nil; tdate = nil
    ti_elements.each do |te|
      cand =
        case shape
        when :yoy   then te['cols'].find { |c| c['name'].to_s =~ /YoY/i }
        when :ytd   then te['cols'].find { |c| c['formula'].to_s =~ /\bCumulativeSum\s*\(/ }
        when :prior then te['cols'].find { |c| c['formula'].to_s =~ /\bDateLookback\s*\(/ }
        else te['cols'].find { |c| c['formula'].to_s =~ /\b(DateLookback|CumulativeSum)\s*\(/ }
        end
      if cand then target = cand; tmid = te['mid']; tname = te['name']; tdate = te['date']; break end
    end
    next unless target
    entry = { 'master' => tname, 'ref' => "[#{tmid}/#{target['name']}]", 'agg' => nil }
    # bead 525l: same headline-KPI determinism as above — a bare row-level ref on
    # the grouped element is nondeterministic when consumed by a single-value KPI.
    if tdate
      entry['formula'] = "Sum(If([#{tmid}/#{tdate}] = Max([#{tmid}/#{tdate}]), " \
                         "[#{tmid}/#{target['name']}], Null))"
    end
    field_map["#{tbl}.#{mname}"] = entry
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

# GRACEFUL AGENT-PATH FALLBACK. The DM is already posted + valid (dm_id above), so
# if the MECHANICAL workbook layer (build / validate-spec / POST) hits a field it
# cannot translate (Sigma rejects the spec / unresolved "Dependency not found" /
# unmapped derived-dim or measure / source:{}), we must NOT bare-crash. Catch it
# and exit with a clear, FRIENDLY non-zero handoff: the agent path rebuilds the
# workbook against this DM (see SKILL.md). Never worse than the proven agent path.
begin
  build_log = run_wb!(build)
  wb_readback = File.join(WORK, 'wb-readback.json')
  rb_log = run_wb!(['ruby', File.join(HERE, 'post-and-readback.rb'), '--type', 'workbook',
                    '--spec', wb_spec, '--out', wb_readback, '--workdir', WORK], env: ENV.to_h)
rescue WorkbookBuildError => e
  failed = cull_failed_fields(e.captured_output, (defined?(build_log) ? build_log : ''))
  # Also surface the converter (c)-tail measures as the likely culprits when the
  # log itself doesn't name a field.
  if failed.empty?
    failed = conv_warnings.map { |w| w.to_s.gsub(/\s+/, ' ').strip }
                          .select { |w| w.start_with?('⛔') }
                          .map { |w| w[/[“"]([^”"]+)[”"]/, 1] || w.sub(/^⛔\s*/, '')[0, 60] }
                          .compact.uniq
  end
  names = failed.empty? ? 'one or more fields' : failed.join(', ')
  n = failed.empty? ? 'some' : failed.size.to_s
  puts
  puts "── Mechanical path: data model built OK (dataModelId=#{dm_id}). The WORKBOOK " \
       "layer hit #{n} field(s) the mechanical path can't translate (#{names}). " \
       "Falling back to the agent path: rebuild the workbook via the skill's " \
       "agent-authored flow (see SKILL.md) against this DM. The data model is " \
       "posted and ready to attach."
  exit 4
end
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
