#!/usr/bin/env ruby
# frozen_string_literal: true
#
# enhance-apply.rb — Phase E (opt-in) shared engine, part 2 of 2: APPLY.
#
# CLONE-FIRST, ACCEPT-ONLY, PARITY-GATED application of enhancements.json
# candidates produced by enhance-scan.rb:
#   1. CLONE: GET the parity-verified workbook's spec and POST it as
#      "<name> — Enhanced". The 1:1 parity artifact is NEVER written.
#   2. ACCEPT: only candidates named in --accept (id list) or matching
#      --accept all-low-risk are applied. Everything else is recorded as
#      skipped. Candidates whose patch carries unmet 'needs' (e.g. map
#      centroids) are skipped with the reason, never half-applied.
#   3. APPLY ONE AT A TIME with a parity-unchanged gate: after each item,
#      spot-query 2-3 UNTOUCHED elements on the clone AND the same elements
#      on the original simultaneously; any divergence (clone != original at
#      the same instant — live-drift-proof, the trial's lesson) auto-REVERTS
#      that item and flags it. enhance-report.json records
#      applied/skipped/reverted with evidence.
#
# This file is the SHARED Phase-E engine, vendored byte-identical into every
# covered plugin (md5 discipline — same as escalate-gap.py).
#
# Usage:
#   ruby scripts/enhance-apply.rb --workbook-id <parityWorkbookId> \
#     --enhancements <enhancements.json> \
#     --accept all-low-risk | --accept id1,id2,... \
#     [--name '<clone name>'] [--out enhance-report.json] [--probes N]
#
# Exit codes: 0 = done (clone created; accepted items applied or cleanly
# reverted; parity-unchanged gate green); 2 = nothing accepted; 3 = the
# parity-unchanged gate could not be restored (clone left for inspection,
# report says so); other = error.

require 'json'
require 'yaml'
require 'time'
require 'date'
require 'optparse'

HERE = __dir__
$LOAD_PATH.unshift File.expand_path('lib', HERE)
require 'sigma_rest'

opts = { probes: 3 }
OptionParser.new do |o|
  o.on('--workbook-id ID')   { |v| opts[:wb] = v }
  o.on('--enhancements P')   { |v| opts[:enh] = File.expand_path(v) }
  o.on('--accept LIST')      { |v| opts[:accept] = v }
  o.on('--name NAME')        { |v| opts[:name] = v }
  o.on('--out PATH')         { |v| opts[:out] = File.expand_path(v) }
  o.on('--probes N', Integer) { |v| opts[:probes] = v }
end.parse!
abort 'missing --workbook-id' unless opts[:wb]
abort 'missing --enhancements' unless opts[:enh] && File.exist?(opts[:enh])
abort 'missing --accept (id list or all-low-risk) — nothing applies without explicit acceptance' unless opts[:accept]

ORIG_WB = opts[:wb]
enh = JSON.parse(File.read(opts[:enh]))
OUT = opts[:out] || File.join(File.dirname(opts[:enh]), 'enhance-report.json')

candidates = enh['candidates'] || []
accepted_ids =
  if opts[:accept].strip.casecmp?('all-low-risk')
    candidates.select { |c| c['risk'].to_s == 'low' }.map { |c| c['id'] }
  else
    opts[:accept].split(',').map(&:strip).reject(&:empty?)
  end
unknown = accepted_ids - candidates.map { |c| c['id'] }
abort "FATAL: --accept names unknown candidate id(s): #{unknown.join(', ')}" if unknown.any?

accepted = candidates.select { |c| accepted_ids.include?(c['id']) }
skipped  = candidates.reject { |c| accepted_ids.include?(c['id']) }
                     .map { |c| { 'id' => c['id'], 'risk' => c['risk'], 'reason' => 'not accepted' } }
