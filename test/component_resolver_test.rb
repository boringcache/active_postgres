require 'test_helper'

class ComponentResolverTest < Minitest::Test
  class TestClass
    include ActivePostgres::ComponentResolver
  end

  def setup
    @resolver = TestClass.new
  end

  def test_resolves_core_component
    assert_equal ActivePostgres::Components::Core, @resolver.component_class_for('core')
  end

  def test_resolves_repmgr_component
    assert_equal ActivePostgres::Components::Repmgr, @resolver.component_class_for('repmgr')
  end

  def test_resolves_pgbouncer_component
    assert_equal ActivePostgres::Components::PgBouncer, @resolver.component_class_for('pgbouncer')
  end

  def test_resolves_pgbackrest_component
    assert_equal ActivePostgres::Components::PgBackRest, @resolver.component_class_for('pgbackrest')
  end

  def test_resolves_monitoring_component
    assert_equal ActivePostgres::Components::Monitoring, @resolver.component_class_for('monitoring')
  end

  def test_resolves_ssl_component
    assert_equal ActivePostgres::Components::SSL, @resolver.component_class_for('ssl')
  end

  def test_resolves_extensions_component
    assert_equal ActivePostgres::Components::Extensions, @resolver.component_class_for('extensions')
  end

  def test_resolves_case_insensitive
    assert_equal ActivePostgres::Components::Core, @resolver.component_class_for('CORE')
    assert_equal ActivePostgres::Components::Repmgr, @resolver.component_class_for('RepmGr')
  end

  def test_raises_error_for_unknown_component
    error = assert_raises(ActivePostgres::Error) do
      @resolver.component_class_for('unknown')
    end
    assert_match(/Unknown component: unknown/, error.message)
  end
end
