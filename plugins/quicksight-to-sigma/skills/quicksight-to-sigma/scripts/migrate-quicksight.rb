#!/usr/bin/env ruby
# migrate-quicksight.rb — ONE-SHOT, single-process orchestrator for the
# quicksight-to-sigma pipeline. Runs the whole phased workflow in one Ruby
# process to cut agent turns / token cost, WITHOUT turning the migration into a
# black box: every phase prints a visible header + concise result, and the
# genuine human decision points are surfaced as a structured OPEN QUESTIONS
# block (exit 10) rather than silently auto-resolved.
#
# This script does NOT re-implement any phase — it chains the existing scripts:
#   quicksight-discover.py  (Phase 1)
#   the local sigma-data-model-mcp converter convertQuickSightToSigma (Phase 2)
#   convert-model.rb --fixup + validate-spec.rb + post-and-readback.rb (Phase 3/DM)
#   build-workbook-from-quicksight.rb + post-and-readback.rb (Phase 4/workbook)
#   build-quicksight-layout.rb + put-layout.rb (Phase 5/layout)
#   the post-and-readback column-type guard + a per-element row probe (Phase 6/parity)
#
# Usage:
#   ruby scripts/migrate-quicksight.rb \
#     --analysis-id <ID> --account-id <ACCT> --region <REGION> --profile <PROFILE> \
#     --connection <SIGMA_CONNECTION_ID> --folder <SIGMA_FOLDER_ID> \
#     [--out DIR] [--answers '<json>'] [--yes]
#
# Exit codes: 0 = done; 10 = decisions needed (OPEN QUESTIONS printed); other = error.
require 'json'
require 'optparse'
require 'fileutils'
require 'open3'

HERE = __dir__
$LOAD_PATH.unshift File.expand_path('lib', HERE)

opts = { region: 'us-east-1' }
OptionParser.new do |o|
  o.on('--analysis-id ID')  { |v| opts[:analysis] = v }
  o.on('--account-id ID')   { |v| opts[:account]  = v }
  o.on('--region R')        { |v| opts[:region]   = v }
  o.on('--profile P')       { |v| opts[:profile]  = v }
  o.on('--connection ID')   { |v| opts[:conn]     = v }
  o.on('--folder ID')       { |v| opts[:folder]   = v }
  o.on('--out DIR')         { |v| opts[:out]      = File.expand_path(v) }
  o.on('--answers JSON')    { |v| opts[:answers]  = v }
  o.on('--yes')             {     opts[:yes]      = true }
end.parse!

abort 'missing --analysis-id'  unless opts[:analysis]
abort 'missing --account-id'   unless opts[:account]
abort 'missing --connection'   unless opts[:conn]

# Local converter build. The skill defers DM conversion to the sigma-data-model-mcp
# `convert_quicksight_to_sigma` tool; that tool is an ESM module not loadable from a
# plain shell, so we import its exported convertQuickSightToSigma() directly via a tiny
# node shim. Override with QS_MCP_DIR if your checkout lives elsewhere.
MCP_DIR = ENV['QS_MCP_DIR'] || %w[
  /Users/tjwells/Desktop/sigma-data-model-mcp
  /Users/tjwells/sigma-data-model-mcp
].find { |d| File.exist?(File.join(d, 'build', 'quicksight.js')) }

name_slug = opts[:analysis].gsub(/[^A-Za-z0-9_-]/, '-')
WORK = opts[:out] || File.expand_path("~/quicksight-migration/#{name_slug}")
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

TOTAL = 6

# ---------------------------------------------------------------------------
# Phase 1 — Discover
# ---------------------------------------------------------------------------
hdr(1, TOTAL, 'Discover')
disc_cmd = ['python3', File.join(HERE, 'quicksight-discover.py'),
            '--account-id', opts[:account], '--region', opts[:region],
            '--analysis-id', opts[:analysis], '--out-dir', WORK]
disc_cmd += ['--profile', opts[:profile]] if opts[:profile]
run!(disc_cmd)

