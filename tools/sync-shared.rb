#!/usr/bin/env ruby
# frozen_string_literal: true
#
# sync-shared.rb — propagate canonical shared infra into every plugin copy.
#
# Reads shared/manifest.json and copies each canonical file (under shared/) over
# all of its declared targets, preserving file mode (exec bits on .sh/.py).
# Allowlisted exceptions (intentional per-tool forks) are left untouched.
#
#   ruby tools/sync-shared.rb              # write changes
#   ruby tools/sync-shared.rb --dry-run    # show what WOULD change, write nothing
#
# Workflow: edit the canonical copy under shared/, run this, commit the fan-out.
# CI (tools/check-shared.rb) enforces that the fan-out actually happened.

require 'json'
require 'digest'
require 'fileutils'

ROOT = File.expand_path('..', __dir__)
Dir.chdir(ROOT)

dry = ARGV.include?('--dry-run')
manifest = JSON.parse(File.read('shared/manifest.json'))

def sha(path)
  File.exist?(path) ? Digest::SHA1.file(path).hexdigest : nil
end

changed = []
skipped_exc = []

manifest['shared'].each do |entry|
  canonical = entry['canonical']
  abort "FATAL: canonical missing: #{canonical}" unless File.exist?(canonical)
  cmode = File.stat(canonical).mode

  entry['targets'].each do |t|
    path, reason = t.is_a?(Hash) ? [t['path'], t['exception']] : [t, nil]
    if reason
      skipped_exc << path
      next
    end
    next if sha(path) == sha(canonical) # already in sync
    changed << [canonical, path]
    next if dry
    FileUtils.mkdir_p(File.dirname(path))
    FileUtils.cp(canonical, path)
    File.chmod(cmode, path)
  end
end

if changed.empty?
  puts "Already in sync — nothing to #{dry ? 'change' : 'write'}. (#{skipped_exc.size} exceptions skipped)"
  exit 0
end

puts(dry ? "Would update #{changed.size} file(s):" : "Updated #{changed.size} file(s):")
changed.each { |c, t| puts "  #{dry ? '~' : '✓'} #{t}  <- #{c}" }
puts "Skipped #{skipped_exc.size} allowlisted exception(s)." unless skipped_exc.empty?
puts
puts "Next: review the diff and commit. CI will verify with tools/check-shared.rb." unless dry
