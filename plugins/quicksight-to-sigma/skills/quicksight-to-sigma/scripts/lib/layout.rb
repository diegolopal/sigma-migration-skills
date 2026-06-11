# Layout-XML helpers. require'd by per-workbook layout configs.
#
# Container-based layouts (layout-playbook.md, verified 2026-06-10):
#   - spec side: a `kind: container` placeholder element per band
#     (container_el / header_text_el below build those spec objects)
#   - layout side: a <GridContainer> (NOT <LayoutElement type="grid">, which
#     silently drops children) whose child <LayoutElement>s use
#     CONTAINER-RELATIVE coordinates (rows restart at 1).
module SigmaLayout
  module_function

  HEADER_STYLE = { 'backgroundColor' => '#0F172A', 'borderRadius' => 'round' }.freeze
  HEADER_ROWS  = 3 # header band height in grid rows

  def gc(eid, c0, c1, r0, r1, inner)
    "<GridContainer elementId=\"#{eid}\" type=\"grid\" " \
    "gridColumn=\"#{c0} / #{c1}\" gridRow=\"#{r0} / #{r1}\" " \
    "gridTemplateColumns=\"repeat(24, 1fr)\" gridTemplateRows=\"auto\">\n#{inner}\n</GridContainer>"
  end

  def le(eid, c0, c1, r0, r1)
    "  <LayoutElement elementId=\"#{eid}\" gridColumn=\"#{c0} / #{c1}\" gridRow=\"#{r0} / #{r1}\"/>"
  end

  def page_xml(page_id, *children)
    header = "<Page type=\"grid\" gridTemplateColumns=\"repeat(24, 1fr)\" gridTemplateRows=\"auto\" id=\"#{page_id}\">"
    [header, *children.compact, "</Page>"].join("\n")
  end

  def assemble(*pages)
    %(<?xml version="1.0" encoding="utf-8"?>\n) + pages.join("\n")
  end

  # ---- container-layout helpers --------------------------------------------

  # Spec-side placeholder for a band container.
  def container_el(id, style = nil)
    el = { 'id' => id, 'kind' => 'container' }
    el['style'] = style if style
    el
  end

  # Spec-side page-title text element (white text over the dark header band).
  def header_text_el(id, title)
    { 'id' => id, 'kind' => 'text',
      'body' => %(# <span style="color: #FFFFFF">#{title}</span>) }
  end

  # Header band XML: dark full-width container at the top of the page wrapping
  # the title text (child coordinates are container-relative).
  def header_band_xml(container_id, text_id, rows: HEADER_ROWS)
    gc(container_id, 1, 25, 1, 1 + rows, le(text_id, 1, 25, 1, 1 + rows))
  end

  # Cluster placed items into horizontal bands by row overlap. Items are
  # [eid, c0, c1, r0, r1, *rest] tuples with PAGE-ABSOLUTE rows. Returns an
  # array of bands (each an array of items), top-to-bottom.
  def cluster_bands(items)
    bands = []
    items.sort_by { |i| [i[3], i[1]] }.each do |it|
      if bands.any? && it[3] < bands.last[:r1]
        bands.last[:items] << it
        bands.last[:r1] = [bands.last[:r1], it[4]].max
      else
        bands << { r0: it[3], r1: it[4], items: [it] }
      end
    end
    bands.map { |b| b[:items] }
  end

  # One band of items -> a full-width GridContainer spanning the band's row
  # range at page level, children re-emitted with CONTAINER-RELATIVE rows.
  # row_offset shifts the container's page-level position (e.g. +3 when a
  # header band was prepended above the original geometry).
  def band_container_xml(cid, items, row_offset: 0)
    r0 = items.map { |i| i[3] }.min
    r1 = items.map { |i| i[4] }.max
    inner = items.map { |i| le(i[0], i[1], i[2], i[3] - r0 + 1, i[4] - r0 + 1) }.join("\n")
    gc(cid, 1, 25, r0 + row_offset, r1 + row_offset, inner)
  end

  # Full container-banded page: header band + one container per row band.
  # Returns [page_xml_string, extra_spec_elements] — the caller must add the
  # extra elements (containers + header text) to the page's spec `elements`
  # (directly, or via put-layout.rb's <layout>.elements.json sidecar).
  # `title` of nil/empty skips the header band (e.g. when the caller bands an
  # existing title text element explicitly).
  # `header_el`: an EXISTING text element id to wrap as the header band's text
  # (e.g. the source dashboard's own title textbox — phase-e layout-quality
  # fix: a short title text left inside band 1 reads as a dead zone). It must
  # NOT also appear in `items`; the caller should recolor its body for the
  # dark band (see header_text_el's white span).
  def banded_page(page_id, items, title: nil, id_prefix: "band-#{page_id}", header_el: nil)
    extra = []
    children = []
    offset = 0
    if header_el
      hdr_id = "#{id_prefix}-hdr"
      extra << container_el(hdr_id, HEADER_STYLE.dup)
      children << header_band_xml(hdr_id, header_el)
      offset = HEADER_ROWS
    elsif title && !title.to_s.empty?
      hdr_id = "#{id_prefix}-hdr"
      txt_id = "#{id_prefix}-hdrtext"
      extra << container_el(hdr_id, HEADER_STYLE.dup)
      extra << header_text_el(txt_id, title)
      children << header_band_xml(hdr_id, txt_id)
      offset = HEADER_ROWS
    end
    top = items.map { |i| i[3] }.min
    offset += (1 - top) if top # first band starts right under the header
    cluster_bands(items).each_with_index do |band, i|
      cid = "#{id_prefix}-#{i + 1}"
      extra << container_el(cid)
      children << band_container_xml(cid, band, row_offset: offset)
    end
    [page_xml(page_id, *children), extra]
  end
end
