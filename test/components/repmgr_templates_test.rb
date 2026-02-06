require 'test_helper'

class RepmgrTemplatesTest < Minitest::Test
  def setup
    @config = stub_config(
      primary_host: 'primary.example.com',
      standby_hosts: ['standby.example.com'],
      version: 16,
      primary: { 'host' => 'primary.example.com', 'private_ip' => '10.0.0.10', 'label' => 'db-primary' },
      standbys: [{ 'host' => 'standby.example.com', 'private_ip' => '10.0.0.11', 'label' => 'db-standby' }],
      postgres_user: 'postgres',
      repmgr_user: 'repmgr',
      repmgr_database: 'repmgr'
    )
    @secrets = ActivePostgres::Secrets.new(@config)
    @component = repmgr_component(@config, @secrets)
  end

  def test_conf_includes_primary_node_info
    content = render_conf({}, host: 'primary.example.com')

    assert_includes content, 'node_id=1'
    assert_includes content, "node_name='db-primary'"
  end

  def test_conf_uses_standby_node_id
    content = render_conf({}, host: 'standby.example.com')

    assert_includes content, 'node_id=2'
    assert_includes content, "node_name='db-standby'"
  end

  def test_conf_uses_private_ip_for_conninfo
    content = render_conf({}, host: 'primary.example.com')

    assert_includes content, "conninfo='host=10.0.0.10 user=repmgr dbname=repmgr connect_timeout=2'"
  end

  def test_conf_sets_automatic_failover_by_default
    content = render_conf({}, host: 'primary.example.com')

    assert_includes content, 'failover=automatic'
  end

  def test_conf_sets_manual_failover_when_configured
    content = render_conf({ auto_failover: false }, host: 'primary.example.com')

    assert_includes content, 'failover=manual'
  end

  def test_conf_includes_promote_command_for_standby
    content = render_conf({}, host: 'standby.example.com')

    assert_includes content, "promote_command='repmgr standby promote -f /etc/repmgr.conf'"
  end

  def test_conf_includes_follow_command_for_standby
    content = render_conf({}, host: 'standby.example.com')

    assert_includes content, "follow_command='repmgr standby follow -f /etc/repmgr.conf --upstream-node-id=%n'"
  end

  def test_conf_omits_promote_command_for_primary
    content = render_conf({}, host: 'primary.example.com')

    refute_includes content, 'promote_command'
    refute_includes content, 'follow_command'
  end

  def test_conf_includes_custom_reconnect_settings
    content = render_conf({ reconnect_attempts: 10, reconnect_interval: 15 }, host: 'primary.example.com')

    assert_includes content, 'reconnect_attempts=10'
    assert_includes content, 'reconnect_interval=15'
  end

  def test_conf_uses_default_reconnect_settings
    content = render_conf({}, host: 'primary.example.com')

    assert_includes content, 'reconnect_attempts=6'
    assert_includes content, 'reconnect_interval=10'
  end

  def test_conf_includes_use_rewind_when_enabled
    content = render_conf({ use_rewind: true }, host: 'primary.example.com')

    assert_includes content, 'use_rewind=yes'
  end

  def test_conf_includes_use_rewind_no_when_false
    content = render_conf({ use_rewind: false }, host: 'primary.example.com')

    assert_includes content, 'use_rewind=no'
  end

  def test_conf_omits_use_rewind_when_not_set
    content = render_conf({}, host: 'primary.example.com')

    refute_includes content, 'use_rewind'
  end

  def test_conf_includes_dns_failover_event_hook
    content = render_conf({ dns_failover: { enabled: true } }, host: 'primary.example.com')

    assert_includes content, "event_notification_command='/usr/local/bin/active-postgres-dns-failover'"
  end

  def test_conf_includes_default_dns_events
    content = render_conf({ dns_failover: { enabled: true } }, host: 'primary.example.com')

    assert_includes content, 'repmgrd_failover_promote,standby_promote,standby_switchover,standby_follow'
  end

  def test_conf_includes_custom_dns_events
    content = render_conf({ dns_failover: { enabled: true, events: 'standby_promote' } }, host: 'primary.example.com')

    assert_includes content, "event_notifications='standby_promote'"
  end

  def test_conf_omits_dns_failover_when_disabled
    content = render_conf({}, host: 'primary.example.com')

    refute_includes content, 'event_notification_command'
  end

  def test_conf_includes_monitoring_settings
    content = render_conf({}, host: 'primary.example.com')

    assert_includes content, 'monitoring_history=yes'
    assert_includes content, 'monitor_interval_secs=5'
  end

  def test_conf_includes_log_settings
    content = render_conf({}, host: 'primary.example.com')

    assert_includes content, 'log_level=INFO'
    assert_includes content, "log_file='/var/log/postgresql/repmgr.log'"
  end

  def test_conf_includes_data_directory
    content = render_conf({}, host: 'primary.example.com')

    assert_includes content, "data_directory='/var/lib/postgresql/16/main'"
  end

  def test_dns_script_uses_single_primary_record
    content = render_dns_script(
      primary_records: ['db-primary.mesh.internal'],
      replica_records: ['db-replica.mesh.internal']
    )

    assert_includes content, 'PRIMARY_RECORDS=(db-primary.mesh.internal)'
    assert_includes content, 'REPLICA_RECORDS=(db-replica.mesh.internal)'
  end

  def test_dns_script_uses_multiple_records
    content = render_dns_script(
      primary_records: ['db-primary.mesh.internal', 'db-primary.mesh.v2.internal'],
      replica_records: ['db-replica.mesh.internal', 'db-replica.mesh.v2.internal']
    )

    assert_includes content, 'PRIMARY_RECORDS=(db-primary.mesh.internal db-primary.mesh.v2.internal)'
    assert_includes content, 'REPLICA_RECORDS=(db-replica.mesh.internal db-replica.mesh.v2.internal)'
  end

  def test_dns_script_iterates_primary_records
    content = render_dns_script(
      primary_records: ['db.mesh'],
      replica_records: ['db-replica.mesh']
    )

    assert_includes content, 'for record in "${PRIMARY_RECORDS[@]}"'
    assert_includes content, 'printf -v content \'%saddress=/%s/%s\\n\' "$content" "$record" "$primary_host"'
  end

  def test_dns_script_iterates_replica_records_for_each_standby
    content = render_dns_script(
      primary_records: ['db.mesh'],
      replica_records: ['db-replica.mesh']
    )

    assert_includes content, 'for record in "${REPLICA_RECORDS[@]}"'
    assert_includes content, 'for host in $standby_hosts'
  end

  def test_dns_script_uses_dns_servers
    content = render_dns_script(
      dns_servers: ['10.0.0.50', '10.0.0.51'],
      primary_records: ['db.mesh'],
      replica_records: ['db-replica.mesh']
    )

    assert_includes content, 'DNS_SERVERS=(10.0.0.50 10.0.0.51)'
  end

  def test_dns_script_uses_ssh_key_path
    content = render_dns_script(
      dns_ssh_key_path: '/custom/path/dns_key',
      primary_records: ['db.mesh'],
      replica_records: ['db-replica.mesh']
    )

    assert_includes content, 'DNS_SSH_KEY="/custom/path/dns_key"'
  end

  def test_dns_script_uses_strict_host_key_checking
    content = render_dns_script(
      ssh_strict_host_key: 'accept-new',
      primary_records: ['db.mesh'],
      replica_records: ['db-replica.mesh']
    )

    assert_includes content, 'SSH_STRICT_HOST_KEY="accept-new"'
    assert_includes content, '-o StrictHostKeyChecking="$SSH_STRICT_HOST_KEY"'
  end

  def test_dns_script_updates_dnsmasq_conf
    content = render_dns_script(
      primary_records: ['db.mesh'],
      replica_records: ['db-replica.mesh']
    )

    assert_includes content, 'DNSMASQ_FILE="/etc/dnsmasq.d/active_postgres.conf"'
    assert_includes content, 'cat > ${DNSMASQ_FILE}'
  end

  def test_dns_script_reloads_dnsmasq
    content = render_dns_script(
      primary_records: ['db.mesh'],
      replica_records: ['db-replica.mesh']
    )

    assert_includes content, 'sudo systemctl reload dnsmasq || sudo systemctl restart dnsmasq'
  end

  def test_dns_script_logs_updates
    content = render_dns_script(
      primary_records: ['db.mesh'],
      replica_records: ['db-replica.mesh']
    )

    assert_includes content, 'LOG_TAG="active_postgres_dns"'
    assert_includes content, '/usr/bin/logger -t "$LOG_TAG"'
  end

  def test_dns_script_extracts_primary_from_repmgr
    content = render_dns_script(
      primary_records: ['db.mesh'],
      replica_records: ['db-replica.mesh']
    )

    assert_includes content, 'repmgr -f "$REPMGR_CONF" cluster show --csv'
    assert_includes content, "tolower($3) ~ /primary/"
  end

  def test_dns_script_extracts_standbys_from_repmgr
    content = render_dns_script(
      primary_records: ['db.mesh'],
      replica_records: ['db-replica.mesh']
    )

    assert_includes content, "tolower($3) ~ /standby/"
    assert_includes content, 'sort -u'
  end

  def test_dns_script_skips_empty_records
    content = render_dns_script(
      primary_records: ['db.mesh'],
      replica_records: ['db-replica.mesh']
    )

    assert_includes content, 'if [[ -n "$record" ]]; then'
    assert_includes content, 'if [[ -z "$record" ]]; then'
    assert_includes content, 'continue'
  end

  private

  def render_conf(repmgr_config, host:)
    config = @config
    @component.instance_eval do
      _ = [config, host, repmgr_config]
      render_template('repmgr.conf.erb', binding)
    end
  end

  def render_dns_script(primary_records:, replica_records:, dns_servers: ['10.0.0.50'], dns_user: 'ubuntu', dns_ssh_key_path: '/var/lib/postgresql/.ssh/active_postgres_dns', ssh_strict_host_key: 'accept-new')
    @component.instance_eval do
      _ = [dns_user, dns_servers, dns_ssh_key_path, ssh_strict_host_key, primary_records, replica_records]
      render_template('repmgr_dns_failover.sh.erb', binding)
    end
  end
end
