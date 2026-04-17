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

        setup_inter_node_ssh if config.standby_hosts.any?
        setup_dns_failover if dns_failover_enabled?

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
        install_apt_packages(standby_host, "postgresql-#{version}-repmgr")

        setup_standby(standby_host)

        setup_dns_failover if dns_failover_enabled?
      end

      private

      def install_repmgr_package
        puts '  Installing repmgr package...'

        version = config.version
        config.all_hosts.each do |host|
          install_apt_packages(host, "postgresql-#{version}-repmgr")
          install_postgres_sudoers(host)
        end
      end

      def install_postgres_sudoers(host)
        version = config.version
        sudoers_line = "postgres ALL=(ALL) NOPASSWD: /usr/bin/systemctl start postgresql@#{version}-main, " \
                       "/usr/bin/systemctl stop postgresql@#{version}-main, " \
                       "/usr/bin/systemctl restart postgresql@#{version}-main, " \
                       "/usr/bin/systemctl reload postgresql@#{version}-main, " \
                       "/usr/bin/systemctl status postgresql@#{version}-main"
        ssh_executor.execute_on_host(host) do
          upload! StringIO.new("#{sudoers_line}\n"), '/tmp/postgres-repmgr-sudoers'
          execute :sudo, 'cp', '/tmp/postgres-repmgr-sudoers', '/etc/sudoers.d/postgres-repmgr'
          execute :sudo, 'chmod', '440', '/etc/sudoers.d/postgres-repmgr'
          execute :rm, '-f', '/tmp/postgres-repmgr-sudoers'
        end
      end

      def setup_primary
        puts '  Setting up primary with repmgr...'

        host = config.primary_host
        repmgr_config = config.component_config(:repmgr)
        version = config.version
        repmgr_password = normalize_repmgr_password(secrets.resolve('repmgr_password'))
        replication_password = normalize_replication_password(secrets.resolve('replication_password'))
        secrets_obj = secrets
        repmgr_user = config.repmgr_user
        repmgr_db = config.repmgr_database
        replication_user = config.replication_user
        if replication_user == repmgr_user && replication_password != repmgr_password
          raise Error, 'replication_user matches repmgr user but passwords differ. Use a distinct replication_user or the same password.'
        end
        effective_replication_password = replication_user == repmgr_user ? repmgr_password : replication_password

        # Variables used in ERB templates via binding
        _ = repmgr_config
        _ = secrets_obj

        cluster_exists = cluster_exists?(host, version)
        ssh_executor.ensure_cluster_exists(host, version) unless cluster_exists

        puts '  Configuring PostgreSQL...'
        core_config = config.component_config(:core)
        component_config = core_config

        # Performance tuning is handled by the Core component
        pg_config = component_config[:postgresql] || {}
        # Substitute ${private_ip} with the host's actual private IP
        private_ip = config.replication_host_for(host)
        pg_config = substitute_private_ip(pg_config, private_ip)
        _ = pg_config # Used in ERB template

        upload_template(host, 'postgresql.conf.erb', "/etc/postgresql/#{version}/main/postgresql.conf", binding,
                        owner: 'postgres:postgres')
        upload_template(host, 'pg_hba.conf.erb', "/etc/postgresql/#{version}/main/pg_hba.conf", binding,
                        owner: 'postgres:postgres')

        # Ensure SSL certificates are present if SSL is enabled
        if config.component_enabled?(:ssl)
          puts '  Ensuring SSL certificates...'
          ensure_ssl_certs(host, version, force: !cluster_exists)
        end

        repmgr_component = self
        executor = ssh_executor
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
          repmgr_sql = repmgr_component.send(:build_repmgr_setup_sql, repmgr_user, repmgr_db, repmgr_password)
          executor.run_sql_on_backend(self, repmgr_sql, postgres_user: 'postgres', port: 5432, tuples_only: false,
                                           capture: false)

          if replication_user != repmgr_user
            info 'Ensuring replication user exists...'
            repl_sql = repmgr_component.send(:build_replication_user_sql, replication_user, effective_replication_password)
            executor.run_sql_on_backend(self, repl_sql, postgres_user: 'postgres', port: 5432, tuples_only: false,
                                             capture: false)
          end

          info 'Reloading PostgreSQL configuration to apply pg_hba.conf changes...'
          execute :sudo, 'pg_ctlcluster', version.to_s, 'main', 'reload'
        end

        setup_pgpass_file(host, repmgr_password, replication_password: effective_replication_password)

        upload_template(host, 'repmgr.conf.erb', '/etc/repmgr.conf', binding, mode: '600', owner: 'postgres:postgres')

        ssh_executor.execute_on_host(host) do
          info 'Registering primary with repmgr...'
          execute :sudo, '-u', 'postgres', 'env',
                  'HOME=/var/lib/postgresql',
                  'repmgr', 'primary', 'register',
                  '-f', '/etc/repmgr.conf', '--force'

          # Verify registration succeeded (repmgr can take a moment to report)
          cluster_show = nil
          5.times do |attempt|
            cluster_show = capture(:sudo, '-u', 'postgres', 'bash', '-lc',
                                   "repmgr cluster show -f /etc/repmgr.conf 2>&1", raise_on_non_zero_exit: false).to_s

            break if cluster_show.match?(/primary/i)

            sleep 2 if attempt < 4
          end

          unless cluster_show && cluster_show.match?(/primary/i)
            # Fallback: verify via repmgr metadata in the repmgr database
            db_check = executor.run_sql_on_backend(self,
                                                   'SELECT type FROM repmgr.nodes WHERE node_id = 1;',
                                                   postgres_user: 'postgres',
                                                   database: repmgr_db,
                                                   tuples_only: true,
                                                   capture: true).to_s

            unless db_check.match?(/primary/i)
              safe_show = LogSanitizer.sanitize(cluster_show.to_s)
              error "✗ Primary registration verification failed:\n#{safe_show}"
              raise 'Primary registration failed'
            end
          end

          info '✓ Primary successfully registered with repmgr!'
        end

        enable_repmgrd_if_configured(host, repmgr_config)
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
        replication_user = config.replication_user

        # Variables used in ERB templates via binding
        _ = host
        _ = repmgr_config
        _ = secrets_obj

        node_id = config.standby_hosts.index(standby_host) + 2
        repmgr_password = normalize_repmgr_password(secrets_obj.resolve('repmgr_password'))
        replication_password = normalize_replication_password(secrets_obj.resolve('replication_password'))
        if replication_user == repmgr_user && replication_password != repmgr_password
          raise Error, 'replication_user matches repmgr user but passwords differ. Use a distinct replication_user or the same password.'
        end
        effective_replication_password = replication_user == repmgr_user ? repmgr_password : replication_password

        ensure_primary_registered
        ensure_primary_replication_ready(repmgr_password, effective_replication_password)

        setup_pgpass_file(standby_host, repmgr_password, replication_password: effective_replication_password,
                                                      primary_ip: primary_replication_host)

        if standby_already_configured?(standby_host)
          puts '  Standby already configured, updating configs...'
          upload_template(standby_host, 'repmgr.conf.erb', '/etc/repmgr.conf', binding, mode: '600',
                                                                                        owner: 'postgres:postgres')
          update_postgres_configs_on_standby(standby_host, version)
          ensure_ssl_certs(standby_host, version) if config.component_enabled?(:ssl)
          register_standby_with_primary(standby_host)
          setup_inter_node_ssh
          enable_repmgrd_if_configured(standby_host, repmgr_config)
          return
        end

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
          temp_repmgr_conf = <<~CONF
            node_id=#{node_id}
            node_name='#{standby_host}'
            conninfo='host=#{primary_replication_host} user=#{repmgr_user} dbname=#{repmgr_db} connect_timeout=10'
            data_directory='/var/lib/postgresql/#{version}/main'
          CONF

          info 'Creating temporary repmgr config for cloning...'
          upload! StringIO.new(temp_repmgr_conf), '/tmp/repmgr_clone.conf'
          execute :sudo, 'mv', '/tmp/repmgr_clone.conf', '/etc/repmgr_clone.conf'
          execute :sudo, 'chown', 'postgres:postgres', '/etc/repmgr_clone.conf'
          execute :sudo, 'chmod', '600', '/etc/repmgr_clone.conf'

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
        upload_template(standby_host, 'repmgr.conf.erb', '/etc/repmgr.conf', binding, mode: '600',
                                                                                      owner: 'postgres:postgres')

        # Create config directory and setup PostgreSQL configuration
        puts '  Setting up PostgreSQL configuration on standby...'
        core_config = config.component_config(:core)
        component_config = core_config

        # Performance tuning is handled by the Core component
        pg_config = component_config[:postgresql] || {}
        # Substitute ${private_ip} with the standby's actual private IP
        private_ip = config.replication_host_for(standby_host)
        pg_config = substitute_private_ip(pg_config, private_ip)
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

        # Ensure SSL certificates if SSL is enabled (clone doesn't copy config files)
        if config.component_enabled?(:ssl)
          puts '  Ensuring SSL certificates on standby...'
          ensure_ssl_certs(standby_host, version, force: true)
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
        setup_inter_node_ssh
        enable_repmgrd_if_configured(standby_host, repmgr_config)
      end

      def setup_inter_node_ssh
        dns_config = dns_failover_config
        key_path = dns_config && dns_config[:ssh_key_path] || '/var/lib/postgresql/.ssh/active_postgres_dns'
        postgres_user = config.postgres_user
        all_hosts = config.all_hosts
        pub_keys = {}

        all_hosts.each do |host|
          pub_keys[host] = ensure_dns_ssh_key(host, key_path, [])
        end

        all_hosts.each do |host|
          ssh_executor.execute_on_host(host) do
            other_keys = pub_keys.reject { |h, _| h == host }.values
            other_keys.each do |key|
              next if key.to_s.empty?

              upload! StringIO.new("#{key}\n"), '/tmp/pg_peer_key.pub'
              execute :sudo, '-u', postgres_user, 'bash', '-c',
                      "grep -qxF -f /tmp/pg_peer_key.pub /var/lib/postgresql/.ssh/authorized_keys 2>/dev/null || cat /tmp/pg_peer_key.pub >> /var/lib/postgresql/.ssh/authorized_keys"
              execute :rm, '-f', '/tmp/pg_peer_key.pub'
            end

            peer_ips = all_hosts.reject { |h| h == host }.map { |h| config.replication_host_for(h) }
            scan_cmd = "ssh-keyscan #{peer_ips.join(' ')} >> /var/lib/postgresql/.ssh/known_hosts 2>/dev/null || true"
            execute :sudo, '-u', postgres_user, 'bash', '-c', scan_cmd
          end
        end
      end

      def setup_dns_failover
        dns_config = dns_failover_config
        return unless dns_config

        dns_servers = normalize_dns_servers(dns_config[:dns_servers])
        dns_private_ips = dns_servers.map { |server| server[:private_ip] }.reject(&:empty?)
        dns_ssh_hosts = dns_servers.map { |server| server[:ssh_host] }.reject(&:empty?)
        dns_user = dns_config[:dns_user] || config.user
        dns_ssh_key_path = dns_config[:ssh_key_path] || '/var/lib/postgresql/.ssh/active_postgres_dns'
        ssh_strict_host_key = normalize_dns_host_key_verification(
          dns_config[:ssh_host_key_verification] || config.ssh_host_key_verification
        )

        pub_keys = {}
        config.all_hosts.each do |host|
          pub_keys[host] = ensure_dns_ssh_key(host, dns_ssh_key_path, dns_private_ips)
        end

        dns_ssh_hosts.each do |dns_server|
          authorize_dns_keys(dns_server, dns_user, pub_keys.values.compact)
        end

        setup_inter_node_ssh

        config.all_hosts.each do |host|
          install_dns_failover_script(host, dns_config, dns_private_ips, dns_user, dns_ssh_key_path, ssh_strict_host_key)
        end
      end

      def dns_failover_enabled?
        dns_failover_config != nil
      end

      def dns_failover_config
        repmgr_config = config.component_config(:repmgr)
        dns_config = repmgr_config[:dns_failover]
        return nil unless dns_config && dns_config[:enabled]

        dns_config
      end

      def normalize_dns_servers(raw_servers)
        Array(raw_servers).map do |server|
          if server.is_a?(Hash)
            ssh_host = server[:ssh_host] || server['ssh_host'] || server[:host] || server['host']
            private_ip = server[:private_ip] || server['private_ip'] || server[:ip] || server['ip']
            private_ip ||= ssh_host
            ssh_host ||= private_ip
            { ssh_host: ssh_host.to_s, private_ip: private_ip.to_s }
          else
            value = server.to_s
            { ssh_host: value, private_ip: value }
          end
        end
      end

      def ensure_dns_ssh_key(host, key_path, dns_servers)
        postgres_user = config.postgres_user
        public_key = nil

        ssh_executor.execute_on_host(host) do
          execute :sudo, 'mkdir', '-p', '/var/lib/postgresql/.ssh'
          execute :sudo, 'chown', "#{postgres_user}:#{postgres_user}", '/var/lib/postgresql/.ssh'
          execute :sudo, 'chmod', '700', '/var/lib/postgresql/.ssh'

          unless test(:sudo, '-u', postgres_user, 'test', '-f', key_path)
            execute :sudo, '-u', postgres_user, "ssh-keygen -t ed25519 -N '' -f #{key_path}"
          end

          public_key = capture(:sudo, '-u', postgres_user, 'cat', "#{key_path}.pub").strip

          unless dns_servers.empty?
            execute :sudo, '-u', postgres_user, 'touch', '/var/lib/postgresql/.ssh/known_hosts'
            scan_cmd = "ssh-keyscan -H #{dns_servers.join(' ')} >> /var/lib/postgresql/.ssh/known_hosts 2>/dev/null || true"
            execute :sudo, '-u', postgres_user, 'bash', '-c', scan_cmd
            execute :sudo, '-u', postgres_user, 'chmod', '600', '/var/lib/postgresql/.ssh/known_hosts'
          end
        end

        public_key
      end

      def authorize_dns_keys(dns_server, dns_user, keys)
        return if keys.empty?

        ssh_executor.execute_on_host_as(dns_server, dns_user) do
          execute :mkdir, '-p', '~/.ssh'
          execute :chmod, '700', '~/.ssh'
          execute :touch, '~/.ssh/authorized_keys'
          execute :chmod, '600', '~/.ssh/authorized_keys'

          keys.each do |key|
            next if key.to_s.empty?

            upload! StringIO.new("#{key}\n"), '/tmp/active_postgres_dns_key.pub'
            execute :bash, '-c',
                    "grep -qxF -f /tmp/active_postgres_dns_key.pub ~/.ssh/authorized_keys || " \
                    "cat /tmp/active_postgres_dns_key.pub >> ~/.ssh/authorized_keys"
            execute :rm, '-f', '/tmp/active_postgres_dns_key.pub'
          end
        end
      rescue Net::SSH::ConnectionTimeout, Net::SSH::AuthenticationFailed => e
        raise Error,
              "Failed to SSH to DNS server #{dns_server} as #{dns_user}. " \
              'If you run setup outside the mesh, use dns_failover.dns_servers entries ' \
              'with host/private_ip or run setup from a mesh node. ' \
              "(#{e.class})"
      end

      def install_dns_failover_script(host, dns_config, dns_servers, dns_user, dns_ssh_key_path, ssh_strict_host_key)
        return if dns_servers.empty?

        domains = normalize_dns_domains(dns_config)
        primary_records = normalize_dns_records(dns_config[:primary_records] || dns_config[:primary_record],
                                               default_prefix: 'db-primary',
                                               domains: domains)
        replica_records = normalize_dns_records(dns_config[:replica_records] || dns_config[:replica_record],
                                               default_prefix: 'db-replica',
                                               domains: domains)

        _ = primary_records
        _ = replica_records
        _ = dns_servers
        _ = dns_user
        _ = dns_ssh_key_path
        _ = ssh_strict_host_key

        upload_template(host, 'repmgr_dns_failover.sh.erb', '/usr/local/bin/active-postgres-dns-failover', binding,
                        mode: '755', owner: 'root:root')
      end

      def normalize_dns_domains(dns_config)
        domains = Array(dns_config[:domains] || dns_config[:domain]).map(&:to_s).map(&:strip).reject(&:empty?)
        domains = ['mesh'] if domains.empty?
        domains
      end

      def normalize_dns_records(value, default_prefix:, domains:)
        records = Array(value).map(&:to_s).map(&:strip).reject(&:empty?)
        return records unless records.empty?

        domains.map { |domain| "#{default_prefix}.#{domain}" }
      end

      def normalize_dns_host_key_verification(value)
        normalized = case value
                     when Symbol
                       value
                     else
                       value.to_s.strip.downcase.tr('-', '_').to_sym
                     end

        return 'accept-new' if normalized == :accept_new
        return 'no' if normalized == :never

        'yes'
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
          execute :sudo, 'chmod', '600', temp_sql

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
        repmgr_db = config.repmgr_database
        executor = ssh_executor
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
          cluster_output = capture(:sudo, '-u', 'postgres',
                                   'repmgr', '-f', '/etc/repmgr.conf', 'cluster', 'show',
                                   raise_on_non_zero_exit: false).to_s
          # Primary always has node_id=1, check if it's registered and running
          if cluster_output.match?(/\s+1\s+\|.*primary.*\*\s+running/i)
            info '✓ Primary is registered with repmgr'
          else
            db_check = executor.run_sql_on_backend(self,
                                                   'SELECT type FROM repmgr.nodes WHERE node_id = 1 AND active IS TRUE;',
                                                   postgres_user: postgres_user,
                                                   database: repmgr_db,
                                                   tuples_only: true,
                                                   capture: true).to_s
            if db_check.match?(/primary/i)
              info '✓ Primary is registered with repmgr'
            else
              error '✗ Primary is not registered with repmgr'
              all_healthy = false
            end
          end

          # Check replication slots (if standbys exist)
          if standby_hosts.any?
            begin
              slots = executor.run_sql_on_backend(self,
                                                  'SELECT slot_name, active FROM pg_replication_slots;',
                                                  postgres_user: postgres_user,
                                                  tuples_only: false,
                                                  capture: true)
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
              rep_status = executor.run_sql_on_backend(self,
                                                      'SELECT pg_is_in_recovery();',
                                                      postgres_user: postgres_user,
                                                      tuples_only: true,
                                                      capture: true).to_s
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
              lag_result = executor.run_sql_on_backend(self,
                                                      'SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))::int AS lag;',
                                                      postgres_user: postgres_user,
                                                      tuples_only: true,
                                                      capture: true).to_s.strip
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
          cluster_show = capture(:sudo, '-u', 'postgres',
                                 'repmgr', '-f', '/etc/repmgr.conf', 'cluster', 'show',
                                 raise_on_non_zero_exit: false).to_s
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

      def setup_pgpass_file(host, repmgr_password, replication_password: nil, primary_ip: nil)
        # Create .pgpass file for postgres user to avoid password exposure in logs
        # Format: hostname:port:database:username:password
        pgpass_content = build_pgpass_content(host, repmgr_password, replication_password: replication_password,
                                                                   primary_ip: primary_ip)

        ssh_executor.execute_on_host(host) do
          # Create .pgpass in postgres user's home directory
          upload! StringIO.new(pgpass_content), '/tmp/.pgpass'
          execute :sudo, 'mv', '/tmp/.pgpass', '/var/lib/postgresql/.pgpass'
          execute :sudo, 'chown', 'postgres:postgres', '/var/lib/postgresql/.pgpass'
          execute :sudo, 'chmod', '600', '/var/lib/postgresql/.pgpass' # Must be 600 for security

          info '✓ Configured .pgpass file for secure authentication'
        end
      end

      def build_pgpass_content(host, repmgr_password, replication_password: nil, primary_ip: nil)
        escaped_password = escape_pgpass_value(repmgr_password)
        repmgr_user = config.repmgr_user
        repmgr_db = config.repmgr_database
        replication_user = config.replication_user
        replication_password ||= secrets.resolve('replication_password')
        replication_password = normalize_replication_password(replication_password) if replication_password

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

        # Allow repmgr to connect to all nodes for cluster status checks
        config.all_hosts.each do |node|
          replication_host = config.replication_host_for(node)
          next if replication_host.nil? || %w[localhost 127.0.0.1].include?(replication_host)

          entries << "#{replication_host}:5432:#{repmgr_db}:#{repmgr_user}:#{escaped_password}"
          entries << "#{replication_host}:5432:*:#{repmgr_user}:#{escaped_password}"
        end

        if replication_password && !replication_password.empty?
          escaped_replication_password = escape_pgpass_value(replication_password)
          entries << "localhost:5432:replication:#{replication_user}:#{escaped_replication_password}"
          entries << "127.0.0.1:5432:replication:#{replication_user}:#{escaped_replication_password}"
          entries << "localhost:5432:*:#{replication_user}:#{escaped_replication_password}"
          entries << "127.0.0.1:5432:*:#{replication_user}:#{escaped_replication_password}"
          if primary_ip
            entries << "#{primary_ip}:5432:replication:#{replication_user}:#{escaped_replication_password}"
            entries << "#{primary_ip}:5432:*:#{replication_user}:#{escaped_replication_password}"
          end
          if local_replication_host && !%w[localhost 127.0.0.1].include?(local_replication_host)
            entries << "#{local_replication_host}:5432:replication:#{replication_user}:#{escaped_replication_password}"
            entries << "#{local_replication_host}:5432:*:#{replication_user}:#{escaped_replication_password}"
          end
        end
        "#{entries.uniq.join("\n")}\n"
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
        replication_password = secrets.resolve('replication_password')
        replication_password = normalize_replication_password(replication_password) if replication_password
        replication_user = config.replication_user

        user = replication_password && !replication_password.empty? ? replication_user : repmgr_user
        dbname = replication_password && !replication_password.empty? ? 'replication' : repmgr_db
        "host=#{primary_host} user=#{user} dbname=#{dbname} application_name=#{standby_label}"
      end

      def normalize_repmgr_password(raw_password)
        password = raw_password.to_s.rstrip

        raise 'repmgr_password secret is missing' if password.empty?

        password
      end

      def normalize_replication_password(raw_password)
        password = raw_password.to_s.rstrip

        raise 'replication_password secret is missing' if password.empty?

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

      def ensure_primary_replication_ready(repmgr_password, effective_replication_password)
        host = config.primary_host
        repmgr_user = config.repmgr_user
        repmgr_db = config.repmgr_database
        replication_user = config.replication_user
        repmgr_component = self
        executor = ssh_executor

        puts '  Ensuring repmgr user has correct password and privileges on primary...'

        ssh_executor.execute_on_host(host) do
          repmgr_sql = repmgr_component.send(:build_repmgr_setup_sql, repmgr_user, repmgr_db, repmgr_password)
          executor.run_sql_on_backend(self, repmgr_sql, postgres_user: 'postgres', port: 5432, tuples_only: false,
                                           capture: false)

          if replication_user != repmgr_user
            repl_sql = repmgr_component.send(:build_replication_user_sql, replication_user, effective_replication_password)
            executor.run_sql_on_backend(self, repl_sql, postgres_user: 'postgres', port: 5432, tuples_only: false,
                                             capture: false)
          end

          info '✓ Primary replication user is ready'
        end

        setup_pgpass_file(host, repmgr_password, replication_password: effective_replication_password)
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

      def ensure_ssl_certs(host, version, force: false)
        ssl_cert = secrets.resolve('ssl_cert')
        ssl_key = secrets.resolve('ssl_key')

        return regenerate_ssl_certs(host, version) if force

        if ssl_cert && ssl_key
          regenerate_ssl_certs(host, version)
          return
        end

        cert_path = "/etc/postgresql/#{version}/main/server.crt"
        key_path = "/etc/postgresql/#{version}/main/server.key"

        cert_exists = false
        key_exists = false

        ssh_executor.execute_on_host(host) do
          cert_exists = test(:sudo, 'test', '-f', cert_path)
          key_exists = test(:sudo, 'test', '-f', key_path)
        end

        regenerate_ssl_certs(host, version) unless cert_exists && key_exists
      end

      def cluster_exists?(host, version)
        exists = false
        ssh_executor.execute_on_host(host) do
          exists = test(:sudo, 'test', '-d', "/var/lib/postgresql/#{version}/main/base")
        end
        exists
      rescue StandardError
        false
      end

      def standby_already_configured?(host)
        version = config.version
        postgres_user = config.postgres_user
        configured = false

        ssh_executor.execute_on_host(host) do
          data_dir = test(:sudo, 'test', '-d', "/var/lib/postgresql/#{version}/main/base")
          repmgr_conf = test(:sudo, 'test', '-f', '/etc/repmgr.conf')
          clusters = begin
            capture(:sudo, 'pg_lsclusters', '-h')
          rescue StandardError
            ''
          end
          online = clusters.lines.any? { |line| line.include?(version.to_s) && line.include?('main') && line.include?('online') }
          in_recovery = begin
            capture(:sudo, '-u', postgres_user, 'psql', '-tA', '-c', '"SELECT pg_is_in_recovery();"').strip == 't'
          rescue StandardError
            false
          end

          configured = data_dir && repmgr_conf && online && in_recovery
        end

        configured
      rescue StandardError
        false
      end

      def update_postgres_configs_on_standby(host, version)
        core_config = config.component_config(:core)
        component_config = core_config
        pg_config = component_config[:postgresql] || {}
        private_ip = config.replication_host_for(host)
        pg_config = substitute_private_ip(pg_config, private_ip)
        _ = pg_config

        upload_template(host, 'postgresql.conf.erb', "/etc/postgresql/#{version}/main/postgresql.conf",
                        binding, owner: 'postgres:postgres')
        upload_template(host, 'pg_hba.conf.erb', "/etc/postgresql/#{version}/main/pg_hba.conf",
                        binding, owner: 'postgres:postgres')

        ssh_executor.restart_postgres(host, version)
      end

      def enable_repmgrd_if_configured(host, repmgr_config)
        return if repmgr_config[:auto_failover] == false

        default_config = <<~CONF
          REPMGRD_ENABLED=yes
          REPMGRD_CONF="/etc/repmgr.conf"
          REPMGRD_OPTS=""
          REPMGRD_USER=postgres
          REPMGRD_BIN=/usr/bin/repmgrd
          REPMGRD_PIDFILE=/var/run/repmgrd.pid
        CONF

        ssh_executor.execute_on_host(host) do
          upload! StringIO.new(default_config), '/tmp/repmgrd-default'
          execute :sudo, 'mv', '/tmp/repmgrd-default', '/etc/default/repmgrd'
          execute :sudo, 'chown', 'root:root', '/etc/default/repmgrd'
          execute :sudo, 'chmod', '644', '/etc/default/repmgrd'
          execute :sudo, 'systemctl', 'enable', 'repmgrd'
          execute :sudo, 'systemctl', 'restart', 'repmgrd'
          execute :pgrep, '-x', 'repmgrd'
        end
      end

      def build_repmgr_setup_sql(repmgr_user, repmgr_db, repmgr_password)
        escaped_password = repmgr_password.gsub("'", "''")

        [
          'DO $$',
          'BEGIN',
          "  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '#{repmgr_user}') THEN",
          "    CREATE USER #{repmgr_user} WITH SUPERUSER REPLICATION PASSWORD '#{escaped_password}';",
          '  ELSE',
          "    ALTER USER #{repmgr_user} WITH SUPERUSER REPLICATION PASSWORD '#{escaped_password}';",
          '  END IF;',
          'END $$;',
          '',
          "SELECT 'CREATE DATABASE #{repmgr_db} OWNER #{repmgr_user}'",
          "WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '#{repmgr_db}')\\gexec",
          ''
        ].join("\n")
      end

      def build_replication_user_sql(replication_user, replication_password)
        escaped_password = replication_password.gsub("'", "''")

        [
          'DO $$',
          'BEGIN',
          "  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '#{replication_user}') THEN",
          "    CREATE USER #{replication_user} WITH REPLICATION LOGIN PASSWORD '#{escaped_password}';",
          '  ELSE',
          "    ALTER USER #{replication_user} WITH REPLICATION LOGIN PASSWORD '#{escaped_password}';",
          '  END IF;',
          'END $$;',
          ''
        ].join("\n")
      end
    end
  end
end
