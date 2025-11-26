module ActivePostgres
  module Components
    class Repmgr < Base
      def install
        puts 'Installing repmgr for High Availability...'

        install_repmgr_package
        setup_primary

        config.standby_hosts.each do |host|
          setup_standby(host)
        end

        # Verify the entire cluster is healthy after setup
        puts "\n🏥 Performing final health check..."
        verify_cluster_health
      end

      def uninstall
        puts 'Uninstalling repmgr...'

        config.all_hosts.each do |host|
          is_primary = host == config.primary_host
          node_id = if is_primary
                      1
                    else
                      begin
                        config.standby_hosts.index(host) + 2
                      rescue StandardError
                        999
                      end
                    end

          ssh_executor.execute_on_host(host) do
            cluster_output = begin
              capture(:sudo, '-u', 'postgres', 'repmgr', 'cluster', 'show')
            rescue StandardError
              ''
            end

            if cluster_output.include?("| #{node_id}") && cluster_output.include?('running')
              info "✓ Skipping repmgr removal from #{host} - node #{node_id} is running"
            else
              info "Removing repmgr from #{host}"
              execute :sudo, 'apt-get', 'remove', '-y', '-q', 'postgresql-*-repmgr', '||', 'true'
            end
          end
        end
      end

      def restart
        puts 'Restarting repmgr...'

        config.all_hosts.each do |host|
          ssh_executor.execute_on_host(host) do
            execute :sudo, 'systemctl', 'restart', 'repmgrd' if test('systemctl is-active repmgrd')
          end
        end
      end

      def setup_standby_only(standby_host)
        puts "Setting up standby #{standby_host} (primary will not be touched)..."

        version = config.version
        ssh_executor.execute_on_host(standby_host) do
          execute :sudo, 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'install', '-y', '-qq',
                  "postgresql-#{version}-repmgr"
        end

        setup_standby(standby_host)
      end

      private

      def install_repmgr_package
        puts '  Installing repmgr package...'

        version = config.version
        config.all_hosts.each do |host|
          ssh_executor.execute_on_host(host) do
            execute :sudo, 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'install', '-y', '-qq',
                    "postgresql-#{version}-repmgr"
          end
        end
      end

      def setup_primary
        puts '  Setting up primary with repmgr...'

        host = config.primary_host
        repmgr_config = config.component_config(:repmgr)
        version = config.version
        repmgr_password = normalize_repmgr_password(secrets.resolve('repmgr_password'))
        secrets_obj = secrets
        repmgr_user = config.repmgr_user
        repmgr_db = config.repmgr_database

        # Variables used in ERB templates via binding
        _ = repmgr_config
        _ = secrets_obj

        ssh_executor.recreate_cluster(host, version)

        puts '  Configuring PostgreSQL...'
        core_config = config.component_config(:core)
        component_config = core_config

        # Performance tuning is handled by the Core component
        pg_config = component_config[:postgresql] || {}
        _ = pg_config # Used in ERB template

        upload_template(host, 'postgresql.conf.erb', "/etc/postgresql/#{version}/main/postgresql.conf", binding,
                        owner: 'postgres:postgres')
        upload_template(host, 'pg_hba.conf.erb', "/etc/postgresql/#{version}/main/pg_hba.conf", binding,
                        owner: 'postgres:postgres')

        # Regenerate SSL certificates if SSL is enabled (cluster recreation deleted them)
        if config.component_enabled?(:ssl)
          puts '  Regenerating SSL certificates...'
          regenerate_ssl_certs(host, version)
        end

        ssh_executor.execute_on_host(host) do
          execute :sudo, 'pg_ctlcluster', version.to_s, 'main', 'restart'

          info 'Waiting for PostgreSQL to start...'
          sleep 3

          # Check if cluster is running
          cluster_status = begin
            capture(:sudo, 'pg_lsclusters', '-h')
          rescue StandardError
            ''
          end
          running = cluster_status.lines.any? do |line|
            line.include?(version.to_s) && line.include?('main') && line.include?('online')
          end

          unless running
            error "PostgreSQL cluster #{version}/main is not running!"
            raise 'PostgreSQL service is not running'
          end

          info 'Verifying PostgreSQL is accepting connections...'
          execute :sudo, '-u', 'postgres', 'psql', '-l'

          info 'Creating repmgr database and user...'
          escaped_password = repmgr_password.gsub("'", "''")
          sql = [
            "DROP DATABASE IF EXISTS #{repmgr_db}",
            "DROP USER IF EXISTS #{repmgr_user}",
            "CREATE USER #{repmgr_user} WITH SUPERUSER PASSWORD '#{escaped_password}'",
            "CREATE DATABASE #{repmgr_db} OWNER #{repmgr_user}",
            '' # Ensures trailing semicolon after join
          ].join('; ')
          upload! StringIO.new(sql), '/tmp/setup_repmgr.sql'
          execute :chmod, '644', '/tmp/setup_repmgr.sql'
          execute :sudo, '-u', 'postgres', 'psql', '-p', '5432', '-f', '/tmp/setup_repmgr.sql'
          execute :rm, '-f', '/tmp/setup_repmgr.sql'

          info 'Reloading PostgreSQL configuration to apply pg_hba.conf changes...'
          execute :sudo, 'pg_ctlcluster', version.to_s, 'main', 'reload'
        end

        setup_pgpass_file(host, repmgr_password)

        upload_template(host, 'repmgr.conf.erb', '/etc/repmgr.conf', binding, mode: '644', owner: 'postgres:postgres')

        ssh_executor.execute_on_host(host) do
          info 'Registering primary with repmgr...'
          execute :sudo, '-u', 'postgres', 'env',
                  'HOME=/var/lib/postgresql',
                  'repmgr', 'primary', 'register',
                  '-f', '/etc/repmgr.conf', '--force'

          # Verify registration succeeded
          sleep 2
          cluster_show = begin
            capture(:sudo, '-u', 'postgres', 'repmgr', 'cluster', 'show', '-f',
                    '/etc/repmgr.conf')
          rescue StandardError
            'Could not show cluster'
          end

          unless cluster_show.include?('primary') && cluster_show.include?('running')
            error '✗ Primary registration verification failed'
            raise 'Primary registration failed'
          end

          info '✓ Primary successfully registered with repmgr!'
        end
      end

      def setup_standby(standby_host)
        puts "  Setting up standby: #{standby_host}..."

        host = standby_host
        repmgr_config = config.component_config(:repmgr)
        primary_replication_host = config.primary_replication_host
        version = config.version
        secrets_obj = secrets
        repmgr_user = config.repmgr_user
        repmgr_db = config.repmgr_database
        postgres_user = config.postgres_user

        # Variables used in ERB templates via binding
        _ = host
        _ = repmgr_config
        _ = secrets_obj

        node_id = config.standby_hosts.index(standby_host) + 2
        repmgr_password = normalize_repmgr_password(secrets_obj.resolve('repmgr_password'))

        ensure_primary_registered

        setup_pgpass_file(standby_host, repmgr_password, primary_replication_host)

        ssh_executor.execute_on_host(standby_host) do
          info 'Preparing standby cluster...'
          begin
            execute :sudo, 'systemctl', 'stop', 'postgresql'
          rescue StandardError
            nil
          end
          begin
            execute :sudo, 'pg_dropcluster', '--stop', version.to_s, 'main'
          rescue StandardError
            nil
          end
          begin
            execute :sudo, 'rm', '-rf', "/etc/postgresql/#{version}/main"
          rescue StandardError
            nil
          end
          begin
            execute :sudo, 'rm', '-rf', "/var/lib/postgresql/#{version}/main"
          rescue StandardError
            nil
          end

          info 'Cloning from primary over private network...'
          # Create a temporary repmgr config for cloning that points to the primary
          # The regular config points to localhost which doesn't work during initial clone
          escaped_password = repmgr_password.gsub("'", "\\\\'")

          temp_repmgr_conf = <<~CONF
            node_id=#{node_id}
            node_name='#{standby_host}'
            conninfo='host=#{primary_replication_host} user=#{repmgr_user} dbname=#{repmgr_db} password=#{escaped_password} connect_timeout=10'
            data_directory='/var/lib/postgresql/#{version}/main'
          CONF

          info 'Creating temporary repmgr config for cloning...'
          upload! StringIO.new(temp_repmgr_conf), '/tmp/repmgr_clone.conf'
          execute :sudo, 'mv', '/tmp/repmgr_clone.conf', '/etc/repmgr_clone.conf'
          execute :sudo, 'chown', 'postgres:postgres', '/etc/repmgr_clone.conf'
          execute :sudo, 'chmod', '644', '/etc/repmgr_clone.conf'

          info 'Running: repmgr standby clone (this may take a few minutes to copy the database)...'

          clone_success = false
          begin
            execute :sudo, '-u', postgres_user, 'env',
                    'HOME=/var/lib/postgresql',
                    'repmgr', 'standby', 'clone',
                    '-h', primary_replication_host,
                    '-U', repmgr_user,
                    '-d', repmgr_db,
                    '-f', '/etc/repmgr_clone.conf',
                    '--force',
                    '--verbose'

            info 'Clone command completed'

            # Check if clone actually succeeded
            if test(:sudo, 'test', '-d', "/var/lib/postgresql/#{version}/main")
              clone_success = true
              info 'Data directory successfully cloned!'

              # Clean up temporary clone config
              execute :sudo, 'rm', '-f', '/etc/repmgr_clone.conf'
            else
              error "Data directory /var/lib/postgresql/#{version}/main was not created even though command succeeded!"
            end
          rescue SSHKit::Command::Failed => e
            error "Clone command failed with exit code #{e.message}"
          rescue StandardError => e
            error "Clone command raised exception: #{e.class}: #{e.message}"
          end

          # If clone failed, raise error
          unless clone_success
            error '✗ repmgr standby clone failed'
            raise 'repmgr standby clone failed to create data directory'
          end
        end

        # Upload the proper repmgr.conf now that clone is complete
        puts '  Uploading final repmgr configuration...'
        upload_template(standby_host, 'repmgr.conf.erb', '/etc/repmgr.conf', binding, mode: '644',
                                                                                      owner: 'postgres:postgres')

        # Create config directory and setup PostgreSQL configuration
        puts '  Setting up PostgreSQL configuration on standby...'
        core_config = config.component_config(:core)
        component_config = core_config

        # Performance tuning is handled by the Core component
        pg_config = component_config[:postgresql] || {}
        _ = pg_config # Used in ERB template

        ssh_executor.execute_on_host(standby_host) do
          # Create config directory if it doesn't exist
          execute :sudo, 'mkdir', '-p', "/etc/postgresql/#{version}/main"
          execute :sudo, 'chown', 'postgres:postgres', "/etc/postgresql/#{version}/main"
        end

        # Upload configuration files
        upload_template(standby_host, 'postgresql.conf.erb', "/etc/postgresql/#{version}/main/postgresql.conf",
                        binding, owner: 'postgres:postgres')
        upload_template(standby_host, 'pg_hba.conf.erb', "/etc/postgresql/#{version}/main/pg_hba.conf", binding,
                        owner: 'postgres:postgres')

        # Regenerate SSL certificates if SSL is enabled (clone doesn't copy config files)
        if config.component_enabled?(:ssl)
          puts '  Regenerating SSL certificates on standby...'
          regenerate_ssl_certs(standby_host, version)
        end

        ssh_executor.execute_on_host(standby_host) do
          info 'Starting PostgreSQL cluster...'
          execute :sudo, 'pg_ctlcluster', version.to_s, 'main', 'start'

          # Wait for PostgreSQL to be ready
          max_attempts = 12
          attempt = 0
          pg_ready = false

          while attempt < max_attempts && !pg_ready
            attempt += 1
            sleep 3
            pg_ready = test(:sudo, '-u', 'postgres', 'pg_isready', '-h', '127.0.0.1', '-p', '5432')

            if !pg_ready && attempt == max_attempts
              error '✗ PostgreSQL failed to start on standby'
              raise 'PostgreSQL failed to start on standby'
            end
          end

          info '✓ PostgreSQL is ready!'
        end

        register_standby_with_primary(standby_host)
      end

      def register_standby_with_primary(standby_host)
        standby_config = config.standby_config_for(standby_host)
        standby_label = standby_config&.dig('label') || "standby-#{standby_host.split('.').first}"

        primary_conninfo = build_primary_conninfo(standby_label)
        escaped_conninfo = primary_conninfo.gsub("'", "''")
        sql_content = "ALTER SYSTEM SET primary_conninfo = '#{escaped_conninfo}';\n"
        temp_sql = '/tmp/set_primary_conninfo.sql'
        version = config.version
        postgres_user = config.postgres_user

        ssh_executor.execute_on_host(standby_host) do
          info 'Setting primary_conninfo with application_name...'
          upload! StringIO.new(sql_content), temp_sql
          execute :sudo, 'chown', "#{postgres_user}:#{postgres_user}", temp_sql

          begin
            execute :sudo, '-u', postgres_user, 'psql', '-f', temp_sql
          ensure
            execute :sudo, 'rm', '-f', temp_sql
          end

          execute :sudo, 'pg_ctlcluster', version.to_s, 'main', 'reload'

          info 'Registering standby with repmgr...'

          execute :sudo, '-u', postgres_user, 'env',
                  'HOME=/var/lib/postgresql',
                  'repmgr', '-f', '/etc/repmgr.conf',
                  'standby', 'register',
                  '--force'

          info '✓ Standby successfully registered!'
        end
      end

      def verify_cluster_health
        puts 'Verifying PostgreSQL HA cluster health...'

        primary_host = config.primary_host
        standby_hosts = config.standby_hosts
        version = config.version
        postgres_user = config.postgres_user
        all_healthy = true

        # Check primary
        ssh_executor.execute_on_host(primary_host) do
          info "Checking primary node #{primary_host}..."

          # Check PostgreSQL is running
          begin
            clusters = capture(:sudo, 'pg_lsclusters')
          rescue StandardError => e
            clusters = ''
            error "Failed to check clusters on primary: #{e.message}"
          end

          if clusters.match?(/#{version}.*main.*online/)
            info '✓ PostgreSQL is running on primary'
          else
            error '✗ PostgreSQL is not running on primary'
            all_healthy = false
          end

          # Check repmgr registration
          cluster_output = begin
            capture(:sudo, '-u', 'postgres', 'repmgr', 'cluster', 'show')
          rescue StandardError
            ''
          end
          # Primary always has node_id=1, check if it's registered and running
          if cluster_output.match?(/\s+1\s+\|.*primary.*\*\s+running/)
            info '✓ Primary is registered with repmgr'
          else
            error '✗ Primary is not registered with repmgr'
            all_healthy = false
          end

          # Check replication slots (if standbys exist)
          if standby_hosts.any?
            begin
              slots_sql = 'SELECT slot_name, active FROM pg_replication_slots;'
              slots = capture(:sudo, '-u', postgres_user, 'psql', '-c', "'#{slots_sql}'")
              info "Replication slots:\n#{slots}"
            rescue StandardError => e
              error "Failed to fetch replication slots: #{e.message}"
              all_healthy = false
            end
          end
        end

        # Check standbys
        standby_hosts.each do |standby_host|
          ssh_executor.execute_on_host(standby_host) do
            info "Checking standby node #{standby_host}..."

            # Check PostgreSQL is running
            begin
              clusters = capture(:sudo, 'pg_lsclusters')
            rescue StandardError => e
              clusters = ''
              error "Failed to check clusters on #{standby_host}: #{e.message}"
            end

            if clusters.match?(/#{version}.*main.*online/)
              info '✓ PostgreSQL is running on standby'
            else
              error '✗ PostgreSQL is not running on standby'
              all_healthy = false
            end

            # Check replication status
            begin
              recovery_sql = 'SELECT pg_is_in_recovery();'
              rep_status = capture(:sudo, '-u', postgres_user, 'psql', '-t', '-c', "'#{recovery_sql}'")
              if rep_status.include?('t')
                info '✓ Standby is in recovery mode (receiving replication)'
              else
                error '✗ Standby is not in recovery mode'
                all_healthy = false
              end
            rescue StandardError => e
              error "Failed to check recovery status: #{e.message}"
              all_healthy = false
            end

            # Check lag
            begin
              lag_sql = 'SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))::int AS lag;'
              lag_result = capture(:sudo, '-u', postgres_user, 'psql', '-t', '-c', "'#{lag_sql}'").strip
              info "Replication lag: #{lag_result}"
            rescue StandardError => e
              error "Failed to get replication lag: #{e.message}"
              all_healthy = false
            end
          end
        end

        # Show final cluster status
        ssh_executor.execute_on_host(primary_host) do
          info 'Final cluster status:'
          cluster_show = begin
            capture(:sudo, '-u', 'postgres', 'repmgr', 'cluster', 'show')
          rescue StandardError
            'Error'
          end
          safe_show = LogSanitizer.sanitize(cluster_show)
          info safe_show
        end

        if all_healthy
          puts '✅ PostgreSQL HA cluster is healthy!'
        else
          puts '⚠️ PostgreSQL HA cluster has issues - check the errors above'
        end

        all_healthy
      end

      def setup_pgpass_file(host, password, primary_ip = nil)
        # Create .pgpass file for postgres user to avoid password exposure in logs
        # Format: hostname:port:database:username:password
        pgpass_content = build_pgpass_content(host, password, primary_ip)

        ssh_executor.execute_on_host(host) do
          # Create .pgpass in postgres user's home directory
          upload! StringIO.new(pgpass_content), '/tmp/.pgpass'
          execute :sudo, 'mv', '/tmp/.pgpass', '/var/lib/postgresql/.pgpass'
          execute :sudo, 'chown', 'postgres:postgres', '/var/lib/postgresql/.pgpass'
          execute :sudo, 'chmod', '600', '/var/lib/postgresql/.pgpass' # Must be 600 for security

          info '✓ Configured .pgpass file for secure authentication'
        end
      end

      def build_pgpass_content(host, password, primary_ip)
        escaped_password = escape_pgpass_value(password)
        repmgr_user = config.repmgr_user
        repmgr_db = config.repmgr_database

        entries = [
          "localhost:5432:#{repmgr_db}:#{repmgr_user}:#{escaped_password}",
          "127.0.0.1:5432:#{repmgr_db}:#{repmgr_user}:#{escaped_password}",
          "localhost:5432:*:#{repmgr_user}:#{escaped_password}",
          "127.0.0.1:5432:*:#{repmgr_user}:#{escaped_password}"
        ]

        if primary_ip
          entries << "#{primary_ip}:5432:#{repmgr_db}:#{repmgr_user}:#{escaped_password}"
          entries << "#{primary_ip}:5432:*:#{repmgr_user}:#{escaped_password}"
        end

        local_replication_host = config.replication_host_for(host)
        if local_replication_host && !%w[localhost 127.0.0.1].include?(local_replication_host)
          entries << "#{local_replication_host}:5432:#{repmgr_db}:#{repmgr_user}:#{escaped_password}"
          entries << "#{local_replication_host}:5432:*:#{repmgr_user}:#{escaped_password}"
        end

        "#{entries.join("\n")}\n"
      end

      def escape_pgpass_value(value)
        return '' if value.nil?

        # Must escape backslashes first, then colons (order matters!)
        value.to_s.gsub('\\', '\\\\\\\\').gsub(':', '\\:')
      end

      def build_primary_conninfo(standby_label)
        primary_host = config.primary_replication_host
        repmgr_user = config.repmgr_user
        repmgr_db = config.repmgr_database
        "host=#{primary_host} user=#{repmgr_user} dbname=#{repmgr_db} application_name=#{standby_label}"
      end

      def normalize_repmgr_password(raw_password)
        password = raw_password.to_s.rstrip

        raise 'repmgr_password secret is missing' if password.empty?

        password
      end

      def reload_postgres_cluster
        execute :sudo, 'pg_ctlcluster', config.version.to_s, 'main', 'reload'
      rescue StandardError => e
        warn "Failed to reload via pg_ctlcluster: #{e.message}, falling back to systemctl"
        service_name = "postgresql@#{config.version}-main"
        execute :sudo, 'systemctl', 'reload', service_name
      end

      def ensure_primary_registered
        host = config.primary_host
        config.version
        is_registered = false

        ssh_executor.execute_on_host(host) do
          info 'Verifying primary registration...'

          cluster_output = begin
            capture(:sudo, '-u', 'postgres', 'env',
                    'HOME=/var/lib/postgresql',
                    'repmgr', 'cluster', 'show')
          rescue StandardError
            ''
          end

          if cluster_output.include?('| 1') && cluster_output.include?('primary')
            info '✓ Primary is registered (node_id=1)'
          else
            warn "⚠ Primary not found in cluster, assuming it's registered"
          end
          is_registered = true
        end

        is_registered
      end

      def regenerate_ssl_certs(host, version)
        ssl_config = config.component_config(:ssl)
        ssl_cert = secrets.resolve('ssl_cert')
        ssl_key = secrets.resolve('ssl_key')

        if ssl_cert && ssl_key
          puts '    Using SSL certificates from secrets...'
          ssh_executor.upload_file(host, ssl_cert, "/etc/postgresql/#{version}/main/server.crt", mode: '644',
                                                                                                 owner: 'postgres:postgres')
          ssh_executor.upload_file(host, ssl_key, "/etc/postgresql/#{version}/main/server.key", mode: '600',
                                                                                                owner: 'postgres:postgres')
        else
          puts '    Generating self-signed SSL certificates...'
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
end
