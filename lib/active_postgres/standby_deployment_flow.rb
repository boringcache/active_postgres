module ActivePostgres
  class StandbyDeploymentFlow < DeploymentFlow
    attr_reader :standby_host

    def initialize(config, standby_host:, **)
      super(config, **)
      @standby_host = standby_host
    end

    private

    def operation_name
      "Standby Setup: #{standby_host}"
    end

    def print_targets
      logger.info "Primary: #{config.primary_host}"
      logger.info "Standby: #{standby_host}"
    end

    def validate_specific_requirements
      abort "❌ #{standby_host} is not configured as a standby in config/postgres.yml" unless config.standby_hosts.include?(standby_host)

      abort '❌ repmgr component must be enabled to setup standbys' unless config.component_enabled?(:repmgr)

      validate_required_secrets!
    end

    def run_preflight_checks
      super

      check_if_standby_already_deployed
    end

    def check_if_standby_already_deployed
      logger.info "\nChecking if standby is already deployed..."

      postgres_running = ssh_executor.postgres_running?(standby_host)

      return unless postgres_running

      logger.warn "⚠️  PostgreSQL is already running on #{standby_host}"
      logger.warn '   This deployment will DROP and RECREATE the database cluster'
      logger.warn '   All data on this standby will be LOST and re-cloned from primary'
      puts ''
    rescue StandardError => e
      logger.warn "Could not check if standby is deployed: #{e.message}"
    end

    def list_deployment_steps
      logger.info "  • Install PostgreSQL #{config.version} packages on #{standby_host}"
      if config.standby_seed_method_for(standby_host) == :pgbackrest
        logger.info '  • Restore the latest valid pgBackRest backup as a standby'
      else
        logger.info "  • Clone data from primary: #{config.primary_host}"
      end
      logger.info '  • Register standby with repmgr cluster'
    end

    def list_warnings
      logger.info "\n⚠️  Primary stays online; setup performs idempotent role and repmgr checks"
    end

    def deploy_components
      deploy_ssl if config.component_enabled?(:ssl)
      deploy_core
      deploy_pgbackrest if config.component_enabled?(:pgbackrest)
      deploy_repmgr
      deploy_optional_components
    end

    def deploy_ssl
      logger.task('Setting up SSL on standby') do
        component = Components::SSL.new(config, ssh_executor, secrets)
        register_rollback('SSL', component)
        component.install_on_standby(standby_host)
      end
    end

    def deploy_core
      logger.task('Installing PostgreSQL packages on standby') do
        component = Components::Core.new(config, ssh_executor, secrets)
        component.install_packages_only(standby_host)
      end
    end

    def deploy_pgbackrest
      logger.task('Installing pgBackRest on standby') do
        component = Components::PgBackRest.new(config, ssh_executor, secrets)
        component.install_on_standby(standby_host)
      end
    end

    def deploy_repmgr
      logger.task('Setting up repmgr and seeding standby') do
        component = Components::Repmgr.new(config, ssh_executor, secrets)
        register_rollback('repmgr', component)
        component.setup_standby_only(standby_host)
      end
    end

    def deploy_optional_components
      deploy_pgbouncer if config.component_enabled?(:pgbouncer)
      deploy_monitoring if config.component_enabled?(:monitoring)
    end

    def deploy_pgbouncer
      logger.task('Setting up pgbouncer on standby') do
        component = Components::PgBouncer.new(config, ssh_executor, secrets)
        component.install_on_standby(standby_host)
      end
    end

    def deploy_monitoring
      logger.task('Setting up monitoring on standby') do
        component = Components::Monitoring.new(config, ssh_executor, secrets)
        component.install_on_standby(standby_host) if component.respond_to?(:install_on_standby)
      end
    end

    def register_rollback(component_name, component)
      target_host = standby_host
      captured_logger = logger

      rollback_manager.register("Uninstall #{component_name} on #{target_host}") do
        if component.respond_to?(:uninstall_from)
          component.uninstall_from(target_host)
        else
          component.uninstall
        end
      rescue StandardError => e
        captured_logger.warn "Failed to uninstall #{component_name} on #{target_host}: #{e.message}"
      end
    end

    def validate_required_secrets!
      required = %w[repmgr_password replication_password]
      required.push('ssl_cert', 'ssl_key') if config.component_enabled?(:ssl)
      required << 'monitoring_password' if config.component_enabled?(:monitoring)

      if config.component_enabled?(:pgbackrest)
        pgbackrest = secrets.resolve_value(config.component_config(:pgbackrest))
        if pgbackrest[:repo_type] == 's3'
          required.push('s3_access_key', 's3_secret_key')
          raise Error, 'pgbackrest.s3_bucket did not resolve' if pgbackrest[:s3_bucket].to_s.empty?
        end
      end

      missing = required.uniq.select { |key| secrets.resolve(key).to_s.empty? }
      return if missing.empty?

      raise Error, "Required standby secrets did not resolve: #{missing.join(', ')}"
    end

    def list_next_steps
      logger.info '  1. Check cluster status: active_postgres status'
      logger.info '  2. Verify replication: Check repmgr cluster show'
    end
  end
end
