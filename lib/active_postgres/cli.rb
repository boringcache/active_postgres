require 'thor'

module ActivePostgres
  class CLI < Thor
    class_option :environment, aliases: '-e', default: ENV['BORING_ENVIRONMENT'] || ENV['RAILS_ENV'] || 'development'
    class_option :config, aliases: '-c', default: 'config/postgres.yml'

    desc 'setup', 'Setup PostgreSQL HA cluster'
    option :dry_run, type: :boolean, default: false
    option :only, type: :string, desc: 'Setup only specific component (core, repmgr, pgbouncer, etc.)'
    def setup
      config = load_config
      installer = Installer.new(config, dry_run: options[:dry_run])

      if options[:only]
        installer.setup_component(options[:only])
      else
        installer.setup
      end
    end

    desc 'setup-primary', '[DEPRECATED] Use "setup" instead - it auto-detects primary-only vs HA'
    option :dry_run, type: :boolean, default: false
    def setup_primary
      puts '⚠️  DEPRECATED: Use "active_postgres setup" instead.'
      puts '   The setup command now auto-detects whether to deploy primary-only or HA based on your config.'
      puts ''
      setup
    end

    desc 'setup-standby HOST', 'Setup a single standby server without touching the primary'
    option :dry_run, type: :boolean, default: false
    def setup_standby(host)
      config = load_config
      installer = Installer.new(config, dry_run: options[:dry_run])

      unless config.standby_hosts.include?(host)
        puts "Error: #{host} is not configured as a standby in config/postgres.yml"
        exit 1
      end

      installer.setup_standby_only(host)
    end

    desc 'status', 'Show cluster status'
    def status
      config = load_config
      health_checker = HealthChecker.new(config)
      health_checker.show_status
    end

    desc 'health', 'Run health checks'
    def health
      config = load_config
      health_checker = HealthChecker.new(config)
      health_checker.run_health_checks
    end

    desc 'promote HOST', 'Promote standby to primary'
    option :node, type: :string
    def promote(host = nil)
      host ||= options[:node]

      unless host
        puts 'Error: Must specify host or --node'
        exit 1
      end

      config = load_config
      failover = Failover.new(config)
      failover.promote(host)
    end

    desc 'backup', 'Create backup'
    option :type, default: 'full', desc: 'Backup type: full, incremental'
    def backup
      config = load_config

      unless config.component_enabled?(:pgbackrest)
        puts 'Error: pgBackRest component not enabled'
        exit 1
      end

      installer = Installer.new(config)
      installer.run_backup(options[:type])
    end

    desc 'restore BACKUP_ID', 'Restore from backup'
    def restore(backup_id)
      config = load_config

      unless config.component_enabled?(:pgbackrest)
        puts 'Error: pgBackRest component not enabled'
        exit 1
      end

      installer = Installer.new(config)
      installer.run_restore(backup_id)
    end

    desc 'list-backups', 'List available backups'
    def list_backups
      config = load_config

      unless config.component_enabled?(:pgbackrest)
        puts 'Error: pgBackRest component not enabled'
        exit 1
      end

      installer = Installer.new(config)
      installer.list_backups
    end

    desc 'install COMPONENT', 'Install specific component'
    def install(component)
      config = load_config
      installer = Installer.new(config)
      installer.setup_component(component)
    end

    desc 'uninstall COMPONENT', 'Uninstall specific component'
    def uninstall(component)
      config = load_config
      installer = Installer.new(config)
      installer.uninstall_component(component)
    end

    desc 'restart COMPONENT', 'Restart specific component'
    def restart(component)
      config = load_config
      installer = Installer.new(config)
      installer.restart_component(component)
    end

    desc 'cache-secrets', 'Fetch and cache secrets locally'
    option :directory, default: '.secrets'
    def cache_secrets
      config = load_config
      secrets = Secrets.new(config)
      secrets.cache_to_files(options[:directory])
    end

    desc 'version', 'Show version'
    def version
      puts "active_postgres #{ActivePostgres::VERSION}"
    end

    private

    def load_config
      Configuration.load(options[:config], options[:environment])
    rescue StandardError => e
      puts "Error loading config: #{e.message}"
      exit 1
    end
  end
end
