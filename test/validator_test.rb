require 'test_helper'

class ValidatorHarness < ActivePostgres::Validator
  attr_reader :calls

  def initialize(config, ssh_executor)
    super
    @calls = []
  end

  def validate_configuration
    calls << :configuration
  end

  def validate_ssh_connectivity
    calls << :ssh_connectivity
  end

  def validate_network_connectivity
    calls << :network
  end

  def validate_system_requirements
    calls << :system
  end
end

class ValidatorTest < Minitest::Test
  def test_validate_all_returns_true_when_validations_pass
    validator = ValidatorHarness.new(stub_config, Object.new)

    output, = capture_io { assert validator.validate_all }
    assert_includes validator.calls, :configuration
    assert validator.calls.include?(:system)
    assert_includes output, 'Running pre-flight validation'
  end

  def test_validate_all_returns_false_when_errors_present
    validator = ValidatorHarness.new(stub_config, Object.new)
    validator.errors << 'Test error'

    capture_io do
      refute validator.validate_all
    end
  end

  def test_validate_all_prints_warnings
    validator = ValidatorHarness.new(stub_config, Object.new)
    validator.warnings << 'Test warning'

    output, = capture_io { validator.validate_all }
    assert_includes output, 'warning'
  end

  def test_validate_configuration_requires_primary_host
    config = stub_config(primary_host: nil, primary: {})
    validator = ActivePostgres::Validator.new(config, Object.new)

    validator.send(:validate_configuration)

    assert_includes validator.errors, 'Primary host not configured'
  end

  def test_validate_configuration_requires_supported_version
    config = stub_config(version: 11)
    validator = ActivePostgres::Validator.new(config, Object.new)

    validator.send(:validate_configuration)

    assert_includes validator.errors.first, 'version must be 12 or higher'
  end

  def test_validate_configuration_requires_standby_when_repmgr_enabled
    config = stub_config(
      standby_hosts: [],
      component_enabled?: ->(name) { name == :repmgr }
    )
    validator = ActivePostgres::Validator.new(config, Object.new)

    validator.send(:validate_configuration)

    assert_includes validator.errors.first, 'no standby hosts configured'
  end

  def test_validate_configuration_warns_when_replication_uses_public_host
    config = stub_config(
      primary: { 'host' => 'primary.example.com' },
      standbys: [{ 'host' => 'standby.example.com' }],
      component_enabled?: ->(name) { name == :repmgr }
    )
    validator = ActivePostgres::Validator.new(config, Object.new)

    validator.send(:validate_configuration)

    assert(validator.warnings.any? { |w| w.include?('primary.example.com') })
    assert(validator.warnings.any? { |w| w.include?('standby.example.com') })
  end

  def test_validate_ssh_connectivity_checks_all_hosts
    config = stub_config(standby_hosts: ['standby.example.com'])
    backend = Object.new
    backend.define_singleton_method(:test) { |*| true }
    calls = []

    ssh_executor = Object.new
    ssh_executor.define_singleton_method(:execute_on_host) do |host, &block|
      calls << host
      block.call(backend)
    end

    validator = ActivePostgres::Validator.new(config, ssh_executor)
    validator.send(:validate_ssh_connectivity)

    assert_equal ['primary.example.com', 'standby.example.com'], calls
  end

  def test_validate_ssh_connectivity_records_errors
    config = stub_config
    ssh_executor = Object.new
    ssh_executor.define_singleton_method(:execute_on_host) do |_host|
      raise StandardError, 'Connection refused'
    end

    validator = ActivePostgres::Validator.new(config, ssh_executor)
    validator.send(:validate_ssh_connectivity)

    assert_match(/Cannot connect/, validator.errors.first)
  end

  def test_validate_network_connectivity_uses_replication_host
    config = stub_config(
      component_enabled?: ->(name) { name == :repmgr },
      standby_hosts: ['standby.example.com']
    )
    calls = []

    ssh_executor = Object.new
    ssh_executor.define_singleton_method(:execute_on_host) do |_host, &block|
      backend = Object.new
      backend.define_singleton_method(:test) do |*args|
        calls << args
        false
      end
      backend.instance_eval(&block)
    end

    validator = ActivePostgres::Validator.new(config, ssh_executor)
    validator.send(:validate_network_connectivity)

    assert_match '10.0.0.10', validator.errors.first
    assert_equal [:ping, '-c', '1', '-W', '2', '10.0.0.10'], calls.first
  end

  def test_validate_network_connectivity_warns_when_check_fails
    config = stub_config(
      component_enabled?: ->(name) { name == :repmgr },
      standby_hosts: ['standby.example.com']
    )

    ssh_executor = Object.new
    ssh_executor.define_singleton_method(:execute_on_host) do |_host|
      raise StandardError, 'no route'
    end

    validator = ActivePostgres::Validator.new(config, ssh_executor)
    validator.send(:validate_network_connectivity)

    assert_match(/private network/, validator.warnings.first)
  end
end
