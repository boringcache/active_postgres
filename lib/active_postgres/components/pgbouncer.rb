module ActivePostgres
  module Components
    class PgBouncer < Base
      def install
        puts 'Installing PgBouncer for connection pooling...'

        # Install on primary (can also install on standbys if needed)
        install_on_host(config.primary_host)
      end

      def uninstall
        puts 'Uninstalling PgBouncer...'

        ssh_executor.execute_on_host(config.primary_host) do
          execute :sudo, 'systemctl', 'stop', 'pgbouncer'
          execute :sudo, 'apt-get', 'remove', '-y', 'pgbouncer'
        end
      end

      def restart
        puts 'Restarting PgBouncer...'

        ssh_executor.execute_on_host(config.primary_host) do
          execute :sudo, 'systemctl', 'restart', 'pgbouncer'
        end
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

        ssh_executor.execute_on_host(host) do
          userlist_entries = []

          begin
            sql = <<~SQL.strip
              SELECT concat('"', rolname, '" "', rolpassword, '"')
              FROM pg_authid
              WHERE rolname = '#{postgres_user}'
            SQL

            upload! StringIO.new(sql), '/tmp/get_user_hash.sql'
            postgres_hash = capture(:sudo, '-u', postgres_user, 'psql', '-t', '-f', '/tmp/get_user_hash.sql').strip
            execute :rm, '-f', '/tmp/get_user_hash.sql'

            if postgres_hash && !postgres_hash.empty?
              userlist_entries << postgres_hash
              puts "  ✓ Added #{postgres_user} to PgBouncer userlist"
            end
          rescue StandardError => e
            warn "  ⚠ Warning: Could not get password hash for #{postgres_user}: #{e.message}"
          end

          if app_user && app_user != postgres_user
            begin
              sql = <<~SQL.strip
                SELECT concat('"', rolname, '" "', rolpassword, '"')
                FROM pg_authid
                WHERE rolname = '#{app_user}'
              SQL

              upload! StringIO.new(sql), '/tmp/get_user_hash.sql'
              app_hash = capture(:sudo, '-u', postgres_user, 'psql', '-t', '-f', '/tmp/get_user_hash.sql').strip
              execute :rm, '-f', '/tmp/get_user_hash.sql'

              if app_hash && !app_hash.empty?
                userlist_entries << app_hash
                puts "  ✓ Added #{app_user} to PgBouncer userlist"
              else
                warn "  ⚠ User #{app_user} not found in PostgreSQL - create it first"
              end
            rescue StandardError => e
              warn "  ⚠ Warning: Could not get password hash for #{app_user}: #{e.message}"
            end
          end

          # Write userlist file
          if userlist_entries.any?
            userlist_content = "#{userlist_entries.join("\n")}\n"
            execute :sudo, 'tee', '/etc/pgbouncer/userlist.txt', stdin: StringIO.new(userlist_content)
            execute :sudo, 'chmod', '640', '/etc/pgbouncer/userlist.txt'
            execute :sudo, 'chown', 'postgres:postgres', '/etc/pgbouncer/userlist.txt'
            puts "  ✓ Created userlist with #{userlist_entries.size} user(s)"
          else
            warn '  Warning: No users added to userlist - connections may fail'
          end
        end
      end
    end
  end
end
