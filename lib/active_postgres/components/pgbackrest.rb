module ActivePostgres
  module Components
    class PgBackRest < Base
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
          end
        end
      end

      def restart
        puts "pgBackRest is a backup tool and doesn't run as a service."
      end

      def run_backup(type = 'full')
        puts "Running #{type} backup..."
        postgres_user = config.postgres_user

        ssh_executor.execute_on_host(config.primary_host) do
          execute :sudo, '-u', postgres_user, 'pgbackrest', '--stanza=main', "--type=#{type}", 'backup'
        end
      end

      def run_restore(backup_id)
        puts "Restoring from backup #{backup_id}..."
        postgres_user = config.postgres_user

        ssh_executor.execute_on_host(config.primary_host) do
          # Stop PostgreSQL
          execute :sudo, 'systemctl', 'stop', 'postgresql'

          # Restore
          execute :sudo, '-u', postgres_user, 'pgbackrest', '--stanza=main', "--set=#{backup_id}", 'restore'

          # Start PostgreSQL
          execute :sudo, 'systemctl', 'start', 'postgresql'
        end
      end

      def list_backups
        puts 'Available backups:'
        postgres_user = config.postgres_user

        ssh_executor.execute_on_host(config.primary_host) do
          execute :sudo, '-u', postgres_user, 'pgbackrest', 'info'
        end
      end

      private

      def install_on_host(host, create_stanza: true)
        puts "  Installing pgBackRest on #{host}..."

        pgbackrest_config = config.component_config(:pgbackrest)
        postgres_user = config.postgres_user
        secrets_obj = secrets
        _ = pgbackrest_config # Used in ERB template
        _ = secrets_obj # Used in ERB template

        # Install package
        ssh_executor.execute_on_host(host) do
          execute :sudo, 'apt-get', 'install', '-y', '-qq', 'pgbackrest'
        end

        # Upload configuration
        upload_template(host, 'pgbackrest.conf.erb', '/etc/pgbackrest.conf', binding, mode: '644')

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
      end
    end
  end
end
