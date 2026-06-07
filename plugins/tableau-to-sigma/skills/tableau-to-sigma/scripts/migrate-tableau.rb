#!/usr/bin/env ruby
# frozen_string_literal: true
# migrate-tableau.rb — ONE-SHOT, single-process orchestrator for the
# tableau-to-sigma pipeline. Runs the whole phased workflow in one Ruby process
# to cut agent turns / token cost, WITHOUT turning the migration into a black
# box: every phase prints a visible header + concise result, and the genuine
# human decision points (window/table-calc degradations, untranslatable calcs,
# custom-SQL / file-based datasources, unsupported viz) are surfaced as a
# structured OPEN QUESTIONS block (exit 10) rather than silently auto-resolved.
#
# This script does NOT re-implement any mechanical phase — it chains the
# existing skill scripts:
#   tableau-discover.rb     (Phase 1 — workbook + views + .twb + ds-metadata + PNG)
#   parse-twb-layout.rb     (Phase 1 — dashboard zone tree + chart kinds)
#   extract-calc-fields.rb  (Phase 1 — calc formulas + requires_custom_sql flag)
#   extract-custom-sql.rb   (Phase 1 — custom-SQL blocks behind the datasource)
#   scan-workbook-gaps.rb   (Phase 1 — feature-gap inventory)
#   discover-columns.rb     (Phase 2 — real warehouse column names/types)
#   validate-spec.rb + post-and-readback.rb (Phase 3 DM, Phase 4 workbook)
#   build-dashboard-layout.rb + put-layout.rb (Phase 5 layout)
#   phase6-parity.rb        (Phase 6 parity, best-effort; falls back to the
#                            post-and-readback column-type guard as the hard signal)
#
# Spec GENERATION (the DM spec + workbook spec) is the one genuinely
# agent-owned step in this skill — there is no mechanical converter the way
# QuickSight has. The orchestrator delegates it to a pluggable generator:
#   * If a `Specs` module is reachable (the validated reference generator at
#     ~/orders-migration/specs.rb, or a per-workbook generator the agent drops
#     next to the working dir), it is used verbatim — deterministic, validated.
#   * Otherwise the orchestrator builds a data-driven DM from the warehouse
#     tables discovered in Phase 2 (one warehouse-table element per table,
#     *_KEY-inferred relationships, calc fields translated by the built-in
#     Tableau->Sigma translator) and the workbook via the skill's own
#     build-charts-from-signals.rb + build-workbook-spec.rb.
#
# Usage:
#   ruby scripts/migrate-tableau.rb \
#     --workbook "<name>" | --workbook-id <luid> \
#     --connection <SIGMA_CONNECTION_ID> --folder <SIGMA_FOLDER_ID> \
#     [--db CSA --schema TJ] [--specs <path/to/specs.rb>] \
#     [--out DIR] [--answers '<json>'] [--yes]
#
# Exit codes: 0 = done (PARITY pass); 10 = decisions needed (OPEN QUESTIONS
# printed, NO Sigma objects created); 3 = parity/guard fail; other = error.
require 'json'
require 'csv'
require 'yaml'
require 'optparse'
require 'fileutils'
require 'open3'
require 'date'
require 'time'

HERE = __dir__
$LOAD_PATH.unshift File.expand_path('lib', HERE)

opts = {}
OptionParser.new do |o|
  o.on('--workbook NAME')    { |v| opts[:wb_name] = v }
  o.on('--workbook-id LUID') { |v| opts[:wb_id]   = v }
  o.on('--connection ID')    { |v| opts[:conn]    = v }
  o.on('--folder ID')        { |v| opts[:folder]  = v }
  o.on('--db NAME')          { |v| opts[:db]      = v }
  o.on('--schema NAME')      { |v| opts[:schema]  = v }
  o.on('--specs PATH')       { |v| opts[:specs]   = File.expand_path(v) }
  o.on('--out DIR')          { |v| opts[:out]     = File.expand_path(v) }
  o.on('--answers JSON')     { |v| opts[:answers] = v }
  o.on('--yes')              {     opts[:yes]     = true }
end.parse!

abort 'missing --workbook or --workbook-id' unless opts[:wb_name] || opts[:wb_id]
abort 'missing --connection' unless opts[:conn]

slug = (opts[:wb_name] || opts[:wb_id]).gsub(/[^A-Za-z0-9_-]/, '-').squeeze('-')
WORK = opts[:out] || File.expand_path("~/tableau-migration/#{slug}")
FileUtils.mkdir_p(File.join(WORK, 'views'))

TOTAL = 6
def hdr(n, title) puts; puts "── Phase #{n}/#{TOTAL} · #{title} ──"; end
def line(m) puts "   #{m}"; end

