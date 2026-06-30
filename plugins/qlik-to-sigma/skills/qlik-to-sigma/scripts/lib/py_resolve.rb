# frozen_string_literal: true
#
# py_resolve.rb — find a REAL Python interpreter, robust to the Windows "Store stub".
#
# Why this exists: on Windows, bare `python` / `python3` very often resolve to the
# Microsoft Store *App Execution Alias* — a zero-byte stub under
#   %LOCALAPPDATA%\Microsoft\WindowsApps\python.exe
# that, when run non-interactively, prints nothing and exits without doing anything
# (it's designed to pop the Store UI). A script that shells out to `python3` then
# "hangs or errors silently" even though real Python is installed — exactly the
# failure a Windows user hit on the converter path. macOS/Linux don't have this, so
# there the resolver just confirms `python3` (or `python`) and returns immediately.
#
# Usage — replace a literal 'python3' in an Open3/system/spawn call with the splat:
#
#   require_relative 'lib/py_resolve'           # (or via $LOAD_PATH)
#   out, st = Open3.capture2(*PyResolve.argv, script, *args)
#   system(env, *PyResolve.argv, script, *args)
#   spawn([*PyResolve.argv, script, *args])     # build the argv list, then splat
#
# PyResolve.argv returns an ARRAY of tokens (e.g. ['python3'], ['py','-3'], or an
# absolute path) because the Windows launcher is two tokens. Resolution is memoized
# per process. Override with SIGMA_PYTHON (or PYTHON) to force a specific interpreter.
module PyResolve
  module_function

  # Cached argv array for the resolved interpreter.
  def argv
    @argv ||= resolve
  end

  # The interpreter as a single display string (for log/error messages).
  def display
    argv.join(' ')
  end

  def windows?
    # RbConfig is the reliable host check; ENV['OS'] is a cheap secondary signal.
    (RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/i) || ENV['OS'].to_s =~ /windows/i
  end

  def resolve
    # 1. Explicit override always wins (honor a full path or "py -3"-style string).
    %w[SIGMA_PYTHON PYTHON].each do |k|
      v = ENV[k].to_s.strip
      next if v.empty?
      cand = v.split(/\s+/)
      return cand if real?(cand)
      warn "WARN: #{k}=#{v.inspect} is not a runnable Python — ignoring"
    end

    candidates = []
    # 2. On Windows, the `py` launcher is the recommended, stub-proof resolver.
    candidates << %w[py -3] if windows?
    # 3. Then the usual names. On non-Windows the first hit returns instantly.
    candidates << %w[python3] << %w[python]

    candidates.each { |c| return c if real?(c) }

    # 4. Nothing usable. Return a sensible default so the caller's own error path
    #    fires with a clear message rather than us guessing.
    warn 'WARN: no real Python interpreter found (checked ' \
         "#{candidates.map { |c| c.join(' ') }.join(', ')}). " \
         'Install Python 3 or set SIGMA_PYTHON to its path. On Windows, disable the ' \
         "'python'/'python3' App Execution Aliases (Settings → Apps → Advanced app " \
         'settings → App execution aliases) or install via python.org / the `py` launcher.'
    windows? ? %w[py -3] : %w[python3]
  end

  # A candidate is "real" if `<cand> --version` runs and is NOT the Store stub.
  def real?(cand)
    require 'open3'
    out, err, st = Open3.capture3(*cand, '--version')
    return false unless st.success?
    # The stub usually fails the version check outright; belt-and-suspenders, also
    # confirm it's real Python and reject any interpreter living in WindowsApps.
    ver = "#{out}#{err}"
    return false unless ver =~ /Python\s+\d/i
    !store_stub?(cand)
  rescue StandardError
    false
  end

  # True when the interpreter resolves to the Microsoft Store execution-alias stub
  # (path under ...\WindowsApps\...). Only meaningful on Windows.
  def store_stub?(cand)
    return false unless windows?
    require 'open3'
    exe, _e, st = Open3.capture3(*cand, '-c', 'import sys; print(sys.executable)')
    return false unless st.success?
    exe.to_s.downcase.include?('windowsapps')
  rescue StandardError
    false
  end
end
