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
