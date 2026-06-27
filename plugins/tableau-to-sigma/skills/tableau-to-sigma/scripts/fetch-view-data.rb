#!/usr/bin/env ruby
# Parse Tableau view CSVs (already on disk) into a signals manifest.
# In production this script would also CALL the Tableau REST API to fetch
# the CSVs with the parallel-then-solo-retry dance for VizQL 401 contention.
#
# Usage:
#   ruby fetch-view-data.rb <views-dir> <out-signals.json>

require 'csv'
require 'json'

VIEWS_DIR = ARGV[0] || abort('usage: fetch-view-data.rb <views-dir> <out-signals.json>')
OUT       = ARGV[1] || abort('usage: fetch-view-data.rb <views-dir> <out-signals.json>')

# Files larger than this (bytes) are sampled rather than fully loaded.
SIZE_CAP_BYTES  = 5 * 1024 * 1024  # 5 MB
# Maximum rows to collect when sampling a large or oversized file.
SAMPLE_ROW_LIMIT = 5_000

def parse_num(s)
  s = s.to_s.strip.delete(',')
  return nil if s.empty?
  Float(s) rescue nil
end

# Type-check a column's values; date only if values look like real dates
# (not bare integers that happen to contain 4 digits).
def column_kind(values)
  non_null = values.compact.reject(&:empty?)
  return 'dimension' if non_null.empty?

  numeric_ratio = non_null.count { |v| parse_num(v) }.to_f / non_null.size
  date_like_ratio = non_null.count { |v|
    v.match?(/\d{4}-\d{2}-\d{2}/) ||                                          # ISO
    v.match?(/^(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+\d{4}$/) ||  # "May 2026"
    v.match?(/\d{1,2}\/\d{1,2}\/\d{2,4}/)                                     # 1/2/26
  }.to_f / non_null.size

  return 'date'    if date_like_ratio >= 0.6
  return 'numeric' if numeric_ratio   >= 0.8
  'dimension'
end

# Tableau CSV headers carry the agg type as a prefix when the display alias
# wasn't customized: "Sum of Gross Revenue", "Distinct count of Order Id",
# etc. When the user gave the field a display alias ("Gross Revenue"), the
# header is just that alias and the agg has to be inferred from elsewhere
# (defaultAggregation in the datasource metadata).
AGG_PREFIX = %w[
  Sum Avg Min Max Median Count\ distinct Distinct\ count
  Std Var Year\ of Month\ of Quarter\ of Day\ of Week\ of
].map { |p| Regexp.escape(p) }.join('|')
AGG_RX = /\A(#{AGG_PREFIX}) of (.+)\z/i

def detect_aggregation(header)
  return nil unless (m = header.match(AGG_RX))
  agg = m[1].downcase.gsub(' ', '_')
  agg = 'count_distinct' if agg == 'distinct_count'
  { agg: agg, of: m[2].strip }
end

# Scrub raw file bytes to clean UTF-8 before handing to the CSV parser.
def safe_read(path)
  File.binread(path).encode('UTF-8', 'binary',
    invalid: :replace, undef: :replace, replace: '')
end

# Collect up to limit CSV::Row objects from content using opts.
# Uses block form of CSV.parse so rows are always CSV::Row objects.
def collect_rows(content, opts, limit)
  rows = []
  CSV.parse(content, **opts) do |row|
    rows << row
    break if rows.size >= limit
  end
  rows
end

# Parse a CSV, tolerating malformed quoting.
# Returns [rows_array, sampled_bool]:
#   rows_array — CSV::Row objects (bounded by SAMPLE_ROW_LIMIT when large)
#   sampled    — true when the file was truncated / row-sampled
#
# Strategy:
#   1. Try liberal_parsing: true (handles most minor quote issues).
#   2. If that raises, retry with quote_char: "\x00" (disables quoting
#      entirely), which tolerates severely unbalanced quote characters.
# Either way one bad file does NOT propagate an exception to the caller.
def parse_csv_safe(path)
  large_file = File.size(path) > SIZE_CAP_BYTES
  limit      = SAMPLE_ROW_LIMIT
  content    = safe_read(path)

  base_opts = { headers: true, liberal_parsing: true }

  rows = begin
    collect_rows(content, base_opts, limit)
  rescue CSV::MalformedCSVError
    warn "  [fetch-view-data] liberal_parsing failed for #{File.basename(path)}, " \
         "retrying with quote_char=NUL"
    collect_rows(content, base_opts.merge(quote_char: "\x00"), limit)
  end

  total_rows = rows.size
  sampled    = large_file || total_rows >= limit

  # Warn if we had to truncate (sampled flag is also recorded in the output).
  if sampled
    warn "  [fetch-view-data] SAMPLED #{File.basename(path, '.csv')}: " \
         "#{File.size(path)} bytes, using first #{total_rows} rows " \
         "(distinct values / ranges are approximate)"
  end

  [rows, sampled]
end

signals  = {}
warnings = []

Dir["#{VIEWS_DIR}/*.csv"].sort.each do |path|
  view_id = File.basename(path, '.csv')

  begin
    rows, sampled = parse_csv_safe(path)
    next if rows.empty?

    headers = rows.first.headers.map { |h| h.to_s.strip }

    by_col   = {}
    agg_hint = {}
    headers.each do |h|
      col_vals = rows.map { |r| r[h] }.compact
      kind = column_kind(col_vals)
      col_entry = {
        kind:           kind,
        distinct_count: col_vals.uniq.size,
        sample:         col_vals.first(5),
        distinct:       (kind == 'dimension' ? col_vals.uniq.sort_by(&:to_s) : nil),
        numeric_range:  (kind == 'numeric' ?
          [col_vals.map { |v| parse_num(v) }.compact.min,
           col_vals.map { |v| parse_num(v) }.compact.max] : nil)
      }
      col_entry[:sampled] = true if sampled
      by_col[h] = col_entry
      if (d = detect_aggregation(h))
        agg_hint[h] = d
      end
    end

    view_entry = {
      headers:           headers,
      row_count:         rows.size,
      columns:           by_col,
      aggregation_hints: agg_hint.empty? ? nil : agg_hint
    }
    view_entry[:sampled] = true if sampled
    signals[view_id] = view_entry

  rescue => e
    msg = "  [fetch-view-data] SKIPPED #{view_id} (#{File.basename(path)}): " \
          "#{e.class}: #{e.message.lines.first&.chomp}"
    warn msg
    warnings << { view_id: view_id, path: path,
                  error: "#{e.class}: #{e.message.lines.first&.chomp}" }
  end
end

File.write(OUT, JSON.pretty_generate(signals))
puts "wrote #{OUT}  (#{signals.size} views, total " \
     "#{signals.values.sum { |v| v[:row_count] || 0 }} rows)"
warn "  [fetch-view-data] #{warnings.size} view(s) skipped due to parse errors" unless warnings.empty?
