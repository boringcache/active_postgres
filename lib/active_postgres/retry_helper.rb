module ActivePostgres
  module RetryHelper
    class RetryExhausted < StandardError; end

    # Retry a block with exponential backoff
    # @param max_attempts [Integer] Maximum number of attempts
    # @param initial_delay [Float] Initial delay in seconds
    # @param max_delay [Float] Maximum delay between retries
    # @param backoff_factor [Float] Multiplier for exponential backoff
    # @param on [Array<Class>] Exception classes to retry on
    # @yield Block to retry
    # @return Result of the block
    def retry_with_backoff(max_attempts: 3, initial_delay: 1.0, max_delay: 30.0,
                           backoff_factor: 2.0, on: [StandardError])
      attempt = 0
      delay = initial_delay

      begin
        attempt += 1
        yield
      rescue *on => e
        if attempt < max_attempts
          puts "  Attempt #{attempt}/#{max_attempts} failed: #{e.message}"
          puts "  Retrying in #{delay.round(1)}s..."
          sleep delay
          delay = [delay * backoff_factor, max_delay].min
          retry
        else
          puts "  All #{max_attempts} attempts failed"
          raise RetryExhausted, "Failed after #{max_attempts} attempts: #{e.message}"
        end
      end
    end

    # Wait for a condition to be true with timeout
    # @param timeout [Float] Maximum time to wait in seconds
    # @param interval [Float] Time between checks in seconds
    # @param description [String] Description of what we're waiting for
    # @yield Block that should return true when condition is met
    # @return [Boolean] true if condition met, false if timeout
    def wait_for(timeout: 60, interval: 3, description: 'condition')
      deadline = Time.now + timeout
      attempts = 0

      while Time.now < deadline
        attempts += 1

        begin
          return true if yield
        rescue StandardError => e
          puts "  Check #{attempts} raised error: #{e.message}" if (attempts % 10).zero?
        end

        remaining = (deadline - Time.now).to_i
        puts "  Waiting for #{description}... (#{remaining}s remaining)" if (attempts % 5).zero?
        sleep interval
      end

      puts "  ⚠️  Timeout waiting for #{description} after #{timeout}s"
      false
    end

    # Execute a block with a timeout
    # @param timeout [Float] Timeout in seconds
    # @param description [String] Description of the operation
    # @yield Block to execute
    # @return Result of the block
    def with_timeout(timeout: 300, description: 'operation')
      result = nil
      thread = Thread.new { result = yield }

      unless thread.join(timeout)
        thread.kill
        raise Timeout::Error, "#{description} timed out after #{timeout}s"
      end

      result
    end
  end
end
