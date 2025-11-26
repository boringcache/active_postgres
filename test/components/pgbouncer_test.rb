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
      postgres_user: 'postgres',
      app_user: 'app_user',
      component_config: {
        pgbouncer: {},
        core: { postgresql: { max_connections: 100 } }
      }
    )

    ssh_executor = Minitest::Mock.new
    secrets = Minitest::Mock.new
    pgbouncer = ActivePostgres::Components::PgBouncer.new(config, ssh_executor, secrets)

    ssh_executor.expect(:execute_on_host, nil) do |host|
      host == 'db.example.com'
    end
    ssh_executor.expect(:execute_on_host, nil) do |host|
      host == 'db.example.com'
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
end
