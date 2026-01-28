require 'test_helper'

class SecretsTest < Minitest::Test
  def test_initialization
    config = stub_config(secrets_config: { 'db_password' => 'secret123' })
    secrets = ActivePostgres::Secrets.new(config)

    assert_equal config, secrets.config
  end

  def test_resolve_literal_value
    config = stub_config(secrets_config: { 'db_password' => 'literal_password' })
    secrets = ActivePostgres::Secrets.new(config)

    assert_equal 'literal_password', secrets.resolve('db_password')
  end

  def test_resolve_env_variable_with_dollar_sign
    ENV['TEST_SECRET'] = 'env_value'
    config = stub_config(secrets_config: { 'db_password' => '$TEST_SECRET' })
    secrets = ActivePostgres::Secrets.new(config)

    assert_equal 'env_value', secrets.resolve('db_password')
  ensure
    ENV.delete('TEST_SECRET')
  end

  def test_resolve_env_variable_with_env_prefix
    ENV['DATABASE_PASSWORD'] = 'db_password_value'
    config = stub_config(secrets_config: { 'db_password' => 'env:DATABASE_PASSWORD' })
    secrets = ActivePostgres::Secrets.new(config)

    assert_equal 'db_password_value', secrets.resolve('db_password')
  ensure
    ENV.delete('DATABASE_PASSWORD')
  end

  def test_resolve_returns_nil_for_missing_env_var
    config = stub_config(secrets_config: { 'db_password' => '$NONEXISTENT_VAR' })
    secrets = ActivePostgres::Secrets.new(config)

    assert_nil secrets.resolve('db_password')
  end

  def test_resolve_returns_nil_for_unknown_key
    config = stub_config(secrets_config: {})
    secrets = ActivePostgres::Secrets.new(config)

    assert_nil secrets.resolve('nonexistent_key')
  end

  def test_resolve_caches_results
    config = stub_config(secrets_config: { 'db_password' => 'cached_value' })
    secrets = ActivePostgres::Secrets.new(config)

    # First call
    result1 = secrets.resolve('db_password')
    # Second call should use cache
    result2 = secrets.resolve('db_password')

    assert_equal result1, result2
    assert_equal 'cached_value', result2
  end

  def test_resolve_all
    ENV['TEST_VAR'] = 'test_value'
    config = stub_config(secrets_config: {
                           'password' => 'literal',
                           'api_key' => '$TEST_VAR'
                         })
    secrets = ActivePostgres::Secrets.new(config)

    all_secrets = secrets.resolve_all

    assert_equal 'literal', all_secrets['password']
    assert_equal 'test_value', all_secrets['api_key']
  ensure
    ENV.delete('TEST_VAR')
  end

  def test_resolve_does_not_cache_nil_values
    ENV.delete('DYNAMIC_SECRET')
    config = stub_config(secrets_config: { 'db_password' => '$DYNAMIC_SECRET' })
    secrets = ActivePostgres::Secrets.new(config)

    assert_nil secrets.resolve('db_password')

    ENV['DYNAMIC_SECRET'] = 'now-present'
    assert_equal 'now-present', secrets.resolve('db_password')
  ensure
    ENV.delete('DYNAMIC_SECRET')
  end

  def test_resolve_value_nested_hash_and_array
    ENV['NESTED_SECRET'] = 'nested'
    config = stub_config(secrets_config: {})
    secrets = ActivePostgres::Secrets.new(config)

    resolved = secrets.resolve_value({
      'literal' => 'value',
      'env' => '$NESTED_SECRET',
      'array' => ['a', 'env:NESTED_SECRET']
    })

    assert_equal 'value', resolved['literal']
    assert_equal 'nested', resolved['env']
    assert_equal ['a', 'nested'], resolved['array']
  ensure
    ENV.delete('NESTED_SECRET')
  end
end
