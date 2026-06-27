#!/usr/bin/env ruby
# Emit a "Not Migrated (and why)" punch-list (Markdown) for a Tableau→Sigma
# migration: every source tile that did NOT make it into the final workbook gets a
# binding-constraint category + an action, so no empty/sparse tab is mysterious.
# Aligns with the cross-converter reason-taxonomy goal (bead ncwe).
#
# Reads the converter meta (conv-meta.json — must carry workbookPatterns +
# parameters; see mechanical-specs.run_converter), the pre-prune chart specs, the
# final posted workbook spec, and the source .twb (to detect calcs that are
# commented-out in the source). No converter re-run.
#
# Usage:
#   ruby scripts/migration-notes.rb \
#     --conv-meta /tmp/<n>/conv-meta.json --chart-specs /tmp/<n>/chart-specs.json \
#     --wb-spec /tmp/<n>/wb-spec.json --twb /tmp/<n>/workbook-content.twb \
#     --out /tmp/<n>/migration-notes.md

require 'json'
require 'set'
require 'optparse'

opts = {}
OptionParser.new do |p|
  p.on('--conv-meta PATH')   { |v| opts[:meta] = v }
  p.on('--chart-specs PATH') { |v| opts[:specs] = v }
  p.on('--wb-spec PATH')     { |v| opts[:wb] = v }
  p.on('--twb PATH')         { |v| opts[:twb] = v }
  p.on('--out PATH')         { |v| opts[:out] = v }
end.parse!
%i[meta specs wb out].each { |k| abort("missing --#{k.to_s.tr('_', '-')}") unless opts[k] }

meta  = JSON.parse(File.read(opts[:meta]))
specs = JSON.parse(File.read(opts[:specs]))
wb    = JSON.parse(File.read(opts[:wb]))
xml   = opts[:twb] && File.exist?(opts[:twb]) ? File.read(opts[:twb], encoding: 'utf-8', invalid: :replace, undef: :replace) : ''

def nk(s)
  (s || '').gsub(/[^a-z0-9]/i, '').downcase
end

# Merged kind:sql element → its columns + metrics (what the model can resolve).
el = (meta.dig('model', 'pages') || []).flat_map { |p| p['elements'] || [] }
         .find { |e| e.dig('source', 'kind') == 'sql' }
col_lc   = Set.new((el&.dig('columns') || []).map { |c| (c['name'] || '').downcase })
col_norm = Set.new((el&.dig('columns') || []).map { |c| nk(c['name']) })
met_norm = Set.new((el&.dig('metrics') || []).map { |m| nk(m['name']) })

wp = meta['workbookPatterns'] || []
param_switch = {}; wp.select { |p| p['kind'] == 'param-switch' }.each { |p| param_switch[p['name']] = p }
param_filter = Set.new(wp.select { |p| p['kind'] == 'param-filter' }.map { |p| p['name'] })

