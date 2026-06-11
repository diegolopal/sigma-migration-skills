# frozen_string_literal: true
#
# layout_lint.rb — mechanized layout-quality lint for built Sigma workbooks.
#
# SHARED lib, vendored byte-identical into every covered plugin's scripts/lib/
# (md5 discipline — same as escalate-gap.py / enhance-apply.rb). Run by:
#   - post-and-readback.rb (--type workbook) right after the column-type guard
#   - enhance-apply.rb's finalize (the Phase E clone must lint clean)
#   - assert-phase6-ran.rb gate 6 (with a --skip-layout-lint escape)
#
# It exists because a workbook can pass every data gate and still ship as a
# visual mess (raw-id chart titles, controls dumped at the page foot, dead
# zones) — the "PHASEE PBI Employee Dashboard" regression. Three checks:
#
#   (a) raw-id display names — any element display name matching a raw-id
#       pattern (^[0-9a-f]{12,}$ or ^el-[0-9a-f]+$). A human must never see a
#       visual id as a chart title.
#   (b) orphan controls — input controls placed OUTSIDE any <GridContainer>
#       on a page that HAS containers (banded layout). Controls belong in a
#       band (control band, or their chart's container), never loose at the
#       page foot.
#   (c) dead zones — more than 25% of a page's grid rows empty between the
#       page's first and last positioned element (top-level layout entries).
#       Catches the "elements scattered with a hole next to the title" look.
#
# API:
#   violations = LayoutLint.lint(spec)   # spec = parsed workbook spec Hash
#   -> array of human-readable violation strings; empty = clean.
#
# Standalone:
#   ruby scripts/lib/layout_lint.rb <spec.json>   # exit 1 + list on violations
module LayoutLint
  RAW_ID_NAME = /\A(?:[0-9a-f]{12,}|el-[0-9a-f]+)\z/i
  DEAD_ZONE_MAX = 0.25

  module_function

  # All [element, page] pairs in the spec (skips layout-only container shells).
  def named_elements(spec)
    (spec['pages'] || []).flat_map do |pg|
      (pg['elements'] || []).map { |el| [el, pg] }
    end
  end

  # Per-page layout blocks: { page_id => page_inner_xml }.
  def page_blocks(layout_xml)
    layout_xml.to_s.scan(%r{<Page\b[^>]*\bid="([^"]*)"[^>]*>(.*?)</Page>}m).to_h
  end

  # Top-level entries of a page block (direct children only, containers kept
  # opaque): [[:container|:element, element_id, row_start, row_end], ...]
  def top_level_entries(page_xml)
    entries = []
    s = page_xml.to_s
    pos = 0
    while (m = s.match(%r{<(GridContainer|LayoutElement)\b([^>]*?)(/>|>)}m, pos))
      tag, attrs, close = m[1], m[2], m[3]
      eid = attrs[/elementId="([^"]*)"/, 1]
      rows = attrs[/gridRow="\s*(\d+)\s*/, 1].to_i
      rowe = attrs[/gridRow="\s*\d+\s*\/\s*(\d+)\s*"/, 1].to_i
      if tag == 'GridContainer' && close == '>'
        endm = s.match(%r{</GridContainer>}m, m.end(0))
        entries << [:container, eid, rows, rowe]
        pos = endm ? endm.end(0) : m.end(0)
      else
        entries << [tag == 'GridContainer' ? :container : :element, eid, rows, rowe]
        pos = m.end(0)
      end
    end
    entries
  end

  def lint(spec)
    violations = []
    el_kind = {}
    named_elements(spec).each { |el, _pg| el_kind[el['id']] = el['kind'] }

    # (a) raw-id display names ------------------------------------------------
    named_elements(spec).each do |el, pg|
      name = el['name'].to_s
      next if name.empty?
      next unless name.match?(RAW_ID_NAME)
      violations << "raw-id display name: element #{el['id']} (#{el['kind']}) on page " \
                    "'#{pg['name'] || pg['id']}' is named #{name.inspect} — derive a human title " \
                    '(the source visual had no explicit title; see derived_title in the builder)'
    end

    page_blocks(spec['layout']).each do |page_id, body|
      next if page_id.to_s.downcase.include?('data')
      entries = top_level_entries(body)
      next if entries.empty?

      # (b) controls outside any container on a containered page --------------
      if body.include?('<GridContainer')
        entries.each do |kind, eid, _r0, _r1|
          next unless kind == :element && el_kind[eid] == 'control'
          violations << "orphan control: #{eid} sits OUTSIDE every GridContainer on page #{page_id} " \
                        '(banded page) — place it in the control band or its chart\'s container'
        end
      end

      # (c) dead-zone heuristic ------------------------------------------------
      spans = entries.map { |_k, _e, r0, r1| [r0, [r1, r0 + 1].max] }
                     .select { |r0, _r1| r0.positive? }
      next if spans.length < 2
      first = spans.map(&:first).min
      last  = spans.map(&:last).max
      total = last - first
      next if total <= 0
      covered = Array.new(total, false)
      spans.each { |r0, r1| (r0...r1).each { |r| covered[r - first] = true if r - first < total } }
      empty = covered.count(false)
      ratio = empty.to_f / total
      if ratio > DEAD_ZONE_MAX
        violations << format('dead zone: page %s has %d of %d grid rows empty between its first and ' \
                             'last element (%.0f%% > %.0f%% allowed) — close the gaps (banded layout)',
                             page_id, empty, total, ratio * 100, DEAD_ZONE_MAX * 100)
      end
    end

    violations
  end
end

if __FILE__ == $PROGRAM_NAME
  require 'json'
  abort 'usage: ruby layout_lint.rb <workbook-spec.json>' unless ARGV[0] && File.exist?(ARGV[0])
  v = LayoutLint.lint(JSON.parse(File.read(ARGV[0])))
  if v.empty?
    puts 'layout lint: clean'
  else
    warn "layout lint: #{v.size} violation(s):"
    v.each { |x| warn "  - #{x}" }
    exit 1
  end
end