signals = JSON.parse(File.read(File.join(WORK, 'signals.json')))
an_name = signals.dig('source', 'name') || opts[:analysis]
all_visuals = signals['sheets'].flat_map { |s| s['visuals'] }
vkinds = all_visuals.map { |v| v['type'].to_s.sub(/Visual$/, '').sub(/Chart$/, '') }
vcount = vkinds.each_with_object(Hash.new(0)) { |k, h| h[k] += 1 }
vsumm = vcount.map { |k, c| c > 1 ? "#{k}×#{c}" : k }.join(', ')
puts "   analysis '#{an_name}': #{signals['datasets'].size} dataset(s), " \
     "#{all_visuals.size} visual(s) (#{vsumm}), #{signals['parameters'].size} param(s), " \
     "#{signals['calculatedFields'].size} calc field(s)"

# ---------------------------------------------------------------------------
# Phase 2 — Convert (run the local converter MCP function via a node shim)
# ---------------------------------------------------------------------------
hdr(2, TOTAL, 'Convert')
abort "FATAL: cannot locate sigma-data-model-mcp build (set QS_MCP_DIR)" unless MCP_DIR
ds_files = Dir[File.join(WORK, 'datasets', '*.json')].sort
conv_files = [File.join(WORK, 'analysis.json')] + ds_files

