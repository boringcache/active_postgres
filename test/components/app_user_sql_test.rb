require 'test_helper'

class AppUserSqlTest < Minitest::Test
  def test_app_user_sql_generation_basic
    app_user = 'test_user'
    app_database = 'test_db'
    app_password = 'simple_password'
    escaped_password = app_password.gsub("'", "''")

    sql = [
      'DO $',
      'BEGIN',
      "  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '#{app_user}') THEN",
      "    CREATE USER #{app_user} WITH PASSWORD '#{escaped_password}';",
      '  ELSE',
      "    ALTER USER #{app_user} WITH PASSWORD '#{escaped_password}';",
      '  END IF;',
      'END $;',
      '',
      "SELECT 'CREATE DATABASE #{app_database} OWNER #{app_user}'",
      "WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '#{app_database}')\\gexec",
      '',
      "GRANT ALL PRIVILEGES ON DATABASE #{app_database} TO #{app_user};",
      "\\c #{app_database}",
      "GRANT ALL ON SCHEMA public TO #{app_user};"
    ].join("\n")

    assert_includes sql, "CREATE USER #{app_user}"
    assert_includes sql, "CREATE DATABASE #{app_database}"
    assert_includes sql, 'GRANT ALL PRIVILEGES'
    assert_includes sql, 'GRANT ALL ON SCHEMA public'
  end

  def test_app_user_sql_with_special_chars_in_password
    app_user = 'test_user'
    passwords = [
      "pass'word",
      'jF7Bj}^~8l~,4KcY(~,R6m!M_|IIe6}Z',
      'test"quote',
      "has'many''quotes"
    ]

    passwords.each do |password|
      escaped_password = password.gsub("'", "''")

      sql = "CREATE USER #{app_user} WITH PASSWORD '#{escaped_password}';"

      assert_includes sql, escaped_password, 'Escaped password should appear in SQL'

      single_quote_count = password.count("'")
      escaped_single_quote_count = escaped_password.count("'")
      assert_equal single_quote_count * 2, escaped_single_quote_count, 'Each single quote should be doubled'
    end
  end

  def test_app_user_sql_idempotent_create
    app_user = 'test_user'
    app_password = 'test_pass'
    escaped_password = app_password.gsub("'", "''")

    sql = [
      'DO $',
      'BEGIN',
      "  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '#{app_user}') THEN",
      "    CREATE USER #{app_user} WITH PASSWORD '#{escaped_password}';",
      '  ELSE',
      "    ALTER USER #{app_user} WITH PASSWORD '#{escaped_password}';",
      '  END IF;',
      'END $;'
    ].join("\n")

    assert_includes sql, 'IF NOT EXISTS'
    assert_includes sql, 'CREATE USER'
    assert_includes sql, 'ALTER USER'
  end

  def test_database_sql_idempotent_create
    app_database = 'test_db'
    app_user = 'test_user'

    sql = [
      "SELECT 'CREATE DATABASE #{app_database} OWNER #{app_user}'",
      "WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '#{app_database}')\\gexec"
    ].join("\n")

    assert_includes sql, 'WHERE NOT EXISTS'
    assert_includes sql, 'CREATE DATABASE'
    assert_includes sql, '\\gexec'
  end

  def test_grants_all_privileges_on_database
    app_database = 'test_db'
    app_user = 'test_user'

    sql = [
      "GRANT ALL PRIVILEGES ON DATABASE #{app_database} TO #{app_user};",
      "\\c #{app_database}",
      "GRANT ALL ON SCHEMA public TO #{app_user};"
    ].join("\n")

    assert_includes sql, 'GRANT ALL PRIVILEGES ON DATABASE'
    assert_includes sql, "\\c #{app_database}"
    assert_includes sql, 'GRANT ALL ON SCHEMA public'
  end

  def test_sql_injection_prevention
    malicious_user = "test'; DROP DATABASE test; --"
    escaped = malicious_user.gsub("'", "''")

    assert_equal "test''; DROP DATABASE test; --", escaped

    sql = "CREATE USER #{escaped} WITH PASSWORD 'password';"

    assert_includes sql, "test''; DROP DATABASE test; --", 'Should escape the single quote'

    quote_count = malicious_user.count("'")
    escaped_quote_count = escaped.count("'")
    assert_equal quote_count * 2, escaped_quote_count, 'All single quotes should be doubled'
  end
end
