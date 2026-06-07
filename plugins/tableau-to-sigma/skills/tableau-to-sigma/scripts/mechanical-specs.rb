#!/usr/bin/env ruby
# frozen_string_literal: true
#
# mechanical-specs.rb — the DETERMINISTIC Tableau→Sigma spec generator.
#
# Makes Tableau→Sigma spec generation MECHANICAL (no agent hand-authoring in the
# happy path). It chains the EXISTING building blocks:
#   convert_tableau_to_sigma (build/tableau.js)  → the Sigma DATA MODEL spec
#   parse-twb-layout.rb                          → per-dashboard zone signals
#   build-charts-from-signals.rb                 → Sigma chart-element specs
# and supplies the glue that previously forced an agent to step in:
#
#   * DM spec — the converter output IS the DM spec (schemaVersion:1 already set).
#     fixup_dm_spec() resolves the references the converter leaves unresolved
#     (raw-table-name prefixes on derived elements + Tableau internal-GUID sibling
#     refs) and DROPS calc columns that still can't resolve (unknown functions /
#     unresolved refs) so the live POST doesn't error-type. Dropped calcs are
#     returned for the orchestrator to surface as OPEN QUESTIONS.
#
#   * master-map — build-charts needs a regex→{id,name,format} map from CSV-
#     header / shelf-caption text to workbook-master column ids. derive_master()
#     DERIVES it from the converter fact element (its columns + metrics), exactly
#     mirroring how migrate-powerbi.rb derives master-map.json. Each fact column
#     display name D → master column {id:"m-<slug D>", name:D, formula:"[<Fact>/D]"}
#     and a header regex (agg-prefix tolerant). Aggregate calc metrics (Return
#     Rate, Gross Margin Pct) → a master-map entry carrying a verbatim `formula`
#     that build-charts emits straight onto the chart measure.
#
#   * workbook — build_wb_spec() wraps a hidden master table (sourcing the DM
#     fact element) + the build-charts elements into a POST-ready workbook spec.
require 'set'
require 'json'
require 'open3'

