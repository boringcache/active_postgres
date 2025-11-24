module ActivePostgres
  class HealthChecker
    attr_reader :config, :ssh_executor

    def initialize(config)
      @config = config
      @ssh_executor = SSHExecutor.new(config)
    end

    def show_status
      puts '==> PostgreSQL Cluster Status'
      puts "Environment: #{config.environment}"
      puts

      # Check primary
      puts "Primary: #{config.primary_host}"
      check_host_status(config.primary_host, is_primary: true)

      # Check standbys
      return unless config.standby_hosts.any?

      puts "\nStandbys:"
      config.standby_hosts.each do |host|
        puts "  #{host}"
        check_host_status(host, is_primary: false)
      end
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
      # Check if standby is replicating

      result = ssh_executor.run_sql(host, 'SELECT pg_is_in_recovery();')
      result.include?('t') # Should be true for standby
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
      result = ssh_executor.run_sql(host, 'SELECT pg_last_wal_receive_lsn() - pg_last_wal_replay_lsn() AS lag;')
      lag = result.match(/\d+/)[0].to_i
      "#{lag} bytes"
    rescue StandardError
      'unknown'
    end
  end
end
