#!/usr/bin/env ruby
# frozen_string_literal: true
#
# probe-control-formula.rb — live evidence that a spec-authored calc column
# CAN read a page control's value in a formula, and proof of the two ways it
# fails. OPTIONAL diagnostic (like probe-controls.rb) — run it when you want to
# confirm the control-value-in-formula rules on the current org rather than
# trust the doc.
#
# Motivation: migrated dashboards that use a source parameter INSIDE a
# calculated field (Tableau [Parameters].[X] in a calc, PBI slicer-driven
# measures, Qlik variable refs) get converted to a Sigma control + a calc
# column that reads it. Agents repeatedly get `#ERROR` cells here and wrongly
# conclude "controls can't be referenced in formulas," then delete the
# controls. This probe pins down what actually happens:
#
#   [<controlId>]        -> RESOLVES to the control's value        (use the handle)
#   [<elementId>]        -> "Unknown column"                       (id is not the handle)
#   [<dateRangeCtl>] + 1 -> "Expected number; received variant"    (type mismatch, not inert)
#   Text([<ctl>]), If([<ctl>]=[<ctl>],1,0) -> RESOLVE               (type-appropriate use)
#
# It builds a throwaway workbook (warehouse source + a control both cloned from
# a real workbook in the org so conn/path/fields are valid), exports the table
# element, and prints resolved-value-vs-#ERROR per candidate formula, then
# deletes the workbook (KEEP=1 to keep it).
#
# Usage:  ruby scripts/probe-control-formula.rb
# Env:    SIGMA_BASE_URL, SIGMA_CLIENT_ID, SIGMA_CLIENT_SECRET (see sigma-api).
# Exit:   0 if the controlId reference resolved; 1 otherwise.

require 'json'
require 'csv'
require 'net/http'
require 'uri'

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'sigma_rest'

def jget(path); Sigma.request(:get, path); end

# recursively find a warehouse-table node {connectionId, path}
def find_wh(node)
  case node
  when Hash
    return { connectionId: node['connectionId'], path: node['path'] } \
      if node['kind'] == 'warehouse-table' && node['connectionId'] && node['path'].is_a?(Array)
    node.each_value { |v| r = find_wh(v); return r if r }
  when Array
    node.each { |v| r = find_wh(v); return r if r }
  end
  nil
end

# recursively collect all control elements
def all_ctls(node, acc = [])
  case node
  when Hash
    acc << node if node['kind'] == 'control' && node['controlType']
    node.each_value { |v| all_ctls(v, acc) }
  when Array
    node.each { |v| all_ctls(v, acc) }
  end
  acc
end

def export_csv(wb, element_id, timeout = 90)
  body = { 'elementId' => element_id, 'format' => { 'type' => 'csv' } }
  res = Sigma.request(:post, "/v2/workbooks/#{wb}/export", body: JSON.generate(body))
  qid = res.is_a?(Hash) && res['queryId']
  raise "export request failed: #{res.inspect}" unless qid
  deadline = Time.now + timeout
  loop do
    uri = URI("#{Sigma.base_url}/v2/query/#{qid}/download")
    req = Net::HTTP::Get.new(uri); req['Authorization'] = "Bearer #{Sigma.auth_token}"
    r = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 60) { |h| h.request(req) }
    return r.body if r.code.to_i == 200
    raise "download HTTP #{r.code}: #{r.body.to_s[0, 300]}" if r.code.to_i >= 400 && r.code.to_i != 404
    raise "export timeout (#{qid})" if Time.now > deadline
    sleep 2
  end
end

# --- discover home folder + schemaVersion + a real source & control ----------
me  = (jget('/v2/whoami') rescue nil)
uid = me && me['userId']
mem = uid ? (jget("/v2/members/#{uid}") rescue nil) : nil
home = [me, mem].compact.map { |h| h['homeFolderId'] || h['homeFolder'] }.compact.first
abort 'no home folder resolvable' unless home

wbs = jget('/v2/workbooks?limit=50')
entries = wbs['entries'] || wbs['workbooks'] || []
abort 'no workbooks to borrow schemaVersion/source/control from' if entries.empty?

