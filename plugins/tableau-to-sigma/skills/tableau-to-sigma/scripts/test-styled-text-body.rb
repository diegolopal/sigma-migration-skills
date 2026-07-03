#!/usr/bin/env ruby
# Unit test for the B4 (gap ubr5.8) text-body assembler in
# build-charts-from-signals.rb: `text_body_from_runs`, which turns Tableau
# formatted-text runs (parse-twb-layout `text_runs`) into a Sigma text.body —
# color/font-size spans + **bold**, Æ-break paragraphs, center/right <p>
# wrappers, pill background spans, dynamic-token stripping. Extracted as a
# top-level pure def (SRC.match, same pattern as test-control-display-type.rb /
# test-theme-derivation.rb) so no data-pipeline inputs are needed.
#
# Usage:  ruby scripts/test-styled-text-body.rb

require 'json'

DIR = __dir__
SRC = File.read(File.join(DIR, 'build-charts-from-signals.rb'))
m = SRC.match(/^def text_body_from_runs\b.*?\n^end$/m) or
  abort 'could not extract text_body_from_runs from build-charts-from-signals.rb'
eval(m[0])

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# ---- 1. nil / empty ---------------------------------------------------------
check(text_body_from_runs(nil).nil?, 'nil runs → nil', fails)
check(text_body_from_runs([]).nil?, 'empty runs → nil', fails)
check(text_body_from_runs([{ 'text' => '   ' }]).nil?,
      'whitespace-only single run → nil (nothing visible)', fails)

# ---- 2. single styled run → one span with color + font-size + bold ---------
b = text_body_from_runs([{ 'text' => 'Job Losses', 'color' => '#1b1b1b', 'font_size' => 24, 'bold' => true }])
check(b == '<span style="color: #1b1b1b; font-size: 24px">**Job Losses**</span>',
      "single run → color+size span with **bold** (got #{b.inspect})", fails)

# ---- 3. run with no attrs → plain text (no empty span) ---------------------
check(text_body_from_runs([{ 'text' => 'plain' }]) == 'plain',
      'attribute-free run → bare text, no empty span', fails)

# ---- 4. Æ+whitespace spacer kept literal; hard break → \n\n paragraphs ------
runs = [
  { 'text' => 'Job Losses', 'color' => '#1b1b1b', 'bold' => true },
  { 'text' => ' ', 'bold' => true },                    # Æ+whitespace spacer
  { 'text' => 'from Deportations', 'font_size' => 12 },
  { 'text' => "\n", 'break' => true },                  # hard break
  { 'text' => 'Estimating the job loss.', 'color' => '#333333' }
]
b = text_body_from_runs(runs)
check(b.include?('**Job Losses**</span> <span style="font-size: 12px">from Deportations</span>'),
      "spacer keeps literal space between runs (got #{b.inspect})", fails)
check(b.split("\n\n").length == 2 && b.split("\n\n").last.include?('Estimating'),
      'hard-break run splits body into two paragraphs (\n\n)', fails)

# ---- 4b. bold markers hug the text — leading/trailing space stays OUTSIDE --
# (markdown won't bold "** Rank**"; the space must be outside the **).
b = text_body_from_runs([{ 'text' => ' Rank', 'bold' => true }])
check(b == ' **Rank**', "bold run with a leading space → ' **Rank**' not '** Rank**' (got #{b.inspect})", fails)

# ---- 5. HTML in run text is escaped (can't inject markup) ------------------
b = text_body_from_runs([{ 'text' => 'a < b & c > d' }])
check(b == 'a &lt; b &amp; c &gt; d', "raw <, &, > escaped (got #{b.inspect})", fails)

# ---- 6. dynamic Tableau tokens stripped ------------------------------------
b = text_body_from_runs([{ 'text' => 'The <[Parameters].[Parameter 3]> states', 'color' => '#333333' }])
check(b && !b.include?('[Parameter') && b.include?('The ') && b.include?('states'),
      "dynamic <[Parameters]…> token dropped, surrounding text kept (got #{b.inspect})", fails)

# ---- 7. center align → <p style="text-align: center"> wrapper --------------
b = text_body_from_runs([{ 'text' => 'Learn More', 'bold' => true }], align: 'center')
check(b == '<p style="text-align: center">**Learn More**</p>',
      "center align wraps in <p> (got #{b.inspect})", fails)
# left align is Sigma's default and 400s if forced → never wrapped
check(!text_body_from_runs([{ 'text' => 'x' }], align: 'left').include?('<p'),
      'left align is NOT wrapped in <p> (Sigma default; forcing it 400s)', fails)

# ---- 8. pill background span wraps content INSIDE the <p> (valid nesting) ---
b = text_body_from_runs([{ 'text' => 'Learn More', 'bold' => true }], align: 'center', bg: '#fbe7a8')
check(b == '<p style="text-align: center"><span style="background-color: #fbe7a8">**Learn More**</span></p>',
      "pill: bg span nests inside the align <p> (got #{b.inspect})", fails)

puts
if fails.empty?
  puts 'ALL PASS — B4 text_body_from_runs'
  exit 0
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
