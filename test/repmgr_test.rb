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
    content = @component.send(:build_pgpass_content, 'standby.example.com', password, '10.0.0.10')

    assert_includes content, 'localhost:5432:repmgr:repmgr:pa\\:ss\\\\word'
    assert_includes content, '10.0.0.10:5432:*:repmgr:pa\\:ss\\\\word'
    assert_includes content, '10.0.0.11:5432:*:repmgr:pa\\:ss\\\\word'
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
end