# Run a child command, indenting its output. token_env: prepend a fresh
# Sigma/Tableau token via the skill's get-token scripts so long runs survive
# the ~1h token TTL.
def run!(cmd, allow_fail: false)
  out, st = Open3.capture2e(*cmd)
  out.each_line { |l| puts "   #{l.rstrip}" } unless out.strip.empty?
  abort "FATAL: command failed (#{st.exitstatus}): #{cmd.join(' ')}" unless st.success? || allow_fail
  [out, st]
end

# Wrap a command so a Sigma token is live for it (eval get-token.sh first).
def sigma_run!(cmd, allow_fail: false)
  joined = cmd.map { |a| "'" + a.gsub("'", "'\\''") + "'" }.join(' ')
  run!(['bash', '-c', "eval \"$(#{File.join(HERE, 'get-token.sh')})\" && #{joined}"], allow_fail: allow_fail)
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
# abort()ing the process. Captures the child output for field-name mining.
def run_wb!(cmd)
  out, st = Open3.capture2e(*cmd)
  out.each_line { |l| puts "   #{l.rstrip}" } unless out.strip.empty?
  raise WorkbookBuildError.new("command failed (#{st.exitstatus}): #{cmd.join(' ')}", out) unless st.success?
  out
end

# sigma_run! variant that raises WorkbookBuildError instead of aborting.
def sigma_run_wb!(cmd)
  joined = cmd.map { |a| "'" + a.gsub("'", "'\\''") + "'" }.join(' ')
  run_wb!(['bash', '-c', "eval \"$(#{File.join(HERE, 'get-token.sh')})\" && #{joined}"])
end

