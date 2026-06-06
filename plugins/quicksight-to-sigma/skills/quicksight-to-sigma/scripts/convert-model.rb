#!/usr/bin/env ruby
# convert-model.rb — quicksight-to-sigma "convert" phase helper.
#
# MODE A (--emit-mcp): print the exact convert_quicksight_to_sigma MCP-tool call the agent
#                      should run (files = analysis.json + each dataset json from discovery).
# MODE B (--fixup):    take the converter's output Sigma DM JSON and make it POST-ready:
#                        - force schemaVersion = 1
#                        - ensure EVERY element has a non-empty, paren-free `name`
#                          (beads-sigma-vy4k: nameless elements; beads-sigma-nc6g: join-view
#                           and warehouse-table elements also need names)
#                        - rewrite kind:sql refs to [Custom SQL/RAW] form
#                        - rewrite kind:table (join "view") refs so the leading segment is the
#                          SOURCE ELEMENT's display name (beads-sigma-nc6g)
#                        - synthesize a single denormalized kind:sql element for CustomSql
#                          multi-table JoinInstruction datasets (beads-sigma-nc6g)
#                        - fix CastColumnType self-reference (Text([self]) -> Text([Custom SQL/RAW]))
#                          (beads-sigma-23xu)
#                        - neutralize window/table-calc placeholder formulas to `Null` + description
#                          (beads-sigma-woaa)
#                        - drop unapplied FilterOperation boolean calc columns from the DM and
#                          surface the filter so the workbook builder can apply it (beads-sigma-23xu)
#                        - optionally inject folderId
#
# Usage:
#   ruby scripts/convert-model.rb --emit-mcp --discover-dir DIR --connection-id ID [--database DB --schema SCH]
#   ruby scripts/convert-model.rb --fixup --in converter-out.json --discover-dir DIR [--folder-id ID] --out dm-spec.json
require 'json'
require 'optparse'

opts = {}
OptionParser.new do |o|
  o.on('--emit-mcp') { opts[:emit] = true }
  o.on('--fixup') { opts[:fixup] = true }
  o.on('--in F') { |v| opts[:in] = v }
  o.on('--out F') { |v| opts[:out] = v }
  o.on('--discover-dir D') { |v| opts[:dir] = File.expand_path(v) }
  o.on('--connection-id ID') { |v| opts[:conn] = v }
  o.on('--database DB') { |v| opts[:db] = v }
  o.on('--schema SCH') { |v| opts[:schema] = v }
  o.on('--folder-id ID') { |v| opts[:folder] = v }
end.parse!

def titleize(s)
  s.to_s.gsub(/[_.]/, ' ').split.map { |w| w[0..0].upcase + w[1..-1].to_s.downcase }.join(' ')
end

# Strip parentheses (and their contents) and other ref-breaking chars out of an
# element/column name. The converter sometimes emits cross-relation columns like
# "Region (CUSTOMER_DIM)" — the parens collide with Sigma's function-call syntax
# inside [..] refs, so a downstream [El/Region (CUSTOMER_DIM)] ref never resolves.
# (beads-sigma-nc6g point 3)
def sanitize_name(s)
  s.to_s.gsub(/\s*\([^)]*\)/, '').gsub(/[()\[\]]/, '').strip
end

# QuickSight window / table-calc function names. A DM/workbook calc column that
# uses any of these silently errors in Sigma (window aggregates aren't allowed in
# a calc-column context), so we neutralize them to a valid `Null` formula and move
# the original QS expression into the column description. (beads-sigma-woaa)
QS_WINDOW_FUNCS = %w[
  runningSum runningAvg runningCount runningMax runningMin
  percentOfTotal percentDifference difference
  rank denseRank percentileRank
  lag lead firstValue lastValue
  windowSum windowAvg windowCount windowMax windowMin
  movingSum movingAverage
].freeze

