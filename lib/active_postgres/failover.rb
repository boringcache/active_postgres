module ActivePostgres
  class Failover
    attr_reader :config, :ssh_executor

    def initialize(config)
      @config = config
      @ssh_executor = SSHExecutor.new(config)
    end

    def promote(host_or_node)
      # Determine target host
      target_host = resolve_host(host_or_node)

      raise Error, "Could not resolve host: #{host_or_node}" unless target_host

      raise Error, "Host is not a standby: #{target_host}" unless config.standby_hosts.include?(target_host)

      puts "==> Promoting #{target_host} to primary..."
      puts
      puts 'WARNING: This will promote the standby to primary.'
      puts 'Make sure to update your database.yml and restart your application.'
      puts
      print 'Continue? (y/N): '

      response = $stdin.gets.chomp
      unless response.downcase == 'y'
        puts 'Cancelled.'
        return
      end

      # Perform promotion
      if config.component_enabled?(:repmgr)
        promote_with_repmgr(target_host)
      else
        promote_manual(target_host)
      end

      puts "\n✓ Promotion complete!"
      puts "\nNext steps:"
      puts "  1. Update database.yml to point to new primary: #{target_host}"
      puts '  2. Restart your application'
      puts '  3. Rebuild old primary as new standby (if needed)'
    end

    private

    def resolve_host(host_or_node)
      # Check if it's already an IP/hostname
      return host_or_node if config.all_hosts.include?(host_or_node)

      # Try to find by node name
      config.standbys.each do |standby|
        return standby['host'] if standby['name'] == host_or_node
      end

      nil
    end

    def promote_with_repmgr(host)
      puts 'Promoting using repmgr...'
      postgres_user = config.postgres_user

      ssh_executor.execute_on_host(host) do
        # Stop old primary if still running (optional, skip if manual intervention needed)
        # execute :sudo, "-u", postgres_user, "repmgr", "standby", "switchover"

        # Promote this standby
        execute :sudo, '-u', postgres_user, 'repmgr', 'standby', 'promote'
      end
    end

    def promote_manual(host)
      puts 'Promoting manually (no repmgr)...'
      postgres_user = config.postgres_user
      version = config.version

      ssh_executor.execute_on_host(host) do
        # Promote standby to primary
        execute :sudo, '-u', postgres_user, 'pg_ctl', 'promote', '-D', "/var/lib/postgresql/#{version}/main"
      end
    end
  end
end
