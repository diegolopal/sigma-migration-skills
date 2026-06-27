#!/usr/bin/env ruby
# frozen_string_literal: true
# reshape-pivot-actuals.rb — bring Tableau pivot CROSSTABS onto the AUTOMATED
# Phase-6 parity path by reshaping a WIDE pivot grid back into LONG
# (row-dim…, col-key, measure, value) tuples.
#
# THE PROBLEM
# -----------
# collect-parity-actuals.rb skips pivot-tables: a Sigma pivot element's CSV
# export is the WIDE grid (measures × week/quarter columns), and a Tableau
# crosstab exports just as wide. auto-parity-plan likewise builds `expected`
# from the wide Tableau CSV. The two wide grids almost never share column
# NAMES or ORDER (Tableau "Net Revenue / 2026-W12" vs Sigma "2026-W12 Net
# Revenue", measures interleaved differently, Grand-Total columns, etc.), so
# the by-display-name column matcher in auto-parity-plan can't align them and
# the whole crosstab is punted to MANUAL. For a workbook that is almost
# entirely crosstabs of ~22 bespoke calc measures × week columns (the DDMX
# class), that means parity is essentially un-automatable.
#
# THE FIX
# -------
# verify-parity.rb compares expected vs actual as a SET of `round_row` tuples
# (order-independent, full tuple width). So if we reshape BOTH sides into the
# SAME canonical LONG form, the wide-column name/order mismatch evaporates and
# `exp_set == act_set` works exactly as it does for every non-pivot chart.
#
# A wide pivot cell is fully identified by:
#   (row-dim values…, the column-axis key, the measure name) → value
# Reshaping melts every non-row-dim column into one long tuple:
#   [ row_dim_1, …, row_dim_k, col_key, measure_name, value ]
#
# Run it on the Tableau wide CSV to produce the parity `expected`, AND on the
# Sigma pivot export to produce the `actual` — same reshape, same tuple shape,
# directly set-comparable.
#
# HEADER PARSING
# --------------
# Leading --row-dims columns are the pivot rowsBy dimensions (carried verbatim).
# Every remaining column header encodes BOTH a measure and a column-axis key
# (the columnsBy member — a week/quarter/etc). Three shapes are supported:
#
#   1) --measures "A,B,…"  (RECOMMENDED — the ordered Measure-Names members):
#      the header is split into measure + col-key by locating which known
#      measure name the header CONTAINS; the remainder (minus the separator) is
#      the col-key. Robust to either ordering ("A / 2026-W12" or "2026-W12 / A")
#      and to Tableau's "Week of Order Date" verbosity.
#   2) --header-sep SEP (no --measures): split each header on SEP into exactly
#      two parts; --measure-side first|last says which part is the measure
#      (default last — Tableau's "<week> / <measure>" wide export order).
#   3) single measure (--measures with ONE name, or --single-measure NAME):
#      every wide column is a pure col-key for that one measure.
#
# Cells parse with the SAME rules as auto-parity-plan / collect-parity-actuals
# (strip $ , %, percent→fraction) so expected & actual compare on identical
# numeric representations. Blank cells (a measure not present for a col-key)
# are DROPPED, not emitted as nil tuples — Tableau and Sigma agree on absence.
#
# Usage:
#   ruby scripts/reshape-pivot-actuals.rb --csv wide.csv --row-dims 1 \
#       --measures "Net Revenue,Orders,Margin %" [--header-sep " / "] \
#       [--out long.json] [--name "<Sigma chart name>"]
#
#   # Reshape an in-place wide actuals entry (Sigma export already collected):
#   ruby scripts/reshape-pivot-actuals.rb --actuals parity-actuals.json \
#       --name "Weekly Metrics" --row-dims 1 --measures "…" --in-place
#
# Output (default): the long tuples as a JSON array [[…],…] on stdout, OR
# merged into --out / --actuals (keyed by --name) when given. Exit 0 on success.

require 'json'
require 'csv'
require 'optparse'

