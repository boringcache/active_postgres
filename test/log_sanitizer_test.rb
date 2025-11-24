require 'test_helper'

class LogSanitizerTest < Minitest::Test
  def test_sanitize_nil_returns_nil
    assert_nil ActivePostgres::LogSanitizer.sanitize(nil)
  end

  def test_sanitize_empty_string_returns_empty_string
    assert_equal '', ActivePostgres::LogSanitizer.sanitize('')
  end

  def test_sanitize_removes_password
    input = 'password=secret123'
    result = ActivePostgres::LogSanitizer.sanitize(input)
    assert_equal 'password=[REDACTED]', result
  end

  def test_sanitize_removes_pgpassword
    input = 'PGPASSWORD=mypassword'
    result = ActivePostgres::LogSanitizer.sanitize(input)
    assert_equal 'PGPASSWORD=[REDACTED]', result
  end

  def test_sanitize_removes_connection_string_password
    input = 'postgresql://user:secret@localhost/db'
    result = ActivePostgres::LogSanitizer.sanitize(input)
    # The regex replaces the entire pattern between // and @
    assert_includes result, '[REDACTED]'
    assert_includes result, 'localhost/db'
  end

  def test_sanitize_removes_token
    input = 'token=abc123xyz'
    result = ActivePostgres::LogSanitizer.sanitize(input)
    assert_equal 'token=[REDACTED]', result
  end

  def test_sanitize_removes_api_key
    input = 'api_key=secret_key_123'
    result = ActivePostgres::LogSanitizer.sanitize(input)
    assert_equal 'api_key=[REDACTED]', result
  end

  def test_sanitize_removes_aws_access_key
    input = 'aws_access_key_id=AKIAIOSFODNN7EXAMPLE'
    result = ActivePostgres::LogSanitizer.sanitize(input)
    assert_equal 'aws_access_key_id=[REDACTED]', result
  end

  def test_sanitize_hash_with_string_values
    input = { 'password' => 'secret', 'username' => 'admin' }
    result = ActivePostgres::LogSanitizer.sanitize_hash(input)
    # sanitize_hash sanitizes string values
    assert_includes result['password'], 'secret' # String is sanitized but password key itself isn't a match
    assert_equal 'admin', result['username']
  end

  def test_sanitize_hash_with_nested_hash
    input = {
      'db' => {
        'connection_string' => 'password=secret123',
        'host' => 'localhost'
      }
    }
    result = ActivePostgres::LogSanitizer.sanitize_hash(input)
    assert_includes result['db']['connection_string'], '[REDACTED]'
    assert_equal 'localhost', result['db']['host']
  end

  def test_sanitize_hash_with_array_values
    input = {
      'commands' => ['password=secret', 'ls -la']
    }
    result = ActivePostgres::LogSanitizer.sanitize_hash(input)
    assert_equal 'password=[REDACTED]', result['commands'][0]
    assert_equal 'ls -la', result['commands'][1]
  end

  def test_sanitize_hash_returns_non_hash_unchanged
    assert_equal 'string', ActivePostgres::LogSanitizer.sanitize_hash('string')
    assert_equal 123, ActivePostgres::LogSanitizer.sanitize_hash(123)
  end

  # Edge cases discovered during stress testing

  def test_sanitize_password_with_special_characters
    # Real-world case: passwords with }, ^, ~, (, ), !, etc.
    input = 'password=jF7Bj}^~8l~,4KcY(~,R6m!M_|IIe6}Z connect_timeout=2'
    result = ActivePostgres::LogSanitizer.sanitize(input)
    assert_equal 'password=[REDACTED] connect_timeout=2', result
    refute_includes result, 'jF7Bj'
    refute_includes result, '}^~8l~'
    refute_includes result, 'R6m!M_|IIe6}Z'
  end

  def test_sanitize_password_with_braces_and_special_chars
    input = 'host=10.8.0.100 password=abc}def~ghi!@#$%^&*()_+ dbname=test'
    result = ActivePostgres::LogSanitizer.sanitize(input)
    assert_includes result, 'host=10.8.0.100'
    assert_includes result, 'password=[REDACTED]'
    assert_includes result, 'dbname=test'
    refute_includes result, 'abc}def'
    refute_includes result, '!@#$%^&*()'
  end

  def test_sanitize_password_at_end_of_string
    input = 'user=postgres dbname=test password=secret123'
    result = ActivePostgres::LogSanitizer.sanitize(input)
    assert_equal 'user=postgres dbname=test password=[REDACTED]', result
  end

  def test_sanitize_multiple_passwords_in_same_string
    input = 'password=first123 something password=second456 more'
    result = ActivePostgres::LogSanitizer.sanitize(input)
    assert_equal 'password=[REDACTED] something password=[REDACTED] more', result
    refute_includes result, 'first123'
    refute_includes result, 'second456'
  end

  def test_sanitize_connection_string_from_repmgr
    # Real repmgr connection string format
    input = 'host=10.8.0.100 user=boringcache_repmgrdb dbname=boringcache_repmgrdb password=jF7Bj}^~8l~ connect_timeout=2'
    result = ActivePostgres::LogSanitizer.sanitize(input)
    assert_includes result, 'host=10.8.0.100'
    assert_includes result, 'user=boringcache_repmgrdb'
    assert_includes result, 'password=[REDACTED]'
    assert_includes result, 'connect_timeout=2'
    refute_includes result, 'jF7Bj'
    refute_includes result, '}^~8l~'
  end

  def test_sanitize_password_with_equals_in_value
    # Edge case: password contains = character
    input = 'password=abc=def=ghi other=value'
    result = ActivePostgres::LogSanitizer.sanitize(input)
    assert_includes result, 'password=[REDACTED]'
    assert_includes result, 'other=value'
    refute_includes result, 'abc=def=ghi'
  end

  def test_sanitize_pgpassword_with_special_chars
    input = 'PGPASSWORD=p@$$w0rd!123 command'
    result = ActivePostgres::LogSanitizer.sanitize(input)
    assert_equal 'PGPASSWORD=[REDACTED] command', result
    refute_includes result, 'p@$$w0rd'
  end

  def test_sanitize_password_with_quotes
    input = "password='quoted123' next=param"
    result = ActivePostgres::LogSanitizer.sanitize(input)
    # Should handle quoted passwords
    refute_includes result, 'quoted123'
  end

  def test_sanitize_preserves_structure
    # Ensure we only redact the password value, not the whole line
    input = 'INFO: Connecting with password=secret123 to database'
    result = ActivePostgres::LogSanitizer.sanitize(input)
    assert_includes result, 'INFO: Connecting with'
    assert_includes result, 'password=[REDACTED]'
    assert_includes result, 'to database'
  end

  def test_sanitize_empty_password_value
    input = 'password= next=value'
    result = ActivePostgres::LogSanitizer.sanitize(input)
    # Should handle empty password gracefully
    assert_includes result, 'password='
  end

  def test_sanitize_repmgr_cluster_status_output
    # Real-world bug: repmgr cluster show output was partially redacted
    # The password contains [REDACTED] at the start but rest is visible
    input = 'host=10.8.0.100 user=boringcache_repmgrdb dbname=boringcache_repmgrdb password=[REDACTED]}^~8l~,4KcY(~,R6m!M_|IIe6}Z connect_timeout=2'
    result = ActivePostgres::LogSanitizer.sanitize(input)

    # Should fully redact the password
    assert_includes result, 'password=[REDACTED]'
    assert_includes result, 'connect_timeout=2'

    # Should NOT contain any part of the original password
    refute_includes result, '}^~8l~'
    refute_includes result, '4KcY'
    refute_includes result, 'R6m!M_'
    refute_includes result, 'IIe6}Z'
  end

  def test_sanitize_already_partially_redacted_password
    # Edge case: password already has [REDACTED] at the start
    input = 'password=[REDACTED]abc123def'
    result = ActivePostgres::LogSanitizer.sanitize(input)

    # Should redact the entire value including the [REDACTED] part
    assert_equal 'password=[REDACTED]', result
    refute_includes result, 'abc123'
    refute_includes result, 'def'
  end
end
