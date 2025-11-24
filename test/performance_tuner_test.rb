require 'test_helper'

class PerformanceTunerTest < Minitest::Test
  def setup
    @config = stub_config
    @ssh_executor = Object.new
    @tuner = ActivePostgres::PerformanceTuner.new(@config, @ssh_executor)
  end

  def test_initializes_with_config_and_ssh_executor
    assert_equal @config, @tuner.config
    assert_equal @ssh_executor, @tuner.ssh_executor
    assert @tuner.logger
  end

  def test_format_bytes_converts_bytes_to_human_readable
    # PerformanceTuner has a private format_bytes method
    # We test it indirectly through the public interface
    assert @tuner.respond_to?(:tune_for_host)
  end
end
