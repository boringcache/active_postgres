require 'test_helper'
require 'tempfile'

class SSHExecutorTest < Minitest::Test
  def test_standby_can_connect_through_a_declared_jump_host
    Tempfile.create('known-hosts') do |known_hosts|
      config = build_config(
        'ssh_key' => File::NULL,
        'ssh_known_hosts_file' => known_hosts.path,
        'ssh_host_key_verification' => 'accept_new',
        'jump_hosts' => {
          'app-oci' => { 'host' => '1.2.3.4', 'user' => 'ubuntu' }
        },
        'standby' => [
          { 'host' => '5.6.7.8', 'private_ip' => '10.0.0.11', 'jump_host' => 'app-oci' }
        ]
      )
      executor = ActivePostgres::SSHExecutor.new(config, quiet: true)

      host = executor.send(:ssh_host_for, '5.6.7.8')
      proxy = host.ssh_options.fetch(:proxy)

      assert_instance_of Net::SSH::Proxy::Command, proxy
      assert_equal [known_hosts.path], host.ssh_options.fetch(:user_known_hosts_file)
      assert_equal :accept_new, host.ssh_options.fetch(:verify_host_key)
      assert_includes proxy.command_line_template, 'ssh -F /dev/null'
      assert_includes proxy.command_line_template, '-o BatchMode\\=yes'
      assert_includes proxy.command_line_template, '-o ForwardAgent\\=no'
      assert_includes proxy.command_line_template, '-o StrictHostKeyChecking\\=accept-new'
      assert_includes proxy.command_line_template, "UserKnownHostsFile\\=#{known_hosts.path}"
      assert_includes proxy.command_line_template, '-W %h:%p ubuntu@1.2.3.4'
    end
  end

  def test_direct_host_does_not_receive_a_proxy
    config = build_config('standby' => [{ 'host' => '5.6.7.8', 'private_ip' => '10.0.0.11' }])
    executor = ActivePostgres::SSHExecutor.new(config, quiet: true)

    host = executor.send(:ssh_host_for, '5.6.7.8')

    refute host.ssh_options.key?(:proxy)
  end

  private

  def build_config(overrides)
    config = {
      'test' => {
        'primary' => { 'host' => 'primary.example.com' },
        'standby' => [{ 'host' => 'standby.example.com' }],
        'components' => {},
        'secrets' => {}
      }.merge(overrides)
    }

    ActivePostgres::Configuration.new(config, 'test')
  end
end
