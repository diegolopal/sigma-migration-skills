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
# DECISIONS CHECKPOINT — surface the genuine human questions ONLY. Mechanical
# fixup / POST / layout / parity are never asked about.
# ---------------------------------------------------------------------------
questions = []

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
# Locate a spec generator (the agent-owned DM/workbook step).
# ---------------------------------------------------------------------------
specs_path = opts[:specs] ||
             [File.join(WORK, 'specs.rb'),
              File.expand_path('~/orders-migration/specs.rb')].find { |p| File.exist?(p) }
have_specs = false
if specs_path && File.exist?(specs_path)
  begin
    require specs_path.sub(/\.rb$/, '')
    have_specs = defined?(Specs) && Specs.respond_to?(:dm_spec) && Specs.respond_to?(:wb_spec)
  rescue StandardError => e
    line "(spec generator at #{specs_path} failed to load: #{e.message})"
  end
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
  if have_specs
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
unless have_specs
  abort <<~MSG
    FATAL: no spec generator found and the general data-driven DM builder is not
    wired for this datasource shape. Drop a Ruby file defining a `Specs` module
    with `dm_spec` + `wb_spec(dm_id, fact_eid)` (+ optional `layout_xml`) next to
    the working dir (#{WORK}/specs.rb) or pass --specs <path>. The validated
    reference generator lives at ~/orders-migration/specs.rb.
  MSG
end
dm = Specs.dm_spec
dm['folderId'] = opts[:folder] if opts[:folder]
File.write(dm_spec_path, JSON.pretty_generate(dm))
run!(['ruby', File.join(HERE, 'validate-spec.rb'), '--type', 'datamodel', dm_spec_path])
dm_ids_path = File.join(WORK, 'dm-ids.json')
sigma_run!(['ruby', File.join(HERE, 'post-and-readback.rb'), '--type', 'datamodel',
            '--spec', dm_spec_path, '--out', dm_ids_path, '--workdir', WORK])
dm_ids = JSON.parse(File.read(dm_ids_path))
dm_id = dm_ids['dataModelId']
dm_els = dm_ids['pages'].flat_map { |p| p['elements'] }
fact = dm_els.find { |e| e['name'] !~ / Dim$/i } || dm_els.first
fact_eid = fact['id']
line "dataModelId = #{dm_id}  (fact element '#{fact['name']}' = #{fact_eid})"

# ---------------------------------------------------------------------------
# Phase 4 — Build + POST the workbook.
# ---------------------------------------------------------------------------
hdr(4, 'Build workbook')
wb_spec_path = File.join(WORK, 'wb-spec.json')
spec = Specs.wb_spec(dm_id, fact_eid)
spec['folderId'] = opts[:folder] if opts[:folder]
layout_xml = (Specs.respond_to?(:layout_xml) ? Specs.layout_xml : nil)
File.write(wb_spec_path, JSON.pretty_generate(spec))
run!(['ruby', File.join(HERE, 'validate-spec.rb'), '--type', 'workbook',
      '--dm-context', dm_ids_path, wb_spec_path])
wb_ids_path = File.join(WORK, 'wb-ids.json')
sigma_run!(['ruby', File.join(HERE, 'post-and-readback.rb'), '--type', 'workbook',
            '--spec', wb_spec_path, '--out', wb_ids_path, '--workdir', WORK])
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
  run!(['ruby', File.join(HERE, 'build-dashboard-layout.rb'),
        '--layout', layout_json, '--wb-ids', wb_ids_path, '--out', layout_path])
else
  line 'no layout source — skipping (workbook renders single-column stack)'
end
if File.exist?(layout_path)
  sigma_run!(['ruby', File.join(HERE, 'put-layout.rb'),
              '--workbook', wb_id, '--layout', layout_path])
  line "layout applied to workbook #{wb_id}"
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
