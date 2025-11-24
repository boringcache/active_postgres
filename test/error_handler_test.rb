require 'test_helper'

class ErrorHandlerTest < Minitest::Test
  def test_identify_error_type_for_ssh
    assert_equal :ssh_connection, described_class.identify_error_type('SSH connection refused')
  end

  def test_identify_error_type_for_private_network
    message = 'Cannot reach WireGuard network 10.8.0.100'
    assert_equal :private_network_connectivity, described_class.identify_error_type(message)
  end

  def test_identify_error_type_for_postgresql_startup
    assert_equal :postgresql_not_starting, described_class.identify_error_type('PostgreSQL cluster not running')
  end

  def test_identify_error_type_for_repmgr_clone
    assert_equal :repmgr_clone_failed,
                 described_class.identify_error_type('repmgr standby clone failed: data directory not found')
  end

  def test_identify_error_type_for_repmgr_register
    assert_equal :repmgr_register_failed,
                 described_class.identify_error_type('repmgr: unable to connect to the primary database')
  end

  def test_identify_error_type_for_ssl
    assert_equal :ssl_certificate_error, described_class.identify_error_type('SSL certificate verification failed')
  end

  def test_identify_error_type_for_disk_space
    assert_equal :disk_space_error, described_class.identify_error_type('No space left on device')
  end

  def test_identify_error_type_for_authentication
    assert_equal :authentication_failed, described_class.identify_error_type('password authentication failed')
  end

  def test_identify_error_type_returns_nil_for_unknown_messages
    assert_nil described_class.identify_error_type('Some unknown error')
  end

  def test_handle_prints_sanitized_error_details
    error = StandardError.new('password=supersecret')

    output, = capture_io do
      described_class.handle(error)
    end

    refute_includes output, 'supersecret'
    assert_includes output, '[REDACTED]'
  end

  def test_handle_prints_context
    error = StandardError.new('Test error message')

    output, = capture_io do
      described_class.handle(error, context: { host: 'primary' })
    end

    assert_includes output, 'host: primary'
  end

  def test_with_handling_yields_without_errors
    yielded = false

    described_class.with_handling { yielded = true }

    assert yielded
  end

  def test_with_handling_handles_errors_and_reraises
    handled = false

    assert_raises(StandardError) do
      described_class.stub(:handle, ->(*) { handled = true }) do
        described_class.with_handling do
          raise StandardError, 'boom'
        end
      end
    end

    assert handled
  end

  private

  def described_class
    ActivePostgres::ErrorHandler
  end
end
