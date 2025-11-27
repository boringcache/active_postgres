module ActivePostgres
  class HealthChecker
    attr_reader :config, :ssh_executor

    def initialize(config)
      @config = config
      @ssh_executor = SSHExecutor.new(config, quiet: true)
    end

    def show_status
      puts
      puts "PostgreSQL Cluster Status (#{config.environment})"
      puts '=' * 70
      puts

      # Collect all node data first
      nodes = collect_node_status

      # Print table
      print_status_table(nodes)

      # Print components
      print_components

      puts
    end

    def run_health_checks
      puts '==> Running health checks...'
      puts

      all_ok = true

      # Check primary
      print "Primary (#{config.primary_host})... "
      if check_postgres_running(config.primary_host)
        puts '✓'
      else
        puts '✗'
        all_ok = false
      end

      # Check standbys
      config.standby_hosts.each do |host|
        print "Standby (#{host})... "
        if check_postgres_running(host) && check_replication_status(host)
          puts '✓'
        else
          puts '✗'
          all_ok = false
        end
      end

      puts
      if all_ok
        puts '✓ All checks passed'
      else
        puts '✗ Some checks failed'
      end

      all_ok
    end

    def cluster_status
      status = {
        primary: {
          host: config.primary_host,
          status: check_postgres_running(config.primary_host) ? 'running' : 'down',
          connections: get_connection_count(config.primary_host),
          replication_lag: nil
        },
        standbys: []
      }

      config.standby_hosts.each do |host|
        standby_status = {
          host: host,
          status: check_postgres_running(host) ? 'streaming' : 'down',
          lag: get_replication_lag(host),
          sync_state: 'async'
        }
        status[:standbys] << standby_status
      end

      status
    end

    private

    def collect_node_status
      nodes = []

      # Primary
      primary_config = config.primary
      nodes << {
        role: 'primary',
        host: config.primary_host,
        private_ip: primary_config&.dig('private_ip') || '-',
        label: primary_config&.dig('label') || '-',
        status: check_postgres_running(config.primary_host) ? '✓ running' : '✗ down',
        connections: get_connection_count(config.primary_host),
        lag: '-'
      }

      # Standbys
      config.standby_hosts.each_with_index do |host, i|
        standby_config = config.standbys[i]
        running = check_postgres_running(host)

        nodes << {
          role: 'standby',
          host: host,
          private_ip: standby_config&.dig('private_ip') || '-',
          label: standby_config&.dig('label') || '-',
          status: running ? '✓ streaming' : '✗ down',
          connections: running ? get_connection_count(host) : 0,
          lag: running ? get_replication_lag(host) : '-'
        }
      end

      nodes
    end

    def print_status_table(nodes)
      cols = calculate_column_widths(nodes)
      print_table_header(cols)
      nodes.each { |node| print_table_row(node, cols) }
    end

    def calculate_column_widths(nodes)
      {
        role: [4, nodes.map { |n| n[:role].length }.max].max,
        host: [4, nodes.map { |n| n[:host].length }.max].max,
        private_ip: [10, nodes.map { |n| n[:private_ip].to_s.length }.max].max,
        label: [5, nodes.map { |n| n[:label].to_s.length }.max].max,
        status: [6, nodes.map { |n| n[:status].length }.max].max,
        conn: 5,
        lag: [3, nodes.map { |n| n[:lag].to_s.length }.max].max
      }
    end

    def print_table_header(cols)
      fmt = "%-#{cols[:role]}s  %-#{cols[:host]}s  %-#{cols[:private_ip]}s  " \
            "%-#{cols[:label]}s  %-#{cols[:status]}s  %#{cols[:conn]}s  %#{cols[:lag]}s"
      header = format(fmt, 'Role', 'Host', 'Private IP', 'Label', 'Status', 'Conn', 'Lag')
      puts header
      puts '-' * header.length
    end

    def print_table_row(node, cols)
      fmt = "%-#{cols[:role]}s  %-#{cols[:host]}s  %-#{cols[:private_ip]}s  " \
            "%-#{cols[:label]}s  %-#{cols[:status]}s  %#{cols[:conn]}d  %#{cols[:lag]}s"
      puts format(fmt, node[:role], node[:host], node[:private_ip], node[:label],
                  node[:status], node[:connections], node[:lag])
    end

    def print_components
      enabled = []
      enabled << 'repmgr' if config.component_enabled?(:repmgr)
      enabled << 'pgbouncer' if config.component_enabled?(:pgbouncer)
      enabled << 'pgbackrest' if config.component_enabled?(:pgbackrest)
      enabled << 'monitoring' if config.component_enabled?(:monitoring)
      enabled << 'ssl' if config.component_enabled?(:ssl)

      return if enabled.empty?

      puts
      puts "Components: #{enabled.join(', ')}"
    end

    def check_host_status(host, is_primary:)
      running = check_postgres_running(host)

      if running
        puts '  Status: Running'

        connections = get_connection_count(host)
        puts "  Connections: #{connections}"

        unless is_primary
          lag = get_replication_lag(host)
          puts "  Replication lag: #{lag}"
        end
      else
        puts '  Status: Down'
      end
    end

    def check_postgres_running(host)
      ssh_executor.postgres_running?(host)
    rescue StandardError
      false
    end

    def check_replication_status(host)
      result = ssh_executor.run_sql(host, 'SELECT pg_is_in_recovery();')
      result.include?('t')
    rescue StandardError
      false
    end

    def get_connection_count(host)
      result = ssh_executor.run_sql(host, 'SELECT count(*) FROM pg_stat_activity;')
      result.match(/\d+/)[0].to_i
    rescue StandardError
      0
    end

    def get_replication_lag(host)
      # Get lag from primary's perspective (more accurate)
      standby_ip = config.replication_host_for(host)
      lag_bytes = get_lag_from_primary(standby_ip)

      return format_lag(lag_bytes) if lag_bytes

      # Fallback: query standby directly
      result = ssh_executor.run_sql(host, 'SELECT pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn());')
      lag = result.match(/-?\d+/)[0].to_i.abs
      format_lag(lag)
    rescue StandardError
      'unknown'
    end

    def get_lag_from_primary(standby_ip)
      sql = 'SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)::bigint as lag ' \
            "FROM pg_stat_replication WHERE client_addr = '#{standby_ip}';"
      result = ssh_executor.run_sql(config.primary_host, sql)
      result.match(/-?\d+/)[0].to_i.abs
    rescue StandardError
      nil
    end

    def format_lag(bytes)
      return '0 (synced)' if bytes.zero?
      return "#{bytes} B" if bytes < 1024

      kb = bytes / 1024.0
      return "#{kb.round(1)} KB" if kb < 1024

      mb = kb / 1024.0
      "#{mb.round(1)} MB"
    end
  end
end
