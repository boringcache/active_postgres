require 'test_helper'

class RepmgrTest < Minitest::Test
  def setup
    @config = stub_config
    @secrets = ActivePostgres::Secrets.new(@config)
    @ssh_executor = Object.new
    @component = ActivePostgres::Components::Repmgr.new(@config, @ssh_executor, @secrets)
  end

  def test_pgpass_content_escapes_colons_and_backslashes
    password = 'pa:ss\word'
    replication_password = 're:pl\word'
    content = @component.send(:build_pgpass_content, 'standby.example.com', password,
                              replication_password: replication_password, primary_ip: '10.0.0.10')

    assert_includes content, 'localhost:5432:repmgr:repmgr:pa\\:ss\\\\word'
    assert_includes content, '10.0.0.10:5432:*:repmgr:pa\\:ss\\\\word'
    assert_includes content, '10.0.0.11:5432:*:repmgr:pa\\:ss\\\\word'
    assert_includes content, 'localhost:5432:replication:replication:re\\:pl\\\\word'
    assert_includes content, '10.0.0.10:5432:*:replication:re\\:pl\\\\word'
  end

  def test_normalize_repmgr_password_strips_trailing_whitespace
    password = @component.send(:normalize_repmgr_password, "s3cret\n")
    assert_equal 's3cret', password
  end

  def test_normalize_repmgr_password_raises_when_empty
    assert_raises RuntimeError do
      @component.send(:normalize_repmgr_password, "\n\n")
    end
  end

  def test_build_primary_conninfo_uses_primary_replication_host
    label = 'standby-node'
    conninfo = @component.send(:build_primary_conninfo, label)

    assert_equal 'host=10.0.0.10 user=repmgr dbname=repmgr application_name=standby-node', conninfo
  end

  def test_build_primary_conninfo_uses_replication_user_when_password_present
    config = stub_config(secrets_config: { 'replication_password' => 'secret' }, replication_user: 'repl_user')
    secrets = ActivePostgres::Secrets.new(config)
    component = ActivePostgres::Components::Repmgr.new(config, Object.new, secrets)

    conninfo = component.send(:build_primary_conninfo, 'standby-node')

    assert_equal 'host=10.0.0.10 user=repl_user dbname=replication application_name=standby-node', conninfo
  end

  def test_normalize_dns_servers_handles_hash_and_string
    raw = [
      { 'host' => 'public.example.com', 'private_ip' => '10.0.0.10' },
      { 'ssh_host' => 'ssh.example.com', 'private_ip' => '10.0.0.11' },
      '10.0.0.12'
    ]

    normalized = @component.send(:normalize_dns_servers, raw)

    assert_equal 'public.example.com', normalized[0][:ssh_host]
    assert_equal '10.0.0.10', normalized[0][:private_ip]
    assert_equal 'ssh.example.com', normalized[1][:ssh_host]
    assert_equal '10.0.0.11', normalized[1][:private_ip]
    assert_equal '10.0.0.12', normalized[2][:ssh_host]
    assert_equal '10.0.0.12', normalized[2][:private_ip]
  end

  def test_dns_failover_script_uses_primary_only_for_writer_record
    content = @component.instance_eval do
      dns_user = 'ubuntu'
      dns_servers = ['10.0.0.10', '10.0.0.11']
      dns_ssh_key_path = '/var/lib/postgresql/.ssh/active_postgres_dns'
      ssh_strict_host_key = 'accept-new'
      primary_records = ['db-primary.mesh.internal']
      replica_records = ['db-replica.mesh.internal']
      _ = [dns_user, dns_servers, dns_ssh_key_path, ssh_strict_host_key, primary_records, replica_records]
      render_template('repmgr_dns_failover.sh.erb', binding)
    end

    assert_includes content, 'primary_host'
    refute_includes content, 'all_hosts='
    assert_includes content, 'for host in $standby_hosts'
    assert_includes content, 'printf -v content'
    assert_includes content, 'PRIMARY_RECORDS'
    assert_includes content, 'REPLICA_RECORDS'
    assert_includes content, '"$record" "$primary_host"'
    assert_includes content, '"$record" "$host"'
  end

  def test_normalize_dns_domains_with_multiple_entries
    dns_config = { domains: ['mesh.internal', 'mesh.v2.internal'] }
    domains = @component.send(:normalize_dns_domains, dns_config)

    assert_equal ['mesh.internal', 'mesh.v2.internal'], domains
  end

  def test_normalize_dns_domains_with_single_domain
    dns_config = { domain: 'mesh.internal' }
    domains = @component.send(:normalize_dns_domains, dns_config)

    assert_equal ['mesh.internal'], domains
  end

  def test_normalize_dns_domains_defaults_to_mesh
    dns_config = {}
    domains = @component.send(:normalize_dns_domains, dns_config)

    assert_equal ['mesh'], domains
  end

  def test_normalize_dns_domains_strips_whitespace
    dns_config = { domains: ['  mesh.internal  ', 'mesh.v2.internal'] }
    domains = @component.send(:normalize_dns_domains, dns_config)

    assert_equal ['mesh.internal', 'mesh.v2.internal'], domains
  end

  def test_normalize_dns_domains_rejects_empty_strings
    dns_config = { domains: ['mesh.internal', '', '  ', 'mesh.v2.internal'] }
    domains = @component.send(:normalize_dns_domains, dns_config)

    assert_equal ['mesh.internal', 'mesh.v2.internal'], domains
  end

  def test_normalize_dns_records_defaults_to_domains
    records = @component.send(:normalize_dns_records, nil, default_prefix: 'db-primary', domains: ['mesh.internal'])

    assert_equal ['db-primary.mesh.internal'], records
  end

  def test_normalize_dns_records_with_explicit_records
    records = @component.send(:normalize_dns_records, ['db.example.com', 'db.v2.example.com'],
                              default_prefix: 'db-primary', domains: ['mesh.internal'])

    assert_equal ['db.example.com', 'db.v2.example.com'], records
  end

  def test_normalize_dns_records_with_multiple_domains
    records = @component.send(:normalize_dns_records, nil, default_prefix: 'db-primary',
                              domains: ['mesh.internal', 'mesh.v2.internal'])

    assert_equal ['db-primary.mesh.internal', 'db-primary.mesh.v2.internal'], records
  end

  def test_normalize_dns_records_strips_whitespace
    records = @component.send(:normalize_dns_records, ['  db.example.com  '],
                              default_prefix: 'db-primary', domains: ['mesh.internal'])

    assert_equal ['db.example.com'], records
  end

  def test_normalize_dns_records_rejects_empty_strings
    records = @component.send(:normalize_dns_records, ['db.example.com', '', '  '],
                              default_prefix: 'db-primary', domains: ['mesh.internal'])

    assert_equal ['db.example.com'], records
  end

  def test_dns_failover_script_with_multiple_domains
    content = @component.instance_eval do
      dns_user = 'ubuntu'
      dns_servers = ['10.0.0.10']
      dns_ssh_key_path = '/var/lib/postgresql/.ssh/active_postgres_dns'
      ssh_strict_host_key = 'accept-new'
      primary_records = ['db-primary.mesh.internal', 'db-primary.mesh.v2.internal']
      replica_records = ['db-replica.mesh.internal', 'db-replica.mesh.v2.internal']
      _ = [dns_user, dns_servers, dns_ssh_key_path, ssh_strict_host_key, primary_records, replica_records]
      render_template('repmgr_dns_failover.sh.erb', binding)
    end

    assert_includes content, 'PRIMARY_RECORDS=(db-primary.mesh.internal db-primary.mesh.v2.internal)'
    assert_includes content, 'REPLICA_RECORDS=(db-replica.mesh.internal db-replica.mesh.v2.internal)'
    assert_includes content, 'for record in "${PRIMARY_RECORDS[@]}"'
    assert_includes content, 'for record in "${REPLICA_RECORDS[@]}"'
  end

  def test_dns_failover_script_iterates_all_primary_records
    content = @component.instance_eval do
      dns_user = 'ubuntu'
      dns_servers = ['10.0.0.10']
      dns_ssh_key_path = '/var/lib/postgresql/.ssh/active_postgres_dns'
      ssh_strict_host_key = 'accept-new'
      primary_records = ['db-primary.mesh.internal']
      replica_records = ['db-replica.mesh.internal']
      _ = [dns_user, dns_servers, dns_ssh_key_path, ssh_strict_host_key, primary_records, replica_records]
      render_template('repmgr_dns_failover.sh.erb', binding)
    end

    assert_includes content, 'for record in "${PRIMARY_RECORDS[@]}"'
    assert_includes content, 'printf -v content \'%saddress=/%s/%s\\n\' "$content" "$record" "$primary_host"'
  end

  def test_dns_failover_script_iterates_all_replica_records
    content = @component.instance_eval do
      dns_user = 'ubuntu'
      dns_servers = ['10.0.0.10']
      dns_ssh_key_path = '/var/lib/postgresql/.ssh/active_postgres_dns'
      ssh_strict_host_key = 'accept-new'
      primary_records = ['db-primary.mesh.internal']
      replica_records = ['db-replica.mesh.internal']
      _ = [dns_user, dns_servers, dns_ssh_key_path, ssh_strict_host_key, primary_records, replica_records]
      render_template('repmgr_dns_failover.sh.erb', binding)
    end

    assert_includes content, 'for record in "${REPLICA_RECORDS[@]}"'
    assert_includes content, 'for host in $standby_hosts'
  end

  def test_repmgr_conf_template_omits_invalid_use_rewind_setting
    content = render_repmgr_conf({ use_rewind: true })

    refute_includes content, 'use_rewind'
  end

  private

  def render_repmgr_conf(repmgr_config)
    config = @config
    host = 'primary.example.com'
    @component.instance_eval do
      _ = [config, host, repmgr_config]
      render_template('repmgr.conf.erb', binding)
    end
  end
end
