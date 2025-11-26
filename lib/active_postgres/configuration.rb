require 'yaml'

module ActivePostgres
  class Configuration
    attr_reader :environment, :version, :user, :ssh_key, :primary, :standbys, :components, :secrets_config, :database_config

    def initialize(config_hash, environment = 'development')
      @environment = environment
      env_config = config_hash[environment] || {}

      # Check if deployment should be skipped (e.g., for development)
      @skip_deployment = env_config['skip_deployment'] == true

      @version = env_config['version'] || 18
      @user = env_config['user'] || 'ubuntu'
      @ssh_key = File.expand_path(env_config['ssh_key'] || '~/.ssh/id_rsa')

      @primary = env_config['primary'] || {}
      @standbys = env_config['standby'] || []
      @standbys = [@standbys] unless @standbys.is_a?(Array)

      @components = parse_components(env_config['components'] || {})
      @secrets_config = env_config['secrets'] || {}
    end

    def self.load(config_path = 'config/postgres.yml', environment = nil)
      environment ||= ENV['BORING_ENVIRONMENT'] || ENV['RAILS_ENV'] || 'development'

      raise Error, "Config file not found: #{config_path}" unless File.exist?(config_path)

      config_hash = YAML.load_file(config_path, aliases: true)
      new(config_hash, environment)
    end

    def all_hosts
      [primary_host] + standby_hosts
    end

    def primary_host
      @primary['host']
    end

    def standby_hosts
      @standbys.map { |s| s['host'] }
    end

    def component_enabled?(name)
      @components[name]&.[](:enabled) == true
    end

    def component_config(name)
      @components[name] || {}
    end

    def skip_deployment?
      @skip_deployment
    end

    def primary_replication_host
      replication_host_for(primary_host)
    end

    def replication_host_for(host)
      node = node_config_for(host)
      private_ip_for(node) || host
    end

    def standby_config_for(host)
      @standbys.find { |s| s['host'] == host }
    end

    def node_label_for(host)
      if host == primary_host
        @primary['label']
      else
        standby_config_for(host)&.dig('label')
      end
    end

    def validate!
      raise Error, 'No primary host defined' unless primary_host

      # Validate required secrets if components are enabled
      raise Error, 'Missing replication_password secret' if component_enabled?(:repmgr) && !secrets_config['replication_password']

      true
    end

    # Database and user configuration helpers from components
    def postgres_user
      component_config(:core)[:postgres_user] || 'postgres'
    end

    def repmgr_user
      component_config(:repmgr)[:user] || 'repmgr'
    end

    def repmgr_database
      component_config(:repmgr)[:database] || 'repmgr'
    end

    def pgbouncer_user
      component_config(:pgbouncer)[:user] || 'pgbouncer'
    end

    def app_user
      value = component_config(:core)[:app_user]
      value.nil? || value.to_s.strip.empty? ? 'app' : value
    end

    def app_database
      value = component_config(:core)[:app_database]
      value.nil? || value.to_s.strip.empty? ? "app_#{environment}" : value
    end

    private

    def parse_components(components_config)
      result = {}

      # Core is always enabled - include ALL core config, not just specific fields
      core_config = components_config['core'] || {}
      result[:core] = {
        enabled: true,
        version: @version,
        locale: core_config['locale'] || 'en_US.UTF-8',
        encoding: core_config['encoding'] || 'UTF8',
        data_checksums: core_config['data_checksums'] != false,
        app_user: core_config['app_user'],
        app_database: core_config['app_database']
      }

      # Include pg_hba and postgresql config if present
      result[:core][:pg_hba] = symbolize_keys_deep(core_config['pg_hba']) if core_config['pg_hba']
      result[:core][:postgresql] = symbolize_keys(core_config['postgresql']) if core_config['postgresql']

      # Parse each component
      %i[repmgr pgbouncer pgbackrest monitoring ssl extensions].each do |component|
        component_str = component.to_s
        result[component] = if components_config[component_str]
                              symbolize_keys(components_config[component_str])
                            else
                              { enabled: false }
                            end
      end

      # Performance tuning must be explicitly enabled
      result[:performance_tuning] = if components_config['performance_tuning']
                                      symbolize_keys(components_config['performance_tuning'])
                                    else
                                      { enabled: false }
                                    end

      result
    end

    def node_config_for(host)
      return @primary if host == primary_host

      standby_config_for(host)
    end

    def private_ip_for(node_config)
      return unless node_config

      node_config['private_ip'] || node_config['host']
    end

    def symbolize_keys(hash)
      hash.each_with_object({}) do |(key, value), result|
        new_key = key.to_sym
        new_value = value.is_a?(Hash) ? symbolize_keys(value) : value
        result[new_key] = new_value
      end
    end

    def symbolize_keys_deep(value)
      case value
      when Hash
        value.each_with_object({}) do |(k, v), result|
          result[k.to_sym] = symbolize_keys_deep(v)
        end
      when Array
        value.map { |v| symbolize_keys_deep(v) }
      else
        value
      end
    end
  end
end
