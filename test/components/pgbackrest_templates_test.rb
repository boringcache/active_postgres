require 'test_helper'

class PgBackRestTemplatesTest < Minitest::Test
  def setup
    @config = stub_config(
      primary_host: 'primary.example.com',
      version: 16,
      primary: { 'host' => 'primary.example.com', 'private_ip' => '10.0.0.10' },
      postgres_user: 'postgres'
    )
    @secrets = ActivePostgres::Secrets.new(@config)
    @component = pgbackrest_component(@config, @secrets)
  end

  def test_conf_s3_configuration
    content = render_conf(repo_type: 's3', s3_bucket: 'my-backups', s3_region: 'us-west-2')

    assert_includes content, 'repo1-type=s3'
    assert_includes content, 'repo1-s3-bucket=my-backups'
    assert_includes content, 'repo1-s3-region=us-west-2'
    assert_includes content, 'repo1-s3-endpoint=s3.us-west-2.amazonaws.com'
  end

  def test_conf_s3_custom_endpoint
    content = render_conf(repo_type: 's3', s3_bucket: 'my-backups', s3_endpoint: 't3.storage.dev', s3_uri_style: 'path')

    assert_includes content, 'repo1-s3-endpoint=t3.storage.dev'
    assert_includes content, 'repo1-s3-uri-style=path'
  end

  def test_conf_s3_default_region
    content = render_conf(repo_type: 's3', s3_bucket: 'my-backups')

    assert_includes content, 'repo1-s3-region=us-east-1'
    assert_includes content, 'repo1-s3-endpoint=s3.us-east-1.amazonaws.com'
  end

  def test_conf_gcs_configuration
    content = render_conf(repo_type: 'gcs', gcs_bucket: 'my-gcs-backups')

    assert_includes content, 'repo1-type=gcs'
    assert_includes content, 'repo1-gcs-bucket=my-gcs-backups'
  end

  def test_conf_azure_configuration
    content = render_conf(repo_type: 'azure', azure_container: 'my-azure-container')

    assert_includes content, 'repo1-type=azure'
    assert_includes content, 'repo1-azure-container=my-azure-container'
  end

  def test_conf_local_configuration
    content = render_conf(repo_type: 'local', repo_path: '/mnt/backups')

    assert_includes content, 'repo1-path=/mnt/backups'
    refute_includes content, 'repo1-type=s3'
    refute_includes content, 'repo1-type=gcs'
  end

  def test_conf_local_default_path
    content = render_conf(repo_type: 'local')

    assert_includes content, 'repo1-path=/var/lib/pgbackrest'
  end

  def test_conf_custom_retention_settings
    content = render_conf(repo_type: 'local', retention_full: 14, retention_archive: 30)

    assert_includes content, 'repo1-retention-full=14'
    assert_includes content, 'repo1-retention-archive=30'
  end

  def test_conf_default_retention
    content = render_conf(repo_type: 'local')

    assert_includes content, 'repo1-retention-full=7'
    assert_includes content, 'repo1-retention-archive=14'
  end

  def test_conf_includes_compression
    content = render_conf(repo_type: 'local')

    assert_includes content, 'compress-type=lz4'
    assert_includes content, 'compress-level=3'
  end

  def test_conf_includes_stanza_settings
    content = render_conf(repo_type: 'local')

    assert_includes content, '[main]'
    assert_includes content, 'pg1-path=/var/lib/postgresql/16/main'
    assert_includes content, 'pg1-port=5432'
    assert_includes content, 'pg1-user=postgres'
    assert_includes content, 'pg1-socket-path=/var/run/postgresql'
  end

  def test_conf_custom_process_max
    content = render_conf(repo_type: 'local', process_max: 4)

    assert_includes content, 'process-max=4'
  end

  def test_conf_enables_async_archiving
    content = render_conf(repo_type: 's3', s3_bucket: 'my-backups')

    assert_includes content, 'archive-async=y'
    assert_includes content, 'spool-path=/var/spool/pgbackrest'
  end

  def test_conf_default_process_max
    content = render_conf(repo_type: 'local')

    assert_includes content, 'process-max=2'
  end

  def test_conf_includes_start_fast
    content = render_conf(repo_type: 'local')

    assert_includes content, 'start-fast=y'
    assert_includes content, 'stop-auto=y'
  end

  def test_conf_includes_logging
    content = render_conf(repo_type: 'local')

    assert_includes content, 'log-level-console=info'
    assert_includes content, 'log-level-file=detail'
    assert_includes content, 'log-path=/var/log/pgbackrest'
  end

  def test_conf_s3_repo_path
    content = render_conf(repo_type: 's3', s3_bucket: 'my-backups', repo_path: '/custom/path')

    assert_includes content, 'repo1-path=/custom/path'
  end

  def test_conf_s3_default_repo_path
    content = render_conf(repo_type: 's3', s3_bucket: 'my-backups')

    assert_includes content, 'repo1-path=/backups'
  end

  def test_log_archive_script_supports_packaged_s3cmd_fallback
    content = @component.instance_eval do
      render_template('postgres_log_archive.sh.erb', binding)
    end

    assert_includes content, 'command -v aws'
    assert_includes content, 'command -v s3cmd'
    assert_includes content, '--ignore-failed-read'
    assert_includes content, '--host-bucket="${endpoint}/%(bucket)"'
    assert_includes content, 'missing aws or s3cmd command'
  end

  private

  def render_conf(pgbackrest_config)
    config = @config
    secrets_obj = @secrets
    @component.instance_eval do
      _ = [pgbackrest_config, config, secrets_obj]
      render_template('pgbackrest.conf.erb', binding)
    end
  end
end
