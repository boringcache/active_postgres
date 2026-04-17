require 'test_helper'

class PgBouncerTemplatesTest < Minitest::Test
  def setup
    @config = stub_config(
      primary_host: 'primary.example.com',
      standby_hosts: ['standby.example.com'],
      version: 16,
      primary: { 'host' => 'primary.example.com', 'private_ip' => '10.0.0.10' },
      standbys: [{ 'host' => 'standby.example.com', 'private_ip' => '10.0.0.11' }],
      postgres_user: 'postgres'
    )
    @secrets = ActivePostgres::Secrets.new(@config)
    @component = pgbouncer_component(@config, @secrets)
  end

  def test_ini_uses_database_host_from_config
    content = render_ini({ database_host: '10.0.0.10', database_port: 5432 })

    assert_includes content, '* = host=10.0.0.10 port=5432'
  end

  def test_ini_defaults_to_localhost
    content = render_ini({})

    assert_includes content, '* = host=127.0.0.1 port=5432'
  end

  def test_ini_uses_custom_listen_port
    content = render_ini({ listen_port: 6433 })

    assert_includes content, 'listen_port = 6433'
  end

  def test_ini_defaults_listen_port_to_6432
    content = render_ini({})

    assert_includes content, 'listen_port = 6432'
  end

  def test_ini_uses_transaction_pool_mode_by_default
    content = render_ini({})

    assert_includes content, 'pool_mode = transaction'
  end

  def test_ini_uses_custom_pool_mode
    content = render_ini({ pool_mode: 'session' })

    assert_includes content, 'pool_mode = session'
  end

  def test_ini_includes_ssl_when_enabled
    content = render_ini({}, ssl_enabled: true)

    assert_includes content, 'client_tls_sslmode = require'
    assert_includes content, 'client_tls_key_file = /etc/pgbouncer/server.key'
    assert_includes content, 'client_tls_cert_file = /etc/pgbouncer/server.crt'
  end

  def test_ini_includes_ca_cert_when_present
    content = render_ini({}, ssl_enabled: true, has_ca_cert: true)

    assert_includes content, 'client_tls_ca_file = /etc/pgbouncer/ca.crt'
  end

  def test_ini_omits_ssl_when_disabled
    content = render_ini({})

    refute_includes content, 'client_tls_sslmode'
  end

  def test_ini_uses_scram_sha_256_auth_by_default
    content = render_ini({})

    assert_includes content, 'auth_type = scram-sha-256'
  end

  def test_ini_includes_pool_settings
    content = render_ini({ max_client_conn: 500, default_pool_size: 50, reserve_pool_size: 10 })

    assert_includes content, 'max_client_conn = 500'
    assert_includes content, 'default_pool_size = 50'
    assert_includes content, 'reserve_pool_size = 10'
  end

  def test_ini_includes_optional_max_db_connections
    content = render_ini({ max_db_connections: 100 })

    assert_includes content, 'max_db_connections = 100'
  end

  def test_ini_omits_max_db_connections_when_not_set
    content = render_ini({})

    refute_includes content, 'max_db_connections'
  end

  def test_ini_includes_admin_users
    content = render_ini({})

    assert_includes content, 'admin_users = postgres'
    assert_includes content, 'stats_users = postgres'
  end

  def test_follow_script_uses_repmgr
    content = render_follow_script

    assert_includes content, 'REPMGR_DB="repmgr"'
    assert_includes content, 'psql -h /var/run/postgresql -d "$REPMGR_DB" -tAF'
    assert_includes content, 'SELECT type, conninfo FROM repmgr.nodes WHERE active = true'
  end

  def test_follow_script_uses_postgres_user
    content = render_follow_script(postgres_user: 'pgadmin')

    assert_includes content, 'sudo -u pgadmin'
  end

  def test_follow_script_extracts_primary_from_repmgr_nodes
    content = render_follow_script

    assert_includes content, '$1 == "primary"'
  end

  def test_follow_script_updates_pgbouncer_ini
    content = render_follow_script

    assert_includes content, 'PGBOUNCER_INI="/etc/pgbouncer/pgbouncer.ini"'
    assert_includes content, '/usr/bin/sed -i -E'
    assert_includes content, '${primary_host}'
  end

  def test_follow_script_reloads_pgbouncer
    content = render_follow_script

    assert_includes content, '/usr/bin/systemctl reload "$PGBOUNCER_SERVICE"'
  end

  def test_follow_script_logs_updates
    content = render_follow_script

    assert_includes content, 'LOG_TAG="pgbouncer-follow-primary"'
    assert_includes content, '/usr/bin/logger -t "$LOG_TAG"'
  end

  def test_follow_script_exits_early_on_empty_cluster
    content = render_follow_script

    assert_includes content, 'if [[ -z "$cluster_nodes" ]]; then'
    assert_includes content, 'exit 0'
  end

  def test_follow_script_skips_update_when_host_matches
    content = render_follow_script

    assert_includes content, 'if [[ "$current_host" != "$primary_host" ]]; then'
  end

  def test_follow_timer_uses_interval
    content = render_follow_timer(5)

    assert_includes content, 'OnUnitActiveSec=5s'
  end

  def test_follow_timer_starts_on_boot
    content = render_follow_timer(5)

    assert_includes content, 'OnBootSec=10s'
  end

  def test_follow_timer_references_service
    content = render_follow_timer(5)

    assert_includes content, 'Unit=pgbouncer-follow-primary.service'
  end

  def test_follow_timer_installs_to_timers_target
    content = render_follow_timer(5)

    assert_includes content, 'WantedBy=timers.target'
  end

  def test_follow_service_is_oneshot
    content = render_follow_service

    assert_includes content, 'Type=oneshot'
  end

  def test_follow_service_runs_script
    content = render_follow_service

    assert_includes content, 'ExecStart=/usr/local/bin/pgbouncer-follow-primary'
  end

  def test_follow_service_waits_for_network
    content = render_follow_service

    assert_includes content, 'After=network-online.target'
  end

  private

  def render_ini(pgbouncer_config, ssl_enabled: false, has_ca_cert: false)
    config = @config
    secrets_obj = @secrets
    @component.instance_eval do
      _ = [pgbouncer_config, ssl_enabled, has_ca_cert, config, secrets_obj]
      render_template('pgbouncer.ini.erb', binding)
    end
  end

  def render_follow_script(postgres_user: 'postgres')
    @component.instance_eval do
      repmgr_conf = '/etc/repmgr.conf'
      repmgr_database = 'repmgr'
      _ = [repmgr_conf, repmgr_database, postgres_user]
      render_template('pgbouncer_follow_primary.sh.erb', binding)
    end
  end

  def render_follow_timer(interval)
    @component.instance_eval do
      _ = interval
      render_template('pgbouncer-follow-primary.timer.erb', binding)
    end
  end

  def render_follow_service
    @component.instance_eval do
      render_template('pgbouncer-follow-primary.service.erb', binding)
    end
  end
end
