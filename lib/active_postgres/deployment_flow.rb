module ActivePostgres
  class DeploymentFlow
    include ComponentResolver

    attr_reader :config, :ssh_executor, :secrets, :logger, :rollback_manager, :skip_validation

    def initialize(config, ssh_executor:, secrets:, logger:, rollback_manager:, skip_validation: false)
      @config = config
      @ssh_executor = ssh_executor
      @secrets = secrets
      @logger = logger
      @rollback_manager = rollback_manager
      @skip_validation = skip_validation
    end

    def execute
      ErrorHandler.with_handling(context: { operation: operation_name }) do
        print_header
        validate_prerequisites
        run_preflight_checks unless skip_validation
        print_deployment_plan
        return unless confirm_deployment

        rollback_manager.with_rollback(description: operation_name) do
          deploy_components
        end

        print_success_message
      end
    end

    private

    def operation_name
      raise NotImplementedError, 'Subclasses must implement #operation_name'
    end

    def print_header
      logger.section(operation_name)
      logger.info "Environment: #{config.environment}"
      print_targets
      puts
    end

    def print_targets
      raise NotImplementedError, 'Subclasses must implement #print_targets'
    end

    def validate_prerequisites
      config.validate!
      validate_specific_requirements
    end

    def validate_specific_requirements; end

    def run_preflight_checks
      logger.task('Running pre-flight validation') do
        validator = Validator.new(config, ssh_executor)
        abort '❌ Validation failed. Fix errors before proceeding, or use --skip-validation to bypass.' unless validator.validate_all
      end
    end

    def print_deployment_plan
      logger.info "\nThis will:"
      list_deployment_steps
      list_warnings
      puts
    end

    def list_deployment_steps
      raise NotImplementedError, 'Subclasses must implement #list_deployment_steps'
    end

    def list_warnings; end

    def confirm_deployment
      print 'Do you want to proceed? (yes/no): '
      response = $stdin.gets.chomp.downcase
      unless %w[yes y].include?(response)
        puts 'Deployment cancelled.'
        return false
      end
      true
    end

    def deploy_components
      raise NotImplementedError, 'Subclasses must implement #deploy_components'
    end

    def print_success_message
      logger.success "\n✓ #{operation_name} complete!"
      print_connection_details
      logger.info "\nNext steps:"
      list_next_steps
    end

    def print_connection_details
      logger.section('Database Connection Details')
      print_primary_info
      print_standby_info
      print_rails_config
    end

    def print_primary_info
      primary_private_ip = config.primary['private_ip'] || config.primary_host
      logger.info "Primary Host (Public):  #{config.primary_host}"
      logger.info "Primary Host (Private): #{primary_private_ip}"
    end

    def print_standby_info
      return unless config.standby_hosts.any?

      logger.info "\nStandbys:"
      config.standby_hosts.each do |host|
        standby_config = config.standby_config_for(host)
        private_ip = standby_config&.dig('private_ip') || host
        logger.info "  - #{host} (Private: #{private_ip})"
      end
    end

    def print_rails_config
      primary_private_ip = config.primary['private_ip'] || config.primary_host
      logger.info "\nFor Rails config/database.yml (production):"
      logger.info "  host: #{primary_private_ip}  # Use private IP for internal connections"
      logger.info '  port: 5432'
      logger.info "  username: <%= Rails.application.credentials.dig(:postgres, :username) || 'app' %>"
      logger.info '  password: <%= Rails.application.credentials.dig(:postgres, :password) %>'
      puts ''
    end

    def list_next_steps
      raise NotImplementedError, 'Subclasses must implement #list_next_steps'
    end

    def setup_component(component_name, hosts)
      logger.task("Setting up #{component_name}") do
        component_class = component_class_for(component_name)
        component = component_class.new(config, ssh_executor, secrets)

        Array(hosts).each do |host|
          captured_logger = logger
          rollback_manager.register("Uninstall #{component_name} on #{host}", host: host) do
            component.uninstall
          rescue StandardError => e
            captured_logger.warn "Failed to uninstall #{component_name} on #{host}: #{e.message}"
          end
        end

        component.install
        logger.success "#{component_name} setup complete"
      end
    end
  end
end
