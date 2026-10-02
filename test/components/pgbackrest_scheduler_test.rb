require 'test_helper'

class PgBackRestSchedulerTest < Minitest::Test
  def test_install_requires_running_cron_after_configuring_primary_and_standby_schedules
    [true, false].each do |primary|
      host = 'db.example.com'
      config = stub_config(primary_host: host, component_config: {
                             pgbackrest: { repo_type: 'local', schedule_full: '0 2 * * 0' }
                           })
      calls = []
      backend = Object.new
      backend.define_singleton_method(:execute) { |*args| calls << args }
      executor = Object.new
      executor.define_singleton_method(:execute_on_host) { |_host, &block| backend.instance_exec(&block) }
      executor.define_singleton_method(:upload_file) { |_host, _content, path, **_options| calls << [:upload, path] }
      component = ActivePostgres::Components::PgBackRest.new(config, executor, ActivePostgres::Secrets.new(config))
      component.define_singleton_method(:upload_template) { |*_args, **_options| nil }

      component.send(:install_on_host, host, create_stanza: primary)

      cron_install = calls.index { |args| args.include?('apt-get') && args.last == 'cron' }
      cron_enable = calls.index([:sudo, 'systemctl', 'enable', '--now', 'cron'])
      cron_check = calls.index([:sudo, 'systemctl', 'is-active', '--quiet', 'cron'])
      schedule = if primary
                   calls.index([:upload, '/etc/cron.d/pgbackrest-backup'])
                 else
                   calls.index([:sudo, 'rm', '-f', '/etc/cron.d/pgbackrest-backup-incremental'])
                 end
      assert_operator schedule, :<, cron_install
      assert_operator cron_install, :<, cron_enable
      assert_operator cron_enable, :<, cron_check
      refute_includes calls, [:sudo, 'systemctl', 'restart', 'postgresql']
    end
  end
end
