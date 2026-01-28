require 'cgi'

module ActivePostgres
  module Components
    class Monitoring < Base
      def install
        puts 'Installing postgres_exporter for monitoring...'

        ensure_monitoring_user

        config.all_hosts.each do |host|
          install_on_host(host)
        end
      end

      def uninstall
        puts 'Uninstalling postgres_exporter...'

        config.all_hosts.each do |host|
          ssh_executor.execute_on_host(host) do
            execute :sudo, 'systemctl', 'stop', 'prometheus-postgres-exporter'
            execute :sudo, 'systemctl', 'disable', 'prometheus-postgres-exporter'
            execute :sudo, 'apt-get', 'remove', '-y', 'prometheus-postgres-exporter'
          end
        end
      end

      def restart
        puts 'Restarting postgres_exporter...'

        config.all_hosts.each do |host|
          ssh_executor.execute_on_host(host) do
            execute :sudo, 'systemctl', 'restart', 'prometheus-postgres-exporter'
          end
        end
      end

      def install_on_standby(standby_host)
        puts "Installing postgres_exporter on standby #{standby_host}..."
        install_on_host(standby_host)
      end

      private

      def install_on_host(host)
        puts "  Installing postgres_exporter on #{host}..."

        monitoring_config = config.component_config(:monitoring)
        exporter_port = monitoring_config[:exporter_port] || 9187

        # Download and install postgres_exporter
        ssh_executor.execute_on_host(host) do
          # Install via package manager or download binary
          execute :sudo, 'apt-get', 'install', '-y', '-qq', 'prometheus-postgres-exporter'
        end

        configure_exporter_service(host, monitoring_config, exporter_port)

        ssh_executor.execute_on_host(host) do
          # Enable and start
          execute :sudo, 'systemctl', 'enable', 'prometheus-postgres-exporter'
          execute :sudo, 'systemctl', 'restart', 'prometheus-postgres-exporter'
        end

        puts "  Metrics available at: http://#{host}:#{exporter_port}/metrics"
      end

      def ensure_monitoring_user
        monitoring_config = config.component_config(:monitoring)
        monitoring_user = monitoring_config[:user] || 'postgres_exporter'
        monitoring_password = normalize_monitoring_password(secrets.resolve('monitoring_password'))

        sql = build_monitoring_user_sql(monitoring_user, monitoring_password)

        ssh_executor.run_sql(config.primary_host, sql, postgres_user: 'postgres', port: 5432, tuples_only: false,
                                                     capture: false)
      end

      def build_monitoring_user_sql(user, password)
        escaped_password = password.gsub("'", "''")

        [
          'DO $$',
          'BEGIN',
          "  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '#{user}') THEN",
          "    CREATE USER #{user} WITH LOGIN PASSWORD '#{escaped_password}';",
          '  ELSE',
          "    ALTER USER #{user} WITH LOGIN PASSWORD '#{escaped_password}';",
          '  END IF;',
          'END $$;',
          '',
          "GRANT pg_monitor TO #{user};",
          ''
        ].join("\n")
      end

      def configure_exporter_service(host, monitoring_config, exporter_port)
        monitoring_user = monitoring_config[:user] || 'postgres_exporter'
        monitoring_password = normalize_monitoring_password(secrets.resolve('monitoring_password'))

        dsn = build_exporter_dsn(monitoring_config, monitoring_user, monitoring_password)
        override = <<~CONF
          [Service]
          Environment="DATA_SOURCE_NAME=#{escape_systemd_env(dsn)}"
          Environment="PG_EXPORTER_WEB_LISTEN_ADDRESS=:#{exporter_port}"
        CONF

        ssh_executor.execute_on_host(host) do
          execute :sudo, 'mkdir', '-p', '/etc/systemd/system/prometheus-postgres-exporter.service.d'
          upload! StringIO.new(override), '/tmp/prometheus-postgres-exporter.override'
          execute :sudo, 'mv', '/tmp/prometheus-postgres-exporter.override',
                  '/etc/systemd/system/prometheus-postgres-exporter.service.d/override.conf'
          execute :sudo, 'chown', 'root:root', '/etc/systemd/system/prometheus-postgres-exporter.service.d/override.conf'
          execute :sudo, 'chmod', '600', '/etc/systemd/system/prometheus-postgres-exporter.service.d/override.conf'
          execute :sudo, 'systemctl', 'daemon-reload'
        end
      end

      def build_exporter_dsn(monitoring_config, monitoring_user, monitoring_password)
        host = monitoring_config[:database_host] || 'localhost'
        port = monitoring_config[:database_port] || 5432
        database = monitoring_config[:database] || 'postgres'
        sslmode = config.component_enabled?(:ssl) ? 'require' : 'prefer'

        encoded_password = CGI.escape(monitoring_password.to_s)
        "postgresql://#{monitoring_user}:#{encoded_password}@#{host}:#{port}/#{database}?sslmode=#{sslmode}"
      end

      def normalize_monitoring_password(raw_password)
        password = raw_password.to_s.rstrip

        raise Error, 'monitoring_password secret is missing (required for monitoring)' if password.empty?

        password
      end

      def escape_systemd_env(value)
        value.to_s.gsub('\\', '\\\\').gsub('"', '\\"')
      end
    end
  end
end
