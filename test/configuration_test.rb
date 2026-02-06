require 'test_helper'

class ConfigurationTest < Minitest::Test
  def test_primary_replication_host_prefers_private_ip
    config = build_config(
      'primary' => { 'host' => 'primary.example.com', 'private_ip' => '10.0.0.10' }
    )

    assert_equal '10.0.0.10', config.primary_replication_host
  end

  def test_replication_host_prefers_private_ip_for_standby
    config = build_config(
      'primary' => { 'host' => 'primary.example.com', 'private_ip' => '10.0.0.10' },
      'standby' => [{ 'host' => 'standby.example.com', 'private_ip' => '10.0.0.11' }]
    )

    assert_equal '10.0.0.10', config.primary_replication_host
    assert_equal '10.0.0.11', config.replication_host_for('standby.example.com')
  end

  def test_replication_host_falls_back_to_host_when_no_private_ip
    config = build_config(
      'primary' => { 'host' => 'primary.example.com' },
      'standby' => [{ 'host' => 'standby.example.com' }]
    )

    assert_equal 'primary.example.com', config.primary_replication_host
    assert_equal 'standby.example.com', config.replication_host_for('standby.example.com')
  end

  def test_node_label_uses_configured_label
    config = build_config(
      'primary' => { 'host' => 'primary.example.com', 'label' => 'db-primary' }
    )

    assert_equal 'db-primary', config.node_label_for('primary.example.com')
  end

  def test_grafana_requires_admin_password_and_host
    config = build_config(
      'components' => {
        'monitoring' => {
          'enabled' => true,
          'grafana' => { 'enabled' => true }
        }
      },
      'secrets' => { 'monitoring_password' => 'monitor' }
    )

    error = assert_raises(ActivePostgres::Error) { config.validate! }
    assert_match(/grafana_admin_password|grafana.host/, error.message)
  end

  def test_grafana_validation_passes_with_secret_and_host
    config = build_config(
      'components' => {
        'monitoring' => {
          'enabled' => true,
          'grafana' => { 'enabled' => true, 'host' => 'grafana.example.com' }
        }
      },
      'secrets' => {
        'monitoring_password' => 'monitor',
        'grafana_admin_password' => 'secret'
      }
    )

    assert config.validate!
  end

  def test_dns_failover_requires_domain_or_domains
    config = build_config(
      'components' => {
        'repmgr' => {
          'enabled' => true,
          'dns_failover' => {
            'enabled' => true,
            'dns_servers' => [{ 'host' => '10.0.0.10' }]
          }
        }
      },
      'secrets' => { 'replication_password' => 'secret' }
    )

    error = assert_raises(ActivePostgres::Error) { config.validate! }
    assert_match(/domain.*required/i, error.message)
  end

  def test_dns_failover_accepts_single_domain
    config = build_config(
      'components' => {
        'repmgr' => {
          'enabled' => true,
          'dns_failover' => {
            'enabled' => true,
            'domain' => 'mesh.internal',
            'dns_servers' => [{ 'host' => '10.0.0.10' }]
          }
        }
      },
      'secrets' => { 'replication_password' => 'secret' }
    )

    assert config.validate!
  end

  def test_dns_failover_accepts_multiple_domains
    config = build_config(
      'components' => {
        'repmgr' => {
          'enabled' => true,
          'dns_failover' => {
            'enabled' => true,
            'domains' => ['mesh.internal', 'mesh.v2.internal'],
            'dns_servers' => [{ 'host' => '10.0.0.10' }]
          }
        }
      },
      'secrets' => { 'replication_password' => 'secret' }
    )

    assert config.validate!
  end

  def test_dns_failover_requires_dns_servers
    config = build_config(
      'components' => {
        'repmgr' => {
          'enabled' => true,
          'dns_failover' => {
            'enabled' => true,
            'domain' => 'mesh.internal'
          }
        }
      },
      'secrets' => { 'replication_password' => 'secret' }
    )

    error = assert_raises(ActivePostgres::Error) { config.validate! }
    assert_match(/dns_servers.*required/i, error.message)
  end

  def test_pgbackrest_retention_archive_must_be_gte_retention_full
    config = build_config(
      'components' => {
        'pgbackrest' => {
          'enabled' => true,
          'retention_full' => 7,
          'retention_archive' => 3
        }
      }
    )

    error = assert_raises(ActivePostgres::Error) { config.validate! }
    assert_match(/retention_archive.*retention_full/i, error.message)
  end

  def test_pgbackrest_retention_validation_passes_when_archive_gte_full
    config = build_config(
      'components' => {
        'pgbackrest' => {
          'enabled' => true,
          'retention_full' => 7,
          'retention_archive' => 14
        }
      }
    )

    assert config.validate!
  end

  def test_standby_config_for_returns_standby_hash
    config = build_config(
      'standby' => [
        { 'host' => 'standby1.example.com', 'private_ip' => '10.0.0.11', 'pgbouncer_follow_primary' => true },
        { 'host' => 'standby2.example.com', 'private_ip' => '10.0.0.12' }
      ]
    )

    standby1 = config.standby_config_for('standby1.example.com')
    standby2 = config.standby_config_for('standby2.example.com')
    unknown = config.standby_config_for('unknown.example.com')

    assert_equal '10.0.0.11', standby1['private_ip']
    assert_equal true, standby1['pgbouncer_follow_primary']
    assert_equal '10.0.0.12', standby2['private_ip']
    assert_nil standby2['pgbouncer_follow_primary']
    assert_nil unknown
  end

  def test_standby_config_for_with_pgbouncer_follow_primary_false
    config = build_config(
      'standby' => [
        { 'host' => 'standby.example.com', 'pgbouncer_follow_primary' => false }
      ]
    )

    standby = config.standby_config_for('standby.example.com')

    assert_equal false, standby['pgbouncer_follow_primary']
  end

  private

  def build_config(overrides)
    hash = {
      'test' => {
        'primary' => { 'host' => 'primary.example.com' },
        'standby' => [{ 'host' => 'standby.example.com' }],
        'components' => {},
        'secrets' => {}
      }.merge(overrides)
    }

    ActivePostgres::Configuration.new(hash, 'test')
  end
end
