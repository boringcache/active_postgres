require 'test_helper'

class HealthCheckerTest < Minitest::Test
  def setup
    @original_mode = ENV['ACTIVE_POSTGRES_STATUS_MODE']
  end

  def teardown
    ENV['ACTIVE_POSTGRES_STATUS_MODE'] = @original_mode
  end

  def test_uses_direct_executor_for_localhost
    ENV['ACTIVE_POSTGRES_STATUS_MODE'] = nil
    config = stub_config(primary_host: 'localhost', primary: { 'host' => 'localhost' })
    checker = ActivePostgres::HealthChecker.new(config)

    assert_kind_of ActivePostgres::DirectExecutor, checker.executor
  end

  def test_uses_ssh_executor_for_remote_host
    ENV['ACTIVE_POSTGRES_STATUS_MODE'] = nil
    config = stub_config(primary_host: '1.2.3.4', primary: { 'host' => '1.2.3.4' })
    checker = ActivePostgres::HealthChecker.new(config)

    assert_kind_of ActivePostgres::SSHExecutor, checker.executor
  end

  def test_env_override_forces_direct
    ENV['ACTIVE_POSTGRES_STATUS_MODE'] = 'direct'
    config = stub_config(primary_host: '1.2.3.4', primary: { 'host' => '1.2.3.4' })
    checker = ActivePostgres::HealthChecker.new(config)

    assert_kind_of ActivePostgres::DirectExecutor, checker.executor
  end

  def test_env_override_forces_ssh
    ENV['ACTIVE_POSTGRES_STATUS_MODE'] = 'ssh'
    config = stub_config(primary_host: 'localhost', primary: { 'host' => 'localhost' })
    checker = ActivePostgres::HealthChecker.new(config)

    assert_kind_of ActivePostgres::SSHExecutor, checker.executor
  end
end
