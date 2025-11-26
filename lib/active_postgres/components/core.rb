module ActivePostgres
  module Components
    class Core < Base
      def install
        puts 'Installing PostgreSQL core...'

        # Install on primary
        install_on_host(config.primary_host, is_primary: true)

        # NOTE: App user creation moved to after repmgr setup to avoid being wiped
        # See: create_application_user_and_database method called from deployment flow

        # Install on standbys
        # If repmgr is enabled, only install packages (cluster will be cloned by repmgr)
        # If repmgr is disabled, install everything including cluster creation
        config.standby_hosts.each do |host|
          if config.component_enabled?(:repmgr)
            install_packages_only(host)
          else
            install_on_host(host, is_primary: false)
          end
        end
      end

      def uninstall
        puts 'Uninstalling PostgreSQL is not recommended and must be done manually.'
      end

      def restart
        puts 'Restarting PostgreSQL...'

        # Restart on all hosts
        config.all_hosts.each do |host|
          ssh_executor.restart_postgres(host, config.version)
        end
      end

      # Public method to create application users - called after repmgr setup
      # This is done after repmgr to avoid being wiped by cluster recreation
      def create_application_users
        return unless config.app_user && config.app_database

        puts "\n📝 Creating application users and databases..."
        create_app_user_and_database(config.primary_host)
      end

      private

      def install_on_host(host, is_primary:)
        puts "  Installing on #{host}..."

        ssh_executor.install_postgres(host, config.version)
        ssh_executor.ensure_cluster_exists(host, config.version)

        # Get base component config
        component_config = config.component_config(:core)

        # Calculate optimal PostgreSQL settings if performance tuning is enabled
        # pg_config is used in ERB template via binding
        pg_config = if config.component_enabled?(:performance_tuning)
                      calculate_tuned_settings(host, component_config)
                    else
                      component_config[:postgresql] || {}
                    end
        _ = pg_config # Used in ERB template

        upload_template(host, 'postgresql.conf.erb', "/etc/postgresql/#{config.version}/main/postgresql.conf", binding,
                        owner: 'postgres:postgres')
        upload_template(host, 'pg_hba.conf.erb', "/etc/postgresql/#{config.version}/main/pg_hba.conf", binding,
                        owner: 'postgres:postgres')

        ssh_executor.restart_postgres(host, config.version)
      end

      def calculate_tuned_settings(host, component_config)
        tuning_config = config.component_config(:performance_tuning)
        db_type = tuning_config[:db_type] || 'web'

        puts "  Auto-tuning PostgreSQL for #{db_type} workload..."

        # Initialize tuner and calculate optimal settings
        tuner = PerformanceTuner.new(config, ssh_executor)
        optimal_settings = tuner.tune_for_host(host, db_type: db_type)

        # Merge: user config overrides calculated settings
        user_postgresql = component_config[:postgresql] || {}
        optimal_settings.merge(user_postgresql)
      end

      def install_packages_only(host)
        puts "  Installing packages on #{host} (cluster will be created by repmgr)..."
        ssh_executor.install_postgres(host, config.version)
      end

      def create_app_user_and_database(host)
        app_user = config.app_user
        app_database = config.app_database

        return unless app_user && app_database

        puts "  Creating application user '#{app_user}' and database '#{app_database}'..."
        app_password = resolve_app_password
        sql = build_app_user_sql(app_user, app_database, app_password)

        ssh_executor.execute_on_host(host) do
          upload! StringIO.new(sql), '/tmp/create_app_user.sql'
          execute :chmod, '644', '/tmp/create_app_user.sql'
          execute :sudo, '-u', 'postgres', 'psql', '-f', '/tmp/create_app_user.sql'
          execute :rm, '-f', '/tmp/create_app_user.sql'

          puts "  ✓ Created app user '#{app_user}' and database '#{app_database}'"
        end
      rescue StandardError => e
        warn "  Warning: Could not create app user: #{e.message}"
        warn '  You may need to create the user manually'
      end

      def resolve_app_password
        app_password = secrets.resolve('app_password')
        if app_password.nil? || app_password.empty?
          raise Error, 'app_password is empty or nil. Check your postgres.yml secrets section and ensure RAILS_ENV=production is set.'
        end

        app_password
      rescue StandardError => e
        raise Error, "Cannot resolve app_password: #{e.message}. Make sure RAILS_ENV is set when running deployment."
      end

      def build_app_user_sql(app_user, app_database, app_password)
        escaped_password = app_password.gsub("'", "''")

        [
          '-- Create app user if not exists',
          'DO $$',
          'BEGIN',
          "  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '#{app_user}') THEN",
          "    CREATE USER #{app_user} WITH PASSWORD '#{escaped_password}' CREATEDB;",
          '  ELSE',
          "    ALTER USER #{app_user} WITH PASSWORD '#{escaped_password}';",
          '  END IF;',
          'END $$;',
          '',
          '-- Ensure user has CREATEDB',
          "ALTER USER #{app_user} CREATEDB;",
          '',
          '-- Create database if not exists',
          "SELECT 'CREATE DATABASE #{app_database} OWNER #{app_user}'",
          "WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '#{app_database}')\\gexec",
          '',
          '-- Grant privileges',
          "GRANT ALL PRIVILEGES ON DATABASE #{app_database} TO #{app_user};",
          "\\c #{app_database}",
          "GRANT ALL ON SCHEMA public TO #{app_user};"
        ].join("\n")
      end
    end
  end
end
