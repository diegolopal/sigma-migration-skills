# frozen_string_literal: true
#
# twb_xml.rb — Nokogiri-backed drop-in for the slice of the REXML API the
# .twb parsers use. REXML is O(n^2) on large workbooks: a 5 MB / 3.7k-column
# .twb takes >150 s in extract-calc-fields.rb (often never finishing inside an
# agent turn) where libxml2 does the same parse + walk in ~35 ms. That hang was
# the root cause of both the "10 minutes extracting calcs" stall and the
# downstream blank-page workbooks (an empty/partial calc-fields.json starves
# build-charts-from-signals.rb of the calcs its elements reference).
#
# Goal: a behavior-identical adapter so the existing parsers change by one line
# (REXML::Document.new(str) -> TwbXml.parse(str)) instead of a risky rewrite of
# the 1100-line layout parser.
#
# Covered REXML surface (everything the four .twb scripts call):
#   doc/node.elements.each('xpath') { |el| }
#   doc/node.elements['xpath-or-child-name']        -> El or nil  (first match)
#   doc/node.elements.to_a('xpath')                 -> [El, ...]
#   node.each_element('xpath') { |el| }
#   node.attributes['name'] / node.attributes       -> String|nil / attr accessor
#   node.text                                        -> text content
#   node.parent                                      -> El or nil (nil at root)
#   node.name
#
# XPath dialect note: Nokogiri (libxml2) and REXML agree on the forms these
# scripts use — a bare step ('column') selects child elements, './/x' selects
# descendants, '/workbook/...' is absolute, and '//x' is absolute-from-root
# regardless of the context node (matching REXML's behavior). So expressions
# pass through unchanged.

# Nokogiri gives O(n) parsing on large .twb files and is the normal path (the
# converter's runtime ships it). When it's absent — creds-free CI, no-egress
# stdlib-only environments — fall back to REXML: the El wrapper mirrors REXML's
# API exactly, so a real REXML::Document is a drop-in return value. REXML is
# O(n^2) on huge workbooks, but the only files parsed without Nokogiri are small
# (unit-test fixtures), so the perf cliff never bites.
begin
  require 'nokogiri'
  TWB_XML_NOKOGIRI = true
rescue LoadError
  require 'rexml/document'
  TWB_XML_NOKOGIRI = false
end

module TwbXml
  # Wraps a Nokogiri node (Element or Document) and re-exposes the REXML methods.
  class El
    attr_reader :node

    def initialize(node)
      @node = node
    end

    def elements
      Elements.new(@node)
    end

    # REXML's node.each_element(xpath) — same as elements.each.
    def each_element(xpath, &blk)
      elements.each(xpath, &blk)
    end

    # REXML's node.attributes['name'] returns the attribute String or nil.
    # Returning the underlying Nokogiri node gives us that via node['name'],
    # and also supports `a = node.attributes; a['x']` (the bare-attributes
    # assignment pattern in parse-twb-layout / scan-workbook-gaps).
    def attributes
      @node
    end

    # REXML .text returns the first character-data node, or nil when the element
    # has none (e.g. an empty <rows/>). libxml2's #content returns "" in that
    # case, so collapse "" -> nil to stay byte-identical with the REXML output
    # downstream (parse_shelf(nil) vs parse_shelf("")). Whitespace-only text is
    # preserved by both, so only the genuinely-empty case is normalized.
    def text
      t = @node.text
      t.empty? ? nil : t
    end

    def name
      @node.name
    end

    # REXML returns nil once you walk above the root element; Nokogiri's root
    # element parent is the Document, so collapse Document/nil to nil to stop
    # the ancestor walk in parse-twb-layout's story-container resolver.
    def parent
      p = @node.respond_to?(:parent) ? @node.parent : nil
      return nil if p.nil? || p.is_a?(Nokogiri::XML::Document)

      El.new(p)
    end
  end

  # Re-exposes node.elements.each / [] / to_a.
  class Elements
    def initialize(node)
      @node = node
    end

    def each(xpath)
      @node.xpath(xpath).each { |n| yield El.new(n) }
    end

    def [](xpath)
      n = @node.at_xpath(xpath)
      n && El.new(n)
    end

    def to_a(xpath)
      @node.xpath(xpath).map { |n| El.new(n) }
    end
  end

  # Drop-in replacement for REXML::Document.new(string). With Nokogiri, wrap it
  # in El (the REXML-API shim); without it, return a real REXML::Document, which
  # already exposes the same API the .twb scripts call.
  def self.parse(xml_string)
    return REXML::Document.new(xml_string) unless TWB_XML_NOKOGIRI
    El.new(Nokogiri::XML(xml_string))
  end
end
