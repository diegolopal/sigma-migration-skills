# frozen_string_literal: true
# pbi_element_match.rb — pair each converter element to its posted-DM (readback)
# element when deriving the master-map in migrate-powerbi.rb.
#
# WHY THIS IS NOT A SIMPLE POSITIONAL MATCH: a DM POST does NOT preserve element
# order. It floats NAMELESS Custom SQL elements (rule 3 omits their `name`) to the
# FRONT of the readback. A raw positional index (`dm_elements[i]`) is therefore
# unsafe for a nameless converter element: it grabs whatever NAMED element now
# sits at that shifted index, and the master-builder then OVERWRITES that named
# master with the SQL element's columns.
#
# Live failure (KitchenSink, contract run-2): the nameless DimDate spine sat at
# converter idx 3, but POST moved it to readback idx 0, shifting SAFETY_INCIDENTS
# down into idx 3. The nameless element positional-matched idx 3 = SAFETY_INCIDENTS
# and overwrote its 8 base columns with 4 date-hierarchy cols → workbook POST
# "Dependency not found: 'safety_incidents/year'" (and the dependent KPI/table refs).
#
# The fix, encapsulated here: match nameless-to-nameless. Named converter elements
# bind by NAME (POST/PUT keep names; only ids churn); nameless converter elements
# consume the readback's nameless elements IN ORDER and never claim a named one.
module PbiElementMatch
  module_function

  # conv_elements : the converter's elements, in converter order.
  # dm_elements   : the posted-DM readback elements (REORDERED by POST).
  # Returns an Array aligned to conv_elements: dmel_for[i] is the readback element
  # that converter element i maps to (may be nil only if the readback is emptier
  # than the converter output, which never happens for a successful POST).
  def pair(conv_elements, dm_elements)
    conv_elements ||= []
    dm_elements   ||= []
    nameless_readback = dm_elements.select { |e| nameless?(e) }
    nameless_cursor = 0
    conv_elements.each_with_index.map do |cel, idx|
      cname = cel && cel['name']
      if cname && !cname.to_s.empty?
        # named: by NAME first, then by ID, then positionally (named elements keep
        # their relative order across the POST).
        dm_elements.find { |e| e['name'] == cname } ||
          dm_elements.find { |e| e['id'] == cel['id'] } ||
          dm_elements[idx] || dm_elements.first
      else
        # nameless (Custom SQL): the next unclaimed nameless readback element —
        # NEVER a named element via a stale positional index.
        dmel = nameless_readback[nameless_cursor]
        nameless_cursor += 1
        dmel || (cel && dm_elements.find { |e| e['id'] == cel['id'] }) ||
          dm_elements[idx] || dm_elements.first
      end
    end
  end

  def nameless?(el)
    el.nil? || el['name'].nil? || el['name'].to_s.empty?
  end
end
