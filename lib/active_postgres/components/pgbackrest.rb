require 'shellwords'

module ActivePostgres
  module Components
    class PgBackRest < Base
      LOG_ARCHIVE_CRON_FILE = '/etc/cron.d/postgres-log-archive'
      LOG_ARCHIVE_ENV_FILE = '/etc/active-postgres-log-archive.env'
      LOG_ARCHIVE_SCRIPT = '/usr/local/bin/active-postgres-archive-logs'

      def install
        puts 'Installing pgBackRest for backups...'

        # Install on primary with full setup (stanza-create)
        install_on_host(config.primary_host, create_stanza: true)

        # Install on standbys (package + config only, no stanza-create)
        config.standby_hosts.each do |host|
          install_on_host(host, create_stanza: false)
        end
      end

      def uninstall
        puts 'Uninstalling pgBackRest...'

        config.all_hosts.each do |host|
          ssh_executor.execute_on_host(host) do
            execute :sudo, 'apt-get', 'remove', '-y', 'pgbackrest'
            execute :sudo, 'rm', '-f', '/etc/cron.d/pgbackrest-backup'
            execute :sudo, 'rm', '-f', '/etc/cron.d/pgbackrest-backup-incremental'
            execute :sudo, 'rm', '-f', LOG_ARCHIVE_CRON_FILE
            execute :sudo, 'rm', '-f', LOG_ARCHIVE_ENV_FILE
            execute :sudo, 'rm', '-f', LOG_ARCHIVE_SCRIPT
          end
        end
      end

      def restart
        puts "pgBackRest is a backup tool and doesn't run as a service."
      end

      def install_on_standby(host)
        puts "  Installing pgBackRest on standby #{host}..."
        install_on_host(host, create_stanza: false)
      end

      def run_backup(type = 'full')
        puts "Running #{type} backup..."
        postgres_user = config.postgres_user

        output = nil
        ssh_executor.execute_on_host(config.primary_host) do
          output = capture(:sudo, '-u', postgres_user, 'pgbackrest', '--stanza=main', "--type=#{type}", 'backup')
        end

        puts output if output
      end

      def run_restore(backup_id)
        puts "Restoring from backup #{backup_id}..."
        postgres_user = config.postgres_user

        ssh_executor.execute_on_host(config.primary_host) do
          # Stop PostgreSQL
          execute :sudo, 'systemctl', 'stop', 'postgresql'

          # Restore
          output = capture(:sudo, '-u', postgres_user, 'pgbackrest', '--stanza=main', "--set=#{backup_id}", 'restore')
          puts output if output

          # Start PostgreSQL
          execute :sudo, 'systemctl', 'start', 'postgresql'
        end
      end

      def run_restore_at(target_time, target_action: 'promote')
        puts "Restoring to #{target_time} (PITR)..."
        postgres_user = config.postgres_user

        ssh_executor.execute_on_host(config.primary_host) do
          execute :sudo, 'systemctl', 'stop', 'postgresql'

          output = capture(:sudo, '-u', postgres_user, 'pgbackrest',
                           '--stanza=main',
                           '--type=time',
                           "--target=#{target_time}",
                           "--target-action=#{target_action}",
                           'restore')
          puts output if output

          execute :sudo, 'systemctl', 'start', 'postgresql'
        end
      end

      def list_backups
        puts 'Available backups:'
        postgres_user = config.postgres_user

        output = nil
        ssh_executor.execute_on_host(config.primary_host) do
          output = capture(:sudo, '-u', postgres_user, 'pgbackrest', 'info')
        end

        puts output if output
      end

      private

      def install_on_host(host, create_stanza: true)
        puts "  Installing pgBackRest on #{host}..."

        pgbackrest_config = secrets.resolve_value(config.component_config(:pgbackrest))
        postgres_user = config.postgres_user
        secrets_obj = secrets
        _ = pgbackrest_config # Used in ERB template
        _ = secrets_obj # Used in ERB template

        install_apt_packages(host, 'pgbackrest')

        # Upload configuration
        upload_template(host, 'pgbackrest.conf.erb', '/etc/pgbackrest.conf', binding,
                        mode: '640', owner: "root:#{postgres_user}")

        ssh_executor.execute_on_host(host) do
          execute :sudo, 'rm', '-rf', '/var/lib/pgbackrest', '||', 'true'
          execute :sudo, 'mkdir', '-p', '/var/lib/pgbackrest'
          execute :sudo, 'chown', "#{postgres_user}:#{postgres_user}", '/var/lib/pgbackrest'
          execute :sudo, 'chmod', '750', '/var/lib/pgbackrest'

          execute :sudo, 'rm', '-rf', '/var/log/pgbackrest', '||', 'true'
          execute :sudo, 'mkdir', '-p', '/var/log/pgbackrest'
          execute :sudo, 'chown', "#{postgres_user}:#{postgres_user}", '/var/log/pgbackrest'

          execute :sudo, 'rm', '-rf', '/var/spool/pgbackrest', '||', 'true'
          execute :sudo, 'mkdir', '-p', '/var/spool/pgbackrest'
          execute :sudo, 'chown', "#{postgres_user}:#{postgres_user}", '/var/spool/pgbackrest'

          # Only create stanza on primary - standbys share the same backup repo
          if create_stanza
            execute :sudo, '-u', postgres_user, 'pgbackrest', '--stanza=main', 'stanza-create'
          end
        end

        if log_archive_enabled?(pgbackrest_config)
          setup_log_archive(host, pgbackrest_config)
        else
          remove_log_archive(host)
        end

        # Set up scheduled backups on primary only
        if create_stanza
          setup_backup_schedules(host, pgbackrest_config)
        else
          remove_backup_schedule(host)
        end
      end

      def setup_backup_schedules(host, pgbackrest_config)
        remove_backup_schedule(host)
        schedules = backup_schedules(pgbackrest_config)
        schedules.each do |entry|
          setup_backup_schedule(host, entry[:schedule], entry[:type], entry[:file])
        end
      end

      def backup_schedules(pgbackrest_config)
        schedule_full = pgbackrest_config[:schedule_full] || pgbackrest_config[:schedule]
        schedule_incremental = pgbackrest_config[:schedule_incremental]

        schedules = []
        if schedule_full
          schedules << { type: 'full', schedule: schedule_full, file: '/etc/cron.d/pgbackrest-backup' }
        end
        if schedule_incremental
          schedules << { type: 'incremental', schedule: schedule_incremental, file: '/etc/cron.d/pgbackrest-backup-incremental' }
        end

        schedules
      end

      def setup_backup_schedule(host, schedule, backup_type = 'full', cron_file = '/etc/cron.d/pgbackrest-backup')
        puts "  Setting up #{backup_type} backup schedule: #{schedule}"
        postgres_user = config.postgres_user

        # Create cron job for scheduled backups
        # /etc/cron.d format requires username after time spec
        cron_content = <<~CRON
          # pgBackRest scheduled backups (managed by active_postgres)
          SHELL=/bin/bash
          PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
          #{schedule} #{postgres_user} pgbackrest --stanza=main --type=#{backup_type} backup
        CRON

        # Install cron job in /etc/cron.d (system cron directory)
        # Use a temp file + sudo mv to avoid shell redirection permission issues.
        ssh_executor.upload_file(host, cron_content, cron_file, mode: '644', owner: 'root:root')
      end

      def remove_backup_schedule(host)
        ssh_executor.execute_on_host(host) do
          execute :sudo, 'rm', '-f', '/etc/cron.d/pgbackrest-backup'
          execute :sudo, 'rm', '-f', '/etc/cron.d/pgbackrest-backup-incremental'
        end
      end

      def setup_log_archive(host, pgbackrest_config)
        log_archive_config = pgbackrest_config[:log_archive] || {}
        unless pgbackrest_config[:repo_type] == 's3'
          raise Error, 'pgbackrest.log_archive requires pgbackrest.repo_type: s3'
        end

        postgres_user = config.postgres_user
        env_content = log_archive_env(pgbackrest_config, log_archive_config, host)
        cron_content = log_archive_cron(log_archive_config)

        install_apt_packages(host, 'awscli')

        ssh_executor.upload_file(host, env_content, LOG_ARCHIVE_ENV_FILE, mode: '640', owner: "root:#{postgres_user}")

        upload_template(host, 'postgres_log_archive.sh.erb', LOG_ARCHIVE_SCRIPT, binding,
                        mode: '750', owner: "root:#{postgres_user}")
        ssh_executor.upload_file(host, cron_content, LOG_ARCHIVE_CRON_FILE, mode: '644', owner: 'root:root')
      end

      def remove_log_archive(host)
        ssh_executor.execute_on_host(host) do
          execute :sudo, 'rm', '-f', LOG_ARCHIVE_CRON_FILE
          execute :sudo, 'rm', '-f', LOG_ARCHIVE_ENV_FILE
          execute :sudo, 'rm', '-f', LOG_ARCHIVE_SCRIPT
        end
      end

      def log_archive_enabled?(pgbackrest_config)
        (pgbackrest_config[:log_archive] || {})[:enabled] == true
      end

      def log_archive_cron(log_archive_config)
        schedule = log_archive_config[:schedule] || '17 3 * * *'
        <<~CRON
          # PostgreSQL text log archive (managed by active_postgres)
          SHELL=/bin/bash
          PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
          #{schedule} root #{LOG_ARCHIVE_SCRIPT}
        CRON
      end

      def log_archive_env(pgbackrest_config, log_archive_config, host)
        access_key = secrets.resolve('s3_access_key')
        secret_key = secrets.resolve('s3_secret_key')
        raise Error, 's3_access_key secret is required for pgbackrest.log_archive' if access_key.to_s.empty?
        raise Error, 's3_secret_key secret is required for pgbackrest.log_archive' if secret_key.to_s.empty?

        env = {
          'AWS_ACCESS_KEY_ID' => access_key,
          'AWS_SECRET_ACCESS_KEY' => secret_key,
          'AWS_DEFAULT_REGION' => pgbackrest_config[:s3_region] || 'us-east-1',
          'AWS_BUCKET' => pgbackrest_config[:s3_bucket],
          'AWS_ENDPOINT_URL' => s3_endpoint_url(pgbackrest_config),
          'POSTGRES_LOG_ARCHIVE_LOG_DIR' => log_archive_config[:log_directory] || '/var/log/postgresql',
          'POSTGRES_LOG_ARCHIVE_PREFIX' => log_archive_config[:prefix] || 'postgres-logs',
          'POSTGRES_LOG_ARCHIVE_NODE' => config.node_label_for(host) || host
        }.compact

        env.map { |key, value| "#{key}=#{Shellwords.escape(value.to_s)}" }.join("\n") + "\n"
      end

      def s3_endpoint_url(pgbackrest_config)
        endpoint = pgbackrest_config[:s3_endpoint]
        return nil if endpoint.to_s.empty?
        return endpoint if endpoint.match?(/\Ahttps?:\/\//)

        "https://#{endpoint}"
      end
    end
  end
end
