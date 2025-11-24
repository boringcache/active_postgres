require 'test_helper'
require 'stringio'

class LoggerTest < Minitest::Test
  def test_info_sanitizes_sensitive_information
    output = StringIO.new
    original_stdout = $stdout
    $stdout = output

    begin
      logger = ActivePostgres::Logger.new(verbose: true)
      logger.info('password=supersecret')
    ensure
      $stdout = original_stdout
    end

    refute_includes output.string, 'supersecret'
    assert_includes output.string, '[REDACTED]'
  end

  def test_logger_handles_binary_encoded_messages
    output = StringIO.new
    original_stdout = $stdout
    $stdout = output

    begin
      logger = ActivePostgres::Logger.new(verbose: true)
      message = "binary\xC3".dup.force_encoding(Encoding::ASCII_8BIT)
      logger.info(message)
    ensure
      $stdout = original_stdout
    end

    assert_includes output.string, 'binary?'
  end
end
