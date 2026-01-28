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
      primary_record = 'db-primary.mesh.internal'
      replica_record = 'db-replica.mesh.internal'
      _ = [dns_user, dns_servers, dns_ssh_key_path, ssh_strict_host_key, primary_record, replica_record]
      render_template('repmgr_dns_failover.sh.erb', binding)
    end

    assert_includes content, 'primary_host'
    refute_includes content, 'all_hosts='
    assert_includes content, 'for host in $standby_hosts'
    assert_includes content, 'printf -v content'
    assert_includes content, '"$PRIMARY_RECORD" "$primary_host"'
    assert_includes content, '"$REPLICA_RECORD" "$host"'
  end
end
