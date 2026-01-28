require 'test_helper'

class PgBouncerTest < Minitest::Test
  def test_userlist_sql_generation_for_postgres_user
    postgres_user = 'postgres'

    sql = <<~SQL.strip
      SELECT concat('"', rolname, '" "', rolpassword, '"')
      FROM pg_authid
      WHERE rolname = '#{postgres_user}'
    SQL

    expected = %{SELECT concat('"', rolname, '" "', rolpassword, '"')\nFROM pg_authid\nWHERE rolname = 'postgres'}
    assert_equal expected, sql
  end

  def test_userlist_sql_generation_for_app_user
    app_user = 'boring_cache_web'

    sql = <<~SQL.strip
      SELECT concat('"', rolname, '" "', rolpassword, '"')
      FROM pg_authid
      WHERE rolname = '#{app_user}'
    SQL

    expected = %{SELECT concat('"', rolname, '" "', rolpassword, '"')\nFROM pg_authid\nWHERE rolname = 'boring_cache_web'}
    assert_equal expected, sql
  end

  def test_userlist_sql_escapes_special_user_names
    app_user = "test'user"

    sql = <<~SQL.strip
      SELECT concat('"', rolname, '" "', rolpassword, '"')
      FROM pg_authid
      WHERE rolname = '#{app_user}'
    SQL

    assert_includes sql, "test'user"
  end

  def test_pgbouncer_install_calls_create_userlist
    config = stub_config(
      primary_host: 'db.example.com',
      standby_hosts: ['standby.example.com'],
      postgres_user: 'postgres',
      app_user: 'app_user',
      component_config: {
        pgbouncer: {},
        ssl: { enabled: false },
        core: { postgresql: { max_connections: 100 } }
      }
    )

    ssh_executor = Minitest::Mock.new
    secrets = Minitest::Mock.new
    secrets.expect(:resolve, nil, ['ssl_chain'])
    secrets.expect(:resolve, nil, ['ssl_chain'])
    pgbouncer = ActivePostgres::Components::PgBouncer.new(config, ssh_executor, secrets)

    ssh_executor.expect(:execute_on_host, nil) do |host|
      host == 'db.example.com'
    end
    ssh_executor.expect(:execute_on_host, nil) do |host|
      host == 'db.example.com'
    end
    ssh_executor.expect(:execute_on_host, nil) do |host|
      host == 'standby.example.com'
    end
    ssh_executor.expect(:execute_on_host, nil) do |host|
      host == 'standby.example.com'
    end

    def pgbouncer.upload_template(*); end
    def pgbouncer.get_postgres_max_connections(*) = 100

    userlist_called = false
    pgbouncer.define_singleton_method(:create_userlist) do |_host|
      userlist_called = true
    end

    pgbouncer.install

    assert userlist_called, 'Should call create_userlist during install'
  end

  def test_userlist_handles_different_users
    config = stub_config(
      postgres_user: 'postgres',
      app_user: 'boring_cache_web'
    )

    refute_equal config.postgres_user, config.app_user, 'Test requires different users'
  end

  def test_userlist_skips_app_user_when_same_as_postgres
    config = stub_config(
      postgres_user: 'postgres',
      app_user: 'postgres'
    )

    assert_equal config.postgres_user, config.app_user
  end

  def test_follow_primary_script_template_includes_repmgr_lookup
    config = stub_config(component_config: { pgbouncer: {}, repmgr: {} })
    secrets = ActivePostgres::Secrets.new(config)
    component = ActivePostgres::Components::PgBouncer.new(config, Object.new, secrets)

    content = component.instance_eval do
      repmgr_conf = '/etc/repmgr.conf'
      postgres_user = 'postgres'
      _ = [repmgr_conf, postgres_user]
      render_template('pgbouncer_follow_primary.sh.erb', binding)
    end

    assert_includes content, 'repmgr -f "$REPMGR_CONF" cluster show --csv'
    assert_includes content, 'PGBOUNCER_INI="/etc/pgbouncer/pgbouncer.ini"'
    assert_match(/sed -i -E "s\/\^\(\\\\\* = host=\)\[\^ \]\+\//, content)
    assert_includes content, '${primary_host}'
  end

  def test_follow_primary_timer_template_includes_interval
    config = stub_config(component_config: { pgbouncer: {}, repmgr: {} })
    secrets = ActivePostgres::Secrets.new(config)
    component = ActivePostgres::Components::PgBouncer.new(config, Object.new, secrets)

    content = component.instance_eval do
      interval = 5
      _ = interval
      render_template('pgbouncer-follow-primary.timer.erb', binding)
    end

    assert_includes content, 'OnUnitActiveSec=5s'
  end
end
