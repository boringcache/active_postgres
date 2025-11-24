module ActivePostgres
  # Sanitizes sensitive information from logs - CRITICAL for production security
  module LogSanitizer
    # Patterns for sensitive data that must NEVER appear in logs
    SENSITIVE_PATTERNS = [
      # Passwords in connection strings (matches until whitespace)
      # Handles special chars like: password=abc}def~ghi!@#$%^&*()
      /password[=:]\s*(\S+)/i,
      /PGPASSWORD[=:]\s*(\S+)/i,
      /passwd[=:]\s*(\S+)/i,

      # Connection strings with passwords
      %r{(postgresql://[^:]+:)([^@]+)(@)}i,
      %r{(postgres://[^:]+:)([^@]+)(@)}i,

      # SSH keys
      /-----BEGIN [A-Z ]+ KEY-----[\s\S]+?-----END [A-Z ]+ KEY-----/,

      # Tokens and secrets
      /token[=:]\s*(\S+)/i,
      /secret[=:]\s*(\S+)/i,
      /api[_-]?key[=:]\s*(\S+)/i,

      # AWS credentials
      /aws[_-]?access[_-]?key[_-]?id[=:]\s*(\S+)/i,
      /aws[_-]?secret[_-]?access[_-]?key[=:]\s*(\S+)/i
    ].freeze

    REDACTED_TEXT = '[REDACTED]'.freeze

    def self.sanitize(text)
      return text if text.nil? || text.empty?

      sanitized = text.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')

      SENSITIVE_PATTERNS.each do |pattern|
        sanitized.gsub!(pattern) do |match|
          # Replace only the sensitive part, keep structure
          if ::Regexp.last_match(1) # Captured group exists
            match.gsub(::Regexp.last_match(1), REDACTED_TEXT)
          else
            REDACTED_TEXT
          end
        end
      end

      sanitized
    end

    def self.sanitize_hash(hash)
      return hash unless hash.is_a?(Hash)

      hash.transform_values do |value|
        case value
        when Hash
          sanitize_hash(value)
        when String
          sanitize(value)
        when Array
          value.map { |v| v.is_a?(String) ? sanitize(v) : v }
        else
          value
        end
      end
    end
  end
end
