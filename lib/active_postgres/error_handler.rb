module ActivePostgres
  class ErrorHandler
    # Define common errors and their troubleshooting steps
    ERROR_GUIDES = {
      ssh_connection: {
        title: 'SSH Connection Failed',
        hints: [
          'Ensure SSH keys are properly configured for the target host',
          'Verify the host is reachable: ping <hostname>',
          'Check SSH config in ~/.ssh/config',
          'Try manual SSH connection: ssh <user>@<host>'
        ]
      },

      private_network_connectivity: {
        title: 'Private Network Connectivity Failed',
        hints: [
          'Ensure the private/VPC network (or WireGuard) is configured on all nodes',
          'Verify interfaces are up and have the expected IPs',
          'Check firewall/security-group rules for the replication subnet',
          'Test connectivity: ping <private_ip>',
          'Confirm routing tables/NAT rules allow node-to-node traffic'
        ]
      },

      postgresql_not_starting: {
        title: 'PostgreSQL Failed to Start',
        hints: [
          'Check PostgreSQL logs: sudo tail -100 /var/log/postgresql/postgresql-*-main.log',
          'Verify configuration: sudo -u postgres pg_lsclusters',
          'Check if port 5432 is already in use: sudo lsof -i :5432',
          'Verify data directory permissions: ls -la /var/lib/postgresql/*/main',
          'Check systemd status: sudo systemctl status postgresql'
        ]
      },

      repmgr_clone_failed: {
        title: 'Repmgr Standby Clone Failed',
        hints: [
          'Verify primary PostgreSQL is running and accessible',
          'Check pg_hba.conf allows replication from standby IP',
          'Test connection: psql -h <primary_ip> -U repmgr -d repmgr',
          'Ensure sufficient disk space on standby',
          'Check repmgr logs for detailed error messages',
          'Verify repmgr user has replication privileges'
        ]
      },

      repmgr_register_failed: {
        title: 'Repmgr Registration Failed',
        hints: [
          'Ensure primary is registered first: repmgr cluster show',
          'Verify standby can connect to primary PostgreSQL',
          'Check repmgr.conf conninfo is correct',
          'Ensure repmgr database and tables exist on primary',
          'Verify standby PostgreSQL is running before registration'
        ]
      },

      ssl_certificate_error: {
        title: 'SSL Certificate Error',
        hints: [
          'Check certificate file permissions (should be 600 for .key)',
          'Verify certificate paths in postgresql.conf',
          'Ensure certificate is valid: openssl x509 -in <cert> -text -noout',
          'Check certificate ownership: ls -la /etc/postgresql/*/main/server.*'
        ]
      },

      disk_space_error: {
        title: 'Insufficient Disk Space',
        hints: [
          'Check available disk space: df -h /var/lib/postgresql',
          'Clean up old PostgreSQL logs if needed',
          'Consider increasing volume size',
          'Check for large files: du -sh /var/lib/postgresql/* | sort -h'
        ]
      },

      authentication_failed: {
        title: 'PostgreSQL Authentication Failed',
        hints: [
          'Verify pg_hba.conf has correct authentication methods',
          "Check if user exists: sudo -u postgres psql -c '\\du'",
          'Ensure password is set correctly',
          'Reload PostgreSQL after pg_hba.conf changes: sudo systemctl reload postgresql',
          'Check PostgreSQL logs for authentication errors'
        ]
      }
    }.freeze

    class << self
      # Handle an error with context and helpful hints
      def handle(error, context: {}, error_type: nil)
        puts "\n#{'=' * 80}"
        puts '❌ ERROR OCCURRED'.center(80)
        puts '=' * 80

        puts "\nError: #{LogSanitizer.sanitize(error.message)}"
        puts "Type: #{error.class.name}"

        if context.any?
          puts "\nContext:"
          context.each do |key, value|
            puts "  #{key}: #{LogSanitizer.sanitize(value.to_s)}"
          end
        end

        if error.backtrace&.any?
          puts "\nBacktrace (last 5 lines):"
          error.backtrace.first(5).each do |line|
            puts "  #{LogSanitizer.sanitize(line)}"
          end
        end

        # Try to identify error type from message if not provided
        error_type ||= identify_error_type(error.message)

        if error_type && ERROR_GUIDES[error_type]
          show_troubleshooting_guide(error_type)
        else
          show_generic_troubleshooting
        end

        puts "\n#{'=' * 80}\n"
      end

      # Identify error type from error message
      def identify_error_type(message)
        case message.downcase
        when /ssh|connection refused|network unreachable/
          :ssh_connection
        when /private network|vpn|wireguard network/
          :private_network_connectivity
        when /postgresql.*not.*start|cluster.*not.*running/
          :postgresql_not_starting
        when /repmgr.*clone|data directory/
          :repmgr_clone_failed
        when /repmgr.*register|unable to connect to.*primary/
          :repmgr_register_failed
        when /ssl|certificate|tls/
          :ssl_certificate_error
        when /no space|disk full/
          :disk_space_error
        when /authentication|password|pg_hba/
          :authentication_failed
        end
      end

      # Show troubleshooting guide for a specific error type
      def show_troubleshooting_guide(error_type)
        guide = ERROR_GUIDES[error_type]
        return unless guide

        puts "\n#{'-' * 80}"
        puts "🔧 TROUBLESHOOTING: #{guide[:title]}"
        puts '-' * 80
        puts "\nTry these steps:"
        guide[:hints].each_with_index do |hint, index|
          puts "  #{index + 1}. #{hint}"
        end
      end

      # Show generic troubleshooting steps
      def show_generic_troubleshooting
        puts "\n#{'-' * 80}"
        puts '🔧 TROUBLESHOOTING STEPS'
        puts '-' * 80
        puts "\n1. Check the error message and backtrace above"
        puts '2. Verify all hosts are accessible via SSH'
        puts '3. Check PostgreSQL logs on affected hosts'
        puts '4. Run with --verbose for more detailed output'
        puts '5. Consult the documentation: https://github.com/your-repo/active_postgres'
      end

      # Wrap a block with error handling
      def with_handling(context: {})
        yield
      rescue StandardError => e
        handle(e, context: context)
        raise
      end
    end
  end
end
