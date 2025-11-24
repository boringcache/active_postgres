require 'simplecov'
SimpleCov.start do
  add_filter '/test/'
  add_filter '/vendor/'
  add_group 'Components', 'lib/active_postgres/components'
  add_group 'Core', 'lib/active_postgres'
end

begin
  require 'bundler/setup'
rescue StandardError => e
  warn "Skipping bundler/setup: #{e.message}" if ENV['VERBOSE']
end

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'active_postgres'
require 'minitest/autorun'

module TestHelpers
  class ConfigStub
    attr_accessor :primary_host, :standby_hosts, :version, :primary, :standbys, :environment, :secrets_config, :ssh_key, :user, :postgres_user,
                  :pgbouncer_user, :app_user, :app_database, :repmgr_user, :repmgr_database

    def initialize(attrs = {})
      @primary_host = attrs[:primary_host]
      @standby_hosts = attrs[:standby_hosts]
      @version = attrs[:version]
      @primary = attrs[:primary]
      @standbys = attrs[:standbys]
      @environment = attrs[:environment] || 'test'
      @secrets_config = attrs[:secrets_config] || {}
      @ssh_key = attrs[:ssh_key] || '~/.ssh/id_rsa'
      @user = attrs[:user] || 'ubuntu'
      @postgres_user = attrs[:postgres_user] || 'postgres'
      @pgbouncer_user = attrs[:pgbouncer_user] || 'pgbouncer'
      @app_user = attrs[:app_user] || 'app'
      @app_database = attrs[:app_database] || 'app_production'
      @repmgr_user = attrs[:repmgr_user] || 'repmgr'
      @repmgr_database = attrs[:repmgr_database] || 'repmgr'
      @component_enabled_override = attrs.fetch(:component_enabled?, false)
      @component_config_override = attrs.fetch(:component_config, {})
    end

    def component_enabled?(name)
      !!evaluate_override(@component_enabled_override, name)
    end

    def component_config(name)
      evaluate_override(@component_config_override, name) || {}
    end

    def primary_replication_host
      replication_host_for(primary_host)
    end

    def replication_host_for(host)
      if host == primary_host
        primary['private_ip'] || primary_host
      else
        standby_config_for(host)&.fetch('private_ip', nil) || host
      end
    end

    def standby_config_for(host)
      standbys.find { |s| s['host'] == host }
    end

    private

    def evaluate_override(override, arg)
      case override
      when Proc
        override.call(arg)
      when Hash
        override[arg]
      else
        override
      end
    end
  end

  def stub_config(**overrides)
    defaults = {
      primary_host: 'primary.example.com',
      standby_hosts: ['standby.example.com'],
      version: 16,
      primary: { 'host' => 'primary.example.com', 'private_ip' => '10.0.0.10' },
      standbys: [
        { 'host' => 'standby.example.com', 'private_ip' => '10.0.0.11' }
      ],
      secrets_config: {},
      component_enabled?: false,
      component_config: Hash.new { |h, k| h[k] = {} }
    }

    ConfigStub.new(defaults.merge(overrides))
  end
end

Minitest::Test.include(TestHelpers)