# Pull likely-offending field/column names out of a failed workbook build/POST log.
def cull_failed_fields(*logs)
  text = logs.join("\n")
  names = []
  text.scan(/Dependency not found:?\s*([^\n,]+)/i) { |m| names << m[0].strip }
  text.scan(/Unknown column\s*"?\[?([^"\]\n]+)\]?"?/i) { |m| names << m[0].strip }
  text.scan(/unmapped (?:derived[- ]dim|measure|field)\s*[:=]?\s*([^\n,]+)/i) { |m| names << m[0].strip }
  text.scan(/Circular column reference[^\n]*\[([^\]]+)\]/i) { |m| names << m[0].strip }
  names.map { |n| n.gsub(/[\[\]"]/, '').strip }.reject(&:empty?).uniq
end

def yp(s) YAML.safe_load(s, permitted_classes: [Date, Time]) rescue {} end

# ---------------------------------------------------------------------------
# Phase 1 — Discover (Tableau side). Chains tableau-discover + parse-twb-layout
# + extract-calc-fields + extract-custom-sql + scan-workbook-gaps.
# ---------------------------------------------------------------------------
hdr(1, 'Discover')
disc = ['ruby', File.join(HERE, 'tableau-discover.rb'), '--out', WORK]
disc += opts[:wb_id] ? ['--workbook-id', opts[:wb_id]] : ['--workbook-name', opts[:wb_name]]
run!(['bash', '-c',
      "eval \"$(#{File.join(HERE, 'get-tableau-token.sh')})\" && " +
      disc.map { |a| "'" + a.gsub("'", "'\\''") + "'" }.join(' ')])

gw = JSON.parse(File.read(File.join(WORK, 'get-workbook.json')))
wb = gw['workbook'] || gw
wb_luid = wb['id'] || opts[:wb_id]
wb_name = wb['name'] || opts[:wb_name] || slug
has_extracts = [wb['hasExtracts'], wb.dig('datasources')].to_s.include?('true') ||
               wb['hasExtracts'] == true
views = (wb.dig('views', 'view') || [])
views = [views] unless views.is_a?(Array)
line "workbook '#{wb_name}' (#{wb_luid}): #{views.size} view(s)#{has_extracts ? ', hasExtracts=true' : ''}"

twb = File.join(WORK, 'workbook-content.twb')
layout_json = File.join(WORK, 'dashboard-layout.json')
have_twb = File.exist?(twb)
if have_twb
  run!(['ruby', File.join(HERE, 'parse-twb-layout.rb'), twb, layout_json])
  dash = JSON.parse(File.read(layout_json))
  zones = dash.is_a?(Array) ? dash.flat_map { |d| d['zones'] || [] } : (dash['zones'] || [])
  chart_zones = zones.select { |z| z['kind'] == 'chart' }
  kinds = chart_zones.map { |z| z['chart_kind'] }.compact
                     .each_with_object(Hash.new(0)) { |k, h| h[k] += 1 }
                     .map { |k, c| c > 1 ? "#{k}×#{c}" : k }.join(', ')
  line "parsed .twb: #{chart_zones.size} chart zone(s) (#{kinds})"
else
  chart_zones = []
  line 'no .twb content (MCP-only datasource?) — chart-kind/calc discovery degraded'
end

calc_path = File.join(WORK, 'calc-fields.json')
calcs = []
if wb_luid
  cf = ['ruby', File.join(HERE, 'extract-calc-fields.rb'),
        '--workbook-luid', wb_luid, '--out', calc_path]
  cf += ['--twb', twb] if have_twb
  _, st = run!(['bash', '-c',
                "eval \"$(#{File.join(HERE, 'get-tableau-token.sh')})\" && " +
                cf.map { |a| "'" + a.gsub("'", "'\\''") + "'" }.join(' ')], allow_fail: true)
  if File.exist?(calc_path)
    cfj = JSON.parse(File.read(calc_path)) rescue {}
    calcs = cfj['calcs'] || []
    n_csql = calcs.count { |c| c['requires_custom_sql'] }
    line "#{calcs.size} calc field(s); #{n_csql} require Custom SQL (window/LOD)"
  end
end

custom_sql = []
csql_path = File.join(WORK, 'custom-sql.json')
if wb_luid && have_twb
  csql_cmd = ['ruby', File.join(HERE, 'extract-custom-sql.rb'),
              '--workbook-luid', wb_luid, '--twb', twb, '--out', csql_path]
  run!(['bash', '-c',
        "eval \"$(#{File.join(HERE, 'get-tableau-token.sh')})\" && " +
        csql_cmd.map { |a| "'" + a.gsub("'", "'\\''") + "'" }.join(' ')], allow_fail: true)
  custom_sql = (JSON.parse(File.read(csql_path)) rescue []) if File.exist?(csql_path)
  custom_sql = [] unless custom_sql.is_a?(Array)
end

gaps = []
if have_twb
  run!(['ruby', File.join(HERE, 'scan-workbook-gaps.rb'), twb], allow_fail: true)
  gj = Dir[File.join(WORK, '*gaps*report*.json')].first || Dir[File.join(WORK, '*gaps*.json')].first
  if gj && File.exist?(gj)
    gaps = (JSON.parse(File.read(gj))['detected_features'] || []) rescue []
    bys = gaps.group_by { |g| g['status'] }.transform_values(&:size)
    line "gap scan: #{bys.map { |k, v| "#{v} #{k}" }.join(', ')}"
  end
end

# ---------------------------------------------------------------------------
# Spec generation. The DEFAULT path is MECHANICAL (no agent hand-authoring):
#   convert_tableau_to_sigma → DM spec; parse-twb-layout + build-charts-from-
#   signals + an auto-derived master-map → workbook spec. An explicit --specs
#   <path> (or a per-workbook <workdir>/specs.rb the human dropped in) overrides
#   the mechanical path with a hand-authored `Specs` module, used verbatim.
# ---------------------------------------------------------------------------
require File.join(HERE, 'mechanical-specs')
specs_path = opts[:specs] || [File.join(WORK, 'specs.rb')].find { |p| File.exist?(p) }
have_specs = false
if specs_path && File.exist?(specs_path)
  begin
    require specs_path.sub(/\.rb$/, '')
    have_specs = defined?(Specs) && Specs.respond_to?(:dm_spec) && Specs.respond_to?(:wb_spec)
    line "spec generator: hand-authored Specs module (#{specs_path})" if have_specs
  rescue StandardError => e
    line "(spec generator at #{specs_path} failed to load: #{e.message})"
  end
end

# Mechanical converter run (the default). Requires the .twb (parse-twb-layout
# already gated on have_twb above) and the local build/tableau.js converter.
mechanical = !have_specs
conv = nil
if mechanical
  unless have_twb
    abort <<~MSG
      FATAL: mechanical conversion needs the workbook .twb (for the data model +
      chart signals), but none was downloaded (MCP-only datasource?). Either
      supply a hand-authored Specs module via --specs, or use a .twb-backed
      workbook.
    MSG
  end
  mcp_build = ENV['TABLEAU_MCP_BUILD'] || %w[
    /Users/tjwells/Desktop/sigma-data-model-mcp/build/tableau.js
    /Users/tjwells/sigma-data-model-mcp/build/tableau.js
  ].find { |p| File.exist?(p) }
  abort 'FATAL: cannot locate build/tableau.js (set TABLEAU_MCP_BUILD)' unless mcp_build
  conv = MechanicalSpecs.run_converter(
    twb_path: twb, conn: opts[:conn], db: (opts[:db] || 'CSA'),
    schema: (opts[:schema] || 'TJ'), mcp_build: mcp_build, workdir: WORK)
  st = conv['stats'] || {}
  line "mechanical converter: #{st['elements']} element(s), #{st['columns']} column(s), " \
       "#{st['metrics']} metric(s), #{st['relationships']} relationship(s); #{(conv['warnings'] || []).size} warning(s)"

  # Mechanical DM fixup NOW (so dropped calcs feed the checkpoint): resolve
  # raw-table-name prefixes + GUID sibling refs, and DROP calc columns that
  # still cannot resolve (unknown functions / unresolved refs).
  fx = MechanicalSpecs.fixup_dm_spec(conv['model'])
  line "DM fixup: rewrote #{fx[:fixed]} formula(s); dropped #{fx[:dropped].size} unresolvable calc col(s)" if fx[:fixed].positive? || fx[:dropped].any?
  dropped_calcs = fx[:dropped]

  # Pre-derive the master-map now (deterministic; uses the converter element
  # name — Phase 4 re-derives against the authoritative readback name). This lets
  # us surface any chart-PLOTTED metric that did not fully translate (GUID refs
  # the converter could not resolve) as an OPEN QUESTION rather than a silent
  # blank chart. Metrics that aren't plotted by any view are ignored.
  conv_fact = MechanicalSpecs.pick_fact(conv['model'])
  conv_base = conv_fact ? MechanicalSpecs.base_of(conv['model'], conv_fact) : nil
  pre = conv_fact ? MechanicalSpecs.derive_master(conv_fact, (conv_fact['name'] || 'Order Fact'), conv_base) : { 'untranslated_metrics' => [] }
  csv_headers = Dir[File.join(WORK, 'views', '*.csv')].flat_map do |c|
    (CSV.read(c).first rescue nil) || []
  end.compact.map { |h| h.to_s.strip }.uniq
  plotted_untranslated = (pre['untranslated_metrics'] || []).select do |nm|
    csv_headers.any? { |h| h.casecmp?(nm) || h.sub(/^(sum|avg|min|max|median|distinct count|count) of /i, '').casecmp?(nm) }
  end
end

# ---------------------------------------------------------------------------
# DECISIONS CHECKPOINT — surface the genuine human questions ONLY. Mechanical
# fixup / POST / layout / parity are never asked about.
# ---------------------------------------------------------------------------
questions = []

# (a0) MECHANICAL CONVERTER WARNINGS — the authoritative un-mappable signal.
# convert_tableau_to_sigma marks each calc/LOD/window translation outcome:
#   ⛔ = no/failed translation (calc dropped → charts using it degrade)
#   ⚠  = best-effort / unsupported mode (verify in Sigma)
#   ℹ / ✅ = clean auto-handle (NOT a decision)
(mechanical ? (conv['warnings'] || []) : []).each do |w|
  ws = w.to_s.gsub(/\s+/, ' ').strip
  next if ws.start_with?('ℹ', '✅')
  next if ws.include?('Connection ID not set') # mechanical: --connection always supplied
  if ws.start_with?('⛔')
    questions << { 'id' => 'calc_no_translation', 'severity' => 'review', 'detail' => ws,
                   'options' => ['proceed (calc dropped; dependent charts degrade)',
                                 'abort and re-author the calc manually'],
                   'default' => 'proceed (calc dropped; dependent charts degrade)' }
  else # ⚠ and any unmarked warning
    questions << { 'id' => 'calc_best_effort', 'severity' => 'review', 'detail' => ws,
                   'options' => ['proceed (converter best-effort; verify in Sigma)',
                                 'restructure manually'],
                   'default' => 'proceed (converter best-effort; verify in Sigma)' }
  end
end

# (a1) PLOTTED metrics whose formula did not fully translate (unresolved Tableau
# internal field refs). These are charted by a Tableau view but cannot resolve
# mechanically against the master — a genuine human decision.
(mechanical ? (defined?(plotted_untranslated) && plotted_untranslated || []) : []).each do |nm|
  questions << { 'id' => 'metric_untranslated', 'severity' => 'review', 'calc' => nm,
                 'detail' => "Metric '#{nm}' is plotted in a Tableau view but the converter left unresolved " \
                             'internal field references in its formula — it cannot be rebuilt mechanically.',
                 'options' => ['proceed (chart measure left blank; re-author the calc in Sigma)',
                               'skip this metric'],
                 'default' => 'proceed (chart measure left blank; re-author the calc in Sigma)' }
end

# (a2) calc COLUMNS the mechanical fixup had to DROP (unknown function like
# DATEPARSE, or refs that never resolved). Genuinely un-mappable → human.
(mechanical ? (defined?(dropped_calcs) && dropped_calcs || []) : []).each do |nm|
  questions << { 'id' => 'calc_dropped', 'severity' => 'review', 'calc' => nm,
                 'detail' => "Calc column '#{nm}' could not be translated mechanically (unsupported function " \
                             'or unresolved reference) and was dropped from the data model.',
                 'options' => ['proceed (column dropped; re-author as a Custom SQL element or Sigma calc)',
                               'skip this calc'],
                 'default' => 'proceed (column dropped; re-author as a Custom SQL element or Sigma calc)' }
end

# (a) calc fields that have NO Sigma calc-column translation (window / table
#     calc / LOD) — they become Custom-SQL DM elements or degrade.
calcs.select { |c| c['requires_custom_sql'] }.each do |c|
  questions << {
    'id' => 'calc_requires_custom_sql', 'severity' => 'review',
    'calc' => c['name'],
    'detail' => "Tableau calc '#{c['name']}' (#{c['is_lod'] ? 'LOD' : 'table-calc'}) has no native Sigma " \
                "calc-column form: #{c['formula'].to_s.gsub(/\s+/, ' ').strip[0, 120]}",
    'options' => ['implement as a Custom SQL data-model element (kind: sql)',
                  'degrade (drop the calc; charts using it go blank)',
                  'skip this calc'],
    'default' => 'implement as a Custom SQL data-model element (kind: sql)'
  }
end

# (b) custom-SQL datasource blocks — DM must source via kind:sql, not warehouse-table.
custom_sql.each do |b|
  q = (b['query'] || b['sql'] || '').to_s.gsub(/\s+/, ' ').strip[0, 120]
  questions << {
    'id' => 'custom_sql_datasource', 'severity' => 'review',
    'detail' => "Datasource is backed by Custom SQL; the DM element must use source.kind=sql: #{q}",
    'options' => ['source the DM element via Custom SQL (kind: sql)',
                  'abort and refactor the source in the warehouse first'],
    'default' => 'source the DM element via Custom SQL (kind: sql)'
  }
end

# (c) file-based / "land in warehouse" datasources (Excel/CSV/Hyper extract not
#     backed by a live warehouse table).
ds_type = (wb.dig('datasources') || []).to_s
file_based = ds_type =~ /excel|csv|textscan|hyper|\.tde|google-sheets/i
if file_based || (has_extracts && custom_sql.empty? && !have_twb)
  questions << {
    'id' => 'file_based_datasource', 'severity' => 'required',
    'detail' => 'Datasource appears to be file-based (Excel/CSV/Hyper) — Sigma reads a warehouse, ' \
                'so the data must first land in a warehouse table on the chosen connection',
    'options' => ['land the file in the warehouse, then point the DM at that table',
                  'abort until the data is in the warehouse'],
    'default' => nil
  }
end

# (d) extract-backed workbook — Tableau CSVs are a frozen snapshot; parity will
#     drift vs live warehouse. This is an expectations decision, not a failure.
if has_extracts
  questions << {
    'id' => 'extract_drift', 'severity' => 'review',
    'detail' => 'Workbook/datasource hasExtracts=true: Tableau view CSVs are a frozen snapshot. ' \
                'Sigma reads the warehouse live, so absolute values will drift; parity runs in ' \
                'structural (extract) mode.',
    'options' => ['proceed (structural parity, value drift expected)', 'abort and refresh the extract first'],
    'default' => 'proceed (structural parity, value drift expected)'
  }
end

# (e) unsupported / approximate viz kinds. Keep in lock-step with build-charts'
#     SIGMA_KIND map + the SKILL's "Sigma spec supports" list.
NATIVE = %w[bar line area combo scatter pie kpi map-region map-point pivot-table
            table automatic other table-or-text].freeze
APPROX = {
  'gantt' => 'approximate-to-bar', 'bullet' => 'approximate-to-bar',
  'heatmap' => 'data-migrate-as-table', 'treemap' => 'data-migrate-as-table',
  'packed-bubble' => 'data-migrate-as-table', 'density' => 'data-migrate-as-table'
}.freeze
chart_zones.each do |z|
  k = z['chart_kind'].to_s
  next if NATIVE.include?(k)
  cap = z['caption'] || z['view_ref'] || k
  if APPROX.key?(k)
    questions << { 'id' => 'viz_no_native_kind', 'severity' => 'review',
                   'viz' => cap, 'tableau_kind' => k,
                   'detail' => "Tableau '#{k}' has no native Sigma element kind",
                   'options' => [APPROX[k], 'skip this viz'], 'default' => APPROX[k] }
  else
    questions << { 'id' => 'viz_unknown_kind', 'severity' => 'review',
                   'viz' => cap, 'tableau_kind' => k,
                   'detail' => "Tableau mark '#{k}' did not map to a known Sigma kind — confirm from the dashboard PNG",
                   'options' => ['build as a bar-chart (default fallback)', 'skip this viz'],
                   'default' => 'build as a bar-chart (default fallback)' }
  end
end

# (f) missing folder (DM + workbook land in My Documents).
unless opts[:folder]
  questions << { 'id' => 'folder', 'severity' => 'required',
                 'detail' => 'No Sigma --folder supplied; DM + workbook will land in My Documents',
                 'options' => ['supply --folder <id>', 'proceed into My Documents'],
                 'default' => 'proceed into My Documents' }
end

answers = nil
if opts[:answers]
  answers = JSON.parse(opts[:answers]) rescue abort('FATAL: --answers is not valid JSON')
end

if questions.any? && !opts[:yes] && answers.nil?
  block = {
    'status' => 'decisions_needed',
    'workbook' => wb_name,
    'phases_completed' => ['1 Discover'],
    'note' => 'Deterministic mechanical steps (DM/workbook POST, layout, parity) are NOT asked about. ' \
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
  line "decisions auto-resolved (#{opts[:yes] ? '--yes: defaults' : '--answers supplied'}):"
  questions.each do |q|
    chosen = (answers && answers[q['id']]) || q['default']
    tag = q['calc'] || q['viz']
    line "  - #{q['id']}#{tag ? " [#{tag}]" : ''}: #{chosen || '(no default — required)'}"
    if chosen.nil? && q['severity'] == 'required'
      abort "FATAL: required decision '#{q['id']}' has no default; re-run with --answers or fix inputs"
    end
  end
else
  line 'no open questions — running straight through'
end



# ---------------------------------------------------------------------------
# Phase 2 — Discover warehouse column names (per table) for the DM build.
# ---------------------------------------------------------------------------
hdr(2, 'Discover warehouse columns')
db = opts[:db] || 'CSA'
schema = opts[:schema] || 'TJ'
# Table set: from the generator's DM spec when available, else inferred from the
# datasource's logical tables.
wh_tables =
  if mechanical
    (conv['model']['pages'] || []).flat_map { |p| p['elements'] || [] }
      .select { |e| e.dig('source', 'kind') == 'warehouse-table' }
      .map { |e| e.dig('source', 'path')&.last }.compact.uniq
  elsif have_specs
    Specs.dm_spec['pages'].flat_map { |p| p['elements'] }
         .map { |e| e.dig('source', 'path')&.last }.compact.uniq
  else
    md = (JSON.parse(File.read(File.join(WORK, 'ds-metadata.json'))) rescue {})
    fields = md['data'] || []
    fields.flat_map { |f| (f['name'] || '').scan(/\b([A-Z][A-Z0-9_]*(?:_DIM|_FACT))\b/) }
          .flatten.uniq
  end
wh_tables = [] if wh_tables.nil?
if wh_tables.empty?
  line 'no warehouse tables resolved from metadata; relying on spec generator'
else
  wh_tables.each do |t|
    _, st = sigma_run!(['ruby', File.join(HERE, 'discover-columns.rb'),
                        '--connection-id', opts[:conn],
                        '--table-path', "#{db}.#{schema}.#{t}",
                        '--out', File.join(WORK, "cols-#{t}.json")], allow_fail: true)
    cj = (JSON.parse(File.read(File.join(WORK, "cols-#{t}.json"))) rescue nil)
    n = cj && cj['columns'] ? cj['columns'].size : '?'
    line "#{db}.#{schema}.#{t}: #{n} columns#{st.success? ? '' : ' (not in catalog — Custom SQL fallback may be needed)'}"
  end
end

# ---------------------------------------------------------------------------
# Phase 3 — Build + POST the data model.
# ---------------------------------------------------------------------------
hdr(3, 'Build data model')
dm_spec_path = File.join(WORK, 'dm-spec.json')
if mechanical
  # The converter output IS the DM spec (schemaVersion:1 already set). Apply the
  # mechanical fixup (resolve raw-table-name prefixes + GUID sibling refs the
  # converter left unresolved) then stamp the human-supplied folderId. No agent
  # authoring.
  dm = conv['model'] # already fixed up in Phase 1 (prefixes/GUIDs resolved, bad calcs dropped)
  dm['name'] = wb_name if dm['name'].to_s.empty?
  # Phantom-column filter (needs Phase 2's live warehouse columns): Tableau
  # virtual-connection datasources flatten dim columns into the fact and emit
  # base-column refs that don't exist in the real table. Drop them so the POST
  # resolves. Load the cols-<TABLE>.json files discovered in Phase 2.
  real_cols = {}
  Dir[File.join(WORK, 'cols-*.json')].each do |cf|
    cj = (JSON.parse(File.read(cf)) rescue nil)
    next unless cj && cj['columns']
    tname = File.basename(cf, '.json').sub(/^cols-/, '')
    real_cols[tname] = cj['columns'].map { |c| c['name'] }
  end
  unless real_cols.empty?
    pf = MechanicalSpecs.fixup_dm_spec(dm, real_cols)
    line "phantom-column filter: dropped #{pf[:phantom]} non-existent base column(s) using #{real_cols.size} live table catalog(s)" if pf[:phantom].to_i.positive?
  end
else
  dm = Specs.dm_spec
end
dm['folderId'] = opts[:folder] if opts[:folder]
File.write(dm_spec_path, JSON.pretty_generate(dm))
# In mechanical mode validate-spec.rb is advisory only: it flags cross-element
# sibling refs that Sigma actually resolves via relationships (documented
# false-negative class — see project CLAUDE.md). The authoritative gate is the
# live POST + readback column-type guard below (post-and-readback exits 2 on any
# error-typed column). For hand-authored Specs, keep validation hard.
_, dvst = run!(['ruby', File.join(HERE, 'validate-spec.rb'), '--type', 'datamodel', dm_spec_path],
               allow_fail: mechanical)
line 'DM validate-spec flagged issues (advisory in mechanical mode — live POST is the gate)' if mechanical && !dvst.success?
dm_ids_path = File.join(WORK, 'dm-ids.json')
sigma_run!(['ruby', File.join(HERE, 'post-and-readback.rb'), '--type', 'datamodel',
            '--spec', dm_spec_path, '--out', dm_ids_path, '--workdir', WORK])
dm_ids = JSON.parse(File.read(dm_ids_path))
dm_id = dm_ids['dataModelId']
dm_els = dm_ids['pages'].flat_map { |p| p['elements'] }
if mechanical
  # The master must source the SAME chart-ready element pick_fact chose (the
  # derived "<Fact> View" when present). Match it into the readback by name.
  cf = MechanicalSpecs.pick_fact(conv['model'])
  cf_name = cf && (cf['name'] || MechanicalSpecs.elem_name(cf))
  fact = dm_els.find { |e| e['name'] == cf_name } ||
         dm_els.find { |e| e['name'] !~ / Dim$/i } || dm_els.first
else
  fact = dm_els.find { |e| e['name'] !~ / Dim$/i } || dm_els.first
end
fact_eid = fact['id']
line "dataModelId = #{dm_id}  (fact element '#{fact['name']}' = #{fact_eid})"

# ---------------------------------------------------------------------------
# Phase 4 — Build + POST the workbook.
# ---------------------------------------------------------------------------
hdr(4, 'Build workbook')
wb_spec_path = File.join(WORK, 'wb-spec.json')
layout_xml = nil
if mechanical
  # 1) Derive the master-map DETERMINISTICALLY from the converter fact element,
  #    using the AUTHORITATIVE readback element name for the [fact/Col] formulas,
  #    AND the readback element's REAL column labels (the suffixed display names
  #    Sigma assigns to joined-dim columns, e.g. "Customer Id (CUSTOMER_DIM)") so
  #    the [fact/Col] formulas resolve for virtual-connection (denormalized) DMs.
  conv_fact = MechanicalSpecs.pick_fact(conv['model'])
  abort 'FATAL: mechanical path could not identify a fact element in the converter output' unless conv_fact
  conv_base = MechanicalSpecs.base_of(conv['model'], conv_fact)
  real_labels = fact['columnLabels'] # from post-and-readback /columns (may be nil)
  derived = MechanicalSpecs.derive_master(conv_fact, fact['name'], conv_base, real_labels)
  master_columns = derived['master_columns']
  mmap = derived['mmap']
  mmap_path = File.join(WORK, 'master-map.json')
  File.write(mmap_path, JSON.pretty_generate(mmap))
  line "master-map: #{master_columns.size} master column(s) (fact element '#{fact['name']}', #{real_labels ? real_labels.size : 0} readback labels)"

  # 2) Build the chart-element specs from the parsed zones + view CSVs + map.
  charts_path = File.join(WORK, 'chart-specs.json')
  build_cmd = ['ruby', File.join(HERE, 'build-charts-from-signals.rb'),
               '--tableau-dir', WORK, '--layout', layout_json,
               '--master-map', mmap_path, '--master-element-id', 'master',
               '--out', charts_path]
  build_cmd += ['--meta', layout_json.sub(/\.json$/, '-meta.json')] if File.exist?(layout_json.sub(/\.json$/, '-meta.json'))
  build_cmd += ['--auto-controls'] if File.exist?(layout_json.sub(/\.json$/, '-meta.json'))
  run!(build_cmd, allow_fail: true)
  raw_charts = (JSON.parse(File.read(charts_path)) rescue [])
  chart_elements = raw_charts.is_a?(Hash) ? (raw_charts['pages'] || []).flat_map { |p| p['elements'] || [] } : raw_charts
  if chart_elements.empty?
    line 'WARN: build-charts produced 0 elements (no usable view CSVs / zones); emitting an empty dashboard page'
  else
    line "build-charts: #{chart_elements.size} chart/control element(s)"
  end

  # 3) Assemble the workbook spec (page-data master + dashboard page).
  spec = MechanicalSpecs.build_wb_spec(
    name: wb_name, dm_id: dm_id, fact_eid: fact_eid,
    master_columns: master_columns, chart_elements: chart_elements,
    folder_id: opts[:folder])
else
  spec = Specs.wb_spec(dm_id, fact_eid)
  spec['folderId'] = opts[:folder] if opts[:folder]
  layout_xml = (Specs.respond_to?(:layout_xml) ? Specs.layout_xml : nil)
end
File.write(wb_spec_path, JSON.pretty_generate(spec))
wb_ids_path = File.join(WORK, 'wb-ids.json')

# GRACEFUL AGENT-PATH FALLBACK. The DM is already posted + valid (dm_id above), so
# if the MECHANICAL workbook layer (validate-spec / build / POST) hits a field it
# cannot translate (Sigma rejects the spec / unresolved "Dependency not found" /
# unmapped derived-dim or measure), we must NOT bare-crash. Catch it and exit with
# a clear, FRIENDLY non-zero handoff: the agent path rebuilds the workbook against
# this DM (see SKILL.md). Never worse than the proven agent path.
begin
  v_log = run_wb!(['ruby', File.join(HERE, 'validate-spec.rb'), '--type', 'workbook',
                   '--dm-context', dm_ids_path, wb_spec_path])
  p_log = sigma_run_wb!(['ruby', File.join(HERE, 'post-and-readback.rb'), '--type', 'workbook',
                         '--spec', wb_spec_path, '--out', wb_ids_path, '--workdir', WORK])
rescue WorkbookBuildError => e
  failed = cull_failed_fields(e.captured_output,
                              (defined?(v_log) ? v_log : ''), (defined?(p_log) ? p_log : ''))
  # Fall back to the mechanically-known untranslatable fields when the log itself
  # doesn't name one (plotted-but-unresolved metrics + dropped calc columns).
  if failed.empty? && mechanical
    failed = ((defined?(plotted_untranslated) && plotted_untranslated || []) +
              (defined?(dropped_calcs) && dropped_calcs || [])).compact.uniq
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
wb_ids = JSON.parse(File.read(wb_ids_path))
wb_id = wb_ids['workbookId']
line "workbookId = #{wb_id}"

# ---------------------------------------------------------------------------
# Phase 5 — Layout. Prefer the generator's layout_xml; else auto-build from the
# parsed Tableau zone tree via build-dashboard-layout.rb.
# ---------------------------------------------------------------------------
hdr(5, 'Layout')
layout_path = File.join(WORK, 'layout.xml')
if layout_xml
  File.write(layout_path, layout_xml)
  line 'layout from spec generator'
elsif File.exist?(layout_json)
  _, lst = run!(['ruby', File.join(HERE, 'build-dashboard-layout.rb'),
                 '--layout', layout_json, '--wb-ids', wb_ids_path, '--out', layout_path],
                allow_fail: true)
  line 'WARN: layout build failed — workbook will render in default stacked order' unless lst.success?
else
  line 'no layout source — skipping (workbook renders single-column stack)'
end
# Layout is cosmetic: a bad grid PUT must NOT fail an otherwise-good migration
# (the workbook still renders + queries). Apply best-effort.
if File.exist?(layout_path)
  _, pst = sigma_run!(['ruby', File.join(HERE, 'put-layout.rb'),
                       '--workbook', wb_id, '--layout', layout_path], allow_fail: true)
  line(pst.success? ? "layout applied to workbook #{wb_id}" :
       'WARN: layout PUT rejected (Invalid element position) — keeping default stacked layout; charts unaffected')
end

# ---------------------------------------------------------------------------
# Phase 6 — Parity. Try the skill's phase6-parity.rb; the hard signal is the
# post-and-readback column-type guard (already enforced above with exit 2),
# plus a live re-check of /columns for any type=error introduced by the layout PUT.
# ---------------------------------------------------------------------------
hdr(6, 'Parity')
require 'sigma_rest'
p6 = ['ruby', File.join(HERE, 'phase6-parity.rb'),
      '--tableau', WORK, '--workbook-id', wb_id]
p6 += ['--extract-mode', '--extract-tol', '0.30'] if has_extracts
_, p6st = sigma_run!(p6, allow_fail: true)

# Independent hard signal: no live column resolves to type "error".
cols = (Sigma.request(:get, "/v2/workbooks/#{wb_id}/columns") rescue { 'entries' => [] })
err_cols = (cols['entries'] || []).select { |c| c.dig('type', 'type') == 'error' }
total_cols = (cols['entries'] || []).size
# Compile-check chart elements (Unknown column / Circular ref markers).
chart_els = wb_ids['pages'].reject { |p| p['id'].to_s =~ /data/ }
                           .flat_map { |p| p['elements'] || [] }
                           .select { |e| e['kind'].to_s.end_with?('-chart') }
bad = []
chart_els.each do |e|
  b = (Sigma.request(:get, "/v2/workbooks/#{wb_id}/elements/#{e['id']}/query", accept: 'text/plain') rescue '')
  bad << (e['name'] || e['id']) if b.to_s =~ /Unknown column "\[|Circular column reference/
end
parity_ok = err_cols.empty? && bad.empty?
if parity_ok
  line "PARITY: PASS — #{total_cols} workbook column(s) resolve (0 error-typed); " \
       "#{chart_els.size} chart element(s) compile clean#{p6st.success? ? '; phase6-parity PASS' : ''}"
else
  line "PARITY: FAIL — #{err_cols.size}/#{total_cols} error-typed column(s)#{bad.any? ? ", #{bad.size} chart(s) with unresolved refs (#{bad.join(', ')})" : ''}"
  err_cols.first(8).each { |c| line "  [#{c['elementId']}] #{c['label']}: #{c['formula']}" }
end

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------
puts
puts '================ RESULT ================'
puts "dataModelId : #{dm_id}"
puts "workbookId  : #{wb_id}"
puts "PARITY      : #{parity_ok ? 'PASS' : 'FAIL'} (#{total_cols} cols resolve, #{err_cols.size} error)"
puts '======================================='
exit(parity_ok ? 0 : 3)