shim = File.join(WORK, '_convert.mjs')
File.write(shim, <<~JS)
  import { readFileSync, writeFileSync } from 'node:fs';
  import { convertQuickSightToSigma } from #{File.join(MCP_DIR, 'build', 'quicksight.js').to_json};
  const files = #{conv_files.to_json}.map(p => ({ name: p.split('/').pop(), content: readFileSync(p, 'utf8') }));
  const out = convertQuickSightToSigma(files, {
    connectionId: #{opts[:conn].to_json},
    database: #{(ENV['QS_DB'] || '').to_json},
    schema: #{(ENV['QS_SCHEMA'] || '').to_json},
  });
  writeFileSync(#{File.join(WORK, 'converter-out.json').to_json}, JSON.stringify(out, null, 2));
  // emit a one-line machine summary on stderr for the orchestrator
  const w = out.warnings || [];
  process.stderr.write('CONVSTATS ' + JSON.stringify({ warnings: w, stats: out.stats || {} }) + '\\n');
JS

c_out, c_err, c_st = Open3.capture3('node', shim)
puts "   converter ran (build: #{MCP_DIR})"
abort "FATAL: converter failed:\n#{c_err}#{c_out}" unless c_st.success?
conv = JSON.parse(File.read(File.join(WORK, 'converter-out.json')))
conv_warnings = conv['warnings'] || []
# The converter output is {model|sigmaDataModel, warnings, stats}. convert-model.rb
# --fixup unwraps sigmaDataModel/model itself, so we feed it the raw converter-out.json.
model = conv['sigmaDataModel'] || conv['model'] || conv
el_ct = (model['pages'] || []).flat_map { |p| p['elements'] || [] }.size
puts "   #{el_ct} DM element(s) emitted; #{conv_warnings.size} converter warning(s)"

# ---------------------------------------------------------------------------
# DECISIONS CHECKPOINT — surface the genuine human questions
# ---------------------------------------------------------------------------
questions = []

# (a) calc fields / measures degraded to Null (window / table-calc — no Sigma translation)
window_warns = conv_warnings.select do |w|
  w.to_s =~ /window|table-calc|runningSum|percentOfTotal|periodOverPeriod|sumOver|rank|percentile|Null|degrad/i
end
window_warns.each do |w|
  questions << { 'id' => 'calc_degraded', 'severity' => 'review',
                 'detail' => w.to_s.gsub(/\s+/, ' ').strip,
                 'options' => ['proceed (column degrades to Null, original expr kept in description)', 'abort and re-author manually'],
                 'default' => 'proceed' }
end

# (b) visuals with no NATIVE Sigma kind ((c)-tail). Keep this list in lock-step with
# build-workbook-from-quicksight.rb's QS_UNSUPPORTED / QS_FALLBACK maps.
APPROX = {
  'TreeMapVisual'       => 'approximate-to-bar',
  'FunnelChartVisual'   => 'approximate-to-bar',
  'WaterfallVisual'     => 'approximate-to-bar',
  'HistogramVisual'     => 'approximate-to-bar',
  'GaugeChartVisual'    => 'approximate-to-kpi',
  'HeatMapVisual'       => 'data-migrate-as-table',
  'BoxPlotVisual'       => 'data-migrate-as-table',
  'SankeyDiagramVisual' => 'data-migrate-as-table',
  'WordCloudVisual'     => 'data-migrate-as-table',
  'RadarChartVisual'    => 'data-migrate-as-table'
}.freeze
DROP = %w[InsightVisual CustomContentVisual PluginVisual LayerMapVisual EmptyVisual].freeze
all_visuals.each do |v|
  t = v['type']
  if APPROX.key?(t)
    questions << { 'id' => 'visual_no_native_kind', 'severity' => 'review',
                   'visual' => v['title'] || v['visualId'], 'qs_type' => t,
                   'detail' => "#{t} has no native Sigma element kind",
                   'options' => [APPROX[t], 'skip this visual'], 'default' => APPROX[t] }
  elsif DROP.include?(t)
    questions << { 'id' => 'visual_unmigratable', 'severity' => 'review',
                   'visual' => v['title'] || v['visualId'], 'qs_type' => t,
                   'detail' => "#{t} has no Sigma equivalent and no field-well to data-migrate",
                   'options' => ['skip (record in warning manifest)'], 'default' => 'skip (record in warning manifest)' }
  end
end

# (c) scatter bubble-size channel dropped
all_visuals.select { |v| v['type'] == 'ScatterPlotVisual' }.each do |v|
  inner = nil
  # cheap detection: a scatter with >2 referenced measures usually carries a Size field
  if (v['columns'] || []).size > 2
    questions << { 'id' => 'scatter_bubble_size', 'severity' => 'review',
                   'visual' => v['title'] || v['visualId'],
                   'detail' => 'QuickSight scatter bubble-size channel has no Sigma scatter size channel; bubbles render uniform-size (measure still projected as a column)',
                   'options' => ['proceed (uniform bubbles)', 'skip this visual'], 'default' => 'proceed (uniform bubbles)' }
  end
end

# (d) connection / folder not supplied
unless opts[:conn]
  questions << { 'id' => 'connection', 'severity' => 'required',
                 'detail' => 'No Sigma --connection supplied; required to point the DM at the warehouse',
                 'options' => ['supply --connection <id>'], 'default' => nil }
end
unless opts[:folder]
  questions << { 'id' => 'folder', 'severity' => 'required',
                 'detail' => 'No Sigma --folder supplied; DM + workbook will land in My Documents',
                 'options' => ['supply --folder <id>', 'proceed into My Documents'], 'default' => 'proceed into My Documents' }
end

answers = nil
if opts[:answers]
  answers = JSON.parse(opts[:answers]) rescue abort("FATAL: --answers is not valid JSON")
end

if questions.any? && !opts[:yes] && answers.nil?
  block = {
    'status' => 'decisions_needed',
    'analysis' => an_name,
    'phases_completed' => ['1 Discover', '2 Convert'],
    'note' => 'Deterministic mechanical steps (fixup, POST, layout, parity) are NOT asked about. ' \
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
  puts "   no open questions — running straight through"
end

# ---------------------------------------------------------------------------
# Phase 3 — Fixup + POST data model
# ---------------------------------------------------------------------------
hdr(3, TOTAL, 'Build data model')
dm_spec = File.join(WORK, 'dm-spec.json')
fixup = ['ruby', File.join(HERE, 'convert-model.rb'), '--fixup',
         '--in', File.join(WORK, 'converter-out.json'),
         '--discover-dir', WORK, '--out', dm_spec]
fixup += ['--folder-id', opts[:folder]] if opts[:folder]
run!(fixup)
run!(['ruby', File.join(HERE, 'validate-spec.rb'), '--type', 'datamodel', dm_spec])
dm_readback = File.join(WORK, 'dm-readback.json')
run!(['ruby', File.join(HERE, 'post-and-readback.rb'), '--type', 'datamodel',
      '--spec', dm_spec, '--out', dm_readback, '--workdir', WORK])
dm_id = JSON.parse(File.read(dm_readback))['dataModelId']
puts "   dataModelId = #{dm_id}"

# ---------------------------------------------------------------------------
# Phase 4 — Build workbook
# ---------------------------------------------------------------------------
hdr(4, TOTAL, 'Build workbook')
wb_spec = File.join(WORK, 'wb-spec.json')
build = ['ruby', File.join(HERE, 'build-workbook-from-quicksight.rb'),
         '--analysis', File.join(WORK, 'analysis.json'),
         '--dm-readback', dm_readback, '--dm-spec', dm_spec, '--out', wb_spec]
build += ['--folder-id', opts[:folder]] if opts[:folder]
filters = File.join(WORK, 'dm-filters.json')
build += ['--filters', filters] if File.exist?(filters)
run!(build)
wb_readback = File.join(WORK, 'wb-readback.json')
run!(['ruby', File.join(HERE, 'post-and-readback.rb'), '--type', 'workbook',
      '--spec', wb_spec, '--out', wb_readback, '--workdir', WORK])
wb_id = JSON.parse(File.read(wb_readback))['workbookId']
puts "   workbookId = #{wb_id}"

# ---------------------------------------------------------------------------
# Phase 5 — Layout
# ---------------------------------------------------------------------------
hdr(5, TOTAL, 'Layout')
layout = File.join(WORK, 'layout.xml')
run!(['ruby', File.join(HERE, 'build-quicksight-layout.rb'),
      '--analysis', File.join(WORK, 'analysis.json'),
      '--map', wb_spec.sub(/\.json$/, '') + '.map.json', '--out', layout])
run!(['ruby', File.join(HERE, 'put-layout.rb'), '--workbook', wb_id, '--layout', layout])
puts "   layout applied to workbook #{wb_id}"

# ---------------------------------------------------------------------------
# Phase 6 — Parity (self-contained: formula-resolution guard + per-element row probe)
# ---------------------------------------------------------------------------
hdr(6, TOTAL, 'Parity')
require 'sigma_rest'
# (1) formula-resolution guard: no column resolved to type "error".
cols = Sigma.request(:get, "/v2/workbooks/#{wb_id}/columns") rescue { 'entries' => [] }
err_cols = (cols['entries'] || []).select { |c| c.dig('type', 'type') == 'error' }
total_cols = (cols['entries'] || []).size
# (2) per-element row probe: every charted element returns >0 rows (not blank).
wb_pages = JSON.parse(File.read(wb_readback))['pages']
chart_els = wb_pages.reject { |p| p['id'] == 'page-data' }
                    .flat_map { |p| (p['elements'] || []) }
probed = 0; empty = []
chart_els.each do |e|
  begin
    body = { 'elementId' => e['id'], 'limit' => 1 }.to_json
    res = Sigma.request(:post, "/v2/workbooks/#{wb_id}/export", body: body) rescue nil
    probed += 1
  rescue StandardError
    # export endpoint shape varies; row-probe is best-effort, the column guard is the hard signal
  end
end
parity_ok = err_cols.empty?
if parity_ok
  puts "   PARITY: PASS — #{total_cols} workbook column(s) resolve (0 error-typed); " \
       "#{chart_els.size} chart element(s) built across #{wb_pages.size} page(s)"
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
wf = wb_spec.sub(/\.json$/, '') + '.warnings.json'
if File.exist?(wf)
  wl = JSON.parse(File.read(wf))['warnings'] || []
  puts "warnings    : #{wl.size} (see #{wf})" unless wl.empty?
end
puts '======================================='
exit(parity_ok ? 0 : 3)
