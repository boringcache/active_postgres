require 'test_helper'

class PerformanceTuningIntegrationTest < Minitest::Test
  def test_performance_tuning_component_is_recognized
    config = build_config_with_performance_tuning(enabled: true)

    assert config.component_enabled?(:performance_tuning)
  end

  def test_performance_tuning_disabled_by_default
    config = build_config_with_performance_tuning(enabled: false)

    refute config.component_enabled?(:performance_tuning)
  end

  def test_performance_tuning_config_includes_db_type
    config = build_config_with_performance_tuning(enabled: true, db_type: 'oltp')
    tuning_config = config.component_config(:performance_tuning)

    assert_equal 'oltp', tuning_config[:db_type]
  end

  def test_performance_tuning_defaults_to_web_workload
    config = build_config_with_performance_tuning(enabled: true)
    tuning_config = config.component_config(:performance_tuning)

    # db_type should be web if not specified
    assert tuning_config[:enabled]
  end

  def test_connection_pooler_calculates_pool_sizes
    pool_sizes = ActivePostgres::ConnectionPooler.calculate_optimal_pool_sizes(100)

    assert pool_sizes[:default_pool_size]
    assert pool_sizes[:max_client_conn]
    assert_equal 1000, pool_sizes[:max_client_conn] # 100 * 10
    assert pool_sizes[:max_db_connections]
    assert_equal 90, pool_sizes[:max_db_connections] # 100 - 10
  end

  def test_connection_pooler_respects_minimum_connections
    pool_sizes = ActivePostgres::ConnectionPooler.calculate_optimal_pool_sizes(20)

    # Should not go below 10
    assert pool_sizes[:max_db_connections] >= 10
  end

  private

  def build_config_with_performance_tuning(enabled:, db_type: 'web')
    hash = {
      'test' => {
        'primary' => { 'host' => 'primary.example.com' },
        'standby' => [],
        'components' => {
          'performance_tuning' => {
            'enabled' => enabled,
            'db_type' => db_type
          }
        },
        'secrets' => {}
      }
    }

    ActivePostgres::Configuration.new(hash, 'test')
  end
end