def qs_window_func?(expr)
  e = expr.to_s
  QS_WINDOW_FUNCS.any? { |fn| e =~ /(?<![A-Za-z0-9_])#{Regexp.escape(fn)}\s*\(/ }
end

# True when a formula is ONLY a /* ... */ comment (the converter's window
# placeholder). Sigma rejects a comment-only formula as "Invalid formula", which
# fails the WHOLE all-or-nothing DM POST. (beads-sigma-woaa)
def comment_only_formula?(f)
  f.to_s.strip =~ /\A\/\*.*\*\/\z/m ? true : false
end

# Recover the original QS expression embedded in a placeholder comment, e.g.
# "/* TODO QuickSight table-calc — re-author in Sigma: runningSum(...) */".
def expr_from_comment(f)
  m = f.to_s.match(/re-author in Sigma:\s*(.*?)\s*\*\/\s*\z/m)
  m ? m[1] : f.to_s.gsub(%r{\A/\*\s*}, '').gsub(%r{\s*\*/\z}, '').strip
end

# Reconstruct a single denormalized SELECT for a QuickSight dataset whose
# LogicalTableMap contains one or more JoinInstructions, so that a CustomSql
# multi-table dataset (which the converter splits into N separate kind:sql
# elements with no join) collapses to ONE kind:sql element that contains every
# OutputColumn the visuals reference. (beads-sigma-nc6g — CustomSql-join path)
# Returns the SQL string, or nil if the dataset isn't a join.
def synth_join_sql(ds)
  ltm = ds['LogicalTableMap'] || {}
  ptm = ds['PhysicalTableMap'] || {}
  return nil unless ltm.values.any? { |v| v.dig('Source', 'JoinInstruction') }

  frag = {}      # logicalId -> "(...)" or "DB.SCH.TBL"
  colmap = {}    # logicalId -> { logicalColName => physicalColName }
  ltm.each do |lid, lt|
    src = lt['Source'] || {}
    pid = src['PhysicalTableId']
    next unless pid
    phys = ptm[pid] || {}
    cmap = {}
    if (cs = phys['CustomSql'])
      frag[lid] = "(#{cs['SqlQuery'].to_s.strip})"
      (cs['Columns'] || []).each { |c| cmap[c['Name']] = c['Name'] }
    elsif (rt = phys['RelationalTable'])
      parts = [rt['Catalog'], rt['Schema'], rt['Name']].compact.reject(&:empty?)
      frag[lid] = parts.join('.')
      (rt['InputColumns'] || []).each { |c| cmap[c['Name']] = c['Name'] }
    end
    (lt['DataTransforms'] || []).each do |t|
      if (ro = t['RenameColumnOperation'])
        old = ro['ColumnName']; nw = ro['NewColumnName']
        cmap[nw] = cmap.delete(old) || old
      end
    end
    colmap[lid] = cmap
  end

  # SQL-safe table aliases (logical ids may contain hyphens, e.g. "orders-log")
  sa = {}
  ltm.each_key { |lid| sa[lid] = lid.to_s.gsub(/[^A-Za-z0-9_]/, "_") }
  joins = ltm.select { |_, v| v.dig("Source", "JoinInstruction") }
  referenced = joins.values.flat_map { |v| ji = v['Source']['JoinInstruction']; [ji['LeftOperand'], ji['RightOperand']] }
  root_id = joins.keys.find { |jid| !referenced.include?(jid) } || joins.keys.first

  emitted = {}
  from_sql = +''
  walk = lambda do |jid|
    ji = ltm[jid]['Source']['JoinInstruction']
    jt = (ji['Type'] || 'INNER').upcase
    left = ji['LeftOperand']; right = ji['RightOperand']
    if joins.key?(left)
      walk.call(left)
    elsif !emitted[left]
      from_sql << "#{frag[left]} #{sa[left]}"
      emitted[left] = true
    end
    if joins.key?(right)
      walk.call(right)
    elsif !emitted[right]
      on = ji['OnClause'].to_s
      on_sql = on.gsub(/\{([^}]+)\}/) do
        col = Regexp.last_match(1).strip
        owner = ([left, right] + emitted.keys).uniq.find { |lid| (colmap[lid] || {}).key?(col) }
        phys = owner ? colmap[owner][col] : col
        owner ? "#{sa[owner]}.#{phys}" : col
      end
      from_sql << " #{jt} JOIN #{frag[right]} #{sa[right]} ON #{on_sql}"
      emitted[right] = true
    end
  end
  walk.call(root_id)

  sels = (ds['OutputColumns'] || []).map do |oc|
    lid, _ = oc['Id'].to_s.split('.', 2)
    pcol = (colmap[lid] || {})[oc['Name']] || oc['Name']
    "#{sa[lid]}.#{pcol} AS #{oc['Name']}"
  end
  return nil if sels.empty? || from_sql.empty?
  "SELECT #{sels.join(', ')} FROM #{from_sql}"
end

dir = opts[:dir]
sig_path = dir && File.join(dir, 'signals.json')
signals = (sig_path && File.exist?(sig_path)) ? JSON.parse(File.read(sig_path)) : nil

