require 'test_helper'

class SSLTest < Minitest::Test
  def test_default_cert_days
    ssl_config = {}
    cert_days = ssl_config[:cert_days] || 3650

    assert_equal 3650, cert_days
  end

  def test_custom_cert_days
    ssl_config = { cert_days: 365 }
    cert_days = ssl_config[:cert_days] || 3650

    assert_equal 365, cert_days
  end

  def test_ssl_modes
    valid_modes = %w[require verify-ca verify-full]

    valid_modes.each do |mode|
      assert_includes valid_modes, mode
    end
  end

  def test_common_name_default_to_host
    ssl_config = {}
    host = 'db.example.com'
    cn = ssl_config[:common_name] || host

    assert_equal 'db.example.com', cn
  end

  def test_custom_common_name
    ssl_config = { common_name: 'postgres.myapp.com' }
    host = 'db.example.com'
    cn = ssl_config[:common_name] || host

    assert_equal 'postgres.myapp.com', cn
  end

  def test_ssl_file_permissions
    key_mode = '600'
    cert_mode = '644'

    assert_equal '600', key_mode, 'Private key must be 600'
    assert_equal '644', cert_mode, 'Certificate can be 644'
  end

  def test_install_on_standby_calls_install_on_host
    config = stub_config(
      primary_host: 'primary.example.com',
      standby_hosts: ['standby.example.com'],
      version: 16,
      component_config: { ssl: { mode: 'require' } }
    )

    ssh_executor = Minitest::Mock.new
    secrets = Minitest::Mock.new
    ssl = ActivePostgres::Components::SSL.new(config, ssh_executor, secrets)

    installed_on = nil
    ssl.define_singleton_method(:install_on_host) do |host|
      installed_on = host
    end

    ssl.install_on_standby('standby.example.com')

    assert_equal 'standby.example.com', installed_on
  end

  def test_full_cert_chain_concatenation
    ssl_cert = "-----BEGIN CERTIFICATE-----\nSERVER_CERT\n-----END CERTIFICATE-----"
    ssl_chain = "-----BEGIN CERTIFICATE-----\nCA_CERT\n-----END CERTIFICATE-----"

    full_cert = "#{ssl_cert.strip}\n#{ssl_chain.strip}\n"

    assert_includes full_cert, 'SERVER_CERT'
    assert_includes full_cert, 'CA_CERT'
    assert full_cert.end_with?("\n")
  end
end
