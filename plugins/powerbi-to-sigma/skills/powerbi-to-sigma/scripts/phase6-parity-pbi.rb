#!/usr/bin/env ruby
# phase6-parity-pbi.rb — Power BI executeQueries(DAX) adapter for Phase 6 parity.
#
# tableau-to-sigma's phase6 compares Sigma chart values against Tableau view
# CSVs. For Power BI the source-of-truth values come from the live semantic
# model via executeQueries (DAX). This script is the PBI-side adapter that
# produces the `expected` half of the parity plan; it reuses the shared
# verify-parity.rb comparison engine for the actual diff.
#
# Two passes (mirrors phase6-parity.rb):
#
# PASS 1 (--emit-dax): given a chart→DAX map, run executeQueries for each chart
#   via the Python harness (pbi_exec.py, written next to this script using the
#   cached Fabric/Power BI token) and write a parity plan with `expected` rows.
#   Also prints the per-chart MCP query the agent should run to collect Sigma
#   actuals, then re-invoke with --finalize.
#
# PASS 2 (--finalize --actuals ...): inject the Sigma actuals and run
#   verify-parity.rb. Writes parity-final.json (the assert-phase6-ran sentinel).
#
# chart-dax.json shape (the agent authors this — one DAX EVALUATE per Sigma chart):
#   { "<Sigma chart name>": {
#       "dax": "EVALUATE SUMMARIZECOLUMNS(EMPLOYEES[DEPARTMENT],\"HC\",[Headcount]) ORDER BY [HC] DESC",
#       "dim_col": "EMPLOYEES[DEPARTMENT]",   # which result column is the dimension
#       "val_col": "[HC]"                      # which is the measure
#     }, ... }
# For single-value charts (KPIs) set dim_col to null; the row becomes [["", val]].
#
# Usage:
#   ruby scripts/phase6-parity-pbi.rb --emit-dax \
#     --workspace <wsId> --dataset <datasetId> \
#     --chart-dax /tmp/pbir/chart-dax.json \
#     --workbook-id <sigmaWbId> \
#     --out /tmp/pbir/parity-plan.json
#
#   ruby scripts/phase6-parity-pbi.rb --finalize \
#     --plan /tmp/pbir/parity-plan.json \
#     --actuals /tmp/pbir/parity-actuals.json \
#     --out-dir /tmp/pbir [--extract-mode --extract-tol 0.02]
#
# Env (finalize): SIGMA_BASE_URL + SIGMA_API_TOKEN are NOT needed here (Sigma
# values arrive via --actuals from the agent's MCP queries).

require 'json'
require 'optparse'
require 'open3'
require 'time'

opts = { extract: false, tol: 0.02 }
OptionParser.new do |p|
  p.on('--emit-dax')            { opts[:emit] = true }
  p.on('--finalize')            { opts[:finalize] = true }
  p.on('--workspace ID')        { |v| opts[:ws] = v }
  p.on('--dataset ID')          { |v| opts[:ds] = v }
  p.on('--chart-dax PATH')      { |v| opts[:cdax] = v }
  p.on('--workbook-id ID')      { |v| opts[:wb] = v }
  p.on('--plan PATH')           { |v| opts[:plan] = v }
  p.on('--actuals PATH')        { |v| opts[:actuals] = v }
  p.on('--out PATH')            { |v| opts[:out] = v }
  p.on('--out-dir DIR')         { |v| opts[:outdir] = v }
  p.on('--extract-mode')        { opts[:extract] = true }
  p.on('--extract-tol F', Float){ |v| opts[:tol] = v }
end.parse!

HERE = File.expand_path(__dir__)
HARNESS = File.join(HERE, 'pbi_exec.py')

# Self-contained Python executeQueries harness (uses the cached Power BI token).
# Written once; idempotent. Power BI-audience scope is mandatory for
# executeQueries (Fabric-audience tokens are rejected by api.powerbi.com).
HARNESS_SRC = <<~PY
  import truststore; truststore.inject_into_ssl()
  import sys, os, json, msal, requests
  CACHE="/tmp/pbiauth/cache.bin"
  cache=msal.SerializableTokenCache()
  if os.path.exists(CACHE): cache.deserialize(open(CACHE).read())
  app=msal.PublicClientApplication("ea0616ba-638b-4df5-95b9-636659ae5121",
      authority="https://login.microsoftonline.com/organizations", token_cache=cache)
  SCOPE=["https://analysis.windows.net/powerbi/api/.default"]
  tok=None
  for a in app.get_accounts():
      r=app.acquire_token_silent(SCOPE, account=a)
      if r and "access_token" in r: tok=r["access_token"]; break
  if not tok:
      flow=app.initiate_device_flow(scopes=SCOPE)
      print(">>> "+flow["verification_uri"]+" code "+flow["user_code"], file=sys.stderr)
      tok=app.acquire_token_by_device_flow(flow).get("access_token")
  if cache.has_state_changed: open(CACHE,"w").write(cache.serialize())
  assert tok, "no powerbi token"
  WS, DS = sys.argv[1], sys.argv[2]
  spec=json.load(sys.stdin)   # {name:{dax,dim_col,val_col}}
  URL=f"https://api.powerbi.com/v1.0/myorg/groups/{WS}/datasets/{DS}/executeQueries"
  out={}
  for name, q in spec.items():
      r=requests.post(URL, headers={"Authorization":f"Bearer {tok}"},
          json={"queries":[{"query":q["dax"]}],"serializerSettings":{"includeNulls":True}})
      if r.status_code!=200:
          out[name]={"error":r.text[:300]}; continue
      rows=r.json()["results"][0]["tables"][0]["rows"]
      dim, val = q.get("dim_col"), q.get("val_col")
      pairs=[]
      for row in rows:
          d = "" if not dim else row.get(dim)
          v = row.get(val) if val else None
          pairs.append([d, v])
      out[name]=pairs
  json.dump(out, sys.stdout)
