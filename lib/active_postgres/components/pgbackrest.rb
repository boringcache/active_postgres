module ActivePostgres
  module Components
    class PgBackRest < Base
      def install
        puts 'Installing pgBackRest for backups...'

        install_on_host(config.primary_host)
      end

      def uninstall
        puts 'Uninstalling pgBackRest...'

        ssh_executor.execute_on_host(config.primary_host) do
          execute :sudo, 'apt-get', 'remove', '-y', 'pgbackrest'
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

      def install_on_host(host)
        puts "  Installing pgBackRest on #{host}..."

        pgbackrest_config = config.component_config(:pgbackrest)
        postgres_user = config.postgres_user
        _ = pgbackrest_config # Used in ERB template

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

          execute :sudo, '-u', postgres_user, 'pgbackrest', '--stanza=main', 'stanza-create'
        end
      end
    end
  end
end