# .twb: caption↔internal-name + which calcs are fully //-commented (inert in source).
name_to_cap = {}; cap_by_norm = {}; inert = Set.new
xml.scan(/<column\b[^>]*\bcaption='([^']*)'[^>]*\bname='\[([^']+)\]'[^>]*>(.*?)<\/column>/m) do |cap, name, body|
  name_to_cap[name] = cap; cap_by_norm[nk(name)] = cap
  if (fm = body.match(/formula='([^']*)'/))
    f = fm[1].gsub('&#10;', "\n").gsub('&quot;', '"')
    live = f.lines.map { |l| l.sub(%r{//.*$}, '').strip }.reject(&:empty?).join(' ')
    (inert << cap; inert << name) if !f.strip.empty? && live.empty?
  end
end
calc_internal = ->(s) { s =~ /\ACalculation_\d+/i || s =~ /_\d{6,}(:|\z)/ || s =~ /\(copy\)/i }

def classify(ref, ctx)
  base = ref.sub(/\s*\([^)]*\)\s*\z/, '').sub(/\s*\(copy\)_\d+\z/, '').sub(/:nk(:\d+)?\z/, '')
  cap  = ctx[:name_to_cap][ref] || ctx[:cap_by_norm][ctx[:nk].call(ref)] || ref
  if (ps = ctx[:param_switch][cap] || ctx[:param_switch][ref])
    return ['param-measure-picker', %(Tableau parameter measure-picker "#{cap}" -> Sigma control-driven Switch. Emit control [#{ps['controlId']}] and set the tile's MEASURE column to the Switch.)]
  end
  return ['param-driven', %(references Tableau parameter "#{cap}" -> bind a Sigma control (segmented/list) to the SOURCE element (control->viz 400s).)] if ctx[:param_filter].include?(cap) || cap =~ /\bParam(eter)?\b/i || ref =~ /Parameter/i
  return ['inert-in-source', %(the Tableau calc "#{cap}" is fully commented-out (//) in the source .twb -- dead in Tableau too; nothing to migrate.)] if ctx[:inert].include?(ref) || ctx[:inert].include?(cap)
  return ['aggregate-metric', %("#{cap}" is an aggregate metric -- plot it as the tile MEASURE (chart-context aggregate), not a row column.)] if ctx[:met_norm].include?(ctx[:nk].call(base)) || ctx[:met_norm].include?(ctx[:nk].call(cap))
  return ['unresolved-calc', %(calc "#{cap}" did not resolve (window/LOD/percent-of-total/copy) -- rebuild in a grouped chart element.)] if ctx[:calc_internal].call(ref)
  return ['absent-from-sql', %(physical field "#{ref}" is not in the custom-SQL SELECT of the collapsed model -- add it to the source query to migrate.)] unless ctx[:col_norm].include?(ctx[:nk].call(base))
  ['unresolved-calc', %(field "#{ref}" did not resolve to a model column.)]
end

ctx = { name_to_cap: name_to_cap, cap_by_norm: cap_by_norm, param_switch: param_switch,
        param_filter: param_filter, inert: inert, met_norm: met_norm, col_norm: col_norm,
        nk: method(:nk), calc_internal: calc_internal }

kept = Set.new((wb['pages'] || []).flat_map { |pg| (pg['elements'] || []).map { |e| e['id'] } })
ref_re = /\[master\/([^\]]+)\]/i
collect = lambda do |o, acc|
  case o
  when Hash  then o.each_value { |v| collect.call(v, acc) }
  when Array then o.each { |v| collect.call(v, acc) }
  when String then o.scan(ref_re) { |m| acc << m[0] }
  end
  acc
end

PRIORITY = %w[absent-from-sql unresolved-calc aggregate-metric inert-in-source param-measure-picker param-driven].freeze
rows = []
(specs['pages'] || []).each do |pg|
  (pg['elements'] || []).each do |e|
    next if kept.include?(e['id'])
    refs = collect.call(e, []).uniq.reject { |r| col_lc.include?(r.downcase) }
    cats = refs.map { |r| classify(r, ctx) }
    cats << ['unresolved-calc', 'no resolvable reason captured'] if cats.empty?
    distinct = cats.map(&:first).uniq.sort_by { |c| PRIORITY.index(c) || 99 }
    primary = distinct.first
    reason = (cats.find { |c| c[0] == primary } || cats[0])[1]
    rows << { page: pg['name'] || pg['id'], tile: e['id'], kind: e['kind'] || e['type'],
              category: primary, also: distinct[1..] || [], reason: reason, refs: refs.first(5) }
  end
end

by_cat = Hash.new(0); rows.each { |r| by_cat[r[:category]] += 1 }
md = +"# Migration — Not Migrated (and why)\n\n#{rows.size} tile(s) not migrated, by reason:\n\n"
by_cat.sort_by { |_, n| -n }.each { |c, n| md << "- **#{c}**: #{n}\n" }
md << "\n> Categories: `absent-from-sql` = the source custom-SQL doesn't select the field (fix the query); "
md << "`param-measure-picker`/`param-driven` = rebuild as a Sigma control-driven Switch/control; "
md << "`inert-in-source` = the Tableau calc is commented-out in the source; "
md << "`aggregate-metric` = plot as a measure; `unresolved-calc` = window/LOD/copy — rebuild in a grouped element.\n\n---\n\n"
rows.group_by { |r| r[:page] }.each do |pg, list|
  md << "## #{pg} (#{list.size})\n\n"
  list.each do |r|
    also = r[:also].empty? ? '' : " _(also: #{r[:also].join(', ')})_"
    refs = r[:refs].empty? ? '' : " _[refs: #{r[:refs].join(', ')}]_"
    md << "- `#{r[:tile]}` (#{r[:kind]}) — **#{r[:category]}**#{also}: #{r[:reason]}#{refs}\n"
  end
  md << "\n"
end
File.write(opts[:out], md)
warn "migration-notes: #{rows.size} tile(s) categorized -> #{opts[:out]}"
by_cat.sort_by { |_, n| -n }.each { |c, n| warn format('  %3d  %s', n, c) }
