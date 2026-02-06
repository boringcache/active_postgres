require 'test_helper'

class PgBouncerTest < Minitest::Test
  def test_userlist_sql_generation_for_postgres_user
    postgres_user = 'postgres'

    sql = <<~SQL.strip
      SELECT concat('"', rolname, '" "', rolpassword, '"')
      FROM pg_authid
      WHERE rolname = '#{postgres_user}'
    SQL

    expected = %{SELECT concat('"', rolname, '" "', rolpassword, '"')\nFROM pg_authid\nWHERE rolname = 'postgres'}
    assert_equal expected, sql
  end

  def test_userlist_sql_generation_for_app_user
    app_user = 'boring_cache_web'

    sql = <<~SQL.strip
      SELECT concat('"', rolname, '" "', rolpassword, '"')
      FROM pg_authid
      WHERE rolname = '#{app_user}'
    SQL

    expected = %{SELECT concat('"', rolname, '" "', rolpassword, '"')\nFROM pg_authid\nWHERE rolname = 'boring_cache_web'}
    assert_equal expected, sql
  end

  def test_userlist_sql_escapes_special_user_names
    app_user = "test'user"

    sql = <<~SQL.strip
      SELECT concat('"', rolname, '" "', rolpassword, '"')
      FROM pg_authid
      WHERE rolname = '#{app_user}'
    SQL

    assert_includes sql, "test'user"
  end

  def test_pgbouncer_install_calls_create_userlist
    config = stub_config(
      primary_host: 'db.example.com',
      standby_hosts: ['standby.example.com'],
      postgres_user: 'postgres',
      app_user: 'app_user',
      component_config: {
        pgbouncer: {},
        ssl: { enabled: false },
        core: { postgresql: { max_connections: 100 } }
      }
    )

    ssh_executor = Minitest::Mock.new
    secrets = Minitest::Mock.new
    secrets.expect(:resolve, nil, ['ssl_chain'])
    secrets.expect(:resolve, nil, ['ssl_chain'])
    pgbouncer = ActivePostgres::Components::PgBouncer.new(config, ssh_executor, secrets)

    ssh_executor.expect(:execute_on_host, nil) do |host|
      host == 'db.example.com'
    end
    ssh_executor.expect(:execute_on_host, nil) do |host|
      host == 'db.example.com'
    end
    ssh_executor.expect(:execute_on_host, nil) do |host|
      host == 'standby.example.com'
    end
    ssh_executor.expect(:execute_on_host, nil) do |host|
      host == 'standby.example.com'
    end

    def pgbouncer.upload_template(*); end
    def pgbouncer.get_postgres_max_connections(*) = 100

    userlist_called = false
    pgbouncer.define_singleton_method(:create_userlist) do |_host|
      userlist_called = true
    end

    pgbouncer.install

    assert userlist_called, 'Should call create_userlist during install'
  end

  def test_userlist_handles_different_users
    config = stub_config(
      postgres_user: 'postgres',
      app_user: 'boring_cache_web'
    )

    refute_equal config.postgres_user, config.app_user, 'Test requires different users'
  end

  def test_userlist_skips_app_user_when_same_as_postgres
    config = stub_config(
      postgres_user: 'postgres',
      app_user: 'postgres'
    )

    assert_equal config.postgres_user, config.app_user
  end

  def test_follow_primary_script_template_includes_repmgr_lookup
    config = stub_config(component_config: { pgbouncer: {}, repmgr: {} })
    secrets = ActivePostgres::Secrets.new(config)
    component = ActivePostgres::Components::PgBouncer.new(config, Object.new, secrets)

    content = component.instance_eval do
      repmgr_conf = '/etc/repmgr.conf'
      postgres_user = 'postgres'
      _ = [repmgr_conf, postgres_user]
      render_template('pgbouncer_follow_primary.sh.erb', binding)
    end

    assert_includes content, 'repmgr -f "$REPMGR_CONF" cluster show --csv'
    assert_includes content, 'PGBOUNCER_INI="/etc/pgbouncer/pgbouncer.ini"'
    assert_includes content, '/usr/bin/sed -i -E "s/^(\\\\* = host=)[^ ]+/\\\\1${primary_host}/"'
    assert_includes content, '${primary_host}'
  end

  def test_follow_primary_timer_template_includes_interval
    config = stub_config(component_config: { pgbouncer: {}, repmgr: {} })
    secrets = ActivePostgres::Secrets.new(config)
    component = ActivePostgres::Components::PgBouncer.new(config, Object.new, secrets)

    content = component.instance_eval do
      interval = 5
      _ = interval
      render_template('pgbouncer-follow-primary.timer.erb', binding)
    end

    assert_includes content, 'OnUnitActiveSec=5s'
  end

  def test_standby_defaults_to_localhost_when_pgbouncer_follow_primary_not_set
    config = stub_config(
      primary_host: 'primary.example.com',
      standby_hosts: ['standby.example.com'],
      primary: { 'host' => 'primary.example.com', 'private_ip' => '10.0.0.10' },
      standbys: [
        { 'host' => 'standby.example.com', 'private_ip' => '10.0.0.11' }
      ],
      component_config: {
        pgbouncer: { follow_primary: true },
        repmgr: { enabled: true },
        ssl: { enabled: false },
        core: { postgresql: { max_connections: 100 } }
      },
      component_enabled?: ->(name) { %i[pgbouncer repmgr].include?(name) }
    )

    secrets = Minitest::Mock.new
    secrets.expect(:resolve, nil, ['ssl_chain'])

    ssh_executor = Minitest::Mock.new
    2.times { ssh_executor.expect(:execute_on_host, nil) { |_host| true } }

    pgbouncer = ActivePostgres::Components::PgBouncer.new(config, ssh_executor, secrets)

    def pgbouncer.upload_template(host, template, dest, binding_obj, **opts)
      @captured_config ||= {}
      @captured_config[host] = eval('pgbouncer_config', binding_obj)
    end
    def pgbouncer.get_postgres_max_connections(*) = 100
    def pgbouncer.create_userlist(*); end
    def pgbouncer.setup_ssl_certs(*); end
    def pgbouncer.captured_config; @captured_config; end

    pgbouncer.send(:install_on_host, 'standby.example.com', is_standby: true)

    captured_config = pgbouncer.captured_config['standby.example.com']
    assert_equal '127.0.0.1', captured_config[:database_host]
  end

  def test_standby_with_pgbouncer_follow_primary_true_uses_primary_host
    config = stub_config(
      primary_host: 'primary.example.com',
      standby_hosts: ['standby.example.com'],
      primary: { 'host' => 'primary.example.com', 'private_ip' => '10.0.0.10' },
      standbys: [
        { 'host' => 'standby.example.com', 'private_ip' => '10.0.0.11', 'pgbouncer_follow_primary' => true }
      ],
      component_config: {
        pgbouncer: {},
        repmgr: { enabled: true },
        ssl: { enabled: false },
        core: { postgresql: { max_connections: 100 } }
      },
      component_enabled?: ->(name) { %i[pgbouncer repmgr].include?(name) }
    )

    secrets = Minitest::Mock.new
    secrets.expect(:resolve, nil, ['ssl_chain'])

    ssh_executor = Minitest::Mock.new
    2.times { ssh_executor.expect(:execute_on_host, nil) { |_host| true } }

    pgbouncer = ActivePostgres::Components::PgBouncer.new(config, ssh_executor, secrets)

    def pgbouncer.upload_template(host, template, dest, binding_obj, **opts)
      @captured_config ||= {}
      @captured_config[host] = eval('pgbouncer_config', binding_obj)
    end
    def pgbouncer.get_postgres_max_connections(*) = 100
    def pgbouncer.create_userlist(*); end
    def pgbouncer.setup_ssl_certs(*); end
    def pgbouncer.install_follow_primary(*); end
    def pgbouncer.captured_config; @captured_config; end

    pgbouncer.send(:install_on_host, 'standby.example.com', is_standby: true)

    captured_config = pgbouncer.captured_config['standby.example.com']
    assert_equal '10.0.0.10', captured_config[:database_host]
  end

  def test_standby_with_pgbouncer_follow_primary_false_uses_localhost
    config = stub_config(
      primary_host: 'primary.example.com',
      standby_hosts: ['standby.example.com'],
      primary: { 'host' => 'primary.example.com', 'private_ip' => '10.0.0.10' },
      standbys: [
        { 'host' => 'standby.example.com', 'private_ip' => '10.0.0.11', 'pgbouncer_follow_primary' => false }
      ],
      component_config: {
        pgbouncer: { follow_primary: true },
        repmgr: { enabled: true },
        ssl: { enabled: false },
        core: { postgresql: { max_connections: 100 } }
      },
      component_enabled?: ->(name) { %i[pgbouncer repmgr].include?(name) }
    )

    secrets = Minitest::Mock.new
    secrets.expect(:resolve, nil, ['ssl_chain'])

    ssh_executor = Minitest::Mock.new
    2.times { ssh_executor.expect(:execute_on_host, nil) { |_host| true } }

    pgbouncer = ActivePostgres::Components::PgBouncer.new(config, ssh_executor, secrets)

    def pgbouncer.upload_template(host, template, dest, binding_obj, **opts)
      @captured_config ||= {}
      @captured_config[host] = eval('pgbouncer_config', binding_obj)
    end
    def pgbouncer.get_postgres_max_connections(*) = 100
    def pgbouncer.create_userlist(*); end
    def pgbouncer.setup_ssl_certs(*); end
    def pgbouncer.captured_config; @captured_config; end

    pgbouncer.send(:install_on_host, 'standby.example.com', is_standby: true)

    captured_config = pgbouncer.captured_config['standby.example.com']
    assert_equal '127.0.0.1', captured_config[:database_host]
  end

  def test_primary_uses_global_follow_primary_setting
    config = stub_config(
      primary_host: 'primary.example.com',
      standby_hosts: [],
      primary: { 'host' => 'primary.example.com', 'private_ip' => '10.0.0.10' },
      standbys: [],
      component_config: {
        pgbouncer: { follow_primary: true },
        repmgr: { enabled: true },
        ssl: { enabled: false },
        core: { postgresql: { max_connections: 100 } }
      },
      component_enabled?: ->(name) { %i[pgbouncer repmgr].include?(name) }
    )

    secrets = Minitest::Mock.new
    secrets.expect(:resolve, nil, ['ssl_chain'])

    ssh_executor = Minitest::Mock.new
    2.times { ssh_executor.expect(:execute_on_host, nil) { |_host| true } }

    pgbouncer = ActivePostgres::Components::PgBouncer.new(config, ssh_executor, secrets)

    def pgbouncer.upload_template(host, template, dest, binding_obj, **opts)
      @captured_config ||= {}
      @captured_config[host] = eval('pgbouncer_config', binding_obj)
    end
    def pgbouncer.get_postgres_max_connections(*) = 100
    def pgbouncer.create_userlist(*); end
    def pgbouncer.setup_ssl_certs(*); end
    def pgbouncer.install_follow_primary(*); end
    def pgbouncer.captured_config; @captured_config; end

    pgbouncer.send(:install_on_host, 'primary.example.com', is_standby: false)

    captured_config = pgbouncer.captured_config['primary.example.com']
    assert_equal '10.0.0.10', captured_config[:database_host]
  end

  def test_primary_without_follow_primary_uses_localhost
    config = stub_config(
      primary_host: 'primary.example.com',
      standby_hosts: [],
      primary: { 'host' => 'primary.example.com', 'private_ip' => '10.0.0.10' },
      standbys: [],
      component_config: {
        pgbouncer: { follow_primary: false },
        repmgr: { enabled: true },
        ssl: { enabled: false },
        core: { postgresql: { max_connections: 100 } }
      },
      component_enabled?: ->(name) { %i[pgbouncer repmgr].include?(name) }
    )

    secrets = Minitest::Mock.new
    secrets.expect(:resolve, nil, ['ssl_chain'])

    ssh_executor = Minitest::Mock.new
    2.times { ssh_executor.expect(:execute_on_host, nil) { |_host| true } }

    pgbouncer = ActivePostgres::Components::PgBouncer.new(config, ssh_executor, secrets)

    def pgbouncer.upload_template(host, template, dest, binding_obj, **opts)
      @captured_config ||= {}
      @captured_config[host] = eval('pgbouncer_config', binding_obj)
    end
    def pgbouncer.get_postgres_max_connections(*) = 100
    def pgbouncer.create_userlist(*); end
    def pgbouncer.setup_ssl_certs(*); end
    def pgbouncer.captured_config; @captured_config; end

    pgbouncer.send(:install_on_host, 'primary.example.com', is_standby: false)

    captured_config = pgbouncer.captured_config['primary.example.com']
    assert_equal '127.0.0.1', captured_config[:database_host]
  end

  def test_mixed_standby_configuration
    config = stub_config(
      primary_host: 'primary.example.com',
      standby_hosts: ['replica-london.example.com', 'standby-virginia.example.com'],
      primary: { 'host' => 'primary.example.com', 'private_ip' => '10.0.0.10' },
      standbys: [
        { 'host' => 'replica-london.example.com', 'private_ip' => '10.0.0.11' },
        { 'host' => 'standby-virginia.example.com', 'private_ip' => '10.0.0.12', 'pgbouncer_follow_primary' => true }
      ],
      component_config: {
        pgbouncer: { follow_primary: true },
        repmgr: { enabled: true },
        ssl: { enabled: false },
        core: { postgresql: { max_connections: 100 } }
      },
      component_enabled?: ->(name) { %i[pgbouncer repmgr].include?(name) }
    )

    secrets = Minitest::Mock.new
    3.times { secrets.expect(:resolve, nil, ['ssl_chain']) }

    ssh_executor = Minitest::Mock.new
    6.times { ssh_executor.expect(:execute_on_host, nil) { |_host| true } }

    pgbouncer = ActivePostgres::Components::PgBouncer.new(config, ssh_executor, secrets)

    def pgbouncer.upload_template(host, template, dest, binding_obj, **opts)
      @captured_config ||= {}
      @captured_config[host] = eval('pgbouncer_config', binding_obj)
    end
    def pgbouncer.get_postgres_max_connections(*) = 100
    def pgbouncer.create_userlist(*); end
    def pgbouncer.setup_ssl_certs(*); end
    def pgbouncer.install_follow_primary(*); end
    def pgbouncer.captured_config; @captured_config; end

    pgbouncer.send(:install_on_host, 'primary.example.com', is_standby: false)
    pgbouncer.send(:install_on_host, 'replica-london.example.com', is_standby: true)
    pgbouncer.send(:install_on_host, 'standby-virginia.example.com', is_standby: true)

    captured = pgbouncer.captured_config

    assert_equal '10.0.0.10', captured['primary.example.com'][:database_host]
    assert_equal '127.0.0.1', captured['replica-london.example.com'][:database_host]
    assert_equal '10.0.0.10', captured['standby-virginia.example.com'][:database_host]
  end

  def test_install_correctly_identifies_standbys
    config = stub_config(
      primary_host: 'primary.example.com',
      standby_hosts: ['standby.example.com'],
      primary: { 'host' => 'primary.example.com', 'private_ip' => '10.0.0.10' },
      standbys: [
        { 'host' => 'standby.example.com', 'private_ip' => '10.0.0.11' }
      ],
      component_config: {
        pgbouncer: {},
        ssl: { enabled: false },
        core: { postgresql: { max_connections: 100 } }
      }
    )

    secrets = Minitest::Mock.new
    2.times { secrets.expect(:resolve, nil, ['ssl_chain']) }

    ssh_executor = Minitest::Mock.new
    2.times { ssh_executor.expect(:execute_on_host, nil) { |_host| true } }

    pgbouncer = ActivePostgres::Components::PgBouncer.new(config, ssh_executor, secrets)

    installed_hosts = []
    pgbouncer.define_singleton_method(:install_on_host) do |host, is_standby:|
      installed_hosts << { host: host, is_standby: is_standby }
    end

    pgbouncer.install

    primary_install = installed_hosts.find { |h| h[:host] == 'primary.example.com' }
    standby_install = installed_hosts.find { |h| h[:host] == 'standby.example.com' }

    refute primary_install[:is_standby]
    assert standby_install[:is_standby]
  end

  def test_install_on_standby_sets_is_standby_true
    config = stub_config(
      primary_host: 'primary.example.com',
      standby_hosts: ['standby.example.com'],
      primary: { 'host' => 'primary.example.com', 'private_ip' => '10.0.0.10' },
      standbys: [
        { 'host' => 'standby.example.com', 'private_ip' => '10.0.0.11' }
      ],
      component_config: {
        pgbouncer: {},
        ssl: { enabled: false },
        core: { postgresql: { max_connections: 100 } }
      }
    )

    secrets = Minitest::Mock.new
    secrets.expect(:resolve, nil, ['ssl_chain'])

    ssh_executor = Object.new

    pgbouncer = ActivePostgres::Components::PgBouncer.new(config, ssh_executor, secrets)

    captured_is_standby = nil
    pgbouncer.define_singleton_method(:install_on_host) do |host, is_standby:|
      captured_is_standby = is_standby
    end

    pgbouncer.install_on_standby('standby.example.com')

    assert captured_is_standby
  end

  def test_pgbouncer_follow_primary_requires_repmgr_on_standby
    config = stub_config(
      primary_host: 'primary.example.com',
      standby_hosts: ['standby.example.com'],
      primary: { 'host' => 'primary.example.com', 'private_ip' => '10.0.0.10' },
      standbys: [
        { 'host' => 'standby.example.com', 'private_ip' => '10.0.0.11', 'pgbouncer_follow_primary' => true }
      ],
      component_config: {
        pgbouncer: {},
        repmgr: { enabled: false },
        ssl: { enabled: false },
        core: { postgresql: { max_connections: 100 } }
      },
      component_enabled?: ->(name) { name == :pgbouncer }
    )

    secrets = Minitest::Mock.new
    ssh_executor = Object.new

    pgbouncer = ActivePostgres::Components::PgBouncer.new(config, ssh_executor, secrets)

    def pgbouncer.get_postgres_max_connections(*) = 100

    error = assert_raises(ActivePostgres::Error) do
      pgbouncer.send(:install_on_host, 'standby.example.com', is_standby: true)
    end

    assert_match(/follow_primary requires repmgr/i, error.message)
  end

  def test_standby_config_not_found_defaults_to_localhost
    config = stub_config(
      primary_host: 'primary.example.com',
      standby_hosts: ['unknown-standby.example.com'],
      primary: { 'host' => 'primary.example.com', 'private_ip' => '10.0.0.10' },
      standbys: [],
      component_config: {
        pgbouncer: { follow_primary: true },
        repmgr: { enabled: true },
        ssl: { enabled: false },
        core: { postgresql: { max_connections: 100 } }
      },
      component_enabled?: ->(name) { %i[pgbouncer repmgr].include?(name) }
    )

    secrets = Minitest::Mock.new
    secrets.expect(:resolve, nil, ['ssl_chain'])

    ssh_executor = Minitest::Mock.new
    2.times { ssh_executor.expect(:execute_on_host, nil) { |_host| true } }

    pgbouncer = ActivePostgres::Components::PgBouncer.new(config, ssh_executor, secrets)

    def pgbouncer.upload_template(host, template, dest, binding_obj, **opts)
      @captured_config ||= {}
      @captured_config[host] = eval('pgbouncer_config', binding_obj)
    end
    def pgbouncer.get_postgres_max_connections(*) = 100
    def pgbouncer.create_userlist(*); end
    def pgbouncer.setup_ssl_certs(*); end
    def pgbouncer.captured_config; @captured_config; end

    pgbouncer.send(:install_on_host, 'unknown-standby.example.com', is_standby: true)

    captured_config = pgbouncer.captured_config['unknown-standby.example.com']
    assert_equal '127.0.0.1', captured_config[:database_host]
  end

  def test_global_follow_primary_ignored_for_standbys
    config = stub_config(
      primary_host: 'primary.example.com',
      standby_hosts: ['standby.example.com'],
      primary: { 'host' => 'primary.example.com', 'private_ip' => '10.0.0.10' },
      standbys: [
        { 'host' => 'standby.example.com', 'private_ip' => '10.0.0.11' }
      ],
      component_config: {
        pgbouncer: { follow_primary: true },
        repmgr: { enabled: true },
        ssl: { enabled: false },
        core: { postgresql: { max_connections: 100 } }
      },
      component_enabled?: ->(name) { %i[pgbouncer repmgr].include?(name) }
    )

    secrets = Minitest::Mock.new
    2.times { secrets.expect(:resolve, nil, ['ssl_chain']) }

    ssh_executor = Minitest::Mock.new
    4.times { ssh_executor.expect(:execute_on_host, nil) { |_host| true } }

    pgbouncer = ActivePostgres::Components::PgBouncer.new(config, ssh_executor, secrets)

    def pgbouncer.upload_template(host, template, dest, binding_obj, **opts)
      @captured_config ||= {}
      @captured_config[host] = eval('pgbouncer_config', binding_obj)
    end
    def pgbouncer.get_postgres_max_connections(*) = 100
    def pgbouncer.create_userlist(*); end
    def pgbouncer.setup_ssl_certs(*); end
    def pgbouncer.install_follow_primary(*); end
    def pgbouncer.captured_config; @captured_config; end

    pgbouncer.send(:install_on_host, 'primary.example.com', is_standby: false)
    pgbouncer.send(:install_on_host, 'standby.example.com', is_standby: true)

    assert_equal '10.0.0.10', pgbouncer.captured_config['primary.example.com'][:database_host]
    assert_equal '127.0.0.1', pgbouncer.captured_config['standby.example.com'][:database_host]
  end
end
