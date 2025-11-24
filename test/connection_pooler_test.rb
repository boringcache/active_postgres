require 'test_helper'

class ConnectionPoolerTest < Minitest::Test
  def test_calculate_optimal_pool_sizes_for_small_connections
    result = ActivePostgres::ConnectionPooler.calculate_optimal_pool_sizes(50)

    assert_equal 20, result[:default_pool_size]  # (50 * 0.8 / 4) = 10, clamped to min of 20
    assert_equal 500, result[:max_client_conn]   # 50 * 10
    assert_equal 5, result[:reserve_pool_size]
  end

  def test_calculate_optimal_pool_sizes_for_medium_connections
    result = ActivePostgres::ConnectionPooler.calculate_optimal_pool_sizes(200)

    assert_equal 40, result[:default_pool_size]  # (200 * 0.8 / 4) = 40
    assert_equal 2000, result[:max_client_conn]  # 200 * 10
    assert_equal 5, result[:reserve_pool_size]
  end

  def test_calculate_optimal_pool_sizes_for_large_connections
    result = ActivePostgres::ConnectionPooler.calculate_optimal_pool_sizes(500)

    assert_equal 100, result[:default_pool_size]  # (500 * 0.8 / 4) = 100, clamped to max
    assert_equal 5000, result[:max_client_conn]   # 500 * 10
    assert_equal 5, result[:reserve_pool_size]
  end

  def test_calculate_default_pool_size_static_clamps_to_bounds
    # Test minimum bound
    assert_equal 20, ActivePostgres::ConnectionPooler.calculate_default_pool_size_static(10)

    # Test maximum bound
    assert_equal 100, ActivePostgres::ConnectionPooler.calculate_default_pool_size_static(1000)

    # Test middle range
    assert_equal 40, ActivePostgres::ConnectionPooler.calculate_default_pool_size_static(200)
  end
end
