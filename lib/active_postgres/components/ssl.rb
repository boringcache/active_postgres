module ActivePostgres
  module Components
    class SSL < Base
      def install
        puts 'Installing SSL/TLS encryption...'

        config.all_hosts.each do |host|
          install_on_host(host)
        end
      end

      def uninstall
        puts 'SSL certificates remain (harmless to leave configured)'
      end

      def restart
        # SSL doesn't have its own service, restart PostgreSQL
        ssh_executor.restart_postgres(config.primary_host)

        config.standby_hosts.each do |host|
          ssh_executor.restart_postgres(host)
        end
      end

      def install_on_standby(standby_host)
        puts "Installing SSL on standby #{standby_host}..."
        install_on_host(standby_host)
      end

      private

      def install_on_host(host)
        puts "  Installing SSL on #{host}..."

        version = config.version
        ssl_config = config.component_config(:ssl)

        ssh_executor.ensure_postgres_user(host)

        # Ensure the PostgreSQL config directory exists
        ssh_executor.execute_on_host(host) do
          execute :sudo, 'mkdir', '-p', "/etc/postgresql/#{version}/main"
          execute :sudo, 'chown', 'postgres:postgres', "/etc/postgresql/#{version}/main"
        end

        ssl_cert = secrets.resolve('ssl_cert')
        ssl_key = secrets.resolve('ssl_key')

        if ssl_cert && ssl_key
          puts '  Using SSL certificates from secrets...'
          ssh_executor.upload_file(host, ssl_cert, "/etc/postgresql/#{version}/main/server.crt", mode: '644',
                                                                                                 owner: 'postgres:postgres')
          ssh_executor.upload_file(host, ssl_key, "/etc/postgresql/#{version}/main/server.key", mode: '600',
                                                                                                owner: 'postgres:postgres')
        else
          puts '  Generating self-signed SSL certificates...'
          generate_self_signed_cert(host, ssl_config)
        end
      end

      def generate_self_signed_cert(host, ssl_config)
        version = config.version
        cert_path = "/etc/postgresql/#{version}/main/server.crt"
        key_path = "/etc/postgresql/#{version}/main/server.key"

        ssh_executor.execute_on_host(host) do
          days = ssl_config[:cert_days] || 3650
          cn = ssl_config[:common_name] || host

          info "Generating self-signed certificate (CN=#{cn}, valid for #{days} days)..."

          execute :sudo, 'openssl', 'req', '-new', '-x509', '-days', days.to_s,
                  '-nodes', '-text',
                  '-out', cert_path,
                  '-keyout', key_path,
                  '-subj', "/CN=#{cn}"

          execute :sudo, 'chown', 'postgres:postgres', cert_path
          execute :sudo, 'chown', 'postgres:postgres', key_path
          execute :sudo, 'chmod', '644', cert_path
          execute :sudo, 'chmod', '600', key_path
        end
      end
    end
  end
end
