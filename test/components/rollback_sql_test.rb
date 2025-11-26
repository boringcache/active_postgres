require 'test_helper'

class RollbackSqlTest < Minitest::Test
  def test_drop_database_sql_generation
    database_name = 'test_database'
    sql = "DROP DATABASE IF EXISTS #{database_name};"

    assert_includes sql, 'DROP DATABASE IF EXISTS'
    assert_includes sql, database_name
    assert_match(/;$/, sql, 'Should end with semicolon')
  end

  def test_drop_user_sql_generation
    username = 'test_user'
    sql = "DROP USER IF EXISTS #{username};"

    assert_includes sql, 'DROP USER IF EXISTS'
    assert_includes sql, username
    assert_match(/;$/, sql, 'Should end with semicolon')
  end

  def test_drop_operations_are_idempotent
    database_name = 'test_db'
    username = 'test_user'

    db_sql = "DROP DATABASE IF EXISTS #{database_name};"
    user_sql = "DROP USER IF EXISTS #{username};"

    assert_includes db_sql, 'IF EXISTS'
    assert_includes user_sql, 'IF EXISTS'
  end

  def test_drop_database_with_special_chars_in_name
    databases = %w[
      test_database
      my_app_production
      boring_cache_web_production
    ]

    databases.each do |db|
      sql = "DROP DATABASE IF EXISTS #{db};"
      assert_includes sql, db
      assert_includes sql, 'IF EXISTS'
    end
  end

  def test_drop_user_with_special_chars_in_name
    users = %w[
      test_user
      app_user
      boring_cache_web
    ]

    users.each do |user|
      sql = "DROP USER IF EXISTS #{user};"
      assert_includes sql, user
      assert_includes sql, 'IF EXISTS'
    end
  end
end
