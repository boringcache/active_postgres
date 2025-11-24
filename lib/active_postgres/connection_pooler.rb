module ActivePostgres
  # Production-ready connection pooling configuration for PgBouncer
  class ConnectionPooler
    attr_reader :config, :ssh_executor, :logger

    def initialize(config, ssh_executor, logger = Logger.new)
      @config = config
      @ssh_executor = ssh_executor
      @logger = logger
    end

    def setup_on_host(host)
      @logger.info "Configuring optimized connection pooling on #{host}..."

      # Analyze PostgreSQL configuration to determine optimal pool settings
      pg_settings = get_postgresql_settings(host)
      pool_config = calculate_pool_settings(pg_settings)

      # Install PgBouncer
      install_pgbouncer(host)

      # Deploy optimized configuration
      deploy_pgbouncer_config(host, pool_config)

      # Setup authentication
      setup_authentication(host)

      # Enable and start PgBouncer
      enable_pgbouncer(host)

      # Verify the setup
      verify_pgbouncer(host)
    end

    # Calculate optimal pool settings based on PostgreSQL max_connections
    # This is a simpler method used by the PgBouncer component for template integration
    def self.calculate_optimal_pool_sizes(max_connections)
      {
        default_pool_size: calculate_default_pool_size_static(max_connections),
        min_pool_size: 5,
        reserve_pool_size: 5,
        max_client_conn: max_connections * 10,
        max_db_connections: [max_connections - 10, 10].max,
        max_user_connections: [max_connections - 10, 10].max
      }
    end

    def self.calculate_default_pool_size_static(max_connections)
      # Formula: Reserve 80% of PostgreSQL connections for the pool
      # Split among expected number of databases/users
      pool_per_db = (max_connections * 0.8 / 4).to_i # Assume 4 databases

      # Reasonable bounds: 20-100 per pool
      pool_per_db.clamp(20, 100)
    end

    private

    def get_postgresql_settings(host)
      settings = {}
      postgres_user = config.postgres_user

      @ssh_executor.execute_on_host(host) do
        # Get max_connections from PostgreSQL
        max_conn = capture(:sudo, '-u', postgres_user, 'psql', '-t', '-c',
                           "'SHOW max_connections;'").strip.to_i
        settings[:max_connections] = max_conn

        # Get default pool mode preference
        settings[:default_pool_mode] = 'transaction' # Best for web apps

        # Get work_mem
        work_mem = capture(:sudo, '-u', postgres_user, 'psql', '-t', '-c',
                           "'SHOW work_mem;'").strip
        settings[:work_mem] = work_mem
      end

      settings
    end

    def calculate_pool_settings(pg_settings)
      max_connections = pg_settings[:max_connections]
      postgres_user = config.postgres_user
      pgbouncer_user = config.pgbouncer_user

      # Production-optimized PgBouncer settings
      {
        # Connection pool settings
        default_pool_size: calculate_default_pool_size(max_connections),
        min_pool_size: 5,
        reserve_pool_size: 5,
        reserve_pool_timeout: 5,
        max_client_conn: max_connections * 10, # Allow many client connections
        max_db_connections: max_connections - 10, # Leave some for superuser
        max_user_connections: max_connections - 10,

        # Performance settings
        pool_mode: pg_settings[:default_pool_mode],
        server_reset_query: 'DISCARD ALL',
        server_reset_query_always: 0,
        ignore_startup_parameters: 'extra_float_digits,options',
        disable_pqexec: 0,
        application_name_add_host: 1,
        conffile: '/etc/pgbouncer/pgbouncer.ini',
        pidfile: '/var/run/pgbouncer/pgbouncer.pid',

        # Connection behavior
        server_lifetime: 3600,
        server_idle_timeout: 600,
        server_connect_timeout: 15,
        server_login_retry: 15,
        query_timeout: 0,
        query_wait_timeout: 120,
        client_idle_timeout: 0,
        client_login_timeout: 60,
        idle_transaction_timeout: 0,

        # TLS/SSL settings
        server_tls_sslmode: 'prefer',
        server_tls_ca_file: '',
        server_tls_key_file: '',
        server_tls_cert_file: '',
        server_tls_protocols: 'all',
        server_tls_ciphers: 'fast',
        client_tls_sslmode: 'prefer',
        client_tls_ca_file: '',
        client_tls_key_file: '',
        client_tls_cert_file: '',
        client_tls_protocols: 'all',
        client_tls_ciphers: 'fast',
        client_tls_ecdhcurve: 'auto',
        client_tls_dheparams: 'auto',

        # Authentication
        auth_type: 'scram-sha-256',
        auth_file: '/etc/pgbouncer/userlist.txt',
        auth_hba_file: '',
        auth_query: 'SELECT usename, passwd FROM pg_shadow WHERE usename=$1',
        auth_user: pgbouncer_user,

        # Connection sanity checks
        server_check_delay: 30,
        server_check_query: 'select 1',
        server_fast_close: 0,
        server_round_robin: 0,

        # Logging
        log_connections: 1,
        log_disconnections: 1,
        log_pooler_errors: 1,
        log_stats: 1,
        stats_period: 60,
        verbose: 0,
        admin_users: "#{postgres_user},#{pgbouncer_user}",
        stats_users: "#{postgres_user},#{pgbouncer_user},stats_collector",

        # Network settings
        listen_addr: '*',
        listen_port: 6432,
        unix_socket_dir: '/var/run/pgbouncer',
        unix_socket_mode: '0777',
        unix_socket_group: '',

        # Limits
        tcp_keepalive: 1,
        tcp_keepcnt: 9,
        tcp_keepidle: 900,
        tcp_keepintvl: 75,
        tcp_user_timeout: 0,

        # DNS
        dns_max_ttl: 15,
        dns_nxdomain_ttl: 15,
        dns_zone_check_period: 0,
        resolv_conf: '',

        # Timeouts and limits
        sbuf_loopcnt: 5,
        max_packet_size: 2_147_483_647,
        listen_backlog: 128,
        so_reuseport: 0,
        tcp_defer_accept: 0,
        tcp_socket_buffer: 0,

        # Process management
        logfile: '/var/log/pgbouncer/pgbouncer.log',
        syslog: 0,
        syslog_ident: 'pgbouncer',
        syslog_facility: 'daemon',
        user: postgres_user,

        # Track prepared statements per database
        track_extra_parameters: 'IntervalStyle',

        # Connection limits per user/database
        databases: generate_database_config
      }
    end

    def calculate_default_pool_size(max_connections)
      # Formula: Reserve 80% of PostgreSQL connections for the pool
      # Split among expected number of databases/users
      pool_per_db = (max_connections * 0.8 / 4).to_i # Assume 4 databases

      # Reasonable bounds: 20-100 per pool
      pool_per_db.clamp(20, 100)
    end

    def generate_database_config
      databases = {}

      # Generate database connection strings
      if @config.primary_host
        databases['*'] = {
          host: @config.primary_host,
          port: 5432,
          auth_user: 'pgbouncer'
        }
      end

      # Add specific database configurations if needed
      app_databases = @config.component_config(:pgbouncer)[:databases] || []
      app_databases.each do |db_config|
        databases[db_config[:name]] = {
          host: db_config[:host] || @config.primary_host,
          port: db_config[:port] || 5432,
          dbname: db_config[:dbname] || db_config[:name],
          auth_user: db_config[:auth_user] || 'pgbouncer',
          pool_size: db_config[:pool_size] || 25,
          reserve_pool: db_config[:reserve_pool] || 5,
          pool_mode: db_config[:pool_mode] || 'transaction'
        }
      end

      databases
    end

    def install_pgbouncer(host)
      postgres_user = config.postgres_user

      @ssh_executor.execute_on_host(host) do
        # Install PgBouncer package
        execute :sudo, 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'install',
                '-y', '-qq', 'pgbouncer'

        # Create required directories
        execute :sudo, 'mkdir', '-p', '/var/log/pgbouncer'
        execute :sudo, 'mkdir', '-p', '/var/run/pgbouncer'
        execute :sudo, 'chown', '-R', "#{postgres_user}:#{postgres_user}", '/var/log/pgbouncer'
        execute :sudo, 'chown', '-R', "#{postgres_user}:#{postgres_user}", '/var/run/pgbouncer'

        # Stop default PgBouncer if running
        begin
          execute :sudo, 'systemctl', 'stop', 'pgbouncer'
        rescue StandardError
          nil
        end
      end
    end

    def deploy_pgbouncer_config(host, pool_config)
      # Generate PgBouncer configuration
      ini_content = generate_pgbouncer_ini(pool_config)
      postgres_user = config.postgres_user

      @ssh_executor.execute_on_host(host) do
        # Upload configuration
        upload! StringIO.new(ini_content), '/tmp/pgbouncer.ini'
        execute :sudo, 'mv', '/tmp/pgbouncer.ini', '/etc/pgbouncer/pgbouncer.ini'
        execute :sudo, 'chown', "#{postgres_user}:#{postgres_user}", '/etc/pgbouncer/pgbouncer.ini'
        execute :sudo, 'chmod', '640', '/etc/pgbouncer/pgbouncer.ini'
      end
    end

    def generate_pgbouncer_ini(settings)
      ini = "[databases]\n"

      # Add database configurations
      settings[:databases].each do |db_name, db_config|
        if db_name == '*'
          # Wildcard database
          ini += "* = host=#{db_config[:host]} port=#{db_config[:port]}"
          ini += " auth_user=#{db_config[:auth_user]}" if db_config[:auth_user]
        else
          ini += "#{db_name} = "
          ini += "host=#{db_config[:host]} "
          ini += "port=#{db_config[:port]} "
          ini += "dbname=#{db_config[:dbname]} " if db_config[:dbname]
          ini += "auth_user=#{db_config[:auth_user]} " if db_config[:auth_user]
          ini += "pool_size=#{db_config[:pool_size]} " if db_config[:pool_size]
          ini += "reserve_pool=#{db_config[:reserve_pool]} " if db_config[:reserve_pool]
          ini += "pool_mode=#{db_config[:pool_mode]} " if db_config[:pool_mode]
        end
        ini += "\n"
      end

      ini += "\n[pgbouncer]\n"

      # Add PgBouncer settings
      settings.each do |key, value|
        next if key == :databases # Already handled above

        if value.is_a?(String) && !value.empty?
          ini += "#{key} = #{value}\n"
        elsif value.is_a?(Integer) || value.is_a?(Float)
          ini += "#{key} = #{value}\n"
        end
      end

      ini
    end

    def setup_authentication(host)
      postgres_user = config.postgres_user
      pgbouncer_user = config.pgbouncer_user

      @ssh_executor.execute_on_host(host) do
        # Generate userlist.txt from PostgreSQL users
        userlist = capture(:sudo, '-u', postgres_user, 'psql', '-t', '-c',
                           "'SELECT concat('\"', usename, '\" \"', passwd, '\"') " \
                           "FROM pg_shadow WHERE passwd IS NOT NULL;'").strip

        # Add pgbouncer user if not exists
        unless userlist.include?(pgbouncer_user)
          # Create pgbouncer user in PostgreSQL
          pgbouncer_pass = SecureRandom.hex(16)
          execute :sudo, '-u', postgres_user, 'psql', '-c',
                  "'CREATE USER #{pgbouncer_user} WITH PASSWORD '#{pgbouncer_pass}';"
          execute :sudo, '-u', postgres_user, 'psql', '-c',
                  "'GRANT CONNECT ON DATABASE postgres TO #{pgbouncer_user};'"

          # Get the encrypted password
          encrypted = capture(:sudo, '-u', postgres_user, 'psql', '-t', '-c',
                              "'SELECT passwd FROM pg_shadow WHERE usename='#{pgbouncer_user}';'").strip
          userlist += "\n\"#{pgbouncer_user}\" \"#{encrypted}\""
        end

        # Write userlist.txt
        upload! StringIO.new(userlist), '/tmp/userlist.txt'
        execute :sudo, 'mv', '/tmp/userlist.txt', '/etc/pgbouncer/userlist.txt'
        execute :sudo, 'chown', "#{postgres_user}:#{postgres_user}", '/etc/pgbouncer/userlist.txt'
        execute :sudo, 'chmod', '640', '/etc/pgbouncer/userlist.txt'
      end
    end

    def enable_pgbouncer(host)
      @ssh_executor.execute_on_host(host) do
        # Create systemd override for running as postgres user
        systemd_override = <<~CONF
          [Service]
          User=postgres
          Group=postgres
          RuntimeDirectory=pgbouncer
          RuntimeDirectoryMode=0755

          # Resource limits
          LimitNOFILE=65536
          LimitNPROC=32768

          # Restart policy
          Restart=always
          RestartSec=10
        CONF

        upload! StringIO.new(systemd_override), '/tmp/pgbouncer_override.conf'
        execute :sudo, 'mkdir', '-p', '/etc/systemd/system/pgbouncer.service.d/'
        execute :sudo, 'mv', '/tmp/pgbouncer_override.conf',
                '/etc/systemd/system/pgbouncer.service.d/override.conf'

        # Reload systemd and start PgBouncer
        execute :sudo, 'systemctl', 'daemon-reload'
        execute :sudo, 'systemctl', 'enable', 'pgbouncer'
        execute :sudo, 'systemctl', 'restart', 'pgbouncer'
      end
    end

    def verify_pgbouncer(host)
      postgres_user = config.postgres_user
      pgbouncer_user = config.pgbouncer_user

      @ssh_executor.execute_on_host(host) do
        # Check if PgBouncer is running
        raise "PgBouncer is not running on #{host}" unless test('systemctl is-active pgbouncer')

        # Test connection through PgBouncer
        test_conn = test('env', 'PGPASSWORD=test', 'psql', '-h', 'localhost', '-p', '6432',
                         '-U', postgres_user, '-d', 'postgres', '-c', 'SELECT 1', '2>/dev/null')

        if test_conn
          @logger.success "✓ PgBouncer is working correctly on #{host}"
        else
          @logger.warn "⚠ PgBouncer is running but connection test failed on #{host}"
        end

        # Show PgBouncer stats
        stats = begin
          capture(:sudo, '-u', postgres_user, 'psql', '-h', 'localhost', '-p', '6432',
                  '-U', pgbouncer_user, 'pgbouncer', '-c', 'SHOW STATS', '2>/dev/null')
        rescue StandardError
          nil
        end

        if stats
          @logger.info 'PgBouncer statistics:'
          @logger.info stats
        end
      end
    end
  end
end
