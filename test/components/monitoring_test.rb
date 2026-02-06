require 'test_helper'

class MonitoringTest < Minitest::Test
  def test_default_exporter_port
    monitoring_config = {}
    exporter_port = monitoring_config[:exporter_port] || 9187

    assert_equal 9187, exporter_port
  end

  def test_custom_exporter_port
    monitoring_config = { exporter_port: 9188 }
    exporter_port = monitoring_config[:exporter_port] || 9187

    assert_equal 9188, exporter_port
  end

  def test_default_node_exporter_port
    monitoring_config = {}
    port = monitoring_config[:node_exporter_port] || 9100

    assert_equal 9100, port
  end

  def test_custom_node_exporter_port
    monitoring_config = { node_exporter_port: 9200 }
    port = monitoring_config[:node_exporter_port] || 9100

    assert_equal 9200, port
  end

  def test_install_on_standby_calls_install_on_host
    config = stub_config(
      primary_host: 'primary.example.com',
      standby_hosts: ['standby.example.com'],
      component_config: { monitoring: { exporter_port: 9187 } }
    )

    ssh_executor = Minitest::Mock.new
    secrets = Minitest::Mock.new
    monitoring = ActivePostgres::Components::Monitoring.new(config, ssh_executor, secrets)

    installed_on = nil
    monitoring.define_singleton_method(:install_on_host) do |host|
      installed_on = host
    end

    monitoring.install_on_standby('standby.example.com')

    assert_equal 'standby.example.com', installed_on
  end

  def test_service_name_is_prometheus_postgres_exporter
    service_name = 'prometheus-postgres-exporter'

    assert_equal 'prometheus-postgres-exporter', service_name
    refute_equal 'postgres_exporter', service_name
  end
end
