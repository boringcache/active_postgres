module ActivePostgres
  module Components
    class PgBouncer < Base
      def install
        puts 'Installing PgBouncer for connection pooling...'

        config.all_hosts.each do |host|
          is_standby = config.standby_hosts.include?(host)
          install_on_host(host, is_standby: is_standby)
        end
      end

      def uninstall
        puts 'Uninstalling PgBouncer...'

        config.all_hosts.each do |host|
          ssh_executor.execute_on_host(host) do
            execute :sudo, 'systemctl', 'disable', '--now', 'pgbouncer-follow-primary.timer', '||', 'true'
            execute :sudo, 'rm', '-f', '/usr/local/bin/pgbouncer-follow-primary',
                    '/etc/systemd/system/pgbouncer-follow-primary.service',
                    '/etc/systemd/system/pgbouncer-follow-primary.timer'
            execute :sudo, 'systemctl', 'daemon-reload'
            execute :sudo, 'systemctl', 'stop', 'pgbouncer'
            execute :sudo, 'apt-get', 'remove', '-y', 'pgbouncer'
          end
        end
      end

      def restart
        puts 'Restarting PgBouncer...'

        config.all_hosts.each do |host|
          ssh_executor.execute_on_host(host) do
            execute :sudo, 'systemctl', 'restart', 'pgbouncer'
          end
        end
      end

      def update_userlist
        puts 'Updating PgBouncer userlist on all hosts...'

        config.all_hosts.each do |host|
          create_userlist(host)

          ssh_executor.execute_on_host(host) do
            execute :sudo, 'systemctl', 'reload', 'pgbouncer'
          end
        end
      end

      def install_on_standby(standby_host)
        puts "Installing PgBouncer on standby #{standby_host}..."
        install_on_host(standby_host, is_standby: true)
      end

      private

      def install_on_host(host, is_standby: false)
        puts "  Installing PgBouncer on #{host}..."

        user_config = config.component_config(:pgbouncer)

        follow_primary = follow_primary_for?(host, is_standby: is_standby, user_config: user_config)

        if follow_primary && !config.component_enabled?(:repmgr)
          raise Error, 'PgBouncer follow_primary requires repmgr to be enabled'
        end

        max_connections = get_postgres_max_connections(host)
        optimal_pool = ConnectionPooler.calculate_optimal_pool_sizes(max_connections)

        pgbouncer_config = optimal_pool.merge(user_config)
        # For standbys not following primary, use localhost; otherwise use primary host
        pgbouncer_config[:database_host] = follow_primary ? config.primary_replication_host : '127.0.0.1'
        ssl_enabled = config.component_enabled?(:ssl)
        has_ca_cert = ssl_enabled && secrets.resolve('ssl_chain')
        secrets_obj = secrets
        _ = pgbouncer_config
        _ = has_ca_cert
        _ = secrets_obj

        puts "  Calculated pool settings for max_connections=#{max_connections}"

        install_apt_packages(host, 'pgbouncer')

        upload_template(host, 'pgbouncer.ini.erb', '/etc/pgbouncer/pgbouncer.ini', binding, mode: '644')

        setup_ssl_certs(host) if ssl_enabled

        create_userlist(host)

        ensure_firewall_port_open(host, pgbouncer_config[:listen_port] || 6432)

        ssh_executor.execute_on_host(host) do
          execute :sudo, 'systemctl', 'enable', 'pgbouncer'
          execute :sudo, 'systemctl', 'restart', 'pgbouncer'
          unless follow_primary
            execute :sudo, 'systemctl', 'disable', '--now', 'pgbouncer-follow-primary.timer', '||', 'true'
            execute :sudo, 'rm', '-f', '/usr/local/bin/pgbouncer-follow-primary',
                    '/etc/systemd/system/pgbouncer-follow-primary.service',
                    '/etc/systemd/system/pgbouncer-follow-primary.timer'
            execute :sudo, 'systemctl', 'daemon-reload'
          end
        end

        install_follow_primary(host, pgbouncer_config) if follow_primary
      end

      def follow_primary_for?(host, is_standby:, user_config:)
        if is_standby
          standby_config = config.standby_config_for(host) || {}
          standby_override = standby_config['pgbouncer_follow_primary']
          standby_override = standby_config[:pgbouncer_follow_primary] if standby_override.nil?
          return standby_override == true unless standby_override.nil?
        end

        user_config[:follow_primary] == true || user_config['follow_primary'] == true
      end

      def setup_ssl_certs(host)
        puts '  Setting up SSL certificates for PgBouncer...'
        version = config.version

        ssh_executor.execute_on_host(host) do
          execute :sudo, 'cp', "/etc/postgresql/#{version}/main/server.crt", '/etc/pgbouncer/server.crt'
          execute :sudo, 'cp', "/etc/postgresql/#{version}/main/server.key", '/etc/pgbouncer/server.key'
          execute :sudo, 'chmod', '640', '/etc/pgbouncer/server.key'
          execute :sudo, 'chown', 'postgres:postgres', '/etc/pgbouncer/server.key'
          execute :sudo, 'chown', 'postgres:postgres', '/etc/pgbouncer/server.crt'
        end

        ssl_chain = secrets.resolve('ssl_chain')
        if ssl_chain
          ssh_executor.upload_file(host, ssl_chain, '/etc/pgbouncer/ca.crt', mode: '644', owner: 'postgres:postgres')
        end
      end

      def get_postgres_max_connections(host)
        # Try to get max_connections from running PostgreSQL
        postgres_user = config.postgres_user
        max_conn = nil

        ssh_executor.execute_on_host(host) do
          result = capture(:sudo, '-u', postgres_user, 'psql', '-t', '-c', "'SHOW max_connections;'").strip
          max_conn = result.to_i if result && !result.empty?
        rescue StandardError
          # PostgreSQL might not be running yet
        end

        # Fall back to config value or default
        max_conn || config.component_config(:core).dig(:postgresql, :max_connections) || 100
      end

      def create_userlist(host)
        puts '  Creating PgBouncer userlist with database users...'

        postgres_user = config.postgres_user
        app_user = config.app_user
        users_to_add = [postgres_user, (app_user if app_user != postgres_user)].compact
        pgbouncer = self

        ssh_executor.execute_on_host(host) do
          backend = self
          userlist_entries = users_to_add.filter_map { |user| pgbouncer.send(:fetch_user_hash, backend, user, postgres_user) }
          pgbouncer.send(:write_userlist_file, backend, userlist_entries)
        end
      end

      def fetch_user_hash(backend, user, postgres_user)
        sql = build_user_hash_sql(user)

        user_hash = ssh_executor.run_sql_on_backend(backend, sql, postgres_user: postgres_user).to_s.strip

        if user_hash && !user_hash.empty?
          puts "  ✓ Added #{user} to PgBouncer userlist"
          user_hash
        else
          warn "  ⚠ User #{user} not found in PostgreSQL - create it first"
          nil
        end
      rescue StandardError => e
        warn "  ⚠ Warning: Could not get password hash for #{user}: #{e.message}"
        nil
      end

      def build_user_hash_sql(user)
        <<~SQL.strip
          SELECT concat('"', rolname, '" "', rolpassword, '"')
          FROM pg_authid
          WHERE rolname = '#{user}'
        SQL
      end

      def write_userlist_file(backend, userlist_entries)
        if userlist_entries.any?
          userlist_content = "#{userlist_entries.join("\n")}\n"
          backend.upload! StringIO.new(userlist_content), '/tmp/userlist.txt'
          backend.execute :sudo, 'mv', '/tmp/userlist.txt', '/etc/pgbouncer/userlist.txt'
          backend.execute :sudo, 'chmod', '640', '/etc/pgbouncer/userlist.txt'
          backend.execute :sudo, 'chown', 'postgres:postgres', '/etc/pgbouncer/userlist.txt'
          puts "  ✓ Created userlist with #{userlist_entries.size} user(s)"
        else
          warn '  Warning: No users added to userlist - connections may fail'
        end
      end

      def ensure_firewall_port_open(host, port)
        ssh_executor.execute_on_host(host) do
          has_reject = test(:sudo, 'iptables', '-C', 'INPUT', '-j', 'REJECT', '2>/dev/null')
          if has_reject
            execute :sudo, 'iptables', '-I', 'INPUT', '-p', 'tcp', '--dport', port.to_s, '-j', 'ACCEPT'
            execute :sudo, 'sh', '-c', "'iptables-save > /etc/iptables/rules.v4 2>/dev/null || true'"
            puts "  ✓ Opened port #{port} in iptables"
          end
        end
      end

      def install_follow_primary(host, pgbouncer_config)
        interval = pgbouncer_config[:follow_primary_interval] || 5
        interval = interval.to_i
        interval = 5 if interval <= 0

        repmgr_conf = '/etc/repmgr.conf'
        repmgr_database = config.repmgr_database
        postgres_user = config.postgres_user
        _ = interval
        _ = repmgr_conf
        _ = repmgr_database
        _ = postgres_user

        upload_template(host, 'pgbouncer_follow_primary.sh.erb', '/usr/local/bin/pgbouncer-follow-primary', binding,
                        mode: '755', owner: 'root:root')
        upload_template(host, 'pgbouncer-follow-primary.service.erb',
                        '/etc/systemd/system/pgbouncer-follow-primary.service', binding, mode: '644', owner: 'root:root')
        upload_template(host, 'pgbouncer-follow-primary.timer.erb',
                        '/etc/systemd/system/pgbouncer-follow-primary.timer', binding, mode: '644', owner: 'root:root')

        ssh_executor.execute_on_host(host) do
          execute :sudo, 'systemctl', 'daemon-reload'
          execute :sudo, 'systemctl', 'enable', '--now', 'pgbouncer-follow-primary.timer'
          execute :sudo, 'systemctl', 'start', 'pgbouncer-follow-primary.service'
        end
      end
    end
  end
end
