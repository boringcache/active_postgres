require 'pg'

module ActivePostgres
  class DirectExecutor
    attr_reader :config

    def initialize(config, quiet: false)
      @config = config
      @quiet = quiet
    end

    def quiet?
      @quiet
    end

    def postgres_running?(host)
      with_connection(host) do |conn|
        conn.exec('SELECT 1')
        true
      end
    rescue PG::Error
      false
    end

    def run_sql(host, sql)
      with_connection(host) do |conn|
        result = conn.exec(sql)
        result.values.flatten.join("\n")
      end
    rescue PG::Error => e
      raise Error, "Failed to execute SQL on #{host}: #{e.message}"
    end

    def get_postgres_status(host)
      run_sql(host, 'SELECT version();')
    end

    private

    def with_connection(host)
      connection_host = config.connection_host_for(host)
      superuser_password = resolve_secret(config.secrets_config['superuser_password'])

      conn = PG.connect(
        host: connection_host,
        port: 5432,
        dbname: 'postgres',
        user: config.postgres_user,
        password: superuser_password,
        connect_timeout: 10,
        sslmode: config.component_enabled?(:ssl) ? 'require' : 'prefer'
      )

      begin
        yield conn
      ensure
        conn.close
      end
    end

    def resolve_secret(value)
      return nil if value.nil?

      # Handle Rails credentials
      if value.start_with?('rails_credentials:')
        return resolve_rails_credentials(value)
      end

      # Handle environment variables
      if value.start_with?('$')
        return ENV[value[1..]]
      end

      # Handle shell commands
      if value.start_with?('$(') && value.end_with?(')')
        return `#{value[2..-2]}`.strip
      end

      value
    end

    def resolve_rails_credentials(value)
      path = value.sub('rails_credentials:', '')
      keys = path.split('.').map(&:to_sym)

      Rails.application.credentials.dig(*keys)
    rescue NameError
      nil
    end
  end
end
