require 'logger'

module ActivePostgres
  class Logger
    LEVELS = {
      debug: ::Logger::DEBUG,
      info: ::Logger::INFO,
      warn: ::Logger::WARN,
      error: ::Logger::ERROR,
      fatal: ::Logger::FATAL
    }.freeze

    attr_reader :logger, :verbose

    def initialize(verbose: false, log_file: nil)
      @verbose = verbose
      @logger = setup_logger(log_file)
      @step_number = 0
      @current_task = nil
    end

    def setup_logger(log_file)
      if log_file
        file_logger = ::Logger.new(log_file, 'daily')
        file_logger.level = ::Logger::DEBUG
        file_logger
      else
        ::Logger.new($stdout).tap do |l|
          l.level = verbose ? ::Logger::DEBUG : ::Logger::INFO
          l.formatter = proc do |severity, _datetime, _progname, msg|
            case severity
            when 'DEBUG'
              "#{msg}\n" if verbose
            when 'INFO'
              "#{msg}\n"
            when 'WARN'
              "⚠️  #{msg}\n"
            when 'ERROR'
              "❌ #{msg}\n"
            when 'FATAL'
              "💀 #{msg}\n"
            else
              "#{msg}\n"
            end
          end
        end
      end
    end

    def task(description)
      @step_number += 1
      @current_task = description
      logger.info "#{@step_number}. #{sanitize(description)}"

      start_time = Time.now
      result = yield
      duration = Time.now - start_time

      completed_message = "Completed in #{duration.round(2)}s"
      logger.debug "  #{sanitize(completed_message)}"
      result
    rescue StandardError => e
      failure_message = "Failed: #{e.message}"
      logger.error "  #{sanitize(failure_message)}"
      raise
    ensure
      @current_task = nil
    end

    def step(description)
      logger.info "  → #{sanitize(description)}"
      yield if block_given?
    end

    def debug(message)
      logger.debug "    #{sanitize(message)}"
    end

    def info(message)
      logger.info "  #{sanitize(message)}"
    end

    def warn(message)
      logger.warn "  #{sanitize(message)}"
    end

    def error(message)
      logger.error "  #{sanitize(message)}"
    end

    def fatal(message)
      logger.fatal "  #{sanitize(message)}"
    end

    def success(message)
      logger.info "  ✅ #{sanitize(message)}"
    end

    def progress(message)
      logger.info "  ⏳ #{sanitize(message)}"
    end

    # Format diagnostic information nicely
    def diagnostic(title, content)
      logger.debug "\n  📋 #{sanitize(title)}:"
      content.each_line do |line|
        logger.debug "     #{sanitize(line.chomp)}"
      end
      logger.debug ''
    end

    # Log a section header
    def section(title)
      logger.info sanitize("\n#{'=' * 60}")
      logger.info sanitize(title.center(60))
      logger.info sanitize("#{'=' * 60}\n")
    end

    private

    def sanitize(message)
      LogSanitizer.sanitize(message.to_s)
    end
  end
end
