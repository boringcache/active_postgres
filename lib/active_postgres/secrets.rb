require 'English'
module ActivePostgres
  class Secrets
    attr_reader :config

    def initialize(config)
      @config = config
      @cache = {}
    end

    def resolve(secret_key)
      return @cache[secret_key] if @cache.key?(secret_key)

      secret_value = config.secrets_config[secret_key]
      return nil unless secret_value

      resolved = resolve_secret_value(secret_value)
      @cache[secret_key] = resolved
      resolved
    end

    def resolve_all
      config.secrets_config.keys.each_with_object({}) do |key, result|
        result[key] = resolve(key)
      end
    end

    def cache_to_files(directory = '.secrets')
      require 'fileutils'

      FileUtils.mkdir_p(directory)

      resolve_all.each do |key, value|
        file_path = File.join(directory, key)
        File.write(file_path, value)
        File.chmod(0o600, file_path)
        puts "Cached #{key} to #{file_path}"
      end

      puts "\n✓ Secrets cached to #{directory}/"
      puts "Add to .gitignore: #{directory}/"
    end

    private

    def resolve_secret_value(value)
      case value
      when /^rails_credentials:(.+)$/
        # Rails credentials: rails_credentials:postgres.superuser_password
        key_path = ::Regexp.last_match(1)
        fetch_from_rails_credentials(key_path)
      when /^\$\((.+)\)$/
        # Command execution: $(op read "op://...")
        execute_command(::Regexp.last_match(1))
      when /^\$([A-Z_][A-Z0-9_]*)$/
        # Environment variable: $POSTGRES_PASSWORD
        ENV.fetch(::Regexp.last_match(1), nil)
      when /^env:(.+)$/
        # Explicit env var: env:DATABASE_PASSWORD
        ENV.fetch(::Regexp.last_match(1), nil)
      else
        # Literal value
        value
      end
    end

    def fetch_from_rails_credentials(key_path)
      return nil unless Credentials.available?

      keys = key_path.split('.').map(&:to_sym)
      Rails.application.credentials.dig(*keys)
    end

    def execute_command(command)
      # Preserve RAILS_ENV if set
      env_prefix = ENV['RAILS_ENV'] ? "RAILS_ENV=#{ENV['RAILS_ENV']} " : ''
      full_command = "#{env_prefix}#{command}"

      result = `#{full_command}`.strip

      raise Error, "Failed to execute secret command: #{command} (exit status: #{$CHILD_STATUS.exitstatus})" unless $CHILD_STATUS.success?

      result
    end
  end
end
