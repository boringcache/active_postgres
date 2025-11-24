module ActivePostgres
  class Validator
    attr_reader :config, :ssh_executor, :errors, :warnings

    def initialize(config, ssh_executor)
      @config = config
      @ssh_executor = ssh_executor
      @errors = []
      @warnings = []
    end

    # Run all validation checks before installation
    def validate_all
      puts 'Running pre-flight validation checks...'

      validate_configuration
      validate_ssh_connectivity
      validate_network_connectivity
      validate_system_requirements

      if errors.any?
        puts "\n❌ Validation failed with #{errors.count} error(s):"
        errors.each { |error| puts "  - #{error}" }
        return false
      end

      if warnings.any?
        puts "\n⚠️  Found #{warnings.count} warning(s):"
        warnings.each { |warning| puts "  - #{warning}" }
      end

      puts "✅ All validation checks passed!\n"
      true
    end

    private

    def validate_configuration
      puts '  Checking configuration...'

      # Validate primary host
      errors << 'Primary host not configured' unless config.primary_host

      # Validate PostgreSQL version
      errors << "PostgreSQL version must be 12 or higher (got: #{config.version})" unless config.version && config.version >= 12

      # Validate repmgr setup
      if config.component_enabled?(:repmgr)
        errors << 'repmgr enabled but no standby hosts configured' unless config.standby_hosts&.any?

        replication_host = config.primary_replication_host
        if replication_host == config.primary_host
          warnings << "Primary is using '#{config.primary_host}' for replication traffic. Set private_ip for isolated networks."
        end

        config.standby_hosts.each do |host|
          standby_replication_host = config.replication_host_for(host)
          next unless standby_replication_host == host

          warnings << "Standby #{host} is using its SSH host for replication. Provide private_ip if it differs."
        end
      end

      # Validate SSL configuration
      return unless config.component_enabled?(:ssl)

      ssl_config = config.component_config(:ssl)
      return unless ssl_config['certificate_mode'] == 'custom'

      warnings << 'Custom SSL certificates configured - ensure they are available'
    end

    def validate_ssh_connectivity
      puts '  Checking SSH connectivity...'

      all_hosts = [config.primary_host] + config.standby_hosts

      all_hosts.each do |host|
        ssh_executor.execute_on_host(host) do
          test(:echo, 'SSH connection test')
        end
      rescue StandardError => e
        errors << "Cannot connect to #{host} via SSH: #{e.message}"
      end
    end

    def validate_network_connectivity
      puts '  Checking network connectivity...'

      return unless config.component_enabled?(:repmgr)

      primary_replication_host = config.primary_replication_host
      return unless primary_replication_host

      # Capture errors and warnings before entering SSH block
      validator_errors = errors
      validator_warnings = warnings

      # Check if standbys can reach primary via the preferred replication network
      config.standby_hosts.each do |host|
        ssh_executor.execute_on_host(host) do
          can_ping = test(:ping, '-c', '1', '-W', '2', primary_replication_host)
          validator_errors << "Standby #{host} cannot reach the primary over #{primary_replication_host}" unless can_ping
        end
      rescue StandardError => e
        validator_warnings << "Could not test private network connectivity from #{host}: #{e.message}"
      end
    end

    def validate_system_requirements
      puts '  Checking system requirements...'

      all_hosts = [config.primary_host] + config.standby_hosts

      # Capture errors and warnings before entering SSH block
      validator_errors = errors
      validator_warnings = warnings

      all_hosts.each do |host|
        ssh_executor.execute_on_host(host) do
          # Check if running Debian/Ubuntu
          unless test('[ -f /etc/debian_version ]')
            validator_errors << "#{host} is not running Debian/Ubuntu"
            next
          end

          # Check available disk space (require at least 10GB)
          # Check /var or root filesystem (since /var/lib/postgresql may not exist yet)
          disk_space_output = capture(:df, '-BG', '/var', '|', :tail, '-1', '|', :awk, "'{print $4}'")
          disk_space = disk_space_output.gsub('G', '').to_i
          validator_warnings << "#{host} has less than 10GB free disk space (#{disk_space}GB available)" if disk_space < 10

          # Check if postgres user already exists
          if test(:id, 'postgres')
            validator_warnings << "#{host} already has a 'postgres' user - this is expected if PostgreSQL was previously installed"
          end
        end
      rescue StandardError => e
        validator_warnings << "Could not check system requirements on #{host}: #{e.message}"
      end
    end
  end
end
