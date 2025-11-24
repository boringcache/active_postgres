module ActivePostgres
  class Credentials
    def self.get(key_path)
      # Try to get from Rails credentials if Rails is available
      if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
        value = Rails.application.credentials.dig(*key_path.split('.').map(&:to_sym))
        return value if value
      end

      nil
    end

    def self.available?
      defined?(Rails) && Rails.respond_to?(:application) && Rails.application&.credentials
    end
  end
end