module PivotReshape
  module_function

  # Cell parse — identical to collect-parity-actuals / auto-parity-plan so the
  # reshaped expected & actual sets compare on the same representation.
  def parse_cell(v)
    return nil if v.nil? || v.to_s.strip.empty?
    s = v.to_s.strip
    pct = s.end_with?('%')
    f = (Float(s.gsub(/[,$%]/, '')) rescue nil)
    return v if f.nil?
    pct ? f / 100.0 : f
  end

  # Strip Tableau's date-grain verbosity off a column-axis key so a Tableau
  # "Week of Order Date" header aligns with a Sigma "Order Date" / bare-week key.
  def clean_col_key(s)
    s.to_s.strip
     .sub(/^(?:second|minute|hour|day|week|month|quarter|year)\s+of\s+/i, '')
     .strip
  end

  # Split ONE wide header into [measure_name, col_key] given the known ordered
  # measure members. Locates the measure the header CONTAINS (longest match
  # wins so "Margin %" beats a bare "Margin"); the rest, minus separators, is
  # the col-key. Returns nil if no known measure is found in the header.
  def split_by_measure(header, measures, sep)
    h = header.to_s.strip
    hit = measures
          .select { |m| h.downcase.include?(m.to_s.strip.downcase) && !m.to_s.strip.empty? }
          .max_by { |m| m.to_s.strip.length }
    return nil unless hit
    rest = h.dup
    # Remove the measure occurrence (case-insensitive, once).
    i = rest.downcase.index(hit.downcase)
    rest = (rest[0, i].to_s + rest[(i + hit.length)..].to_s)
    rest = rest.sub(Regexp.new('\A\s*' + Regexp.escape(sep.to_s.strip) + '\s*'), '')
               .sub(Regexp.new('\s*' + Regexp.escape(sep.to_s.strip) + '\s*\z'), '')
    [hit.to_s.strip, clean_col_key(rest)]
  end

  # Split ONE header on an explicit separator into [measure, col_key].
  # measure_side = :first | :last says which split part is the measure.
  def split_by_sep(header, sep, measure_side)
    parts = header.to_s.split(sep).map(&:strip).reject(&:empty?)
    return nil if parts.length < 2
    if measure_side == :first
      [parts.first, clean_col_key(parts[1..].join(sep))]
    else
      [parts.last, clean_col_key(parts[0..-2].join(sep))]
    end
  end

  # Reshape a wide pivot grid (header row + body rows, as 2-D arrays of strings)
  # into LONG tuples [row_dim…, col_key, measure, value]. See file header for the
  # header-parsing modes. Returns the array of tuples.
  #
  #   row_dims:      count of leading row-dimension columns (carried verbatim)
  #   measures:      ordered measure-member names (mode 1 / single-measure)
  #   header_sep:    separator string for mode 2 / measure-extraction
  #   measure_side:  :first | :last (mode 2 only)
  def reshape(header, body, row_dims:, measures: nil, header_sep: ' / ',
              measure_side: :last)
    rd = row_dims.to_i
    raise ArgumentError, "row-dims #{rd} >= column count #{header.length}" if rd >= header.length
    wide_cols = (rd...header.length).to_a
    single = measures && measures.length == 1

    # Pre-resolve each wide column header → [measure, col_key].
    split_for = {}
    wide_cols.each do |ci|
      hdr = header[ci].to_s
      split_for[ci] =
        if single
          [measures.first.to_s.strip, clean_col_key(hdr)]
        elsif measures && !measures.empty?
          split_by_measure(hdr, measures, header_sep)
        else
          split_by_sep(hdr, header_sep, measure_side)
        end
    end

    tuples = []
    body.each do |row|
      next if row.nil? || row.all? { |c| c.nil? || c.to_s.strip.empty? }
      row_key = (0...rd).map { |i| parse_cell(row[i]) }
      wide_cols.each do |ci|
        ms = split_for[ci]
        next unless ms # header we couldn't decode → skip (loudly handled by caller)
        val = parse_cell(row[ci])
        next if val.nil? # absent measure for this col-key — Tableau & Sigma agree
        measure, col_key = ms
        tuples << (row_key + [col_key, measure, val])
      end
    end
    tuples
  end

  # Which wide headers failed to decode (so the CLI can warn — a silent drop
  # here would understate parity coverage, the exact failure mode this fixes).
  def undecodable_headers(header, row_dims:, measures: nil, header_sep: ' / ',
                          measure_side: :last)
    rd = row_dims.to_i
    single = measures && measures.length == 1
    (rd...header.length).to_a.reject do |ci|
      hdr = header[ci].to_s
      if single then true
      elsif measures && !measures.empty? then !split_by_measure(hdr, measures, header_sep).nil?
      else !split_by_sep(hdr, header_sep, measure_side).nil?
      end
    end.map { |ci| header[ci] }
  end
