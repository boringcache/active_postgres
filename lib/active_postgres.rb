require_relative 'active_postgres/version'
require_relative 'active_postgres/configuration'
require_relative 'active_postgres/credentials'
require_relative 'active_postgres/secrets'

# Utilities
require_relative 'active_postgres/log_sanitizer'
require_relative 'active_postgres/logger'
require_relative 'active_postgres/retry_helper'
require_relative 'active_postgres/error_handler'
require_relative 'active_postgres/validator'
require_relative 'active_postgres/rollback_manager'

# Shared modules
require_relative 'active_postgres/component_resolver'

# Core functionality
require_relative 'active_postgres/deployment_flow'
require_relative 'active_postgres/cluster_deployment_flow'
require_relative 'active_postgres/standby_deployment_flow'
require_relative 'active_postgres/cli'
require_relative 'active_postgres/installer'
require_relative 'active_postgres/ssh_executor'
require_relative 'active_postgres/health_checker'
require_relative 'active_postgres/failover'
require_relative 'active_postgres/performance_tuner'
require_relative 'active_postgres/connection_pooler'

# Components
require_relative 'active_postgres/components/base'
require_relative 'active_postgres/components/core'
require_relative 'active_postgres/components/repmgr'
require_relative 'active_postgres/components/pgbouncer'
require_relative 'active_postgres/components/pgbackrest'
require_relative 'active_postgres/components/monitoring'
require_relative 'active_postgres/components/ssl'
require_relative 'active_postgres/components/extensions'

# Rails integration
require_relative 'active_postgres/rails/database_config'
require_relative 'active_postgres/rails/migration_guard'

begin
  require_relative 'active_postgres/railtie'
rescue LoadError
  # Rails not available - skip railtie
end

module ActivePostgres
  class Error < StandardError; end

  def self.root
    File.expand_path('..', __dir__)
  end

  def self.status
    config = Configuration.load
    health_checker = HealthChecker.new(config)
    health_checker.cluster_status
  end

  def self.failover_to(node_or_host)
    config = Configuration.load
    failover = Failover.new(config)
    failover.promote(node_or_host)
  end
end
