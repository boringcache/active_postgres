module ActivePostgres
  class RollbackManager
    attr_reader :config, :ssh_executor, :logger, :rollback_stack

    def initialize(config, ssh_executor, logger: nil)
      @config = config
      @ssh_executor = ssh_executor
      @logger = logger || Logger.new
      @rollback_stack = []
    end

    # Register a rollback action
    # @param description [String] Description of what will be rolled back
    # @param host [String] Host to execute rollback on
    # @yield Block to execute for rollback
    def register(description, host: nil, &block)
      rollback_stack.push({
                            description: description,
                            host: host,
                            action: block
                          })
    end

    # Execute all registered rollback actions in reverse order
    def execute
      return if rollback_stack.empty?

      logger.warn "Executing rollback (#{rollback_stack.count} actions)..."

      rollback_stack.reverse.each do |rollback|
        logger.info "  Rolling back: #{rollback[:description]}"

        if rollback[:host]
          ssh_executor.execute_on_host(rollback[:host]) do
            instance_eval(&rollback[:action])
          end
        else
          rollback[:action].call
        end

        logger.success '    Completed'
      rescue StandardError => e
        logger.error "    Failed: #{e.message}"
        # Continue with other rollback actions
      end

      clear
      logger.success 'Rollback completed'
    end

    # Clear all registered rollback actions
    def clear
      rollback_stack.clear
    end

    # Wrap a block with automatic rollback on failure
    # @param description [String] Description of the operation
    # @yield Block to execute
    def with_rollback(description: 'operation')
      result = yield
      clear # Success - clear rollback stack
      result
    rescue StandardError => e
      logger.error "#{description} failed: #{e.message}"
      execute if rollback_stack.any?
      raise
    end

    # Common rollback actions for PostgreSQL components

    def register_postgres_cluster_removal(host, version)
      register("Remove PostgreSQL cluster on #{host}", host: host) do
        begin
          execute :sudo, 'systemctl', 'stop', 'postgresql'
        rescue StandardError
          nil
        end
        execute :sudo, 'pg_dropcluster', '--stop', version.to_s, 'main', rescue: nil
      end
    end

    def register_package_removal(host, packages)
      register("Remove packages on #{host}: #{packages.join(', ')}", host: host) do
        execute :sudo, 'apt-get', 'remove', '-y', *packages
      rescue StandardError
        nil
      end
    end

    def register_file_removal(host, file_path)
      register("Remove file #{file_path} on #{host}", host: host) do
        execute :sudo, 'rm', '-f', file_path
      rescue StandardError
        nil
      end
    end

    def register_directory_removal(host, dir_path)
      register("Remove directory #{dir_path} on #{host}", host: host) do
        execute :sudo, 'rm', '-rf', dir_path
      rescue StandardError
        nil
      end
    end

    def register_user_removal(host, username)
      register("Remove user #{username} on #{host}", host: host) do
        execute :sudo, 'userdel', username
      rescue StandardError
        nil
      end
    end

    def register_database_removal(host, database_name)
      postgres_user = config.postgres_user
      register("Drop database #{database_name} on #{host}", host: host) do
        sql = "DROP DATABASE IF EXISTS #{database_name};"
        upload! StringIO.new(sql), '/tmp/drop_database.sql'
        execute :sudo, '-u', postgres_user, 'psql', '-f', '/tmp/drop_database.sql'
        execute :rm, '-f', '/tmp/drop_database.sql'
      rescue StandardError
        nil
      end
    end

    def register_postgres_user_removal(host, username)
      postgres_user = config.postgres_user
      register("Drop PostgreSQL user #{username} on #{host}", host: host) do
        sql = "DROP USER IF EXISTS #{username};"
        upload! StringIO.new(sql), '/tmp/drop_user.sql'
        execute :sudo, '-u', postgres_user, 'psql', '-f', '/tmp/drop_user.sql'
        execute :rm, '-f', '/tmp/drop_user.sql'
      rescue StandardError
        nil
      end
    end
  end
end