if opts[:emit]
  abort 'need --discover-dir' unless dir
  files = [File.join(dir, 'analysis.json')] + Dir[File.join(dir, 'datasets', '*.json')].sort
  puts 'Call the MCP tool `convert_quicksight_to_sigma` with:'
  puts '  files: [ {name, content} for each ]'
  files.each { |f| puts "    - #{f}" }
  puts "  connection_id: #{opts[:conn] || '<SIGMA_CONNECTION_ID>'}"
  puts "  database: #{opts[:db] || '(override if dataset path is incomplete)'}"
  puts "  schema:   #{opts[:schema] || '(override if dataset path is incomplete)'}"
  puts
  puts "Save the returned model, then: ruby scripts/convert-model.rb --fixup --in <model>.json --discover-dir #{dir} --out dm-spec.json"
  exit 0
end

if opts[:fixup]
  abort 'need --in' unless opts[:in]
  model = JSON.parse(File.read(opts[:in]))
  model = model['model'] if model.is_a?(Hash) && model['model']
  model['schemaVersion'] = 1
  ds_names = signals ? signals['datasets'].map { |d| d['name'] }.compact : []

  ds_jsons = []
  if dir
    Dir[File.join(dir, 'datasets', '*.json')].sort.each do |f|
      j = JSON.parse(File.read(f)) rescue nil
      ds = j && (j['DataSet'] || j)
      ds_jsons << ds if ds.is_a?(Hash) && ds['LogicalTableMap']
    end
  end
  # Any dataset with a JoinInstruction (CustomSql OR RelationalTable physical
  # tables). The converter mishandles BOTH shapes: CustomSql joins are split into
  # N nameless kind:sql elements with no join at all; RelationalTable joins get a
  # fragile relationship "view" element that under-projects dimension columns and
  # drops the 2nd join hop on a chained 3-way join. We replace both with a single
  # denormalized kind:sql element built straight from the QS join tree, so the
  # workbook master sources every charted column from one element. (beads-sigma-nc6g)
  join_dataset = ds_jsons.find do |ds|
    (ds['LogicalTableMap'] || {}).values.any? { |v| v.dig('Source', 'JoinInstruction') }
  end

  fixed = 0
  rewrote = 0
  neutralized = 0
  filter_exprs = []

  if join_dataset
    join_sql = synth_join_sql(join_dataset)
    if join_sql
      conn = nil
      (model['pages'] || []).each do |pg|
        (pg['elements'] || []).each { |el| conn ||= el.dig('source', 'connectionId') }
      end
      out_cols = (join_dataset['OutputColumns'] || []).map do |oc|
        nm = sanitize_name(titleize(oc['Name']))
        { 'id' => "Custom SQL/#{oc['Name']}", 'name' => nm, 'formula' => "[Custom SQL/#{oc['Name']}]" }
      end
      # physical table names participating in this join (to identify which
      # warehouse-table elements to remove when collapsing to the SQL element)
      join_tables = (join_dataset['PhysicalTableMap'] || {}).values.map do |p|
        (p.dig('RelationalTable', 'Name'))
      end.compact
      join_el = {
        'id' => "join-#{join_dataset['DataSetId'] || 'view'}".gsub(/[^A-Za-z0-9_-]/, ''),
        'kind' => 'table',
        'name' => sanitize_name(join_dataset['Name'] || ds_names[0] || 'Join View'),
        'source' => { 'connectionId' => conn, 'kind' => 'sql', 'statement' => join_sql },
        'columns' => out_cols,
        'order' => out_cols.map { |c| c['id'] }
      }
      (model['pages'] || []).each do |pg|
        kept = (pg['elements'] || []).reject do |el|
          srck = el.dig('source', 'kind')
          srck == 'sql' || srck == 'table' ||
            (srck == 'warehouse-table' && join_tables.include?((el.dig('source', 'path') || []).last))
        end
        pg['elements'] = kept + [join_el]
      end
      STDERR.puts "fixup: synthesized join element \"#{join_el['name']}\" with #{out_cols.size} cols (collapsed #{join_tables.size} joined table(s))"
      fixed += 1
    end
  end

  all_els = (model['pages'] || []).flat_map { |pg| pg['elements'] || [] }

  all_els.each_with_index do |el, i|
    src = el['source'] || {}
    if el['name'].nil? || el['name'].to_s.empty?
      el['name'] =
        if src['kind'] == 'warehouse-table' && src['path'].is_a?(Array) && !src['path'].empty?
          titleize(src['path'].last)
        elsif src['kind'] == 'table'
          'Join View'
        elsif ds_names[i]
          ds_names[i]
        elsif ds_names.length == 1
          ds_names[0]
        else
          "Query #{i + 1}"
        end
      fixed += 1
    end
    el['name'] = sanitize_name(el['name'])
  end

  id_to_name = {}
  table_to_name = {}
  all_els.each do |el|
    id_to_name[el['id']] = el['name']
    src = el['source'] || {}
    if src['kind'] == 'warehouse-table' && src['path'].is_a?(Array) && !src['path'].empty?
      table_to_name[src['path'].last] = el['name']
    end
  end

  all_els.each do |el|
    next unless el.dig('source', 'kind') == 'table'
    next unless el['name'] == 'Join View'
    srcnm = id_to_name[el.dig('source', 'elementId')]
    el['name'] = sanitize_name("#{srcnm} View") if srcnm
    id_to_name[el['id']] = el['name']
  end

  all_els.each do |el|
    src = el['source'] || {}
    cols = el['columns'] || []

    cols.each do |c|
      if c['name'].nil? || c['name'].to_s.empty?
        alias_raw = c['id'].to_s.split('/').last
        c['name'] = titleize(alias_raw) unless alias_raw.nil? || alias_raw.empty?
      end
      c['name'] = sanitize_name(c['name']) if c['name']
    end

    cols.each do |c|
      f = c['formula'].to_s
      orig = nil
      if comment_only_formula?(f)
        orig = expr_from_comment(f)
      elsif qs_window_func?(f)
        orig = f
      end
      next unless orig
      c['formula'] = 'Null'
      existing = c['description'].to_s
      note = "QuickSight table-calc (neutralized — re-author in Sigma): #{orig}"
      c['description'] = existing.empty? ? note : "#{existing}\n#{note}"
      neutralized += 1
    end

    if src['kind'] == 'sql'
      disp_to_alias = {}
      cols.each do |c|
        alias_raw = c['id'].to_s.split('/').last
        next if alias_raw.nil? || alias_raw.empty?
        disp_to_alias[titleize(alias_raw)] = alias_raw
        disp_to_alias[sanitize_name(titleize(alias_raw))] = alias_raw
        f = c['formula'].to_s
        m = f.match(/\A\[(.+)\]\z/)
        disp_to_alias[m[1]] = alias_raw if m
      end
      cols.each do |c|
        next unless c['formula']
        next if c['formula'] == 'Null'
        new_f = c['formula'].gsub(/\[([^\]\/]+)\]/) do
          inner = Regexp.last_match(1)
          disp_to_alias[inner] ? "[Custom SQL/#{disp_to_alias[inner]}]" : "[#{inner}]"
        end
        if new_f != c['formula']
          c['formula'] = new_f
          rewrote += 1
        end
      end

    elsif src['kind'] == 'table'
      src_name = id_to_name[src['elementId']]
      cols.each do |c|
        next unless c['formula']
        next if c['formula'] == 'Null'
        new_f = c['formula'].gsub(/\[([^\]]+)\]/) do
          ref = Regexp.last_match(1)
          parts = ref.split('/')
          if table_to_name.key?(parts[0])
            parts[0] = table_to_name[parts[0]]
          elsif src_name
            parts[0] = src_name
          end
          "[#{parts.join('/')}]"
        end
        if new_f != c['formula']
          c['formula'] = new_f
          rewrote += 1
        end
      end
    end

    before = cols.size
    keep = cols.reject do |c|
      m = c['name'].to_s.match(/\AFilter:\s*(.+)\z/)
      if m
        filter_exprs << m[1].strip
        true
      else
        false
      end
    end
    if keep.size != before
      el['columns'] = keep
      el['order'] = (el['order'] || []).select { |oid| keep.any? { |c| c['id'] == oid } } if el['order']
    end
  end

  model['folderId'] = opts[:folder] if opts[:folder]

  if dir && !filter_exprs.empty?
    File.write(File.join(dir, 'dm-filters.json'), JSON.pretty_generate('filters' => filter_exprs.uniq))
    STDERR.puts "fixup: surfaced #{filter_exprs.uniq.size} dataset filter(s) -> dm-filters.json (#{filter_exprs.uniq.join('; ')})"
  end

  out = opts[:out] || 'dm-spec.json'
  File.write(out, JSON.pretty_generate(model))
  STDERR.puts "fixup: named #{fixed} element(s); rewrote #{rewrote} ref(s); neutralized #{neutralized} window calc(s); schemaVersion=1#{opts[:folder] ? '; folderId set' : ''} -> #{out}"
  exit 0
end

abort 'specify --emit-mcp or --fixup'
