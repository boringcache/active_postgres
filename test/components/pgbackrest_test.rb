require 'test_helper'

class PgBackRestTest < Minitest::Test
  def test_schedule_cron_content_format
    schedule = '0 2 * * *'
    postgres_user = 'postgres'

    cron_content = <<~CRON
      # pgBackRest scheduled backups (managed by active_postgres)
      SHELL=/bin/bash
      PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
      #{schedule} #{postgres_user} pgbackrest --stanza=main --type=full backup
    CRON

    assert_includes cron_content, 'SHELL=/bin/bash'
    assert_includes cron_content, '0 2 * * * postgres pgbackrest'
    assert_includes cron_content, '--stanza=main'
    assert_includes cron_content, '--type=full'
  end

  def test_schedule_cron_uses_correct_user
    schedule = '30 3 * * 0'
    postgres_user = 'pgadmin'

    cron_line = "#{schedule} #{postgres_user} pgbackrest --stanza=main --type=full backup"

    assert_includes cron_line, '30 3 * * 0 pgadmin'
  end

  def test_backup_schedules_prefers_schedule_full
    config = stub_config(primary_host: 'primary.example.com')
    secrets = ActivePostgres::Secrets.new(config)
    component = ActivePostgres::Components::PgBackRest.new(config, Object.new, secrets)

    schedules = component.send(:backup_schedules, {
      schedule: '0 2 * * *',
      schedule_full: '0 3 * * *',
      schedule_incremental: '0 * * * *'
    })

    full = schedules.find { |entry| entry[:type] == 'full' }
    incremental = schedules.find { |entry| entry[:type] == 'incremental' }

    assert_equal '0 3 * * *', full[:schedule]
    assert_equal '0 * * * *', incremental[:schedule]
  end

  def test_setup_backup_schedule_uses_backup_type
    schedule = '0 * * * *'
    postgres_user = 'pguser'
    config = stub_config(primary_host: 'primary.example.com', postgres_user: postgres_user)
    secrets = ActivePostgres::Secrets.new(config)
    ssh_executor = Minitest::Mock.new
    component = ActivePostgres::Components::PgBackRest.new(config, ssh_executor, secrets)

    ssh_executor.expect(:upload_file, nil) do |_host, content, path, **_kwargs|
      assert_equal '/etc/cron.d/pgbackrest-backup-incremental', path
      assert_includes content, "--type=incremental"
      assert_includes content, schedule
      true
    end

    component.send(:setup_backup_schedule, 'primary.example.com', schedule, 'incremental',
                   '/etc/cron.d/pgbackrest-backup-incremental')

    ssh_executor.verify
  end

  def test_pgbackrest_config_s3_template_variables
    pgbackrest_config = {
      repo_type: 's3',
      s3_bucket: 'my-backups',
      s3_region: 'us-west-2',
      repo_path: '/backups',
      retention_full: 7,
      retention_archive: 14
    }

    assert_equal 's3', pgbackrest_config[:repo_type]
    assert_equal 'my-backups', pgbackrest_config[:s3_bucket]
    assert_equal 'us-west-2', pgbackrest_config[:s3_region]
  end

  def test_pgbackrest_config_gcs_template_variables
    pgbackrest_config = {
      repo_type: 'gcs',
      gcs_bucket: 'my-gcs-backups',
      repo_path: '/backups'
    }

    assert_equal 'gcs', pgbackrest_config[:repo_type]
    assert_equal 'my-gcs-backups', pgbackrest_config[:gcs_bucket]
  end

  def test_pgbackrest_config_azure_template_variables
    pgbackrest_config = {
      repo_type: 'azure',
      azure_container: 'my-azure-container',
      repo_path: '/backups'
    }

    assert_equal 'azure', pgbackrest_config[:repo_type]
    assert_equal 'my-azure-container', pgbackrest_config[:azure_container]
  end

  def test_pgbackrest_config_local_storage
    pgbackrest_config = {
      repo_type: 'local',
      repo_path: '/var/lib/pgbackrest'
    }

    assert_equal 'local', pgbackrest_config[:repo_type]
    assert_equal '/var/lib/pgbackrest', pgbackrest_config[:repo_path]
  end

  def test_pgbackrest_default_retention_values
    pgbackrest_config = {}

    retention_full = pgbackrest_config[:retention_full] || 7
    retention_archive = pgbackrest_config[:retention_archive] || 14

    assert_equal 7, retention_full
    assert_equal 14, retention_archive
  end

  def test_pgbackrest_template_uses_custom_s3_endpoint_and_uri_style
    config = stub_config(component_config: { pgbackrest: {} })
    secrets = ActivePostgres::Secrets.new(config)
    component = ActivePostgres::Components::PgBackRest.new(config, Object.new, secrets)

    content = component.instance_eval do
      pgbackrest_config = {
        repo_type: 's3',
        s3_bucket: 'my-backups',
        s3_region: 'auto',
        s3_endpoint: 't3.storage.dev',
        s3_uri_style: 'path'
      }
      secrets_obj = secrets
      _ = [pgbackrest_config, secrets_obj]
      render_template('pgbackrest.conf.erb', binding)
    end

    assert_includes content, 'repo1-s3-endpoint=t3.storage.dev'
    assert_includes content, 'repo1-s3-uri-style=path'
    refute_includes content, 's3.auto.amazonaws.com'
  end

  def test_setup_backup_schedule_uses_upload_file
    schedule = '0 2 * * *'
    config = stub_config(primary_host: 'primary.example.com', postgres_user: 'pguser')
    secrets = ActivePostgres::Secrets.new(config)
    ssh_executor = Minitest::Mock.new
    component = ActivePostgres::Components::PgBackRest.new(config, ssh_executor, secrets)

    ssh_executor.expect(:upload_file, nil) do |host, content, path, **kwargs|
      assert_equal 'primary.example.com', host
      assert_equal '/etc/cron.d/pgbackrest-backup', path
      assert_equal '644', kwargs[:mode]
      assert_equal 'root:root', kwargs[:owner]
      assert_includes content, schedule
      assert_includes content, 'pgbackrest --stanza=main --type=full backup'
      true
    end

    component.send(:setup_backup_schedule, 'primary.example.com', schedule)

    ssh_executor.verify
  end

  def test_install_on_standby_does_not_create_stanza
    config = stub_config(
      primary_host: 'primary.example.com',
      standby_hosts: ['standby.example.com'],
      postgres_user: 'postgres',
      component_config: {
        pgbackrest: { repo_type: 'local' }
      }
    )

    ssh_executor = Minitest::Mock.new
    secrets = Minitest::Mock.new
    pgbackrest = ActivePostgres::Components::PgBackRest.new(config, ssh_executor, secrets)

    install_called_with_create_stanza = nil
    pgbackrest.define_singleton_method(:install_on_host) do |host, create_stanza:|
      install_called_with_create_stanza = create_stanza if host == 'standby.example.com'
    end

    pgbackrest.install_on_standby('standby.example.com')

    assert_equal false, install_called_with_create_stanza, 'install_on_standby should not create stanza'
  end
end
