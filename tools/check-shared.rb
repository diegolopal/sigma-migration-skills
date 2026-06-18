#!/usr/bin/env ruby
# frozen_string_literal: true
#
# check-shared.rb — CI gate for vendored shared infra (bead: skill-governance).
#
# Reads shared/manifest.json and asserts every declared target is byte-identical
# to its canonical copy under shared/. Exits non-zero (failing the PR) on any
# drift. Allowlisted exceptions (intentional per-tool forks) are skipped and
# reported separately. This converts the old hand-maintained "md5 discipline"
# into a mechanical gate so concurrent PRs can't silently diverge a shared lib.
#
#   ruby tools/check-shared.rb          # check; non-zero on drift
#
# Creds-free, stdlib-only — safe to run in the corpus-check workflow.

require 'json'
require 'digest'

ROOT = File.expand_path('..', __dir__)
Dir.chdir(ROOT)

manifest = JSON.parse(File.read('shared/manifest.json'))

def sha(path)
  File.exist?(path) ? Digest::SHA1.file(path).hexdigest : nil
end

drift = []      # [canonical, target, reason]
missing = []    # [canonical, target]
exceptions = [] # [target, reason]
checked = 0

manifest['shared'].each do |entry|
  canonical = entry['canonical']
  csha = sha(canonical)
  abort "FATAL: canonical missing: #{canonical}" if csha.nil?

  entry['targets'].each do |t|
    path, reason = t.is_a?(Hash) ? [t['path'], t['exception']] : [t, nil]
    if reason
      exceptions << [path, reason]
      next
    end
    tsha = sha(path)
    if tsha.nil?
      missing << [canonical, path]
    elsif tsha != csha
      drift << [canonical, path]
    end
    checked += 1
  end
end

unless exceptions.empty?
  puts "Allowlisted exceptions (not checked):"
  exceptions.each { |p, r| puts "  - #{p}\n      #{r}" }
  puts
end

if drift.empty? && missing.empty?
  puts "OK: #{checked} shared-file copies all match canonical (#{exceptions.size} allowlisted exceptions)."
  exit 0
end

puts "SHARED-LIB DRIFT DETECTED"
puts "Fix: edit the canonical copy, then run `ruby tools/sync-shared.rb`."
puts "(If a fork is intentional, add it to the target's `exception` in shared/manifest.json with a reason.)"
puts
drift.each do |c, t|
  puts "  DRIFT  #{t}"
  puts "         != #{c}"
end
missing.each do |c, t|
  puts "  MISSING #{t}  (declared target of #{c})"
end
puts
puts "drift: #{drift.size}, missing: #{missing.size}"
exit 1