end

# ---- CLI -------------------------------------------------------------------
if $PROGRAM_NAME == __FILE__
  opts = { row_dims: 1, header_sep: ' / ', measure_side: :last }
  OptionParser.new do |p|
    p.on('--csv PATH', 'wide pivot CSV to reshape (Tableau or Sigma export)') { |v| opts[:csv] = v }
    p.on('--actuals PATH', 'existing actuals JSON whose --name entry is a WIDE [[header],[row]…] to reshape') { |v| opts[:actuals] = v }
    p.on('--row-dims N', Integer, 'leading row-dimension column count (default 1)') { |v| opts[:row_dims] = v }
    p.on('--measures LIST', 'ordered measure-member names, comma-separated') { |v| opts[:measures] = v.split(',').map(&:strip).reject(&:empty?) }
    p.on('--single-measure NAME', 'single measure; all wide columns are col-keys') { |v| opts[:measures] = [v] }
    p.on('--header-sep SEP', 'wide-header separator (default " / ")') { |v| opts[:header_sep] = v }
    p.on('--measure-side SIDE', %w[first last], 'with --header-sep: which split part is the measure (default last)') { |v| opts[:measure_side] = v.to_sym }
    p.on('--name NAME', 'Sigma chart name to key the output under (for --out/--actuals)') { |v| opts[:name] = v }
    p.on('--out PATH', 'merge long tuples into this JSON file under --name (else stdout)') { |v| opts[:out] = v }
    p.on('--in-place', 'with --actuals: rewrite the --name entry in place with the long tuples') { opts[:in_place] = true }
  end.parse!

  abort 'need --csv or --actuals' unless opts[:csv] || opts[:actuals]

  header, body =
    if opts[:csv]
      rows = CSV.read(opts[:csv])
      abort "empty CSV #{opts[:csv]}" if rows.empty?
      [rows.first.map { |h| h.to_s.strip }, rows[1..] || []]
    else
      store = JSON.parse(File.read(opts[:actuals]))
      abort '--actuals needs --name' unless opts[:name]
      wide = store[opts[:name]]
      abort "no entry #{opts[:name].inspect} in #{opts[:actuals]}" unless wide.is_a?(Array) && wide.length >= 1
      [wide.first.map { |h| h.to_s.strip }, wide[1..] || []]
    end

  bad = PivotReshape.undecodable_headers(header, row_dims: opts[:row_dims],
                                         measures: opts[:measures], header_sep: opts[:header_sep],
                                         measure_side: opts[:measure_side])
  warn "reshape-pivot-actuals: #{bad.length} wide header(s) could not be decoded (dropped): #{bad.inspect}" if bad.any?

  tuples = PivotReshape.reshape(header, body, row_dims: opts[:row_dims],
                                measures: opts[:measures], header_sep: opts[:header_sep],
                                measure_side: opts[:measure_side])

  if opts[:actuals] && opts[:in_place]
    store = JSON.parse(File.read(opts[:actuals]))
    store[opts[:name]] = tuples
    File.write(opts[:actuals], JSON.pretty_generate(store))
    warn "reshape-pivot-actuals: rewrote #{opts[:name].inspect} in #{opts[:actuals]} → #{tuples.length} long tuple(s)"
  elsif opts[:out]
    store = (JSON.parse(File.read(opts[:out])) rescue {}) if File.exist?(opts[:out])
    store ||= {}
    abort '--out needs --name' unless opts[:name]
    store[opts[:name]] = tuples
    File.write(opts[:out], JSON.pretty_generate(store))
    warn "reshape-pivot-actuals: wrote #{tuples.length} long tuple(s) for #{opts[:name].inspect} → #{opts[:out]}"
  else
    puts JSON.pretty_generate(tuples)
    warn "reshape-pivot-actuals: #{tuples.length} long tuple(s)"
  end
end
