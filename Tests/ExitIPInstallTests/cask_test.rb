# frozen_string_literal: true

# Evaluate declarations only. Never call Homebrew, sudo, or the captured shell script.
class StepCapture
  attr_reader :runs

  def initialize
    @runs = []
  end

  def run(command, args: [], **options)
    @runs << [command, args, options]
  end

  def method_missing(name, *)
    raise "Unexpected install step: #{name}"
  end

  def respond_to_missing?(*); true; end
end

class CaskCapture
  attr_reader :uninstall_options, :preflight, :postflight

  def initialize
    @preflight = StepCapture.new
    @postflight = StepCapture.new
  end

  def appdir; "/Applications"; end
  def version(value = nil); value || "1.0"; end
  def uninstall(**options); @uninstall_options = options; end
  def preflight_steps(&block); @preflight.instance_eval(&block); end
  def postflight_steps(&block); @postflight.instance_eval(&block); end
  def method_missing(*); nil; end
  def respond_to_missing?(*); true; end
end

def cask(_token, &block)
  $capture = CaskCapture.new
  $capture.instance_eval(&block)
end

load ARGV.fetch(0)
raise "Install must not perform setup" unless $capture.postflight.runs.empty?
# Only Sleepless's app-scoped recovery, on the staged copy and without sudo: a failed signature
# check aborts the install, and quarantine is never removed from anything else.
staged = "{{staged_path}}/ExitIPMonitor.app"
release = [
  ["/usr/bin/codesign", ["--verify", "--deep", "--strict", staged], {}],
  ["/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged], {}],
]
raise "Preflight must only verify, then release this app's quarantine" unless $capture.preflight.runs == release
script = $capture.uninstall_options.fetch(:script)
raise "Cleanup failure must stop uninstall" unless script.fetch(:must_succeed)
raise "Whole cleanup must not run as root" if script[:sudo]
raise "Wrong interpreter" unless script.fetch(:executable) == "/bin/bash"
arguments = script.fetch(:args)
raise "Missing independent cleanup" unless arguments[1].include?('cleanup_main --app "$1"')
raise "Wrong target" unless arguments.last == "/Applications/ExitIPMonitor.app"
raise "No graceful quit" unless $capture.uninstall_options[:quit] == "com.example.exitipmonitor"
puts "PASS: cask releases only the verified staged app's quarantine, sets up no provider, " \
     "and requires external cleanup after graceful quit"
