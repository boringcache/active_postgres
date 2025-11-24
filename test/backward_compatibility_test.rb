require 'test_helper'

class BackwardCompatibilityTest < Minitest::Test
  def test_config_without_performance_tuning_works
    config = build_legacy_config

    # Should not enable performance tuning
    refute config.component_enabled?(:performance_tuning)

    # Core component should still be enabled
    assert config.component_enabled?(:core)

    # Should have sensible defaults
    core_config = config.component_config(:core)
    assert core_config[:enabled]
  end

  def test_pgbouncer_works_without_explicit_pool_settings
    config = build_legacy_config_with_pgbouncer

    assert config.component_enabled?(:pgbouncer)
    pgbouncer_config = config.component_config(:pgbouncer)

    # User can still set values explicitly
    assert_equal 'transaction', pgbouncer_config[:pool_mode]
  end

  def test_postgresql_explicit_settings_are_preserved
    config = build_config_with_explicit_postgres_settings

    core_config = config.component_config(:core)
    pg_settings = core_config[:postgresql]

    # Explicit user settings should be preserved
    assert_equal 200, pg_settings[:max_connections]
    assert_equal '512MB', pg_settings[:shared_buffers]
  end

  private

  def build_legacy_config
    hash = {
      'test' => {
        'primary' => { 'host' => 'primary.example.com' },
        'standby' => [],
        'components' => {
          'core' => {
            'locale' => 'en_US.UTF-8'
          }
        },
        'secrets' => {}
      }
    }

    ActivePostgres::Configuration.new(hash, 'test')
  end

  def build_legacy_config_with_pgbouncer
    hash = {
      'test' => {
        'primary' => { 'host' => 'primary.example.com' },
        'standby' => [],
        'components' => {
          'pgbouncer' => {
            'enabled' => true,
            'pool_mode' => 'transaction'
          }
        },
        'secrets' => {}
      }
    }

    ActivePostgres::Configuration.new(hash, 'test')
  end

  def build_config_with_explicit_postgres_settings
    hash = {
      'test' => {
        'primary' => { 'host' => 'primary.example.com' },
        'standby' => [],
        'components' => {
          'core' => {
            'postgresql' => {
              'max_connections' => 200,
              'shared_buffers' => '512MB'
            }
          }
        },
        'secrets' => {}
      }
    }

    ActivePostgres::Configuration.new(hash, 'test')
  end
end
