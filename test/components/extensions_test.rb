require 'test_helper'

class ExtensionsTest < Minitest::Test
  def test_extension_packages_mapping
    packages = ActivePostgres::Components::Extensions::EXTENSION_PACKAGES

    assert_equal 'postgresql-{version}-pgvector', packages['pgvector']
    assert_equal 'postgresql-{version}-postgis-3', packages['postgis']
    assert_nil packages['pg_trgm']
    assert_nil packages['hstore']
    assert_nil packages['uuid-ossp']
  end

  def test_built_in_extensions_have_no_package
    packages = ActivePostgres::Components::Extensions::EXTENSION_PACKAGES
    built_ins = %w[pg_trgm hstore uuid-ossp ltree citext unaccent pg_stat_statements]

    built_ins.each do |ext|
      assert_nil packages[ext], "#{ext} should be built-in (no package)"
    end
  end

  def test_version_substitution_in_package_name
    package_template = 'postgresql-{version}-pgvector'
    version = 16

    package = package_template.gsub('{version}', version.to_s)

    assert_equal 'postgresql-16-pgvector', package
  end

  def test_extension_sql_generation
    ext_name = 'pgvector'
    sql = "CREATE EXTENSION IF NOT EXISTS \"#{ext_name}\";"

    assert_equal 'CREATE EXTENSION IF NOT EXISTS "pgvector";', sql
  end

  def test_extension_sql_handles_special_names
    ext_name = 'uuid-ossp'
    sql = "CREATE EXTENSION IF NOT EXISTS \"#{ext_name}\";"

    assert_equal 'CREATE EXTENSION IF NOT EXISTS "uuid-ossp";', sql
  end

  def test_restart_does_not_fail
    config = stub_config(
      component_config: { extensions: { enabled: true, list: ['pgvector'] } }
    )

    ssh_executor = Minitest::Mock.new
    secrets = Minitest::Mock.new
    extensions = ActivePostgres::Components::Extensions.new(config, ssh_executor, secrets)

    assert_output(/do not require restart/) do
      extensions.restart
    end
  end

  def test_install_on_standby_only_installs_packages
    config = stub_config(
      primary_host: 'primary.example.com',
      standby_hosts: ['standby.example.com'],
      version: 16,
      component_config: {
        extensions: { enabled: true, list: ['pgvector', 'pg_trgm'] }
      }
    )

    ssh_executor = Minitest::Mock.new
    secrets = Minitest::Mock.new
    extensions = ActivePostgres::Components::Extensions.new(config, ssh_executor, secrets)

    packages_installed_on = nil
    extensions.define_singleton_method(:install_packages_on_host) do |host, _exts|
      packages_installed_on = host
    end

    extensions.install_on_standby('standby.example.com')

    assert_equal 'standby.example.com', packages_installed_on
  end

  def test_install_on_standby_skips_when_disabled
    config = stub_config(
      component_config: { extensions: { enabled: false } }
    )

    ssh_executor = Minitest::Mock.new
    secrets = Minitest::Mock.new
    extensions = ActivePostgres::Components::Extensions.new(config, ssh_executor, secrets)

    packages_called = false
    extensions.define_singleton_method(:install_packages_on_host) do |_host, _exts|
      packages_called = true
    end

    extensions.install_on_standby('standby.example.com')

    refute packages_called, 'Should not install packages when extensions disabled'
  end

  def test_install_on_standby_skips_empty_list
    config = stub_config(
      component_config: { extensions: { enabled: true, list: [] } }
    )

    ssh_executor = Minitest::Mock.new
    secrets = Minitest::Mock.new
    extensions = ActivePostgres::Components::Extensions.new(config, ssh_executor, secrets)

    packages_called = false
    extensions.define_singleton_method(:install_packages_on_host) do |_host, _exts|
      packages_called = true
    end

    extensions.install_on_standby('standby.example.com')

    refute packages_called, 'Should not install packages when list is empty'
  end
end
