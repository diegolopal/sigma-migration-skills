# frozen_string_literal: true
# pbi_timeintel_route.rb — provenance guard for the time-intel fallback router in
# migrate-powerbi.rb.
#
# The converter turns DAX SAMEPERIODLASTYEAR / TOTALYTD measures into synthesized
# grouped elements (DateLookback / CumulativeSum). A fallback pass routes any
# REMAINING time-intel-shaped measure (one with no element of its own) to "the
# best-matching time-intel column". That pass used to scan ALL synthesized
# elements with no regard for which FACT they belong to.
#
# Live failure (KitchenSink run-2): "PY Incident Count" is a SAFETY_INCIDENTS
# measure, but the only synthesized elements were ABSENCE-derived ("YTD Absence
# Hours" / "PY Absence Hours", both sourcing ABSENCE_RECORDS View). The router
# bound the prior-year INCIDENT count to the absence-hours YTD column —
# `SAFETY_INCIDENTS.PY Incident Count -> [YTD Absence Hours/Hours YTD]` — i.e.
# semantically garbage numbers from an unrelated fact.
#
# Guard: a prior-year/YTD measure may only borrow a time-intel element built from
# its OWN fact. If no same-fact element exists, DON'T route — leave it unresolved
# so it degrades honestly into coverage.json, never cross-wired to another table.
module PbiTimeIntelRoute
  module_function

  # base fact of a synthesized time-intel element = the table its source View
  # denormalizes ("ABSENCE_RECORDS View" -> "ABSENCE_RECORDS"). A plain table name
  # passes through unchanged.
  def fact_of(view_or_table_name)
    view_or_table_name.to_s.sub(/\s+View\z/i, '').strip
  end

  # may a measure on `measure_table` borrow a time-intel element whose base fact is
  # `ti_fact`? Only when they are the SAME fact (whitespace/case-insensitive).
  def same_fact?(measure_table, ti_fact)
    a = norm(measure_table)
    b = norm(ti_fact)
    !a.empty? && a == b
  end

  def norm(str)
    str.to_s.gsub(/\s+/, '').downcase
  end
end
