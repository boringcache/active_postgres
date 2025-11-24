require 'test_helper'

class CredentialsTest < Minitest::Test
  def test_get_returns_nil_without_rails
    result = ActivePostgres::Credentials.get('nonexistent.key')
    assert_nil result
  end

  def test_get_returns_nil_for_invalid_key_path
    result = ActivePostgres::Credentials.get('some.nested.key')
    assert_nil result
  end

  def test_get_handles_simple_key_paths
    result = ActivePostgres::Credentials.get('test_key')
    assert_nil result # Returns nil when Rails is not properly configured
  end
end
