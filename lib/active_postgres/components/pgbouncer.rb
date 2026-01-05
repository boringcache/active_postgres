module ActivePostgres
  module Components
    class PgBouncer < Base
      def install
        puts 'Installing PgBouncer for connection pooling...'

        config.all_hosts.each do |host|
          install_on_host(host)
        end
      end

      def uninstall
        puts 'Uninstalling PgBouncer...'

        config.all_hosts.each do |host|
          ssh_executor.execute_on_host(host) do
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
        install_on_host(standby_host)
      end

      private

      def install_on_host(host)
        puts "  Installing PgBouncer on #{host}..."

        # Get user config
        user_config = config.component_config(:pgbouncer)

        # Calculate optimal pool settings based on PostgreSQL max_connections
        max_connections = get_postgres_max_connections(host)
        optimal_pool = ConnectionPooler.calculate_optimal_pool_sizes(max_connections)

        # Merge: user config overrides calculated settings
        pgbouncer_config = optimal_pool.merge(user_config)
        _ = pgbouncer_config # Used in ERB template

        puts "  Calculated pool settings for max_connections=#{max_connections}"

        # Install package
        ssh_executor.execute_on_host(host) do
          execute :sudo, 'apt-get', 'install', '-y', '-qq', 'pgbouncer'
        end

        # Upload configuration
        upload_template(host, 'pgbouncer.ini.erb', '/etc/pgbouncer/pgbouncer.ini', binding, mode: '644')

        # Create userlist with postgres superuser and app user
        create_userlist(host)

        # Enable and start
        ssh_executor.execute_on_host(host) do
          execute :sudo, 'systemctl', 'enable', 'pgbouncer'
          execute :sudo, 'systemctl', 'restart', 'pgbouncer'
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

        backend.upload! StringIO.new(sql), '/tmp/get_user_hash.sql'
        backend.execute :chmod, '644', '/tmp/get_user_hash.sql'
        user_hash = backend.capture(:sudo, '-u', postgres_user, 'psql', '-t', '-f', '/tmp/get_user_hash.sql').strip
        backend.execute :rm, '-f', '/tmp/get_user_hash.sql'

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
    end
  end
end
