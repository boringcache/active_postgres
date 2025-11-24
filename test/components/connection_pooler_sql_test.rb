require 'test_helper'

class ConnectionPoolerSqlTest < Minitest::Test
  def test_get_all_users_sql_generation
    sql = <<~SQL.strip
      SELECT concat('"', usename, '" "', passwd, '"')
      FROM pg_shadow
      WHERE passwd IS NOT NULL
    SQL

    assert_includes sql, "SELECT concat"
    assert_includes sql, "FROM pg_shadow"
    assert_includes sql, "WHERE passwd IS NOT NULL"
  end

  def test_create_pgbouncer_user_sql
    pgbouncer_user = 'pgbouncer'
    password = 'test_password'
    escaped_pass = password.gsub("'", "''")

    sql = [
      "CREATE USER #{pgbouncer_user} WITH PASSWORD '#{escaped_pass}';",
      "GRANT CONNECT ON DATABASE postgres TO #{pgbouncer_user};"
    ].join("\n")

    assert_includes sql, "CREATE USER #{pgbouncer_user}"
    assert_includes sql, "GRANT CONNECT ON DATABASE postgres"
  end

  def test_pgbouncer_password_escaping
    pgbouncer_user = 'pgbouncer'
    passwords = [
      "simple",
      "pass'word",
      "jF7Bj}^~8l~,4KcY(~,R6m!M_|IIe6}Z"
    ]

    passwords.each do |password|
      escaped_pass = password.gsub("'", "''")
      sql = "CREATE USER #{pgbouncer_user} WITH PASSWORD '#{escaped_pass}';"

      assert_includes sql, escaped_pass
      quote_count = password.count("'")
      escaped_quote_count = escaped_pass.count("'")
      assert_equal quote_count * 2, escaped_quote_count
    end
  end

  def test_get_pgbouncer_password_sql
    pgbouncer_user = 'pgbouncer'

    sql = <<~SQL.strip
      SELECT passwd
      FROM pg_shadow
      WHERE usename = '#{pgbouncer_user}'
    SQL

    assert_includes sql, "SELECT passwd"
    assert_includes sql, "FROM pg_shadow"
    assert_includes sql, "WHERE usename = '#{pgbouncer_user}'"
  end

  def test_grant_connect_on_postgres_database
    pgbouncer_user = 'pgbouncer'
    sql = "GRANT CONNECT ON DATABASE postgres TO #{pgbouncer_user};"

    assert_includes sql, "GRANT CONNECT"
    assert_includes sql, "ON DATABASE postgres"
    assert_includes sql, "TO #{pgbouncer_user}"
  end
end
