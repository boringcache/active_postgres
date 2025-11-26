module ActivePostgres
  class ClusterDeploymentFlow < DeploymentFlow
    private

    def operation_name
      if standbys?
        'PostgreSQL HA Cluster Setup'
      else
        'PostgreSQL Primary Setup'
      end
    end

    def print_targets
      logger.info "Primary: #{config.primary_host}"
      if standbys?
        logger.info "Standbys: #{config.standby_hosts.join(', ')}"
      else
        logger.info 'Standbys: None (primary-only setup)'
      end
    end

    def validate_specific_requirements
      return unless config.component_enabled?(:repmgr) && !standbys?

      logger.warn '⚠️  repmgr is enabled but no standbys configured - will skip repmgr setup'
    end

    def list_deployment_steps
      if standbys?
        logger.info "  • Install/recreate PostgreSQL #{config.version} on all servers"
        logger.info '  • Configure repmgr for high availability' if should_setup_repmgr?
      else
        logger.info "  • Install/recreate PostgreSQL #{config.version} on primary"
      end

      logger.info '  • Setup pgbouncer connection pooling' if config.component_enabled?(:pgbouncer)
      logger.info '  • Configure pgbackrest backups' if config.component_enabled?(:pgbackrest)
      logger.info '  • Install postgres_exporter monitoring' if config.component_enabled?(:monitoring)
      logger.info '  • Enable SSL/TLS connections' if config.component_enabled?(:ssl)
    end

    def deploy_components
      hosts_to_deploy = standbys? ? config.all_hosts : [config.primary_host]

      setup_component('ssl', hosts_to_deploy) if config.component_enabled?(:ssl)
      setup_component('core', hosts_to_deploy)

      components = %i[pgbouncer pgbackrest monitoring extensions]
      components.unshift(:repmgr) if should_setup_repmgr?

      components.each do |component|
        setup_component(component.to_s, hosts_to_deploy) if config.component_enabled?(component)
      end

      # Create application users AFTER repmgr to avoid being wiped by cluster recreation
      create_application_users_if_configured
    end

    def list_next_steps
      logger.info ''
      logger.info '📋 Next Steps:'
      logger.info '  1. Verify cluster: rake postgres:verify'
      logger.info "  2. Update database.yml to use: #{config.primary_host}:#{config.component_enabled?(:pgbouncer) ? '6432' : '5432'}"
      logger.info '  3. Run migrations: rake postgres:migrate'
      logger.info '  4. Update PgBouncer userlist: rake postgres:pgbouncer:update_userlist[your_app_user]' if config.component_enabled?(:pgbouncer)

      return if standbys?

      logger.info '  5. To add HA later: Add standbys to config → run: rake postgres:setup'
    end

    def standbys?
      config.standby_hosts.any?
    end

    def should_setup_repmgr?
      config.component_enabled?(:repmgr) && standbys?
    end

    def create_application_users_if_configured
      core_component = Components::Core.new(config, ssh_executor, secrets)
      core_component.create_application_users
    end
  end
end
