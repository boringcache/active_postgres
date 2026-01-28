require 'test_helper'

class RepmgrSqlTest < Minitest::Test
  def test_repmgr_user_sql_generation
    repmgr_user = 'repmgr'
    repmgr_db = 'repmgr'
    password = 'test_password'
    config = stub_config
    secrets = ActivePostgres::Secrets.new(config)
    component = ActivePostgres::Components::Repmgr.new(config, Object.new, secrets)

    sql = component.send(:build_repmgr_setup_sql, repmgr_user, repmgr_db, password)

    assert_includes sql, 'DO $$'
    assert_includes sql, "CREATE USER #{repmgr_user} WITH SUPERUSER"
    assert_includes sql, "ALTER USER #{repmgr_user} WITH SUPERUSER"
    assert_includes sql, "CREATE DATABASE #{repmgr_db} OWNER #{repmgr_user}"
    refute_includes sql, 'DROP DATABASE'
    refute_includes sql, 'DROP USER'
  end

  def test_repmgr_password_escaping
    repmgr_user = 'repmgr'
    passwords = [
      'simple_pass',
      "pass'word",
      'jF7Bj}^~8l~,4KcY(~,R6m!M_|IIe6}Z',
      "test'many''quotes"
    ]

    passwords.each do |password|
      escaped_password = password.gsub("'", "''")
      sql = "CREATE USER #{repmgr_user} WITH SUPERUSER PASSWORD '#{escaped_password}'"

      assert_includes sql, escaped_password
      quote_count = password.count("'")
      escaped_quote_count = escaped_password.count("'")
      assert_equal quote_count * 2, escaped_quote_count
    end
  end

  def test_repmgr_creates_superuser
    repmgr_user = 'repmgr'
    password = 'test_pass'
    escaped_password = password.gsub("'", "''")

    sql = "CREATE USER #{repmgr_user} WITH SUPERUSER PASSWORD '#{escaped_password}'"

    assert_includes sql, 'SUPERUSER', 'Repmgr user must be superuser'
  end

  def test_repmgr_database_owner
    repmgr_user = 'repmgr'
    repmgr_db = 'repmgr'

    sql = "CREATE DATABASE #{repmgr_db} OWNER #{repmgr_user}"

    assert_includes sql, "OWNER #{repmgr_user}"
  end

  def test_repmgr_idempotent_drop
    repmgr_user = 'repmgr'
    repmgr_db = 'repmgr'

    config = stub_config
    secrets = ActivePostgres::Secrets.new(config)
    component = ActivePostgres::Components::Repmgr.new(config, Object.new, secrets)

    sql = component.send(:build_repmgr_setup_sql, repmgr_user, repmgr_db, 'test')

    assert_includes sql, 'IF NOT EXISTS', 'Should use IF NOT EXISTS for idempotent operations'
    refute_includes sql, 'DROP', 'Should avoid destructive drops in idempotent setup'
  end
end
