#!/usr/bin/env ruby
# frozen_string_literal: true
#
# record-visual-check.rb — record the outcome of the MANDATORY Phase 6f
# full-dashboard source-vs-target visual comparison into parity-final.json, so
# assert-phase6-ran.rb gate 8b (--require-visual-comparison) can confirm the
# comparison actually happened instead of trusting a prose "I looked at it".
#
# Run this AFTER you have rendered the Sigma page (sigma-export-png.py) AND read
# it side-by-side against the source dashboard PNG (Tableau MCP get-view-image):
#
#   ruby scripts/record-visual-check.rb --workdir /tmp/<name> \
#     --verdict pass            --notes "matches source; KPI row + 3 trend tiles aligned"
#   ruby scripts/record-visual-check.rb --workdir /tmp/<name> \
#     --verdict divergent       --notes "Region bar truncated vs source — fixing"  [--screenshot <png>]
#
# It does NOT judge for you — it records the verdict YOU reached. `pass` stamps
# visual_checked:true; `divergent` records the gap (visual_checked stays false so
# the gate still blocks until you fix + re-record `pass`).
require 'json'
require 'optparse'

opts = {}
OptionParser.new do |p|
  p.on('--workdir DIR')   { |v| opts[:dir] = v }
  p.on('--verdict V', %w[pass divergent], "pass = render matches the source; divergent = a gap remains (gate stays blocked)") { |v| opts[:verdict] = v }
  p.on('--notes S')       { |v| opts[:notes] = v }
  p.on('--screenshot P')  { |v| opts[:shot] = v }
end.parse!

abort 'FATAL: --workdir required' unless opts[:dir]
abort 'FATAL: --verdict pass|divergent required' unless opts[:verdict]
path = File.join(opts[:dir], 'parity-final.json')
abort "FATAL: #{path} not found — run phase6-parity.rb --finalize first (the visual check records onto the parity result)." unless File.exist?(path)

s = JSON.parse(File.read(path))
s['visual_verdict']  = opts[:verdict]
s['visual_notes']    = opts[:notes] if opts[:notes]
s['visual_checked']  = (opts[:verdict] == 'pass')
s['screenshot_path'] = opts[:shot] if opts[:shot]
File.write(path, JSON.pretty_generate(s))

if opts[:verdict] == 'pass'
  puts "[OK] recorded visual comparison: PASS#{opts[:notes] ? " — #{opts[:notes]}" : ''}"
  puts "     parity-final.json now satisfies assert-phase6-ran.rb gate 8b."
else
  puts "[RECORDED] visual comparison: DIVERGENT#{opts[:notes] ? " — #{opts[:notes]}" : ''}"
  warn "     visual_checked stays FALSE — gate 8b (--require-visual-comparison) will still BLOCK."
  warn '     Fix the divergence, re-render, re-read, then re-run with --verdict pass.'
end
