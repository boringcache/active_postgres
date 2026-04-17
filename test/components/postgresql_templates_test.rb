require 'test_helper'

class PostgresqlTemplatesTest < Minitest::Test
  def setup
    @config = stub_config
    @component = ActivePostgres::Components::Core.new(@config, Object.new, ActivePostgres::Secrets.new(@config))
  end

  def test_conf_includes_log_truncate_on_rotation_when_configured
    content = render_postgresql_conf(log_truncate_on_rotation: 'on')

    assert_includes content, 'log_truncate_on_rotation = on'
  end

  def test_conf_includes_log_file_mode_when_configured
    content = render_postgresql_conf(log_file_mode: '0640')

    assert_includes content, 'log_file_mode = 0640'
  end

  def test_conf_omits_log_truncate_on_rotation_by_default
    content = render_postgresql_conf({})

    refute_includes content, 'log_truncate_on_rotation'
  end

  def test_conf_preloads_repmgr_when_repmgr_component_is_enabled
    @config = stub_config(component_enabled?: ->(name) { name == :repmgr })
    @component = ActivePostgres::Components::Core.new(@config, Object.new, ActivePostgres::Secrets.new(@config))

    content = render_postgresql_conf({})

    assert_includes content, "shared_preload_libraries = 'pg_stat_statements, repmgr'"
  end

  private

  def render_postgresql_conf(pg_config)
    config = @config
    @component.instance_eval do
      _ = pg_config
      render_template('postgresql.conf.erb', binding)
    end
  end
end
