#!/usr/bin/env ruby
# test-intake.rb — unit test for the migration front-door (intake.rb): connection
# resolution precedence + intake.json run metadata. Offline — the /v2/connections
# listing is exercised via the --connections-fixture test seam, never the network.
# Canonical in shared/scripts (epic beads-sigma-p5y2). Run: ruby scripts/test-intake.rb
require 'json'
require 'tmpdir'
require 'rbconfig'

INTAKE = File.join(__dir__, 'intake.rb')
RUBY   = RbConfig.ruby
UUID   = '11111111-2222-3333-4444-555555555555'
UUID2  = '66666666-2222-3333-4444-555555555555'

$fail = 0
def ok(name, cond); puts((cond ? "  ok  " : "FAIL  ") + name); $fail += 1 unless cond; end

def run(dir, *args, env: {})
  # returns [exit_status, connection_hash_or_nil]
  base = { 'SIGMA_CONNECTION_ID' => nil }   # neutralize ambient env by default
  system(base.merge(env), RUBY, INTAKE, '--workdir', dir, *args, out: File::NULL, err: File::NULL)
  st = $?.exitstatus
  conn = (JSON.parse(File.read(File.join(dir, 'connection.json'))) rescue nil)
  [st, conn]
end

def fixture(dir, *conns)
  path = File.join(dir, 'fx.json')
  entries = conns.map { |id, name, type| { 'connectionId' => id, 'name' => name, 'type' => type } }
  File.write(path, JSON.generate('entries' => entries))
  path
end

# 1. explicit UUID wins
Dir.mktmpdir do |d|
  st, c = run(d, '--tool', 'tableau-to-sigma', '--mode', 'live', '--connection', UUID)
  ok('explicit UUID → exit 0', st == 0)
  ok('explicit UUID cached', c && c['connection_id'] == UUID && c['resolved_via'] == 'flag')
  intake = JSON.parse(File.read(File.join(d, 'intake.json')))
  ok('intake.json mode', intake['input_mode'] == 'live')
  ok('intake.json run_start present', !intake['run_start'].to_s.empty?)
end

# 2. malformed UUID → exit 2
Dir.mktmpdir { |d| st, _ = run(d, '--connection', 'nope'); ok('bad UUID → exit 2', st == 2) }

# 3. cached connection.json reused (no flag)
Dir.mktmpdir do |d|
  run(d, '--connection', UUID)
  st, c = run(d, '--mode', 'live')
  ok('cache reused → exit 0', st == 0)
  ok('resolved_via cache', c && c['resolved_via'] == 'cache')
end

# 4. fixture with a single connection → auto-pick
Dir.mktmpdir do |d|
  fx = fixture(d, [UUID, 'Snowflake Prod', 'snowflake'])
  st, c = run(d, '--mode', 'file', '--connections-fixture', fx)
  ok('single connection auto-picked', st == 0 && c['connection_id'] == UUID && c['resolved_via'] == 'only-connection')
end

# 5. fixture with multiple → exit 3 + candidates written, no connection.json
Dir.mktmpdir do |d|
  fx = fixture(d, [UUID, 'SF', 'snowflake'], [UUID2, 'BQ', 'bigquery'])
  st, c = run(d, '--connections-fixture', fx)
  ok('ambiguous → exit 3', st == 3)
  ok('no connection.json written when ambiguous', c.nil?)
  ok('candidates file written', File.exist?(File.join(d, 'connection-candidates.json')))
end

# 6. fixture multiple + unique --name match → auto-pick
Dir.mktmpdir do |d|
  fx = fixture(d, [UUID, 'SF', 'snowflake'], [UUID2, 'BigQuery', 'bigquery'])
  st, c = run(d, '--name', 'bigquery', '--connections-fixture', fx)
  ok('name-match auto-pick', st == 0 && c['connection_id'] == UUID2 && c['resolved_via'] == 'name-match')
end

# 7. ENV SIGMA_CONNECTION_ID used when no flag/cache/fixture
Dir.mktmpdir do |d|
  st, c = run(d, '--mode', 'both', env: { 'SIGMA_CONNECTION_ID' => UUID })
  ok('env connection used', st == 0 && c['connection_id'] == UUID && c['resolved_via'] == 'env')
end

puts $fail.zero? ? "\nall intake tests passed" : "\n#{$fail} FAILED"
exit($fail.zero? ? 0 : 1)
