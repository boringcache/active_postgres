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

        install_grafana_if_enabled
      end

      def uninstall
        puts 'Uninstalling postgres_exporter...'

        config.all_hosts.each do |host|
          ssh_executor.execute_on_host(host) do
            execute :sudo, 'systemctl', 'stop', 'prometheus-postgres-exporter'
            execute :sudo, 'systemctl', 'disable', 'prometheus-postgres-exporter'
            execute :sudo, 'apt-get', 'remove', '-y', 'prometheus-postgres-exporter'

            if node_exporter_enabled?
              execute :sudo, 'systemctl', 'stop', 'prometheus-node-exporter'
              execute :sudo, 'systemctl', 'disable', 'prometheus-node-exporter'
              execute :sudo, 'apt-get', 'remove', '-y', 'prometheus-node-exporter'
            end
          end
        end

        uninstall_grafana_if_enabled
      end

      def restart
        puts 'Restarting postgres_exporter...'

        config.all_hosts.each do |host|
          ssh_executor.execute_on_host(host) do
            execute :sudo, 'systemctl', 'restart', 'prometheus-postgres-exporter'
            execute :sudo, 'systemctl', 'restart', 'prometheus-node-exporter' if node_exporter_enabled?
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

        install_node_exporter(host, monitoring_config) if node_exporter_enabled?
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

      def node_exporter_enabled?
        monitoring_config = config.component_config(:monitoring)
        monitoring_config.fetch(:node_exporter, false) == true
      end

      def install_node_exporter(host, monitoring_config)
        port = monitoring_config[:node_exporter_port] || 9100
        listen_address = monitoring_config[:node_exporter_listen_address].to_s.strip
        puts "  Installing node_exporter on #{host}..."

        ssh_executor.execute_on_host(host) do
          execute :sudo, 'apt-get', 'install', '-y', '-qq', 'prometheus-node-exporter'
        end

        configure_node_exporter_service(host, port, listen_address)

        ssh_executor.execute_on_host(host) do
          execute :sudo, 'systemctl', 'enable', 'prometheus-node-exporter'
          execute :sudo, 'systemctl', 'restart', 'prometheus-node-exporter'
        end

        puts "  Node metrics available at: http://#{host}:#{port}/metrics"
      end

      def configure_node_exporter_service(host, port, listen_address)
        listen = if listen_address.empty?
                   ":#{port}"
                 else
                   "#{listen_address}:#{port}"
                 end

        return if listen == ':9100'

        override = <<~CONF
          [Service]
          ExecStart=
          ExecStart=/usr/bin/prometheus-node-exporter --web.listen-address=#{listen}
        CONF

        ssh_executor.execute_on_host(host) do
          execute :sudo, 'mkdir', '-p', '/etc/systemd/system/prometheus-node-exporter.service.d'
          upload! StringIO.new(override), '/tmp/prometheus-node-exporter.override'
          execute :sudo, 'mv', '/tmp/prometheus-node-exporter.override',
                  '/etc/systemd/system/prometheus-node-exporter.service.d/override.conf'
          execute :sudo, 'chown', 'root:root', '/etc/systemd/system/prometheus-node-exporter.service.d/override.conf'
          execute :sudo, 'chmod', '644', '/etc/systemd/system/prometheus-node-exporter.service.d/override.conf'
          execute :sudo, 'systemctl', 'daemon-reload'
        end
      end

      def install_grafana_if_enabled
        monitoring_config = config.component_config(:monitoring)
        grafana_config = monitoring_config[:grafana] || {}
        return unless grafana_config[:enabled]

        host = grafana_config[:host].to_s.strip
        raise Error, 'monitoring.grafana.host is required when grafana is enabled' if host.empty?

        admin_password = normalize_grafana_password(secrets.resolve('grafana_admin_password'))
        prometheus_url = grafana_config[:prometheus_url]
        listen_address = grafana_config[:listen_address].to_s.strip
        port = (grafana_config[:port] || 3000).to_i

        puts "Installing Grafana on #{host}..."

        ssh_executor.execute_on_host(host) do
          execute :sudo, 'apt-get', 'install', '-y', '-qq', 'apt-transport-https', 'software-properties-common', 'wget'
          execute :sudo, 'wget', '-q', '-O', '/usr/share/keyrings/grafana.gpg', 'https://apt.grafana.com/gpg.key'
          execute :sudo, 'sh', '-c',
                  'echo "deb [signed-by=/usr/share/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list'
          execute :sudo, 'apt-get', 'update', '-qq'
          execute :sudo, 'apt-get', 'install', '-y', '-qq', 'grafana'
          execute :sudo, 'systemctl', 'enable', '--now', 'grafana-server'
          execute :sudo, 'grafana-cli', 'admin', 'reset-admin-password', admin_password
        end

        configure_grafana_service(host, listen_address, port)
        configure_grafana_datasource(host, prometheus_url) if prometheus_url

        puts "  Grafana available at: http://#{host}:#{port}"
      end

      def configure_grafana_service(host, listen_address, port)
        env_lines = []
        env_lines << "Environment=\"GF_SERVER_HTTP_ADDR=#{listen_address}\"" unless listen_address.empty?
        env_lines << "Environment=\"GF_SERVER_HTTP_PORT=#{port}\"" if port && port != 3000
        return if env_lines.empty?

        override = <<~CONF
          [Service]
          #{env_lines.join("\n  ")}
        CONF

        ssh_executor.execute_on_host(host) do
          execute :sudo, 'mkdir', '-p', '/etc/systemd/system/grafana-server.service.d'
          upload! StringIO.new(override), '/tmp/active_postgres_grafana.override'
          execute :sudo, 'mv', '/tmp/active_postgres_grafana.override',
                  '/etc/systemd/system/grafana-server.service.d/override.conf'
          execute :sudo, 'chown', 'root:root', '/etc/systemd/system/grafana-server.service.d/override.conf'
          execute :sudo, 'chmod', '644', '/etc/systemd/system/grafana-server.service.d/override.conf'
          execute :sudo, 'systemctl', 'daemon-reload'
          execute :sudo, 'systemctl', 'restart', 'grafana-server'
        end
      end

      def uninstall_grafana_if_enabled
        monitoring_config = config.component_config(:monitoring)
        grafana_config = monitoring_config[:grafana] || {}
        return unless grafana_config[:enabled]

        host = grafana_config[:host].to_s.strip
        return if host.empty?

        ssh_executor.execute_on_host(host) do
          execute :sudo, 'systemctl', 'stop', 'grafana-server'
          execute :sudo, 'systemctl', 'disable', 'grafana-server'
          execute :sudo, 'apt-get', 'remove', '-y', 'grafana'
          execute :sudo, 'rm', '-f', '/etc/apt/sources.list.d/grafana.list'
          execute :sudo, 'rm', '-f', '/usr/share/keyrings/grafana.gpg'
          execute :sudo, 'rm', '-rf', '/etc/grafana/provisioning/datasources/active_postgres.yml'
        end
      end

      def configure_grafana_datasource(host, prometheus_url)
        datasource = <<~YAML
          apiVersion: 1
          datasources:
            - name: Prometheus
              type: prometheus
              access: proxy
              url: #{prometheus_url}
              isDefault: true
        YAML

        ssh_executor.execute_on_host(host) do
          execute :sudo, 'mkdir', '-p', '/etc/grafana/provisioning/datasources'
          upload! StringIO.new(datasource), '/tmp/active_postgres_grafana_ds.yml'
          execute :sudo, 'mv', '/tmp/active_postgres_grafana_ds.yml', '/etc/grafana/provisioning/datasources/active_postgres.yml'
          execute :sudo, 'chown', 'root:root', '/etc/grafana/provisioning/datasources/active_postgres.yml'
          execute :sudo, 'chmod', '644', '/etc/grafana/provisioning/datasources/active_postgres.yml'
          execute :sudo, 'systemctl', 'restart', 'grafana-server'
        end
      end

      def normalize_grafana_password(raw_password)
        password = raw_password.to_s.rstrip

        raise Error, 'grafana_admin_password secret is missing (required for grafana)' if password.empty?

        password
      end

      def escape_systemd_env(value)
        value.to_s.gsub('\\', '\\\\').gsub('"', '\\"')
      end
    end
  end
end
