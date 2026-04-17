def format_lag_status(lag)
  if lag < 10
    "      Lag: ✅ #{lag}s (excellent)"
  elsif lag < 60
    "      Lag: ⚠️ #{lag}s (acceptable)"
  else
    "      Lag: ❌ #{lag}s (high)"
  end
end

namespace :postgres do
  desc 'Setup PostgreSQL HA cluster (use CLEAN=true for fresh install)'
  task setup: :environment do
    require 'active_postgres'

    # Run purge first if CLEAN flag is set
    if ENV['CLEAN'] == 'true'
      puts "\n🧹 CLEAN flag detected - purging existing installation first...\n"
      Rake::Task['postgres:purge'].invoke
      puts "\n✅ Purge complete, proceeding with fresh setup...\n"
      sleep 2 # Brief pause for user to see purge completion
    end

    config = ActivePostgres::Configuration.load
    installer = ActivePostgres::Installer.new(config)
    installer.setup
  end

  desc 'Destroy PostgreSQL cluster and remove all data (WARNING: destructive)'
  task purge: :environment do
    require 'active_postgres'

    config = ActivePostgres::Configuration.load
    ssh_executor = ActivePostgres::SSHExecutor.new(config)

    puts "\n#{'=' * 80}"
    puts '⚠️  PostgreSQL Cluster Destruction'
    puts "#{'=' * 80}\n"

    # 1. Run validation
    puts '1. Running pre-flight validation'
    validator = ActivePostgres::Validator.new(config, ssh_executor)
    validation_result = validator.validate_all

    puts "\n⚠️  Validation found errors, but continuing with purge..." unless validation_result

    # 2. Show targets
    puts "\n2. Destruction targets"
    puts "Primary: #{config.primary_host}"
    if config.standby_hosts.any?
      puts "Standbys: #{config.standby_hosts.join(', ')}"
    else
      puts 'Standbys: None'
    end

    # 3. Show what will be destroyed
    puts "\n⚠️  This will PERMANENTLY DELETE:"
    puts "    • All PostgreSQL installations (version #{config.version} and others)"
    puts '    • All databases and data in /var/lib/postgresql'
    puts '    • All configuration in /etc/postgresql'
    puts '    • PgBouncer installation and configuration' if config.component_enabled?(:pgbouncer)
    puts '    • Repmgr installation and configuration' if config.component_enabled?(:repmgr)
    puts '    • Monitoring (prometheus-postgres-exporter)' if config.component_enabled?(:monitoring)
    puts '    • SSL certificates and keys' if config.component_enabled?(:ssl)
    puts '    • All log files'
    puts '    • postgres system user and group'

    # 4. Interactive confirmation
    print "\n🚨 This action CANNOT be undone. Do you want to proceed? (yes/no): "
    confirmation = $stdin.gets.chomp.downcase

    unless confirmation == 'yes'
      puts "\n❌ Purge cancelled"
      exit 0
    end

    # 5. Execute purge
    puts "\n🗑️  Purging PostgreSQL cluster..."

    [config.primary_host, *config.standby_hosts].compact.each do |host|
      puts "\n📦 Purging #{host}..."

      ssh_executor.execute_on_host(host) do
        # Stop all services
        %w[postgresql pgbouncer repmgr prometheus-postgres-exporter].each do |service|
          begin
            execute :sudo, 'systemctl', 'stop', service
          rescue StandardError
            nil
          end
          begin
            execute :sudo, 'systemctl', 'disable', service
          rescue StandardError
            nil
          end
        end

        # Remove packages
        begin
          execute :sudo, 'DEBIAN_FRONTEND=noninteractive', 'apt-get',
                  '-o', 'DPkg::Lock::Timeout=300', 'remove', '--purge', '-y',
                  'postgresql*', 'pgbouncer', 'repmgr', 'prometheus-postgres-exporter'
        rescue StandardError
          nil
        end
        begin
          execute :sudo, 'apt-get', '-o', 'DPkg::Lock::Timeout=300', 'autoremove', '-y'
        rescue StandardError
          nil
        end

        # Remove data and config directories
        %w[
          /var/lib/postgresql
          /etc/postgresql
          /etc/pgbouncer
          /var/log/postgresql
          /var/log/pgbouncer
          /var/run/postgresql
        ].each do |dir|
          execute :sudo, 'rm', '-rf', dir
        end

        # Remove postgres system user and group
        begin
          execute :sudo, 'userdel', '-r', 'postgres'
        rescue StandardError
          nil
        end
        begin
          execute :sudo, 'groupdel', 'postgres'
        rescue StandardError
          nil
        end

        puts "  ✓ Purged PostgreSQL from #{host}"
      end
    end

    puts "\n#{'=' * 80}"
    puts '✅ Cluster purged successfully'
    puts "#{'=' * 80}\n"
  end

  desc 'Check cluster status'
  task status: :environment do
    require 'active_postgres'

    config = ActivePostgres::Configuration.load
    health_checker = ActivePostgres::HealthChecker.new(config)
    health_checker.show_status
  end

  desc 'Show control tower overview'
  task overview: :environment do
    require 'active_postgres'

    config = ActivePostgres::Configuration.load
    overview = ActivePostgres::Overview.new(config)
    overview.show
  end

  desc 'Visualize cluster nodes and topology'
  task nodes: :environment do
    require 'active_postgres'

    config = ActivePostgres::Configuration.load
    ssh_executor = ActivePostgres::SSHExecutor.new(config, quiet: true)

    puts "\n#{'=' * 80}"
    puts 'PostgreSQL HA Cluster Topology'
    puts "#{'=' * 80}\n"

    # Primary node
    puts '📍 PRIMARY'
    puts "   Host: #{config.primary_host}"
    puts "   Private IP: #{config.primary&.dig('private_ip') || 'N/A'}"
    puts "   Label: #{config.primary&.dig('label') || 'N/A'}"
    puts "   Port: #{config.component_enabled?(:pgbouncer) ? '6432 (PgBouncer)' : '5432 (Direct)'}"

    # Check if running
    begin
      ssh_executor.execute_on_host(config.primary_host) do
        status = begin
          capture(:pg_lsclusters, '-h').split("\n").first&.split&.[](3)
        rescue StandardError
          'unknown'
        end
        if status =~ /online/
          puts '   Status: ✅ Running'
        else
          puts '   Status: ❌ Offline'
        end
      end
    rescue StandardError
      puts '   Status: ⚠️ Unknown (cannot connect)'
    end

    # Standby nodes
    if config.standby_hosts&.any?
      puts "\n📍 STANDBYS (#{config.standby_hosts.size})"
      config.standby_hosts.each_with_index do |host, i|
        standby_config = config.standbys[i]
        puts "\n   #{i + 1}. #{host}"
        puts "      Private IP: #{standby_config&.dig('private_ip') || 'N/A'}"
        puts "      Label: #{standby_config&.dig('label') || 'N/A'}"
        puts '      Port: 5432'

        begin
          ssh_executor.execute_on_host(host) do
            # Check if PostgreSQL is online
            pg_status = begin
              capture(:pg_lsclusters, '-h').split("\n").first&.split&.[](3)
            rescue StandardError
              'unknown'
            end

            unless pg_status =~ /online/
              puts '      Status: ❌ Offline'
              next
            end

            # Check if in recovery mode (standby)
            in_recovery = begin
              result = capture(:sudo, '-u', 'postgres', 'psql', '-tA', '-c', '"SELECT pg_is_in_recovery();"')
              result.strip == 't'
            rescue StandardError
              false
            end

            if in_recovery
              # Check WAL byte lag
              lag_bytes = begin
                capture(:sudo, '-u', 'postgres', 'psql', '-tA', '-c',
                        '"SELECT pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn());"').strip.to_i.abs
              rescue StandardError
                nil
              end

              # Check time lag
              lag_time = begin
                capture(:sudo, '-u', 'postgres', 'psql', '-tA', '-c',
                        '"SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))::int;"').strip.to_i
              rescue StandardError
                nil
              end

              lag_str = lag_bytes&.zero? ? 'synced' : "#{lag_bytes} bytes behind"
              time_str = lag_time ? "(last tx #{lag_time}s ago)" : ''
              puts "      Status: ✅ Replicating - #{lag_str} #{time_str}".rstrip
            else
              puts '      Status: ⚠️  Running but not in recovery mode'
            end
          end
        rescue StandardError => e
          puts "      Status: ⚠️  Unknown (#{e.message})"
        end
      end
    else
      puts "\n📍 STANDBYS"
      puts '   None configured (primary-only setup)'
    end

    # Components
    puts "\n📦 ENABLED COMPONENTS"
    components = []
    components << '✅ PgBouncer (connection pooling)' if config.component_enabled?(:pgbouncer)
    components << '✅ Repmgr (automatic failover)' if config.component_enabled?(:repmgr)
    components << '✅ PgBackrest (backups)' if config.component_enabled?(:pgbackrest)
    components << '✅ Monitoring (prometheus-postgres-exporter)' if config.component_enabled?(:monitoring)
    components << '✅ SSL/TLS (encrypted connections)' if config.component_enabled?(:ssl)
    components << '✅ Performance Tuning (auto-optimized)' if config.component_enabled?(:performance_tuning)

    if components.any?
      components.each { |c| puts "   #{c}" }
    else
      puts '   None (minimal setup)'
    end

    puts "\n#{'=' * 80}\n"
  end

  desc 'Show help for PostgreSQL rake tasks'
  task help: :environment do
    puts "\nPostgreSQL Rake Tasks"
    puts '=' * 70
    puts "\nTip: set RAILS_ENV=production for production targets"

    puts "\nSetup & Maintenance"
    puts "  rake postgres:setup                  # Deploy HA cluster (CLEAN=true for fresh install)"
    puts "  rake postgres:purge                  # Destroy cluster (DESTRUCTIVE)"
    puts "  rake postgres:setup:core             # PostgreSQL config (postgresql.conf, pg_hba.conf)"
    puts "  rake postgres:setup:repmgr           # HA + failover (repmgr)"
    puts "  rake postgres:setup:pgbouncer        # PgBouncer pooling"
    puts "  rake postgres:setup:pgbackrest       # Backups (pgBackRest)"
    puts "  rake postgres:setup:monitoring       # postgres_exporter"
    puts "  rake postgres:setup:ssl              # SSL certs"

    puts "\nStatus & Health"
    puts "  rake postgres:status                 # Cluster status (SSH by default)"
    puts "  rake postgres:overview               # Control tower overview"
    puts "  rake postgres:nodes                  # Topology view"
    puts "  rake postgres:verify                 # Comprehensive checklist"
    puts "  ACTIVE_POSTGRES_STATUS_MODE=ssh|direct rake postgres:status"

    puts "\nBackups"
    puts "  rake postgres:backup:full            # Full backup"
    puts "  rake postgres:backup:incremental     # Incremental backup"
    puts "  rake postgres:backup:list            # List backups"
    puts "  rake postgres:backup:restore[ID]     # Restore backup set"
    puts "  rake postgres:backup:restore_at[\"YYYY-MM-DD HH:MM:SS\",promote]  # PITR"

    puts "\nMigrations"
    puts "  rake postgres:migrate                # Run migrations on primary only"

    puts "\nPgBouncer"
    puts "  rake postgres:pgbouncer:update_userlist[users]  # Update userlist"
    puts "  rake postgres:pgbouncer:stats        # Service status + stats"

    puts "\nTests"
    puts "  rake postgres:test:replication[rows] # Replication stress test"
    puts "  rake postgres:test:pgbouncer[connections]  # PgBouncer load test"

    puts
  end

  desc 'Promote standby to primary'
  task :promote, [:host] => :environment do |_t, args|
    require 'active_postgres'

    unless args[:host]
      puts 'Usage: rake postgres:promote[standby-host]'
      exit 1
    end

    config = ActivePostgres::Configuration.load
    failover = ActivePostgres::Failover.new(config)
    failover.promote(args[:host])
  end

  desc 'Run migrations on primary only'
  task migrate: :environment do
    # Ensure we're connected to primary
    ActiveRecord::Base.connected_to(role: :writing) do
      Rake::Task['db:migrate'].invoke
    end
  end

  namespace :backup do
    desc 'Create full backup'
    task full: :environment do
      require 'active_postgres'

      config = ActivePostgres::Configuration.load
      installer = ActivePostgres::Installer.new(config)
      installer.run_backup('full')
    end

    desc 'Create incremental backup'
    task incremental: :environment do
      require 'active_postgres'

      config = ActivePostgres::Configuration.load
      installer = ActivePostgres::Installer.new(config)
      installer.run_backup('incremental')
    end

    desc 'Restore from backup'
    task :restore, [:backup_id] => :environment do |_t, args|
      require 'active_postgres'

      unless args[:backup_id]
        puts 'Usage: rake postgres:backup:restore[backup_id]'
        exit 1
      end

      config = ActivePostgres::Configuration.load
      installer = ActivePostgres::Installer.new(config)
      installer.run_restore(args[:backup_id])
    end

    desc 'Restore to a point in time (PITR)'
    task :restore_at, [:target_time, :target_action] => :environment do |_t, args|
      require 'active_postgres'

      unless args[:target_time]
        puts 'Usage: rake postgres:backup:restore_at["2026-01-29 01:15:00",promote]'
        exit 1
      end

      config = ActivePostgres::Configuration.load
      installer = ActivePostgres::Installer.new(config)
      installer.run_restore_at(args[:target_time], target_action: args[:target_action] || 'promote')
    end

    desc 'List available backups'
    task list: :environment do
      require 'active_postgres'

      config = ActivePostgres::Configuration.load
      installer = ActivePostgres::Installer.new(config)
      installer.list_backups
    end
  end

  namespace :setup do
    desc 'Setup only core PostgreSQL (updates postgresql.conf and pg_hba.conf)'
    task core: :environment do
      require 'active_postgres'

      config = ActivePostgres::Configuration.load
      installer = ActivePostgres::Installer.new(config)
      installer.setup_component('core')
    end

    desc 'Setup only SSL certificates'
    task ssl: :environment do
      require 'active_postgres'

      config = ActivePostgres::Configuration.load
      installer = ActivePostgres::Installer.new(config)
      installer.setup_component('ssl')
    end

    desc 'Setup only PgBouncer'
    task pgbouncer: :environment do
      require 'active_postgres'

      config = ActivePostgres::Configuration.load
      installer = ActivePostgres::Installer.new(config)
      installer.setup_component('pgbouncer')
    end

    desc 'Setup only monitoring'
    task monitoring: :environment do
      require 'active_postgres'

      config = ActivePostgres::Configuration.load
      installer = ActivePostgres::Installer.new(config)
      installer.setup_component('monitoring')
    end

    desc 'Setup only pgBackRest backups'
    task pgbackrest: :environment do
      require 'active_postgres'

      config = ActivePostgres::Configuration.load
      installer = ActivePostgres::Installer.new(config)
      installer.setup_component('pgbackrest')
    end

    desc 'Setup only repmgr'
    task repmgr: :environment do
      require 'active_postgres'

      config = ActivePostgres::Configuration.load
      installer = ActivePostgres::Installer.new(config)
      installer.setup_component('repmgr')
    end
  end

  namespace :pgbouncer do
    desc 'Update PgBouncer userlist with current database users'
    task :update_userlist, [:users] => :environment do |_t, args|
      require 'active_postgres'

      config = ActivePostgres::Configuration.load
      ssh_executor = ActivePostgres::SSHExecutor.new(config)
      host = config.primary_host

      # Get users to add (comma-separated or default to postgres + app user)
      users = if args[:users]
                args[:users].split(',').map(&:strip)
              else
                [config.postgres_user, config.app_user].compact.uniq
              end

      puts "Updating PgBouncer userlist on #{host}..."
      puts "  Users: #{users.join(', ')}"

      ssh_executor.execute_on_host(host) do
        postgres_user = config.postgres_user
        userlist_entries = []

        users.each do |user|
          sql = <<~SQL.strip
            SELECT concat('"', rolname, '" "', rolpassword, '"')
            FROM pg_authid
            WHERE rolname = '#{user}'
          SQL

          user_hash = ssh_executor.run_sql_on_backend(self, sql, postgres_user: postgres_user).to_s.strip

          if user_hash && !user_hash.empty?
            userlist_entries << user_hash
            puts "  ✓ Added #{user}"
          else
            warn "  ⚠ User #{user} not found in PostgreSQL"
          end
        rescue StandardError => e
          warn "  ✗ Error getting hash for #{user}: #{e.message}"
        end

        if userlist_entries.any?
          userlist_content = "#{userlist_entries.join("\n")}\n"
          # Upload to temp file first, then move to avoid stdin issues
          upload! StringIO.new(userlist_content), '/tmp/userlist.txt'
          execute :sudo, 'mv', '/tmp/userlist.txt', '/etc/pgbouncer/userlist.txt'
          execute :sudo, 'chmod', '640', '/etc/pgbouncer/userlist.txt'
          execute :sudo, 'chown', 'postgres:postgres', '/etc/pgbouncer/userlist.txt'
          execute :sudo, 'systemctl', 'reload', 'pgbouncer'
          puts "\n✅ Userlist updated with #{userlist_entries.size} user(s) and PgBouncer reloaded"
        else
          warn "\n⚠ No users added to userlist"
        end
      end
    end

    desc 'Show PgBouncer status and statistics'
    task stats: :environment do
      require 'active_postgres'

      config = ActivePostgres::Configuration.load
      ssh_executor = ActivePostgres::SSHExecutor.new(config)
      host = config.primary_host

      ssh_executor.execute_on_host(host) do
        puts "PgBouncer Status on #{host}:"
        execute :sudo, 'systemctl', 'status', 'pgbouncer', '--no-pager'
      end
    end
  end

  desc 'Verify cluster health and configuration (comprehensive checklist)'
  task verify: :environment do
    require 'active_postgres'

    config = ActivePostgres::Configuration.load
    ssh_executor = ActivePostgres::SSHExecutor.new(config)

    puts "\n#{'=' * 80}\n🔍 PostgreSQL HA Cluster Verification Checklist\n#{'=' * 80}"

    results = { passed: [], failed: [], warnings: [] }

    [config.primary_host, *config.standby_hosts].compact.each do |host|
      label = host == config.primary_host ? 'PRIMARY' : 'STANDBY'
      puts "\n📊 #{label}: #{host}\n#{'-' * 80}"

      ssh_executor.execute_on_host(host) do
        # 1. PostgreSQL Installation & Status
        puts "\n1️⃣  PostgreSQL Installation"
        begin
          version = capture(:sudo, '-u', 'postgres', 'psql', '--version').strip
          info "   Version: #{version}"
          cluster_status = begin
            capture(:pg_lsclusters, '-h').split("\n").first.split[3]
          rescue StandardError
            'down'
          end
          if cluster_status == 'online' || cluster_status.start_with?('online,')
            info '   Status: Running ✅'
            results[:passed] << "#{label}: PostgreSQL running"
          else
            warn '   Status: Stopped ❌'
            results[:failed] << "#{label}: PostgreSQL not running"
          end
        rescue StandardError => e
          warn "   ❌ PostgreSQL check failed: #{e.message}"
          results[:failed] << "#{label}: PostgreSQL check failed"
        end

        # 2. Performance Tuning
        puts "\n2️⃣  Performance Tuning"
        tuning_ok = true
        %w[shared_buffers effective_cache_size work_mem max_connections].each do |setting|
          val = begin
            capture(:sudo, '-u', 'postgres', 'psql', '-t', '-c', "'SHOW #{setting};'").strip
          rescue StandardError
            'N/A'
          end
          info "   #{setting.ljust(20)}: #{val}"
          tuning_ok = false if val == 'N/A'
        end
        if tuning_ok
          results[:passed] << "#{label}: Performance tuning applied"
        else
          results[:warnings] << "#{label}: Some performance settings missing"
        end

        # 3. SSL/TLS
        puts "\n3️⃣  SSL/TLS Encryption"
        ssl = begin
          capture(:sudo, '-u', 'postgres', 'psql', '-t', '-c', "'SHOW ssl;'").strip
        rescue StandardError
          'off'
        end
        if ssl == 'on'
          info '   SSL: Enabled ✅'
          cert_valid = test('[ -f /etc/postgresql/*/main/server.crt ]')
          key_valid = test('[ -f /etc/postgresql/*/main/server.key ]')
          if cert_valid && key_valid
            info '   Certificates: Present ✅'
            cert_issuer = begin
              capture(:sudo, 'openssl', 'x509', '-in', "/etc/postgresql/#{config.version}/main/server.crt",
                      '-noout', '-issuer', '2>/dev/null').strip
            rescue StandardError
              nil
            end
            if cert_issuer
              issuer_o = cert_issuer.match(/O\s*=\s*"?([^",\/]+)"?/)&.captures&.first
              issuer_cn = cert_issuer.match(/CN\s*=\s*([^,\/]+)/)&.captures&.first
              issuer_name = issuer_o || issuer_cn || cert_issuer.sub('issuer=', '')
              info "   Issuer: #{issuer_name.strip}"
            end
            results[:passed] << "#{label}: SSL enabled with certificates"
          else
            warn '   Certificates: Missing ⚠️'
            results[:warnings] << "#{label}: SSL enabled but certificates missing"
          end
        else
          warn '   SSL: Disabled'
          results[:warnings] << "#{label}: SSL not enabled"
        end

        # 4. Replication (standbys only)
        if label == 'STANDBY'
          puts "\n4️⃣  Replication"
          begin
            recovery = capture(:sudo, '-u', 'postgres', 'psql', '-t', '-c', "'SELECT pg_is_in_recovery();'").strip
            if recovery == 't'
              info '   Recovery mode: Yes ✅'

              # Check WAL receiver
              wal_status = capture(:sudo, '-u', 'postgres', 'psql', '-t', '-c', "'SELECT status FROM pg_stat_wal_receiver;'").strip
              if wal_status == 'streaming'
                info '   WAL receiver: Streaming ✅'
                results[:passed] << "#{label}: Replication streaming"
              else
                warn "   WAL receiver: #{wal_status} ⚠️"
                results[:warnings] << "#{label}: Replication not streaming"
              end

              # WAL byte lag (actual replication delay)
              byte_lag = capture(:sudo, '-u', 'postgres', 'psql', '-t', '-c',
                                 "'SELECT pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn());'").strip.to_i
              if byte_lag.zero?
                info '   WAL lag: 0 bytes (fully synced) ✅'
                results[:passed] << "#{label}: Replication fully synced"
              else
                info "   WAL lag: #{byte_lag} bytes"
                results[:passed] << "#{label}: Replication lag #{byte_lag} bytes"
              end

              # Time since last transaction (informational only)
              last_tx = capture(:sudo, '-u', 'postgres', 'psql', '-t', '-c',
                                "'SELECT EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))::int;'").strip.to_i
              info "   Last write: #{last_tx}s ago (primary idle time)"
            else
              warn '   Recovery mode: No ❌'
              results[:failed] << "#{label}: Not in recovery mode"
            end
          rescue StandardError => e
            warn "   ❌ Replication check failed: #{e.message}"
            results[:failed] << "#{label}: Replication check failed"
          end
        end

        # 5. Repmgr (if enabled)
        if config.component_enabled?(:repmgr)
          puts "\n5️⃣  Repmgr"
          begin
            # Check if node is registered in cluster
            cluster_show = capture(:sudo, '-u', 'postgres', 'repmgr', 'cluster', 'show', '2>/dev/null')
            node_registered = cluster_show.include?(host) || cluster_show.match?(/\|\s*(primary|standby)\s*\|/)

            if node_registered
              info '   Node registered: Yes ✅'
              results[:passed] << "#{label}: Repmgr node registered"

              # Check if repmgrd daemon is running (for automatic failover)
              if test('systemctl is-active repmgrd')
                info '   Auto-failover daemon: Running ✅'
              else
                warn '   Auto-failover daemon: Not running (manual failover only)'
              end
            else
              warn '   Node registered: No ⚠️'
              results[:warnings] << "#{label}: Repmgr node not registered"
            end
          rescue StandardError => e
            warn "   ❌ Repmgr check failed: #{e.message}"
            results[:failed] << "#{label}: Repmgr check failed"
          end
        end

        # 6. PgBouncer (primary only)
        if label == 'PRIMARY' && config.component_enabled?(:pgbouncer)
          puts "\n6️⃣  PgBouncer"
          if test('systemctl is-active pgbouncer')
            info '   Status: Running ✅'

            # Check userlist (need sudo for file access)
            if test(:sudo, 'test', '-s', '/etc/pgbouncer/userlist.txt')
              user_count = capture(:sudo, :wc, '-l', '/etc/pgbouncer/userlist.txt').split.first.to_i
              info "   Userlist: #{user_count} user(s) configured ✅"
              results[:passed] << "#{label}: PgBouncer running with #{user_count} user(s)"
            else
              warn '   Userlist: Empty ⚠️'
              results[:warnings] << "#{label}: PgBouncer userlist empty"
            end
          else
            warn '   Status: Not running ❌'
            results[:failed] << "#{label}: PgBouncer not running"
          end
        end

        # 7. Disk Space
        puts "\n7️⃣  Disk Space"
        df_output = capture(:df, '-h', '/var/lib/postgresql')
        df_lines = df_output.split("\n")
        if df_lines.size > 1
          usage = df_lines[1].split[4].to_i
          info "   PostgreSQL data: #{df_lines[1].split[4]} used"
          if usage > 90
            warn '   ⚠️  Disk usage critical (>90%)'
            results[:warnings] << "#{label}: Disk usage high (#{usage}%)"
          elsif usage > 80
            info '   ⚠️  Disk usage high (>80%)'
            results[:warnings] << "#{label}: Disk usage moderate (#{usage}%)"
          else
            results[:passed] << "#{label}: Disk space OK (#{usage}%)"
          end
        end

        # 8. Connectivity
        puts "\n8️⃣  Connectivity"
        if test(:sudo, '-u', 'postgres', 'psql', '-c', "'SELECT 1;'")
          info '   Database connection: OK ✅'
          results[:passed] << "#{label}: Database connectable"
        else
          warn '   Database connection: Failed ❌'
          results[:failed] << "#{label}: Cannot connect to database"
        end
      end
    end

    # Summary
    puts "\n#{'=' * 80}\n📋 Verification Summary\n#{'=' * 80}"
    puts "\n✅ Passed (#{results[:passed].size}):"
    results[:passed].each { |r| puts "   #{r}" }

    if results[:warnings].any?
      puts "\n⚠️  Warnings (#{results[:warnings].size}):"
      results[:warnings].each { |r| puts "   #{r}" }
    end

    if results[:failed].any?
      puts "\n❌ Failed (#{results[:failed].size}):"
      results[:failed].each { |r| puts "   #{r}" }
    end

    puts "\n#{'=' * 80}"
    if results[:failed].empty?
      puts '✅ Cluster verification complete - All critical checks passed!'
    else
      puts "⚠️  Cluster verification complete - #{results[:failed].size} critical issue(s) found"
      exit 1
    end
    puts "#{'=' * 80}\n"
  end

  namespace :test do
    desc 'Run replication stress test (creates temp DB, inserts rows, verifies replication, cleans up)'
    task :replication, [:rows] => :environment do |_t, args|
      require 'active_postgres'

      rows = (args[:rows] || 1000).to_i
      config = ActivePostgres::Configuration.load
      ssh_executor = ActivePostgres::SSHExecutor.new(config, quiet: true)

      puts "\n#{'=' * 60}"
      puts '🧪 Replication Stress Test'
      puts "#{'=' * 60}\n"

      test_db = 'active_postgres_stress_test'
      primary = config.primary_host
      standbys = config.standby_hosts

      begin
        # Create test database
        puts '1️⃣  Creating test database...'
        ssh_executor.execute_on_host(primary) do
          execute :sudo, '-u', 'postgres', 'psql', '-c', "\"DROP DATABASE IF EXISTS #{test_db};\""
          execute :sudo, '-u', 'postgres', 'psql', '-c', "\"CREATE DATABASE #{test_db};\""
          execute :sudo, '-u', 'postgres', 'psql', '-d', test_db, '-c',
                  '"CREATE TABLE test_inserts (id SERIAL PRIMARY KEY, data TEXT, created_at TIMESTAMP DEFAULT NOW());"'
        end
        puts '   ✓ Test database created'

        # Run insert stress test
        puts "\n2️⃣  Inserting #{rows} rows on primary..."
        start_time = Time.now
        ssh_executor.execute_on_host(primary) do
          execute :sudo, '-u', 'postgres', 'psql', '-d', test_db, '-c',
                  "\"INSERT INTO test_inserts (data) SELECT md5(random()::text) FROM generate_series(1, #{rows});\""
        end
        insert_time = (Time.now - start_time).round(2)
        puts "   ✓ Inserted #{rows} rows in #{insert_time}s (#{(rows / insert_time).round} rows/sec)"

        # Verify on primary
        puts "\n3️⃣  Verifying row count..."
        primary_count = 0
        ssh_executor.execute_on_host(primary) do
          result = capture(:sudo, '-u', 'postgres', 'psql', '-t', '-d', test_db, '-c', '"SELECT COUNT(*) FROM test_inserts;"')
          primary_count = result.strip.to_i
        end
        puts "   Primary: #{primary_count} rows"

        # Wait for replication
        sleep 1

        # Verify on standbys
        all_synced = true
        standbys.each do |standby|
          standby_count = 0
          ssh_executor.execute_on_host(standby) do
            result = capture(:sudo, '-u', 'postgres', 'psql', '-t', '-d', test_db, '-c', '"SELECT COUNT(*) FROM test_inserts;"')
            standby_count = result.strip.to_i
          end

          if standby_count == primary_count
            puts "   Standby #{standby}: #{standby_count} rows ✓"
          else
            puts "   Standby #{standby}: #{standby_count} rows ✗ (expected #{primary_count})"
            all_synced = false
          end
        end

        # Check replication lag
        puts "\n4️⃣  Replication lag after test..."
        ssh_executor.execute_on_host(primary) do
          result = capture(:sudo, '-u', 'postgres', 'psql', '-t', '-c',
                           '"SELECT client_addr, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) as lag_bytes FROM pg_stat_replication;"')
          result.strip.split("\n").each do |line|
            next if line.strip.empty?

            parts = line.split('|').map(&:strip)
            puts "   #{parts[0]}: #{parts[1]} bytes"
          end
        end

        puts "\n#{'=' * 60}"
        if all_synced
          puts '✅ Replication stress test PASSED!'
        else
          puts '❌ Replication stress test FAILED - not all standbys synced'
        end
        puts "#{'=' * 60}\n"
      ensure
        # Cleanup
        puts "\n5️⃣  Cleaning up test database..."
        ssh_executor.execute_on_host(primary) do
          execute :sudo, '-u', 'postgres', 'psql', '-c', "\"DROP DATABASE IF EXISTS #{test_db};\""
        end
        puts '   ✓ Test database removed'
      end
    end

    desc 'Test PgBouncer connection pooling'
    task :pgbouncer, [:connections] => :environment do |_t, args|
      require 'active_postgres'

      connections = (args[:connections] || 50).to_i
      config = ActivePostgres::Configuration.load
      ssh_executor = ActivePostgres::SSHExecutor.new(config, quiet: true)

      unless config.component_enabled?(:pgbouncer)
        puts '❌ PgBouncer is not enabled in config'
        exit 1
      end

      puts "\n#{'=' * 60}"
      puts '🧪 PgBouncer Connection Test'
      puts "#{'=' * 60}\n"

      primary = config.primary_host

      ssh_executor.execute_on_host(primary) do
        # Check PgBouncer status
        puts '1️⃣  PgBouncer service status:'
        status = capture(:systemctl, 'is-active', 'pgbouncer').strip
        puts "   Service: #{status == 'active' ? '✓ Running' : '✗ Not running'}"

        # Show config
        puts "\n2️⃣  PgBouncer configuration:"
        config_output = capture(:sudo, :grep, '-E', '(listen_port|pool_mode|max_client|default_pool)', '/etc/pgbouncer/pgbouncer.ini')
        config_output.split("\n").each { |line| puts "   #{line.strip}" }

        # Show users
        puts "\n3️⃣  Configured users:"
        users = capture(:sudo, :cut, "-d'\"'", '-f2', '/etc/pgbouncer/userlist.txt')
        users.split("\n").each { |user| puts "   - #{user.strip}" unless user.strip.empty? }

        # Test direct PostgreSQL (port 5432)
        puts "\n4️⃣  Direct PostgreSQL test (port 5432):"
        begin
          execute :sudo, '-u', 'postgres', 'psql', '-p', '5432', '-c', '"SELECT 1;"'
          puts '   ✓ Direct connection works'
        rescue StandardError
          puts '   ✗ Direct connection failed'
        end

        # Test PgBouncer (port 6432)
        puts "\n5️⃣  PgBouncer connection test (port 6432):"
        begin
          execute :sudo, '-u', 'postgres', 'psql', '-h', '127.0.0.1', '-p', '6432', '-d', 'postgres', '-c', '"SELECT 1;"'
          puts '   ✓ PgBouncer connection works'
        rescue StandardError => e
          puts "   ⚠️  PgBouncer connection test: #{e.message.split("\n").first}"
        end

        # Stress test - multiple concurrent connections
        puts "\n6️⃣  Connection stress test (#{connections} concurrent connections via PgBouncer):"
        begin
          # Use pgbench for stress testing
          if test('which pgbench')
            execute :sudo, '-u', 'postgres', 'pgbench', '-i', '-s', '1', '-p', '6432', '-h', '127.0.0.1', 'postgres', '2>/dev/null', '||', 'true'
            result = capture(:sudo, '-u', 'postgres', 'pgbench', '-c', connections.to_s, '-j', '4', '-t', '10',
                             '-p', '6432', '-h', '127.0.0.1', 'postgres', '2>&1')
            tps_match = result.match(/tps = ([\d.]+)/)
            if tps_match
              puts "   ✓ Stress test completed: #{tps_match[1]} TPS"
            else
              puts '   ✓ Stress test completed'
            end
          else
            puts '   ⚠️  pgbench not installed, skipping stress test'
          end
        rescue StandardError => e
          puts "   ⚠️  Stress test failed: #{e.message.split("\n").first}"
        end

        # Show pool stats
        puts "\n7️⃣  Pool statistics:"
        begin
          stats = capture(:sudo, '-u', 'postgres', 'psql', '-h', '127.0.0.1', '-p', '6432', '-d', 'pgbouncer',
                          '-c', '"SHOW POOLS;"', '2>/dev/null')
          stats.split("\n").each { |line| puts "   #{line}" }
        rescue StandardError
          puts '   ⚠️  Could not fetch pool stats'
        end

        puts "\n#{'=' * 60}"
        puts '✅ PgBouncer test complete'
        puts "#{'=' * 60}\n"
      end
    end
  end
end
