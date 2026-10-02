require 'test_helper'

class ConfigurationNodeIdentityTest < Minitest::Test
  def test_legacy_configuration_keeps_position_based_ids
    config = configuration({ 'host' => 'a' }, [{ 'host' => 'b' }])

    assert config.validate!
    assert_equal 1, config.node_id_for('a')
    assert_equal 2, config.node_id_for('b')
  end

  def test_explicit_identities_survive_switchover_and_standby_reordering
    nodes = %w[a b c].each_with_index.map { |host, index| { 'host' => host, 'node_id' => index + 1 } }
    before = configuration(nodes[0], [nodes[1], nodes[2]])
    after = configuration(nodes[2], [nodes[1], nodes[0]])

    assert before.validate!
    assert after.validate!
    nodes.each do |node|
      assert_equal before.node_id_for(node['host']), after.node_id_for(node['host'])
    end
  end

  def test_rejects_explicit_and_implicit_id_collision
    config = configuration({ 'host' => 'a', 'node_id' => 2 }, [{ 'host' => 'b' }])

    error = assert_raises(ActivePostgres::Error) { config.validate! }
    assert_match(/must be unique/, error.message)
  end

  def test_rejects_invalid_ids_before_rendering_sql_or_configuration
    [0, -1, 2_147_483_648, '3', '1; DROP TABLE nodes', nil, 1.5].each do |value|
      config = configuration({ 'host' => 'a', 'node_id' => value }, [])
      assert_raises(ActivePostgres::Error) { config.validate! }
    end
  end

  private

  def configuration(primary, standbys)
    ActivePostgres::Configuration.new({ 'production' => { 'primary' => primary, 'standby' => standbys } }, 'production')
  end
end