schema_version = nil
src = nil
ctl_sample = nil
scalar_types = %w[checkbox switch number text]
entries.each do |w|
  wid = w['workbookId'] || w['id']
  next unless wid
  spec = (Sigma.request(:get, "/v2/workbooks/#{wid}/spec", accept: 'application/json') rescue next)
  next unless spec.is_a?(Hash) && spec['schemaVersion']
  schema_version ||= spec['schemaVersion']
  ctls = all_ctls(spec)
  scalar = ctls.find { |c| scalar_types.include?(c['controlType']) }
  ctl_sample = scalar if scalar && (ctl_sample.nil? || !scalar_types.include?(ctl_sample['controlType']))
  ctl_sample ||= ctls.first
  wh = find_wh(spec)
  src ||= wh
  schema_version = spec['schemaVersion'] if wh
  break if src && ctl_sample && scalar_types.include?(ctl_sample['controlType'])
end
abort 'could not find a warehouse-table source in any workbook' unless src
abort 'could not find a control element to clone' unless ctl_sample
puts "source: conn=#{src[:connectionId]} path=#{src[:path].inspect}"
puts "control cloned: type=#{ctl_sample['controlType']}"

# --- build the probe workbook ------------------------------------------------
tbl_id  = 'tbl-probe'
ctl_id  = 'ctl-probe'
ctl_hdl = 'ProbeCtl'
candidates = {
  'ref_by_controlId' => "[#{ctl_hdl}]",                        # the handle — should resolve
  'ref_by_elementId' => "[#{ctl_id}]",                         # the element id — should NOT
  'coerced_to_text'  => "Text([#{ctl_hdl}])",                  # type-safe consume
  'used_in_predicate'=> "If([#{ctl_hdl}] = [#{ctl_hdl}], 1, 0)", # comparison context
  'used_in_arith'    => "[#{ctl_hdl}] + 1",                    # numeric context (variant if non-numeric ctl)
}
calc_cols = candidates.map { |cid, f| { 'id' => cid, 'name' => cid, 'formula' => f } }

ctl_el = ctl_sample.dup
ctl_el['id'] = ctl_id
ctl_el['controlId'] = ctl_hdl
ctl_el['name'] = 'Probe'
ctl_el.delete('filters')
ctl_el.delete('source')

spec = {
  'name' => "ZZ probe-control-formula (throwaway)",
  'folderId' => home, 'schemaVersion' => schema_version,
  'description' => 'throwaway: control-value-in-formula probe',
  'pages' => [{
    'id' => 'pg-1', 'name' => 'Probe',
    'elements' => [
      { 'kind' => 'table', 'id' => tbl_id, 'name' => 'Probe',
        'source' => { 'kind' => 'warehouse-table',
                      'connectionId' => src[:connectionId], 'path' => src[:path] },
        'columns' => calc_cols },
      ctl_el,
    ],
  }],
}

resp = Sigma.request(:post, '/v2/workbooks/spec', body: JSON.generate(spec),
                     content_type: 'application/json', accept: 'application/json')
wb = resp['workbookId'] || resp['id']
abort "CREATE failed: #{resp.inspect}" unless wb
puts "created throwaway workbook #{wb}"

ok = true
begin
  csv = CSV.parse(export_csv(wb, tbl_id), headers: true)
  row = csv.first
  puts "\n%-20s %s" % ['FORMULA COLUMN', 'FIRST-ROW RESULT']
  candidates.each_key do |cid|
    val = row && (row[cid] rescue nil)
    puts format('%-20s %s', cid, val.inspect)
  end
  handle_val = row && row['ref_by_controlId']
  ok = !handle_val.nil? && !handle_val.to_s.start_with?('Unknown column', 'Argument')
rescue StandardError => e
  puts "EXPORT ERROR: #{e.message[0, 400]}"
  ok = false
ensure
  if ENV['KEEP'] == '1'
    puts "\nkept workbook #{wb}"
  else
    Sigma.request(:delete, "/v2/files/#{wb}", accept: 'application/json') rescue nil
    puts "\ndeleted throwaway workbook #{wb}"
  end
end

puts ok ? "\nPASS — [controlId] reference resolved in a calc column" \
        : "\nFAIL — [controlId] reference did not resolve (see output)"
exit(ok ? 0 : 1)
