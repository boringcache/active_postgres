module ActivePostgres
  class Installer
    include ComponentResolver

    attr_reader :config, :dry_run, :ssh_executor, :secrets, :logger, :rollback_manager, :skip_validation, :use_optimized

    def initialize(config, dry_run: false, verbose: false, skip_validation: false, use_optimized: true,
                   skip_rollback: false)
      @config = config
      @dry_run = dry_run
      @skip_validation = skip_validation
      @use_optimized = use_optimized
      @skip_rollback = skip_rollback || ENV['SKIP_ROLLBACK'] == 'true'
      @ssh_executor = SSHExecutor.new(config)
      @secrets = Secrets.new(config)
      @logger = Logger.new(verbose: verbose || ENV['VERBOSE'] == 'true')
      @rollback_manager = skip_rollback ? nil : RollbackManager.new(config, ssh_executor, logger: logger)
    end

    def setup
      logger.warn 'Skipping pre-flight validation (--skip-validation flag)' if skip_validation

      flow = ClusterDeploymentFlow.new(
        config,
        ssh_executor: ssh_executor,
        secrets: secrets,
        logger: logger,
        rollback_manager: rollback_manager,
        skip_validation: skip_validation
      )
      flow.execute
    end

    def setup_component(component_name)
      logger.task("Setting up #{component_name}") do
        component_class = component_class_for(component_name)
        component = component_class.new(config, ssh_executor, secrets)

        if dry_run
          logger.info "[DRY RUN] Would setup #{component_name}"
        else
          # Register rollback for this component
          rollback_manager.register("Uninstall #{component_name}", host: nil) do
            component.uninstall
          rescue StandardError => e
            logger.warn "Failed to uninstall #{component_name}: #{e.message}"
          end

          component.install
        end

        logger.success "#{component_name} setup complete"
      end
    end

    def uninstall_component(component_name)
      puts "==> Uninstalling #{component_name}..."

      component_class = component_class_for(component_name)
      component = component_class.new(config, ssh_executor, secrets)
      component.uninstall

      puts "✓ #{component_name} uninstalled"
    end

    def restart_component(component_name)
      puts "==> Restarting #{component_name}..."

      component_class = component_class_for(component_name)
      component = component_class.new(config, ssh_executor, secrets)
      component.restart

      puts "✓ #{component_name} restarted"
    end

    def run_backup(type)
      puts "==> Running #{type} backup..."

      component = Components::PgBackRest.new(config, ssh_executor, secrets)
      component.run_backup(type)

      puts '✓ Backup complete'
    end

    def run_restore(backup_id)
      puts "==> Restoring from backup #{backup_id}..."

      component = Components::PgBackRest.new(config, ssh_executor, secrets)
      component.run_restore(backup_id)

      puts '✓ Restore complete'
    end

    def list_backups
      component = Components::PgBackRest.new(config, ssh_executor, secrets)
      component.list_backups
    end

    def setup_standby_only(standby_host)
      logger.warn 'Skipping pre-flight validation (--skip-validation flag)' if skip_validation

      flow = StandbyDeploymentFlow.new(
        config,
        standby_host: standby_host,
        ssh_executor: ssh_executor,
        secrets: secrets,
        logger: logger,
        rollback_manager: rollback_manager,
        skip_validation: skip_validation
      )
      flow.execute
    end
  end
end