PY

def write_harness
  File.write(HARNESS, HARNESS_SRC) unless File.exist?(HARNESS) && File.read(HARNESS) == HARNESS_SRC
end

if opts[:emit]
  %i[ws ds cdax wb out].each { |k| abort("missing --#{k}") unless opts[k] }
  write_harness
  chart_dax = JSON.parse(File.read(opts[:cdax]))
  # Find python (needs truststore+msal): $PBI_PY, else the legacy /tmp/pbiauth
  # venv, else python3 (bead 7o01 — see scripts/requirements.txt / run.sh bootstrap).
  py = ENV['PBI_PY'] ||
       (File.exist?('/tmp/pbiauth/bin/python') ? '/tmp/pbiauth/bin/python' : 'python3')
  out, err, st = Open3.capture3(py, HARNESS, opts[:ws], opts[:ds], stdin_data: JSON.dump(chart_dax))
  warn err unless err.empty?
  abort('executeQueries harness failed') unless st.success?
  expected = JSON.parse(out)
  charts = chart_dax.keys.map do |name|
    exp = expected[name]
    if exp.is_a?(Hash) && exp['error']
      warn "  [DAX ERROR] #{name}: #{exp['error']}"
      exp = []
    end
    { 'chart' => name, 'expected' => exp, 'workbook_id' => opts[:wb] }
  end
  plan = { 'extract' => opts[:extract], 'charts' => charts }
  File.write(opts[:out], JSON.pretty_generate(plan))
  warn "[phase6-pbi] wrote plan with PBI `expected` rows -> #{opts[:out]}"
  puts "=" * 70
  puts "PHASE 6 (PBI) — collect Sigma actuals, one MCP query per chart:"
  puts "=" * 70
  charts.each_with_index do |c, i|
    puts "  [#{i + 1}/#{charts.size}] #{c['chart']}  (expected #{c['expected'].size} row(s) from DAX)"
  end
  puts ""
  puts "Save actuals to parity-actuals.json: { \"<chart name>\": [[dim,val],...] }"
  puts "Then: ruby scripts/phase6-parity-pbi.rb --finalize --plan #{opts[:out]} \\"
  puts "        --actuals <actuals> --out-dir <dir>#{opts[:extract] ? ' --extract-mode --extract-tol ' + opts[:tol].to_s : ''}"
  exit 0
end

if opts[:finalize]
  %i[plan actuals outdir].each { |k| abort("missing --#{k}") unless opts[k] }
  plan = JSON.parse(File.read(opts[:plan]))
  actuals = JSON.parse(File.read(opts[:actuals]))
  plan['charts'].each do |c|
    a = actuals[c['chart']]
    c['actual'] = { 'rows' => a } if a
  end
  File.write(opts[:plan], JSON.pretty_generate(plan))
  args = ['ruby', File.join(HERE, 'verify-parity.rb'), '--plan', opts[:plan]]
  args.concat(['--extract-mode', '--extract-tol', opts[:tol].to_s]) if opts[:extract]
  out, err, st = Open3.capture3(*args)
  puts out
  warn err unless err.empty?
  # assert-phase6-ran.rb sentinel
  total = plan['charts'].size
  passed = out.scan(/^PASS\s+\[[^\]]+\]\s+(.+)$/).flatten
  failed = out.scan(/^DIVERGE\s+\[[^\]]+\]\s+(.+)$/).flatten
  summary = {
    'workbook_id' => plan.dig('charts', 0, 'workbook_id'),
    'ran_at' => Time.now.utc.iso8601,
    'source' => 'powerbi-executequeries',
    'mode' => opts[:extract] ? 'extract' : 'strict',
    'charts_total' => total, 'charts_pass' => passed.size, 'charts_fail' => failed.size,
    'pass_names' => passed, 'fail_names' => failed,
    'status' => (st.success? && total > 0 && passed.size == total) ? 'PASS' : 'FAIL'
  }
  File.write(File.join(opts[:outdir], 'parity-final.json'), JSON.pretty_generate(summary))
  warn "[phase6-pbi] wrote parity-final.json (status=#{summary['status']} #{passed.size}/#{total})"
  exit(st.success? ? 0 : 2)
end

abort('specify --emit-dax or --finalize')
