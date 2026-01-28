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
