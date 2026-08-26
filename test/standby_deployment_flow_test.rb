require 'test_helper'

class StandbyDeploymentFlowTest < Minitest::Test
  class RollbackRecorder
    attr_reader :action, :host

    def register(*, host: nil, &block)
      @action = block
      @host = host
    end
  end

  def test_required_credentials_fail_before_deployment
    config = configuration(
      'repmgr_password' => 'rails_credentials:postgres.repmgr_password',
      'replication_password' => 'rails_credentials:postgres.replication_password'
    )
    flow = build_flow(config)

    error = assert_raises(ActivePostgres::Error) { flow.send(:validate_specific_requirements) }

    assert_match(/Required standby secrets did not resolve/, error.message)
  end

  def test_repmgr_rollback_targets_only_the_requested_standby
    config = configuration(
      'repmgr_password' => 'secret',
      'replication_password' => 'secret'
    )
    rollback = RollbackRecorder.new
    flow = build_flow(config, rollback:)
    removed = []
    component = Object.new
    component.define_singleton_method(:uninstall_from) { |host| removed << host }

    flow.send(:register_rollback, 'repmgr', component)
    rollback.action.call

    assert_equal ['standby.example.com'], removed
    assert_nil rollback.host
  end

  private

  def configuration(secrets)
    ActivePostgres::Configuration.new(
      {
        'test' => {
          'primary' => { 'host' => 'primary.example.com' },
          'standby' => [{ 'host' => 'standby.example.com' }],
          'components' => { 'repmgr' => { 'enabled' => true } },
          'secrets' => secrets
        }
      },
      'test'
    )
  end

  def build_flow(config, rollback: Object.new)
    ActivePostgres::StandbyDeploymentFlow.new(
      config,
      standby_host: 'standby.example.com',
      ssh_executor: Object.new,
      secrets: ActivePostgres::Secrets.new(config),
      logger: ActivePostgres::Logger.new,
      rollback_manager: rollback
    )
  end
end