if accepted.empty?
  puts 'enhance-apply: no candidate accepted — nothing to do (no clone created).'
  File.write(OUT, JSON.pretty_generate(
    'workbook_id' => ORIG_WB, 'status' => 'nothing-accepted',
    'applied' => [], 'skipped' => skipped, 'reverted' => [],
    'descoped_notes' => enh['descoped_notes'] || []))
  exit 2
end

READONLY_KEYS = %w[workbookId url ownerId createdBy updatedBy createdAt updatedAt
                   documentVersion latestDocumentVersion].freeze

def clean(spec)
  s = JSON.parse(JSON.generate(spec))
  READONLY_KEYS.each { |k| s.delete(k) }
  s
end

# Sigma's workbook POST/PUT responses can come back as YAML — parse leniently.
def lenient(body)
  return body if body.is_a?(Hash)
  YAML.safe_load(body.to_s, permitted_classes: [Date, Time]) rescue nil
end

def export_rows(wb, element_id, timeout: 75)
  res = Sigma.request(:post, "/v2/workbooks/#{wb}/export",
                      body: { 'elementId' => element_id, 'format' => { 'type' => 'json' } }.to_json)
  qid = res.is_a?(Hash) ? res['queryId'] : nil
  return nil unless qid
  deadline = Time.now + timeout
  while Time.now < deadline
    body = (Sigma.request(:get, "/v2/query/#{qid}/download", binary: true) rescue nil)
    if body && !body.strip.empty?
      parsed = (JSON.parse(body) rescue nil)
      return parsed if parsed.is_a?(Array)
      return parsed['rows'] if parsed.is_a?(Hash) && parsed['rows'].is_a?(Array)
      lines = body.each_line.map { |l| (JSON.parse(l) rescue nil) }.compact
      return lines unless lines.empty?
    end
    sleep 2
  end
  nil
rescue StandardError
  nil
end

# Order-insensitive, float-tolerant normalization for row comparison.
def norm_rows(rows)
  return nil unless rows.is_a?(Array)
  rows.map do |r|
    r.transform_values { |v| v.is_a?(Numeric) ? v.to_f.round(4) : v }
  end.sort_by { |r| JSON.generate(r.sort.to_h) }
end

# ---------------------------------------------------------------------------
# Layout helper: append a LayoutElement to the bottom of a page's grid block.
# ---------------------------------------------------------------------------
def add_layout!(spec, page_id, element_id, grid_column, height, same_row_start = nil)
  xml = spec['layout'].to_s
  return nil if xml.empty? || page_id.nil?
  m = xml.match(%r{(<Page\b[^>]*\bid="#{Regexp.escape(page_id)}"[^>]*>)(.*?)(</Page>)}m)
  return nil unless m
  block = m[2]
  max_end = block.scan(/gridRow="\s*\d+\s*\/\s*(\d+)\s*"/).flatten.map(&:to_i).max || 1
  row_start = same_row_start || max_end
  entry = %(  <LayoutElement elementId="#{element_id}" gridColumn="#{grid_column}" gridRow="#{row_start} / #{row_start + height}"/>\n)
  spec['layout'] = xml.sub(m[0], "#{m[1]}#{block}#{entry}#{m[3]}")
  row_start
end

def find_element(spec, element_id)
  (spec['pages'] || []).each do |p|
    (p['elements'] || []).each { |e| return [p, e] if e['id'] == element_id }
  end
  nil
end