module MechanicalSpecs
  module_function

  LOWER = %w[a an and as at but by for in nor of on or so the to up yet via vs].freeze

  # Sigma's display-name derivation for a SNAKE_CASE / camelCase identifier.
  def display_name(s)
    norm = (s || '').gsub(/([a-z])([A-Z])/, '\\1_\\2').gsub(/([A-Z]+)([A-Z][a-z])/, '\\1_\\2')
    words = norm.downcase.split('_').reject(&:empty?)
    words.each_with_index.map { |w, i| (i.zero? || !LOWER.include?(w)) ? w.capitalize : w }.join(' ')
  end

  # Display name of a converter column: explicit `name`, else the LAST path
  # segment of the formula. "[A/B/Category]" -> "Category".
  def col_display(col)
    return col['name'] if col['name'] && !col['name'].to_s.empty?
    f = col['formula'].to_s
    m = f.match(/\[([^\]]+)\]\s*$/)
    return nil unless m
    m[1].split('/').last
  end

  def slug(s)
    s.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-|-$/, '')
  end

  # A header-matching regex for a display name that ALSO tolerates a Tableau CSV
  # aggregation prefix ("Sum of X", "Distinct count of X", ...). build-charts
  # passes the raw CSV header to map_column, so the prefix must be optional.
  def header_regex(dname)
    "(?i)^(?:(?:sum|avg|average|min|max|median|distinct count|count) of )?#{Regexp.escape(dname)}$"
  end

  # A pure-GUID display name is an internal converter artifact, never a CSV header.
  GUID_RE = /\A[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\z/i

  # Strip a cross-element calc col's disambiguating suffix:
  #   "Region (STORE_DIM (CSA.STORE_DIM))" -> "Region".
  def base_caption(dname)
    b = dname.to_s.sub(/\s*\([A-Z0-9_]+ \([^)]*\)\)\s*\z/, '').strip
    b.empty? ? nil : b
  end

  def formula_has_guid_ref?(formula)
    formula.to_s =~ /\[[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\]/i
  end

  # Map each Tableau internal field GUID -> its master display name. The
  # converter encodes the raw warehouse column name (a UUID-shaped Tableau field
  # id) as the suffix of the column's sigma inode id ("inode-<hash>/<RAW_UUID>"),
  # so GUID 7b7dc9c3-... in a formula == the column whose inode tail is 7B7DC9C3-.
  def guid_display_index(*elements)
    idx = {}
    elements.compact.each do |el|
      (el['columns'] || []).each do |c|
        tail = c['id'].to_s.split('/').last
        next unless tail =~ /\A[0-9A-F-]{20,}\z/i
        dn = col_display(c)
        idx[tail.downcase] = dn if dn
      end
    end
    idx
  end

  # Rewrite a metric formula: GUID refs -> [Master/<display>], remaining bare
  # [Col] refs -> [Master/Col]. Returns nil if any GUID stays unresolved.
  def rewrite_metric_formula(formula, guid_idx)
    f = formula.to_s.dup
    f = f.gsub(/\[([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\]/i) do
      dn = guid_idx[Regexp.last_match(1).downcase]
      dn ? "[Master/#{dn}]" : Regexp.last_match(0)
    end
    return nil if formula_has_guid_ref?(f)
    f.gsub(/\[([^\/\]]+)\]/) { "[Master/#{Regexp.last_match(1)}]" }
  end

  def all_elements(model)
    (model['pages'] || []).flat_map { |p| p['elements'] || [] }
  end

  def elem_name(e)
    e['name'] || display_name((e.dig('source', 'path') || []).last.to_s)
  end

  # Pick the CHART-READY fact element. The converter builds a derived "<Fact>
  # View" element (kind:table sourcing the base fact) that DENORMALIZES every
  # cross-element + calc column the dashboards plot — base warehouse-table
  # elements carry only their own physical columns. So prefer the largest derived
  # view that is NOT a *Dim; fall back to a base warehouse-table fact otherwise.
  def pick_fact(model)
    els = all_elements(model)
    return nil if els.empty?
    derived = els.select { |e| e.dig('source', 'kind') == 'table' && e.dig('source', 'elementId') }
                 .reject { |e| elem_name(e) =~ / Dim$/i }
    return derived.max_by { |e| (e['columns'] || []).size } if derived.any?
    base = els.select { |e| e.dig('source', 'kind') == 'warehouse-table' }
    return nil if base.empty?
    facts = base.reject { |e| elem_name(e) =~ / Dim$/i }
    (facts.empty? ? base : facts).max_by { |e| (e['columns'] || []).size }
  end

  # The base element a derived view sources (for harvesting its metrics, which
  # don't propagate to derived elements). Returns nil for a base fact.
  def base_of(model, fact_el)
    src_eid = fact_el.dig('source', 'elementId')
    return nil unless src_eid
    all_elements(model).find { |e| e['id'] == src_eid }
  end

  # Run the Tableau→Sigma converter via a node shim importing build/tableau.js.
  def run_converter(twb_path:, conn:, db:, schema:, mcp_build:, workdir:)
    shim = File.join(workdir, '_convert_tableau.mjs')
    raw_out = File.join(workdir, 'dm-raw.json')
    meta_out = File.join(workdir, 'conv-meta.json')
    File.write(shim, <<~JS)
      import { readFileSync, writeFileSync } from 'node:fs';
      import { convertTableauToSigma } from #{mcp_build.to_json};
      const xml = readFileSync(#{twb_path.to_json}, 'utf8');
      const out = convertTableauToSigma(xml, {
        connectionId: #{conn.to_json},
        database: #{db.to_json},
        schema: #{schema.to_json},
      });
      const bare = out.model || out.sigmaDataModel || out;
      writeFileSync(#{raw_out.to_json}, JSON.stringify(bare, null, 2));
      writeFileSync(#{meta_out.to_json}, JSON.stringify({ model: bare, warnings: out.warnings || [], stats: out.stats || {} }, null, 2));
    JS
    o, e, st = Open3.capture3('node', shim)
    raise "converter failed: #{e}#{o}" unless st.success?
    JSON.parse(File.read(meta_out))
  end

  # Tableau functions with no Sigma equivalent (fallback when the SigmaFunctions
  # lib isn't loadable).
  def unknown_functions(formula)
    if defined?(SigmaFunctions) && SigmaFunctions.respond_to?(:unknown_functions)
      return SigmaFunctions.unknown_functions(formula)
    end
    %w[DATEPARSE MAKEDATE MAKEDATETIME WINDOW_SUM WINDOW_AVG RUNNING_SUM RUNNING_AVG
       RANK RANK_DENSE INDEX LOOKUP PREVIOUS_VALUE TOTAL SCRIPT_REAL SCRIPT_STR
       MODEL_QUANTILE MODEL_PERCENTILE].select { |fn| formula.to_s =~ /\b#{fn}\s*\(/i }
  end

  # DM-spec fixup (mechanical). See module doc. Returns
  #   { fixed: <n formulas rewritten>, dropped: [<dropped calc display names>] }.
  # real_columns: optional { "TABLE" => Set/Array of UPPER physical column names }
  # discovered live from the warehouse (Phase 2). When supplied, base
  # warehouse-table columns whose physical name is NOT in the real table are
  # DROPPED as phantom (Tableau virtual-connection flattening invents columns
  # like "REGION (STORE_DIM (CSA.STORE_DIM))" that don't exist in ORDER_FACT).
  def fixup_dm_spec(model, real_columns = nil)
    begin
      require 'set'
      $LOAD_PATH.unshift File.expand_path('lib', __dir__)
      require 'sigma_functions'
    rescue LoadError, StandardError
      # fall back to the mini-blocklist in unknown_functions
    end
    real = {}
    (real_columns || {}).each { |t, cols| real[t.to_s.upcase] = cols.map { |c| c.to_s.upcase }.to_set }
    els = all_elements(model)
    by_id = els.each_with_object({}) { |e, h| h[e['id']] = e }
    guid_idx = guid_display_index(*els)
    fixed = 0
    dropped = []
    # Stamp a display name on every base warehouse-table element that lacks one,
    # so the DM readback returns a concrete element name (master-column formulas
    # and validate-spec --dm-context both key on element name). kind:sql elements
    # MUST stay nameless (spec rule 3) — skip those.
    els.each do |e|
      next if e['name'] && !e['name'].to_s.empty?
      next unless e.dig('source', 'kind') == 'warehouse-table'
      tbl = (e.dig('source', 'path') || []).last.to_s
      e['name'] = display_name(tbl) unless tbl.empty?
    end
    phantom = 0
    dropped_col_ids = Set.new
    dropped_disp_by_el = Hash.new { |h, k| h[k] = Set.new } # element id -> dropped display names
    unless real.empty?
      els.each do |el|
        next unless el.dig('source', 'kind') == 'warehouse-table'
        tbl = (el.dig('source', 'path') || []).last.to_s.upcase
        rc = real[tbl]
        next unless rc
        keep = []
        drop = {}
        (el['columns'] || []).each do |c|
          # Physical warehouse name = the formula tail mapped to UPPER_SNAKE, OR
          # the inode-id tail. A base col formula is "[TABLE/Display Name]".
          tail = c['formula'].to_s[/\[([^\]]+)\]\s*$/, 1]
          phys = tail ? tail.split('/').last.gsub(/\s+/, '_').upcase : nil
          # Only drop pure base-column refs (formula is exactly [TABLE/x]); never
          # drop a calc column (it has functions / multiple refs).
          is_base_ref = c['formula'].to_s =~ /\A\[#{Regexp.escape((el.dig('source','path')||[]).last.to_s)}\/[^\]]+\]\z/
          if is_base_ref && phys && !rc.include?(phys)
            drop[c['id']] = true
            dn = col_display(c)
            dropped_disp_by_el[el['id']] << dn if dn
            phantom += 1
          else
            keep << c
          end
        end
        if drop.any?
          el['columns'] = keep
          el['order'] = (el['order'] || []).reject { |id| drop[id] } if el['order']
          dropped_col_ids.merge(drop.keys)
        end
      end
      # Drop relationships whose key columns were filtered out as phantom (a
      # virtual-connection relationship keyed on a flattened column that does
      # not exist in the real table) — Sigma rejects dangling relationship keys.
      els.each do |el|
        next unless el['relationships']
        el['relationships'] = el['relationships'].reject do |r|
          (r['keys'] || []).any? do |k|
            dropped_col_ids.include?(k['sourceColumnId']) || dropped_col_ids.include?(k['targetColumnId'])
          end
        end
      end
      # Cascade: a derived element column that is a bare single ref to a dropped
      # base column ("[Src/<droppedName>]") can no longer resolve — drop it too.
      els.each do |el|
        src_eid = el.dig('source', 'elementId')
        next unless src_eid && dropped_disp_by_el.key?(src_eid)
        src_el = by_id[src_eid]
        src_name = src_el && (src_el['name'] || display_name((src_el.dig('source', 'path') || []).last.to_s))
        next unless src_name
        dropped_names = dropped_disp_by_el[src_eid]
        keep = []
        drop = {}
        (el['columns'] || []).each do |c|
          tail = c['formula'].to_s[/\A\[#{Regexp.escape(src_name)}\/([^\]]+)\]\z/, 1]
          if tail && dropped_names.include?(tail.split('/').last)
            drop[c['id']] = true
            phantom += 1
          else
            keep << c
          end
        end
        if drop.any?
          el['columns'] = keep
          el['order'] = (el['order'] || []).reject { |id| drop[id] } if el['order']
        end
      end
    end
    els.each do |el|
      src_eid = el.dig('source', 'elementId')
      src_el = src_eid && by_id[src_eid]
      src_name = src_el && (src_el['name'] || display_name((src_el.dig('source', 'path') || []).last.to_s))
      src_table = src_el && (src_el.dig('source', 'path') || []).last
      keep_cols = []
      drop_ids = {}
      (el['columns'] || []).each do |c|
        unless c['formula']
          keep_cols << c
          next
        end
        before = c['formula']
        f = before.dup
        # (1) prefix rewrite for derived elements: [<SRC_TABLE>/ -> [<SrcName>/
        f = f.gsub("[#{src_table}/", "[#{src_name}/") if src_name && src_table && src_name != src_table
        # (2) GUID sibling refs -> bare display name
        f = f.gsub(/\[([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\]/i) do
          dn = guid_idx[Regexp.last_match(1).downcase]
          dn ? "[#{dn}]" : Regexp.last_match(0)
        end
        fixed += 1 if f != before
        c['formula'] = f
        # Drop if it still can't resolve (unresolved GUID or unknown function).
        bad_fn = unknown_functions(f).reject { |n| %w[IF THEN ELSE ELSEIF END WHEN CASE AND OR NOT].include?(n.to_s.upcase) }
        if formula_has_guid_ref?(f) || !bad_fn.empty?
          dn = col_display(c) || c['name']
          dropped << dn if dn
          drop_ids[c['id']] = true
          next
        end
        keep_cols << c
      end
      if drop_ids.any?
        el['columns'] = keep_cols
        el['order'] = (el['order'] || []).reject { |id| drop_ids[id] } if el['order']
      end
      # Metrics get the same treatment: resolve GUID refs, then DROP any metric
      # whose formula still can't resolve (unresolved GUID, or a ref to a
      # parenthesized cross-element column name validate-spec misreads as a
      # function call). Plotted-but-dropped metrics surface via the master-map's
      # untranslated list; here we just keep the DM POST-able.
      if el['metrics']
        kept_metrics = []
        (el['metrics'] || []).each do |m|
          f = (m['formula'] || '').dup
          f = f.gsub(/\[([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\]/i) do
            dn = guid_idx[Regexp.last_match(1).downcase]
            dn ? "[#{dn}]" : Regexp.last_match(0)
          end
          m['formula'] = f
          # A ref whose name contains "(" (e.g. "[Unit Cost (PRODUCT_DIM (...))]")
          # is a cross-element physical column the validator/parsing can't handle
          # in an aggregate metric — drop it.
          paren_ref = f =~ /\[[^\]]*\([^\]]*\][^\]]*\]/ || f =~ /\([A-Z0-9_]+ \(/
          if formula_has_guid_ref?(f) || paren_ref
            dropped << (m['name'] || 'metric')
            next
          end
          kept_metrics << m
        end
        el['metrics'] = kept_metrics
      end
    end
    { fixed: fixed, dropped: dropped.uniq, phantom: phantom }
  end

  # The display-name suffix Sigma stamps on a derived-view column when its bare
  # name collides with a sibling (a joined-dim column or a second join of the
  # same table). The converter column carries the dim in its formula PATH:
  #   "[Order Fact/CUSTOMER_DIM/Region]" -> base label "Region (CUSTOMER_DIM)".
  # A base-fact column ("[Order Fact/Order Id]") and calc columns have no dim
  # path -> bare label. Sigma further appends " (n)" when even the (DIM) form
  # collides (e.g. DATE_DIM joined twice); that ordinal is resolved by matching
  # against the LIVE readback labels in resolve_real_labels, not guessed here.
  def expected_label(col)
    f = col['formula'].to_s
    # A calc column (explicit name, formula is not a single bare ref) keeps its name.
    return col['name'] if col['name'] && !col['name'].to_s.empty? && f !~ /\A\[[^\]]+\]\s*\z/
    tail = f[/\[([^\]]+)\]\s*\z/, 1]
    return (col['name'] && !col['name'].to_s.empty? ? col['name'] : nil) unless tail
    parts = tail.split('/')
    name = parts.last
    parts.size >= 3 ? "#{name} (#{parts[-2]})" : name
  end

  # Match each converter derived-view column to the AUTHORITATIVE display label
  # Sigma assigned on POST/readback. Returns { col_object_id => real_label }.
  # We walk the columns in order (Sigma assigns disambiguating suffixes in column
  # order) and consume from a pool of the real labels: exact (DIM) form first,
  # then the " (n)" disambiguated forms. Columns we cannot match keep their bare
  # expected label as a best-effort fallback.
  def resolve_real_labels(cols, real_labels)
    pool = Hash.new(0)
    (real_labels || []).each { |l| pool[l] += 1 }
    out = {}
    cols.each do |c|
      exp = expected_label(c)
      next if exp.nil? || exp.to_s.empty?
      chosen =
        if pool[exp].positive?
          exp
        else
          # The (DIM) form already consumed (or absent): take the next " (n)" form.
          ((1..20).map { |n| "#{exp} (#{n})" }.find { |t| pool[t].positive? }) || exp
        end
      pool[chosen] -= 1 if pool[chosen].positive?
      out[c['id']] = chosen
    end
    out
  end

  # Derive { 'master_columns' => [...], 'mmap' => {...}, 'untranslated_metrics' => [...] }.
  # fact_name is the AUTHORITATIVE Sigma element name (from the DM readback) used
  # in master-column formulas [fact_name/Col]. base_el (optional) is the element a
  # derived view sources, whose metrics are also harvested.
  #
  # real_labels (optional): the ACTUAL column display labels of the derived fact
  # element, read back from the live DM (`/v2/dataModels/<id>/columns`). The
  # converter exposes a joined-dim column under its bare last-path-segment name
  # ("Customer Id"), but on POST Sigma disambiguates it with a relationship
  # SUFFIX ("Customer Id (CUSTOMER_DIM)"). The master-column FORMULA must use the
  # real (suffixed) label or it errors as "Dependency not found". When supplied,
  # each master column's formula is [fact_name/<real label>] while its NAME (and
  # every mmap regex) stays the BARE caption — so build-charts' [Master/<bare>]
  # refs and the bare Tableau chart captions still resolve. Without real_labels
  # we fall back to the bare-name formula (correct only for non-virtual conns).
  def derive_master(fact_el, fact_name, base_el = nil, real_labels = nil)
    master_columns = []
    mmap = {}
    seen = {}
    used_regex = {}
    untranslated = []
    guid_idx = guid_display_index(fact_el, base_el)
    # dname (BARE caption, used for name+mmap) -> real readback label (used for formula).
    real_for = lambda do |dname, real_label|
      lbl = (real_label && !real_label.to_s.empty?) ? real_label : dname
      "[#{fact_name}/#{lbl}]"
    end
    add = lambda do |dname, format, real_label = nil|
      return if dname.nil? || dname.to_s.empty?
      return if dname =~ GUID_RE
      key = dname.downcase
      return if seen[key]
      seen[key] = true
      id = "m-#{slug(dname)}"
      master_columns << { 'id' => id, 'name' => dname, 'formula' => real_for.call(dname, real_label) }
      entry = { 'id' => id, 'name' => dname }
      entry['format'] = format if format
      rx = header_regex(dname)
      unless used_regex[rx]
        mmap[rx] = entry
        used_regex[rx] = true
      end
      bc = base_caption(dname)
      if bc && bc != dname
        brx = header_regex(bc)
        unless used_regex[brx]
          mmap[brx] = entry
          used_regex[brx] = true
        end
      end
    end
    raw_cols = (fact_el['columns'] || [])
    # Real readback label per converter column (suffixed form). Empty hash when
    # no readback labels supplied -> formulas fall back to the bare name.
    label_for = real_labels ? resolve_real_labels(raw_cols, real_labels) : {}
    # Bare-named columns claim their regex before suffixed cross-element dupes.
    cols = raw_cols.map { |c| [col_display(c), c['format'], label_for[c['id']]] }
    cols.sort_by! { |(dn, _, _)| (dn.to_s.include?('(') ? 1 : 0) }
    cols.each { |(dn, fmt, real_label)| add.call(dn, fmt, real_label) }
    # Aggregate calc metrics are NOT master columns — they are workbook-level
    # aggregate formulas registered as master-map entries with a verbatim
    # `formula` (base-col refs rewritten to [Master/Col]); build-charts emits the
    # formula straight onto the chart measure. The raw base cols are master cols.
    metric_srcs = [fact_el, base_el].compact
    metric_srcs.each do |mel|
      (mel['metrics'] || []).each do |m|
        nm = m['name']
        next if nm.nil? || nm.to_s.empty?
        rx = header_regex(nm)
        next if used_regex[rx]
        formula = rewrite_metric_formula(m['formula'], guid_idx)
        if formula.nil?
          untranslated << nm
          next
        end
        entry = { 'id' => "m-#{slug(nm)}", 'name' => nm, 'formula' => formula }
        entry['format'] = m['format'] if m['format']
        mmap[rx] = entry
        used_regex[rx] = true
      end
    end
    { 'master_columns' => master_columns, 'mmap' => mmap, 'untranslated_metrics' => untranslated }
  end

  # Assemble the full workbook spec: a hidden master table on page-data sourcing
  # the DM fact element, plus a dashboard page of the build-charts elements.
  def build_wb_spec(name:, dm_id:, fact_eid:, master_columns:, chart_elements:, folder_id: nil)
    spec = {
      'name' => name,
      'description' => 'Generated mechanically from Tableau via tableau-to-sigma (convert_tableau_to_sigma + build-charts-from-signals).',
      'schemaVersion' => 1,
      'pages' => [
        { 'id' => 'page-data', 'name' => 'Data',
          'elements' => [{
            'id' => 'master', 'kind' => 'table', 'name' => 'Master', 'visibleAsSource' => false,
            'source' => { 'kind' => 'data-model', 'dataModelId' => dm_id, 'elementId' => fact_eid },
            'columns' => master_columns, 'order' => master_columns.map { |c| c['id'] }
          }] },
        { 'id' => 'page-dash', 'name' => name, 'elements' => chart_elements }
      ]
    }
    spec['folderId'] = folder_id if folder_id
    spec
  end
end
