require 'test_helper'

class RollbackManagerTest < Minitest::Test
  def setup
    @config = stub_config
    @ssh_executor = ActivePostgres::SSHExecutor.new(@config)
    @logger = ActivePostgres::Logger.new
    @manager = ActivePostgres::RollbackManager.new(@config, @ssh_executor, logger: @logger)
  end

  def test_initialization
    assert_equal @config, @manager.config
    assert_equal @ssh_executor, @manager.ssh_executor
    assert_equal @logger, @manager.logger
    assert_empty @manager.rollback_stack
  end

  def test_register_adds_to_stack
    @manager.register('Test rollback') { puts 'rolling back' }

    assert_equal 1, @manager.rollback_stack.length
    assert_equal 'Test rollback', @manager.rollback_stack.first[:description]
  end

  def test_register_with_host
    @manager.register('Test rollback', host: 'host1.example.com') { puts 'rolling back' }

    rollback = @manager.rollback_stack.first
    assert_equal 'host1.example.com', rollback[:host]
  end

  def test_clear_empties_stack
    @manager.register('Test 1') { puts '1' }
    @manager.register('Test 2') { puts '2' }

    assert_equal 2, @manager.rollback_stack.length

    @manager.clear

    assert_empty @manager.rollback_stack
  end

  def test_execute_runs_in_reverse_order
    executed = []

    @manager.register('First') { executed << 'first' }
    @manager.register('Second') { executed << 'second' }
    @manager.register('Third') { executed << 'third' }

    @manager.execute

    assert_equal %w[third second first], executed
  end

  def test_execute_clears_stack
    @manager.register('Test') { puts 'test' }

    @manager.execute

    assert_empty @manager.rollback_stack
  end

  def test_execute_continues_on_error
    executed = []

    @manager.register('First') { executed << 'first' }
    @manager.register('Failing') { raise 'error' }
    @manager.register('Third') { executed << 'third' }

    @manager.execute

    # Should execute all three (third first, then failing, then first)
    assert_equal %w[third first], executed
    assert_empty @manager.rollback_stack
  end

  def test_with_rollback_clears_on_success
    result = @manager.with_rollback(description: 'test operation') do
      @manager.register('Test') { puts 'test' }
      'success'
    end

    assert_equal 'success', result
    assert_empty @manager.rollback_stack
  end

  def test_with_rollback_executes_on_failure
    executed = false

    assert_raises(RuntimeError) do
      @manager.with_rollback(description: 'test operation') do
        @manager.register('Test') { executed = true }
        raise 'intentional failure'
      end
    end

    assert executed, 'Rollback should have been executed'
    assert_empty @manager.rollback_stack
  end

  def test_register_postgres_cluster_removal
    @manager.register_postgres_cluster_removal('host1', 16)

    rollback = @manager.rollback_stack.first
    assert_includes rollback[:description], 'PostgreSQL cluster'
    assert_includes rollback[:description], 'host1'
    assert_equal 'host1', rollback[:host]
  end

  def test_register_package_removal
    @manager.register_package_removal('host1', %w[pkg1 pkg2])

    rollback = @manager.rollback_stack.first
    assert_includes rollback[:description], 'packages'
    assert_includes rollback[:description], 'pkg1, pkg2'
  end

  def test_register_file_removal
    @manager.register_file_removal('host1', '/path/to/file')

    rollback = @manager.rollback_stack.first
    assert_includes rollback[:description], 'Remove file'
    assert_includes rollback[:description], '/path/to/file'
  end

  def test_register_directory_removal
    @manager.register_directory_removal('host1', '/path/to/dir')

    rollback = @manager.rollback_stack.first
    assert_includes rollback[:description], 'Remove directory'
    assert_includes rollback[:description], '/path/to/dir'
  end

  def test_register_user_removal
    @manager.register_user_removal('host1', 'testuser')

    rollback = @manager.rollback_stack.first
    assert_includes rollback[:description], 'Remove user'
    assert_includes rollback[:description], 'testuser'
  end

  def test_register_database_removal
    @manager.register_database_removal('host1', 'testdb')

    rollback = @manager.rollback_stack.first
    assert_includes rollback[:description], 'Drop database'
    assert_includes rollback[:description], 'testdb'
  end

  def test_register_postgres_user_removal
    @manager.register_postgres_user_removal('host1', 'pguser')

    rollback = @manager.rollback_stack.first
    assert_includes rollback[:description], 'Drop PostgreSQL user'
    assert_includes rollback[:description], 'pguser'
  end
end
