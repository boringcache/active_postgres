require 'test_helper'

class JumpHostConfigurationTest < Minitest::Test
  def test_standby_can_reference_a_declared_jump_host
    config = build_config(
      'jump_hosts' => {
        'app-oci' => { 'host' => '1.2.3.4', 'user' => 'ubuntu' }
      },
      'standby' => [
        { 'host' => '5.6.7.8', 'private_ip' => '10.0.0.11', 'jump_host' => 'app-oci' }
      ]
    )

    assert_equal '1.2.3.4', config.jump_host_config_for('5.6.7.8').fetch('host')
  end

  def test_unknown_jump_host_fails_validation
    config = build_config(
      'components' => { 'repmgr' => { 'enabled' => true } },
      'standby' => [
        { 'host' => '5.6.7.8', 'private_ip' => '10.0.0.11', 'jump_host' => 'missing' }
      ],
      'secrets' => { 'replication_password' => 'secret' }
    )

    error = assert_raises(ActivePostgres::Error) { config.validate! }

    assert_match(/jump_host not found: missing/, error.message)
  end

  def test_standby_repmgr_policy_overrides_the_cluster_default
    config = build_config(
      'components' => {
        'repmgr' => { 'enabled' => true, 'auto_failover' => true, 'priority' => 100 }
      },
      'standby' => [
        {
          'host' => 'standby.example.com',
          'private_ip' => '10.0.0.11',
          'repmgr' => { 'auto_failover' => false, 'priority' => 0 }
        }
      ]
    )

    policy = config.repmgr_config_for('standby.example.com')

    assert_equal false, policy.fetch(:auto_failover)
    assert_equal 0, policy.fetch(:priority)
  end

  private

  def build_config(overrides)
    config = {
      'test' => {
        'primary' => { 'host' => 'primary.example.com' },
        'standby' => [{ 'host' => 'standby.example.com' }],
        'components' => {},
        'secrets' => {}
      }.merge(overrides)
    }

    ActivePostgres::Configuration.new(config, 'test')
  end
end
