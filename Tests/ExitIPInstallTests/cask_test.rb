# frozen_string_literal: true

# Evaluate declarations only. Never call Homebrew, sudo, or the captured shell script.
class CaskCapture
  attr_reader :uninstall_options, :install_steps

  def initialize
    @install_steps = []
  end

  def appdir; "/Applications"; end
  def version(value = nil); value || "1.0"; end
  def uninstall(**options); @uninstall_options = options; end
  def postflight_steps(&block); @install_steps << block; end
  def preflight_steps(&block); @install_steps << block; end
  def method_missing(*); nil; end
  def respond_to_missing?(*); true; end
end

def cask(_token, &block)
  $capture = CaskCapture.new
  $capture.instance_eval(&block)
end

load ARGV.fetch(0)
raise "Install must not perform setup" unless $capture.install_steps.empty?
script = $capture.uninstall_options.fetch(:script)
raise "Cleanup failure must stop uninstall" unless script.fetch(:must_succeed)
raise "Whole cleanup must not run as root" if script[:sudo]
raise "Wrong interpreter" unless script.fetch(:executable) == "/bin/bash"
arguments = script.fetch(:args)
raise "Missing independent cleanup" unless arguments[1].include?('cleanup_main --app "$1"')
raise "Wrong target" unless arguments.last == "/Applications/ExitIPMonitor.app"
raise "No graceful quit" unless $capture.uninstall_options[:quit] == "com.example.exitipmonitor"
puts "PASS: cask installs only the app and requires external cleanup after graceful quit"
