module ActivePostgres
  module Components
    class Monitoring < Base
      def install
        puts 'Installing postgres_exporter for monitoring...'

        config.all_hosts.each do |host|
          install_on_host(host)
        end
      end

      def uninstall
        puts 'Uninstalling postgres_exporter...'

        config.all_hosts.each do |host|
          ssh_executor.execute_on_host(host) do
            execute :sudo, 'systemctl', 'stop', 'postgres_exporter'
            execute :sudo, 'systemctl', 'disable', 'postgres_exporter'
          end
        end
      end

      def restart
        puts 'Restarting postgres_exporter...'

        config.all_hosts.each do |host|
          ssh_executor.execute_on_host(host) do
            execute :sudo, 'systemctl', 'restart', 'postgres_exporter'
          end
        end
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

          # Enable and start
          execute :sudo, 'systemctl', 'enable', 'prometheus-postgres-exporter'
          execute :sudo, 'systemctl', 'start', 'prometheus-postgres-exporter'
        end

        puts "  Metrics available at: http://#{host}:#{exporter_port}/metrics"
      end
    end
  end
end
