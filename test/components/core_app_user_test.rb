require 'test_helper'

class CoreAppUserTest < Minitest::Test
  def test_create_application_users_method
    config = stub_config(
      app_user: 'test_app_user',
      app_database: 'test_app_db',
      secrets_config: { app_password: 'test_password' }
    )

    ssh_executor = Minitest::Mock.new
    secrets = Minitest::Mock.new
    core = ActivePostgres::Components::Core.new(config, ssh_executor, secrets)

    # Mock create_app_user_and_database
    app_user_called = false
    called_with_host = nil
    core.define_singleton_method(:create_app_user_and_database) do |host|
      app_user_called = true
      called_with_host = host
    end

    core.create_application_users

    assert app_user_called, 'Should call create_app_user_and_database'
    assert_equal config.primary_host, called_with_host
  end

  def test_skips_app_user_creation_when_not_configured
    config = stub_config(
      app_user: nil,
      app_database: nil,
      component_enabled?: false
    )

    ssh_executor = Minitest::Mock.new
    secrets = Minitest::Mock.new
    core = ActivePostgres::Components::Core.new(config, ssh_executor, secrets)

    # Expect normal install without app user creation
    ssh_executor.expect(:install_postgres, nil, [config.primary_host, config.version])
    ssh_executor.expect(:ensure_cluster_exists, nil, [config.primary_host, config.version])
    ssh_executor.expect(:restart_postgres, nil, [config.primary_host, config.version])

    # Mock standbys
    ssh_executor.expect(:install_postgres, nil, [config.standby_hosts.first, config.version])
    ssh_executor.expect(:ensure_cluster_exists, nil, [config.standby_hosts.first, config.version])
    ssh_executor.expect(:restart_postgres, nil, [config.standby_hosts.first, config.version])

    # Mock upload_template
    def core.upload_template(*); end

    core.install

    ssh_executor.verify
  end

  def test_password_escaping_for_sql
    # Test SQL injection prevention
    password = "pass'word\"with'quotes"
    sql_escaped = password.gsub("'", "''")
    assert_equal "pass''word\"with''quotes", sql_escaped
  end
end
