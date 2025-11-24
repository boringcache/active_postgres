require 'test_helper'

class RetryHelperTest < Minitest::Test
  class Harness
    include ActivePostgres::RetryHelper
  end

  def setup
    @helper = Harness.new
  end

  def test_retry_with_backoff_returns_success
    assert_equal('success', @helper.retry_with_backoff { 'success' })
  end

  def test_retry_with_backoff_retries_until_success
    attempts = 0

    suppress_output do
      @helper.stub(:sleep, ->(_) {}) do
        @helper.retry_with_backoff(max_attempts: 3, initial_delay: 0.1) do
          attempts += 1
          raise StandardError, 'Temporary failure' if attempts < 3

          'success'
        end
      end
    end

    assert_equal 3, attempts
  end

  def test_retry_with_backoff_raises_after_max_attempts
    suppress_output do
      @helper.stub(:sleep, ->(_) {}) do
        assert_raises(ActivePostgres::RetryHelper::RetryExhausted) do
          @helper.retry_with_backoff(max_attempts: 2, initial_delay: 0.1) do
            raise StandardError, 'Always fails'
          end
        end
      end
    end
  end

  def test_retry_with_backoff_applies_exponential_backoff
    delays = []

    suppress_output do
      @helper.stub(:sleep, ->(delay) { delays << delay }) do
        assert_raises(ActivePostgres::RetryHelper::RetryExhausted) do
          @helper.retry_with_backoff(max_attempts: 4, initial_delay: 1.0, backoff_factor: 2.0) do
            raise StandardError, 'Fail'
          end
        end
      end
    end

    assert_equal [1.0, 2.0, 4.0], delays
  end

  def test_retry_with_backoff_respects_max_delay
    delays = []

    suppress_output do
      @helper.stub(:sleep, ->(delay) { delays << delay }) do
        assert_raises(ActivePostgres::RetryHelper::RetryExhausted) do
          @helper.retry_with_backoff(max_attempts: 5, initial_delay: 10.0, max_delay: 15.0, backoff_factor: 2.0) do
            raise StandardError, 'Fail'
          end
        end
      end
    end

    assert_equal [10.0, 15.0, 15.0, 15.0], delays
  end

  def test_retry_with_backoff_only_retries_on_specified_exceptions
    suppress_output do
      @helper.stub(:sleep, ->(_) {}) do
        assert_raises(StandardError) do
          @helper.retry_with_backoff(max_attempts: 3, on: [ArgumentError]) do
            raise StandardError, 'Wrong exception type'
          end
        end
      end
    end
  end

  def test_wait_for_returns_true_when_condition_met
    attempts = 0

    suppress_output do
      @helper.stub(:sleep, ->(_) {}) do
        result = @helper.wait_for(timeout: 10, interval: 1) do
          attempts += 1
          attempts >= 3
        end

        assert result
      end
    end

    assert_equal 3, attempts
  end

  def test_wait_for_returns_false_on_timeout
    suppress_output do
      @helper.stub(:sleep, ->(_) {}) do
        refute @helper.wait_for(timeout: 0.01, interval: 0.005) { false }
      end
    end
  end

  def test_wait_for_handles_exceptions
    attempts = 0

    suppress_output do
      @helper.stub(:sleep, ->(_) {}) do
        result = @helper.wait_for(timeout: 0.05, interval: 0.01) do
          attempts += 1
          raise StandardError, 'Temporary error' if attempts < 3

          false
        end
        refute result
      end
    end
  end

  def test_with_timeout_returns_result
    assert_equal 'success', @helper.with_timeout(timeout: 5) { 'success' }
  end

  def test_with_timeout_raises_when_operation_exceeds_timeout
    assert_raises(Timeout::Error) do
      @helper.with_timeout(timeout: 0.1) { sleep 1 }
    end
  end

  def test_with_timeout_kills_thread_on_timeout
    thread = nil

    begin
      @helper.with_timeout(timeout: 0.1) do
        thread = Thread.current
        sleep 5
      end
    rescue Timeout::Error
      # Expected
    end

    sleep 0.2
    refute thread&.alive?
  end

  private

  def suppress_output(&)
    @helper.stub(:puts, ->(*) {}, &)
  end
end
