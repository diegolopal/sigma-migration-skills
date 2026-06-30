#!/usr/bin/env ruby
# frozen_string_literal: true
# shape-preflight.rb — Phase 2.5 reuse gate. BEFORE wiring a workbook to an
# EXISTING (reused) data model element, mechanically check the three failure
# modes that a spec POST will NOT catch and that otherwise ship silently
# (verified live 2026-06-29; see SKILL.md Phase 2.5 + §3b):
#
#   1. VISIBILITY — the element you wire to must be usable as a source. An element
#      with "visibleAsSource": false builds fine via the API but users can't pick
#      it as a source in the workbook UI. The flag DEFAULTS true and is OMITTED
#      when true, so only a literal `false` means hidden.
#   2. COLUMN COVERAGE — every dashboard-referenced column must resolve on that
#      element (present by name; relationship-reached columns are reported so you
#      know they come via a relationship, not directly).
#   3. FAN-OUT — every relationship the element reaches columns through must be
#      1:1 on its key. A non-unique target key multiplies fact rows and silently
#      inflates every aggregate. The public REST API has no ad-hoc SQL endpoint,
#      so this script EMITS the exact uniqueness query per relationship (run it
#      via the Sigma MCP `query` tool) and BLOCKS until you feed results back via
#      --fanout-results (or acknowledge with --ack-fanout).
#
# Usage:
#   ruby scripts/shape-preflight.rb --dm-id <id> --element <name-or-id> \
#     [--needed-columns "Col A,Col B,..."] \
#     [--fanout-results <file.json>]   # {"<relName>": {"n": <count>, "d": <distinct>}}
#     [--ack-fanout]                    # bypass the fan-out block (records the ack)
#     --out <dir>/shape-preflight.json
#
# Exit: 0 = PASS (safe to reuse this element).
#       2 = FAIL (hidden element / missing columns / unverified or fanning-out relationship).
#       1 = bad invocation.

require 'json'
require 'yaml'
require 'optparse'

opts = {}
OptionParser.new do |p|
  p.on('--dm-id ID')            { |v| opts[:dm] = v }
  p.on('--element NAME_OR_ID')  { |v| opts[:el] = v }
  p.on('--needed-columns LIST') { |v| opts[:cols] = v }
  p.on('--fanout-results PATH') { |v| opts[:fanout] = v }
  p.on('--ack-fanout')          { |_| opts[:ack] = true }
  p.on('--out PATH')            { |v| opts[:out] = v }
end.parse!
%i[dm el out].each { |k| abort "missing --#{k.to_s.tr('_', '-')}" unless opts[k] }

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'sigma_rest'

# GET spec — usually JSON, but tolerate YAML defensively.
raw = Sigma.request(:get, "/v2/dataModels/#{opts[:dm]}/spec", accept: 'application/json')
spec = raw.is_a?(String) ? (JSON.parse(raw) rescue YAML.safe_load(raw, permitted_classes: [Date, Time])) : raw

elements = (spec['elements'] || (spec['pages'] || []).flat_map { |pg| pg['elements'] || [] })
abort "no elements in DM #{opts[:dm]}" if elements.empty?

el_by_id   = elements.each_with_object({}) { |e, h| h[e['id']] = e }
el_by_name = elements.each_with_object({}) { |e, h| h[e['name'].to_s.downcase] = e }
target = el_by_id[opts[:el]] || el_by_name[opts[:el].to_s.downcase]
unless target
  names = elements.map { |e| "#{e['name']} (#{e['id']})" }.join(', ')
  abort "element '#{opts[:el]}' not found in DM. Available: #{names}"
end

norm = ->(s) { s.to_s.downcase.gsub(/[^a-z0-9]/, '') }
fails = []

# ---- Check 1: visibility -------------------------------------------------
hidden = (target['visibleAsSource'] == false)
hidden_siblings = elements.select { |e| e['visibleAsSource'] == false }.map { |e| e['name'] }
if hidden
  fails << "element '#{target['name']}' is visibleAsSource:false (hidden) — it will build via the " \
           "API but users can't pick it as a source. Wire to a visible sibling, or PUT the DM spec " \
           "setting visibleAsSource:true on this element."
end

# ---- Check 2: column coverage -------------------------------------------
target_col_names = (target['columns'] || []).map { |c| c['name'] }.compact
target_col_norms = target_col_names.map(&norm)
needed = (opts[:cols] || '').split(',').map(&:strip).reject(&:empty?)
missing = needed.reject { |n| target_col_norms.include?(norm.call(n)) }
unless missing.empty?
  fails << "columns absent from element '#{target['name']}': #{missing.join(', ')}. They may live " \
           "on a related element (reach them via [#{target['name']}/<RelationshipName>/<col>] in the " \
           "workbook) or be genuinely missing — confirm before wiring."
end

# ---- Check 3: fan-out ----------------------------------------------------
fanout_results = opts[:fanout] ? JSON.parse(File.read(opts[:fanout])) : {}
rels = (target['relationships'] || []).map do |r|
  tgt = el_by_id[r['targetElementId']]
  tgt_path = tgt && (tgt['source'] || {})['path']
  tgt_table = tgt_path.is_a?(Array) ? tgt_path.join('.') : tgt_path
  key = (r['keys'] || []).first || {}
  rname = r['name'] || r['id']
  # Emit the uniqueness query in Sigma-MCP form (column id == live spec id).
  sql = %(SELECT COUNT(*) AS n, COUNT(DISTINCT "#{key['targetColumnId']}") AS d ) +
        %(FROM "datamodel"."#{r['targetElementId']}")
  res = fanout_results[rname]
  verdict =
    if res && res['n'] && res['d']
      res['d'].to_i == res['n'].to_i ? :ok : :fanout
    else
      :unverified
    end
  if verdict == :fanout
    fails << "relationship '#{rname}' FANS OUT: target '#{tgt && tgt['name']}' has #{res['n']} rows " \
             "but only #{res['d']} distinct join-key values — every reached column inflates aggregates " \
             "~#{(res['n'].to_f / [res['d'].to_i, 1].max).round(1)}x. Relate on the dim's true unique key."
  elsif verdict == :unverified && !opts[:ack]
    fails << "relationship '#{rname}' → '#{tgt && tgt['name']}' not verified 1:1. Run via Sigma MCP query " \
             "(dataModelId=#{opts[:dm]}): #{sql}  — then pass --fanout-results (or --ack-fanout to skip)."
  end
  {
    'name' => rname, 'target_element' => (tgt && tgt['name']), 'target_table' => tgt_table,
    'source_column_id' => key['sourceColumnId'], 'target_column_id' => key['targetColumnId'],
    'uniqueness_query' => { 'dataModelId' => opts[:dm], 'sql' => sql },
    'verdict' => verdict.to_s
  }
end

status = fails.empty? ? 'PASS' : 'FAIL'
result = {
  'dm_id' => opts[:dm],
  'element' => { 'id' => target['id'], 'name' => target['name'],
                 'visibleAsSource' => target.fetch('visibleAsSource', true) },
  'hidden_elements' => hidden_siblings,
  'needed_columns' => { 'resolved' => (needed - missing), 'missing' => missing },
  'relationships' => rels,
  'failures' => fails,
  'status' => status
}
File.write(opts[:out], JSON.pretty_generate(result))

warn "shape-preflight: DM #{opts[:dm]} element '#{target['name']}' → #{status}"
fails.each { |f| warn "  FAIL  #{f}" }
warn "  → #{opts[:out]}"
exit(status == 'PASS' ? 0 : 2)