# Apply one candidate's patch to a working spec (in place). Returns a
# human-readable description, or raises with the reason it cannot apply.
def apply_patch!(spec, cand)
  patch = cand['patch']
  raise 'candidate has no machine patch (propose-in-UI only)' unless patch.is_a?(Hash)
  if patch['needs'] && (patch[patch['needs']].nil? || patch[patch['needs']].empty?)
    raise "patch needs '#{patch['needs']}' filled in before apply (see candidate.proposed)"
  end
  case patch['op']
  when 'add_elements'
    page = (spec['pages'] || []).find { |p| p['id'] == patch['page_id'] } ||
           (spec['pages'] || []).reject { |p| p['id'] == 'page-data' }.first
    raise 'target page not found' unless page
    row_anchor = {}
    Array(patch['elements']).each do |el|
      raise "element id #{el['id']} already exists" if find_element(spec, el['id'])
      (page['elements'] ||= []) << el
    end
    Array(patch['layout']).each do |l|
      anchor = l['same_row_as'] && row_anchor[l['same_row_as']]
      placed = add_layout!(spec, page['id'], l['element_id'], l['grid_column'], l['height'] || 4, anchor)
      row_anchor[l['element_id']] = placed if placed
    end
    "added #{Array(patch['elements']).size} element(s) to page #{page['id']}"
  when 'set_column_formula'
    _pg, el = find_element(spec, patch['element_id'])
    raise "element #{patch['element_id']} not found" unless el
    col = (el['columns'] || []).find { |c| c['id'] == patch['column_id'] }
    raise "column #{patch['column_id']} not found on #{patch['element_id']}" unless col
    col['formula'] = patch['formula']
    "set #{patch['element_id']}/#{patch['column_id']} formula"
  when 'rename_element'
    _pg, el = find_element(spec, patch['element_id'])
    raise "element #{patch['element_id']} not found" unless el
    el['name'] = patch['name']
    "renamed #{patch['element_id']} -> '#{patch['name']}'"
  when 'add_control_and_rewire'
    pg, el = find_element(spec, patch.dig('rewire', 'element_id'))
    raise "element #{patch.dig('rewire', 'element_id')} not found" unless el
    col = (el['columns'] || []).find { |c| c['id'] == patch.dig('rewire', 'column_id') }
    raise 'rewire column not found' unless col
    raise "control id #{patch.dig('control', 'id')} already exists" if find_element(spec, patch.dig('control', 'id'))
    (pg['elements'] ||= []) << patch['control']
    col['formula'] = patch.dig('rewire', 'formula')
    Array(patch['layout']).each do |l|
      add_layout!(spec, pg['id'], l['element_id'], l['grid_column'], l['height'] || 3)
    end
    "added control #{patch.dig('control', 'controlId')} + rewired #{el['id']}"
  when 'set_element_prop'
    _pg, el = find_element(spec, patch['element_id'])
    raise "element #{patch['element_id']} not found" unless el
    el[patch['prop']] = patch['value']
    "set #{patch['element_id']}.#{patch['prop']}"
  when 'replace_with_point_map'
    pg, el = find_element(spec, patch['element_id'])
    raise "element #{patch['element_id']} not found" unless el
    geo = patch['geo_column']
    cents = patch['centroids'] || {}
    raise 'centroids empty' if cents.empty?
    sw = lambda do |idx, default|
      args = cents.flat_map { |val, ll| ["\"#{val}\"", ll[idx].to_s] }.join(', ')
      "Switch([#{geo}], #{args}, #{default})"
    end
    geo_ref = patch['geo_ref'] ||
              (el['columns'] || []).map { |c| c['formula'] }.find { |f| f.to_s =~ /\/#{Regexp.escape(geo)}\]\z/ }
    raise 'cannot resolve a geo column reference' unless geo_ref
    map_el = {
      'id' => "map-phasee-#{el['id']}"[0, 40], 'kind' => 'point-map',
      'source' => el['source'],
      'columns' => [
        { 'id' => 'map-phasee-geo', 'formula' => geo_ref, 'name' => geo },
        { 'id' => 'map-phasee-lat', 'formula' => sw.call(0, '39'), 'name' => 'Lat' },
        { 'id' => 'map-phasee-lng', 'formula' => sw.call(1, '-98'), 'name' => 'Long' },
        { 'id' => 'map-phasee-val', 'formula' => patch['value_formula'],
          'name' => patch['value_name'] || 'Value' }
      ],
      'latitude' => { 'id' => 'map-phasee-lat' }, 'longitude' => { 'id' => 'map-phasee-lng' },
      'size' => { 'id' => 'map-phasee-val' },
      'color' => { 'by' => 'category', 'column' => 'map-phasee-geo' },
      'name' => "#{el['name']} (map restored)"
    }
    pg['elements'].delete(el)
    pg['elements'] << map_el
    spec['layout'] = spec['layout'].to_s.gsub(/elementId="#{Regexp.escape(el['id'])}"/,
                                              %(elementId="#{map_el['id']}"))
    "replaced #{el['id']} with point-map #{map_el['id']}"
  else
    raise "unknown patch op #{patch['op'].inspect}"
  end
end

# Element ids a candidate touches (so probes only use UNTOUCHED elements).
def touched_ids(cand)
  p = cand['patch'] || {}
  ids = [p['element_id'], p.dig('rewire', 'element_id')]
  ids += Array(p['elements']).map { |e| e['id'] }
  ids += [p['control'] && p['control']['id']]
  ids.compact.uniq
end

# ---------------------------------------------------------------------------
# 1. CLONE — the 1:1 parity artifact is never touched.
# ---------------------------------------------------------------------------
orig_meta_before = Sigma.request(:get, "/v2/workbooks/#{ORIG_WB}")
orig_spec = Sigma.request(:get, "/v2/workbooks/#{ORIG_WB}/spec")
abort "FATAL: cannot read spec of #{ORIG_WB}" unless orig_spec.is_a?(Hash) && orig_spec['pages']
clone_name = opts[:name] || "#{orig_spec['name']} — Enhanced"

clone_spec = clean(orig_spec)
clone_spec['name'] = clone_name
post = lenient(Sigma.request(:post, '/v2/workbooks/spec',
                             body: JSON.generate(clone_spec), binary: true))
clone_id = post.is_a?(Hash) && (post['workbookId'] || post['id'])
abort "FATAL: clone POST returned no workbookId: #{post.inspect[0, 300]}" unless clone_id
puts "enhance-apply: clone '#{clone_name}' = #{clone_id} (original #{ORIG_WB} untouched)"

# ---------------------------------------------------------------------------
# 2. Pick probe elements (untouched by ANY accepted item) + baseline check.
# ---------------------------------------------------------------------------
all_touched = accepted.flat_map { |c| touched_ids(c) }
viz_kinds = %w[bar-chart line-chart area-chart pie-chart combo-chart scatter-chart kpi-chart table pivot-table]
probe_pool = (orig_spec['pages'] || []).reject { |p| p['id'] == 'page-data' }
                                       .flat_map { |p| p['elements'] || [] }
                                       .select { |e| viz_kinds.include?(e['kind']) }
                                       .reject { |e| all_touched.include?(e['id']) }
probes = probe_pool.first(opts[:probes]).map { |e| e['id'] }
abort 'FATAL: no untouched element available as a parity probe' if probes.empty?
puts "   parity probes (untouched elements): #{probes.join(', ')}"

# clone-vs-original at (near) the same instant: live-drift-proof comparison.
def probe_pair(clone_id, orig_id, probes)
  probes.to_h do |el|
    [el, { 'clone' => norm_rows(export_rows(clone_id, el)),
           'orig' => norm_rows(export_rows(orig_id, el)) }]
  end
end

def probe_diffs(pair)
  pair.reject { |_el, v| v['clone'] && v['orig'] && v['clone'] == v['orig'] }.keys
end

baseline = probe_pair(clone_id, ORIG_WB, probes)
bad = probe_diffs(baseline)
abort "FATAL: clone baseline already diverges from original on #{bad.join(', ')} — aborting before any change" if bad.any?
puts "   baseline: clone == original on #{probes.size}/#{probes.size} probe(s)"

# ---------------------------------------------------------------------------
# 3. Apply accepted items ONE AT A TIME with the parity-unchanged gate.
# ---------------------------------------------------------------------------
def put_spec(wb, spec)
  lenient(Sigma.request(:put, "/v2/workbooks/#{wb}/spec",
                        body: JSON.generate(spec), binary: true))
end

current = clean(Sigma.request(:get, "/v2/workbooks/#{clone_id}/spec"))
applied = []
reverted = []
gate_green = true

accepted.each do |cand|
  print "   [#{cand['id']}] "
  prev = JSON.parse(JSON.generate(current))
  begin
    desc = apply_patch!(current, cand)
  rescue StandardError => e
    skipped << { 'id' => cand['id'], 'risk' => cand['risk'], 'reason' => "not applied: #{e.message}" }
    current = prev
    puts "SKIP (#{e.message})"
    next
  end
  begin
    put_spec(clone_id, current)
  rescue StandardError => e
    current = prev
    (put_spec(clone_id, current) rescue nil) # restore server state if the PUT half-landed
    reverted << { 'id' => cand['id'], 'reason' => "PUT rejected: #{e.message.to_s.gsub(/\s+/, ' ')[0, 200]}" }
    puts 'REVERTED (PUT rejected)'
    next
  end
  # parity-unchanged gate: untouched probes, clone vs original, same instant.
  pair = probe_pair(clone_id, ORIG_WB, probes)
  diffs = probe_diffs(pair)
  if diffs.any?
    current = prev
    begin
      put_spec(clone_id, current)
      recheck = probe_diffs(probe_pair(clone_id, ORIG_WB, probes))
      gate_green &&= recheck.empty?
    rescue StandardError
      gate_green = false
    end
    reverted << { 'id' => cand['id'],
                  'reason' => "parity-unchanged gate: untouched element(s) #{diffs.join(', ')} shifted vs original" }
    puts "REVERTED (probes shifted: #{diffs.join(', ')})"
  else
    applied << { 'id' => cand['id'], 'category' => cand['category'], 'change' => desc,
                 'evidence' => cand['evidence'] }
    puts "APPLIED (#{desc}; #{probes.size} probe(s) unchanged)"
  end
end

# ---------------------------------------------------------------------------
# 4. Final report.
# ---------------------------------------------------------------------------
final_pair = probe_pair(clone_id, ORIG_WB, probes)
final_ok = probe_diffs(final_pair).empty?
gate_green &&= final_ok
orig_meta_after = Sigma.request(:get, "/v2/workbooks/#{ORIG_WB}")
orig_untouched = orig_meta_before['updatedAt'] == orig_meta_after['updatedAt']

report = {
  'workbook_id' => ORIG_WB,
  'workbook_name' => orig_spec['name'],
  'clone_id' => clone_id,
  'clone_name' => clone_name,
  'clone_url' => (lenient(post) || {})['url'],
  'accepted' => accepted_ids,
  'applied' => applied,
  'skipped' => skipped,
  'reverted' => reverted,
  'descoped_notes' => enh['descoped_notes'] || [],
  'parity_unchanged_gate' => {
    'probe_elements' => probes,
    'method' => 'clone-vs-original simultaneous JSON exports (live-drift-proof), after every item',
    'green' => gate_green
  },
  'original_untouched' => {
    'updatedAt_before' => orig_meta_before['updatedAt'],
    'updatedAt_after' => orig_meta_after['updatedAt'],
    'unchanged' => orig_untouched
  },
  'finished_at' => Time.now.utc.iso8601
}
File.write(OUT, JSON.pretty_generate(report))

puts
puts "enhance-apply: #{applied.size} applied, #{skipped.size} skipped, #{reverted.size} reverted"
puts "   clone: '#{clone_name}' (#{clone_id})"
puts "   parity-unchanged gate: #{gate_green ? 'GREEN' : 'NOT GREEN (see report)'}; original untouched: #{orig_untouched}"
puts "   report -> #{OUT}"
exit(gate_green ? 0 : 3)
