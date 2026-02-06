require 'sshkit'
require 'sshkit/dsl'
require 'securerandom'

module ActivePostgres
  class SSHExecutor
    include SSHKit::DSL

    attr_reader :config

    def initialize(config, quiet: false)
      @config = config
      @quiet = quiet
      setup_sshkit
    end

    def quiet?
      @quiet
    end

    def execute_on_host(host, &)
      on("#{config.user}@#{host}", &)
    end

    def execute_on_host_as(host, user, &)
      on("#{user}@#{host}", &)
    end

    def execute_on_primary(&)
      execute_on_host(config.primary_host, &)
    end

    def execute_on_standbys(&)
      hosts = config.standby_hosts.map { |h| "#{config.user}@#{h}" }
      on(hosts, in: :parallel, &)
    end

    def execute_on_all_hosts(&)
      hosts = config.all_hosts.map { |h| "#{config.user}@#{h}" }
      on(hosts, in: :parallel, &)
    end

    def install_postgres(host, version = 18)
      execute_on_host(host) do
        info "Installing PostgreSQL #{version}..."

        if test('[ -f /etc/apt/sources.list.d/pgdg.list ]')
          execute :sudo, 'rm', '-f',
                  '/etc/apt/sources.list.d/pgdg.list'
        end

        execute :sudo, 'apt-get', 'update', '-qq'
        execute :sudo, 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'install', '-y', '-qq', 'gnupg', 'wget',
                'lsb-release', 'locales'

        info 'Generating locales...'
        execute :sudo, 'locale-gen', 'en_US.UTF-8'
        execute :sudo, 'update-locale', 'LANG=en_US.UTF-8'

        # Check for any installed PostgreSQL server packages
        if test('command -v pg_lsclusters')
          existing_clusters = capture(:pg_lsclusters, '-h').split("\n")
          installed_versions = existing_clusters.map { |line| line.split[0].to_i }.uniq.sort

          # Check if we have different versions installed
          other_versions = installed_versions - [version]

          if other_versions.any?
            info "Found PostgreSQL version(s) #{other_versions.join(', ')}, cleaning up for fresh PostgreSQL #{version} install..."

            # Stop all PostgreSQL services
            execute :sudo, 'systemctl', 'stop', 'postgresql' if test('systemctl is-active postgresql')

            # Remove all PostgreSQL packages
            execute :sudo, 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'remove', '--purge', '-y', '-qq', 'postgresql*'
            execute :sudo, 'apt-get', 'autoremove', '-y', '-qq'

            # Clean up OLD version directories only (preserve target version SSL certs, etc.)
            other_versions.each do |old_version|
              execute :sudo, 'rm', '-rf', "/etc/postgresql/#{old_version}"
              execute :sudo, 'rm', '-rf', "/var/lib/postgresql/#{old_version}"
            end

            execute :sudo, 'rm', '-f', '/etc/apt/sources.list.d/pgdg.list'
            execute :sudo, 'rm', '-f', '/usr/share/keyrings/postgresql-archive-keyring.gpg'

            info 'Cleanup complete'
          elsif installed_versions.include?(version)
            info "PostgreSQL #{version} already installed, skipping cleanup"
          end
        end

        info 'Ensuring PostgreSQL GPG key is present...'
        execute :wget, '--quiet', '-O', '/tmp/pgdg.asc', 'https://www.postgresql.org/media/keys/ACCC4CF8.asc'
        execute :sudo, 'gpg', '--dearmor', '--yes', '-o', '/usr/share/keyrings/postgresql-archive-keyring.gpg',
                '/tmp/pgdg.asc'
        execute :rm, '/tmp/pgdg.asc'

        info 'Configuring PostgreSQL apt repository...'
        pgdg_repo = "'echo \"deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] " \
                    'https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > ' \
                    "/etc/apt/sources.list.d/pgdg.list'"
        execute :sudo, 'sh', '-c', pgdg_repo

        execute :sudo, 'apt-get', 'update', '-qq'
        execute :sudo, 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'install', '-y', '-qq', "postgresql-#{version}",
                "postgresql-client-#{version}"

        execute :sudo, 'systemctl', 'enable', 'postgresql'
        execute :sudo, 'systemctl', 'start', 'postgresql' unless test('systemctl is-active postgresql')
      end
    end

    def upload_file(host, content, remote_path, mode: '644', owner: nil)
      execute_on_host(host) do
        temp_file = "/tmp/#{File.basename(remote_path)}"
        upload! StringIO.new(content), temp_file

        execute :sudo, 'mv', temp_file, remote_path
        execute :sudo, 'chown', owner, remote_path if owner
        execute :sudo, 'chmod', mode, remote_path
      end
    end

    def ensure_postgres_user(host)
      postgres_user = config.postgres_user

      execute_on_host(host) do
        execute :sudo, 'groupadd', '--system', postgres_user unless test(:getent, 'group', postgres_user)

        unless test(:id, postgres_user)
          execute :sudo, 'useradd', '--system', '--home', '/var/lib/postgresql',
                  '--shell', '/bin/bash', '--gid', postgres_user, '--create-home', postgres_user
        end
      end
    end

    def postgres_running?(host)
      result = false
      execute_on_host(host) do
        # Check if any PostgreSQL cluster is online using pg_lsclusters
        # This works regardless of whether it's the generic postgresql service
        # or a specific postgresql@version-main service
        clusters = begin
          capture(:sudo, 'pg_lsclusters', '2>/dev/null')
        rescue StandardError
          ''
        end
        result = clusters.include?('online')
      end
      result
    end

    def restart_postgres(host, version = nil)
      execute_on_host(host) do
        if version
          begin
            execute :sudo, 'pg_ctlcluster', version.to_s, 'main', 'restart'
          rescue StandardError => e
            error "Failed to restart PostgreSQL cluster #{version}/main"
            info 'Checking systemd logs...'
            logs = begin
              capture(:sudo, 'journalctl', '-xeu', "postgresql@#{version}-main", '-n', '50',
                      '--no-pager')
            rescue StandardError
              'Could not get systemd logs'
            end
            info logs
            info 'Checking PostgreSQL logs...'
            pg_logs = begin
              capture(:sudo, 'tail', '-100',
                      "/var/log/postgresql/postgresql-#{version}-main.log")
            rescue StandardError
              'Could not get PostgreSQL logs'
            end
            info pg_logs
            info 'Checking cluster status...'
            cluster_status = begin
              capture(:sudo, 'pg_lsclusters')
            rescue StandardError
              'Could not get cluster status'
            end
            info cluster_status
            raise e
          end
        else
          execute :sudo, 'systemctl', 'restart', 'postgresql'
        end
      end
    end

    def stop_postgres(host)
      execute_on_host(host) do
        execute :sudo, 'systemctl', 'stop', 'postgresql'
      end
    end

    def get_postgres_status(host)
      result = nil
      postgres_user = config.postgres_user
      execute_on_host(host) do
        result = capture(:sudo, '-u', postgres_user, 'psql', '-c', 'SELECT version();')
      end
      result
    end

    def run_sql(host, sql, postgres_user: config.postgres_user, port: nil, database: nil, tuples_only: true,
                capture: true)
      result = nil
      executor = self
      execute_on_host(host) do
        backend = self
        result = executor.run_sql_on_backend(backend, sql,
                                    postgres_user: postgres_user,
                                    port: port,
                                    database: database,
                                    tuples_only: tuples_only,
                                    capture: capture)
      end
      result
    end

    def run_sql_on_backend(backend, sql, postgres_user: config.postgres_user, port: nil, database: nil,
                           tuples_only: true, capture: true)
      # Use a temporary file to avoid shell escaping issues with special characters
      temp_file = "/tmp/active_postgres_#{SecureRandom.hex(8)}.sql"
      backend.upload! StringIO.new(sql), temp_file
      backend.execute :chmod, '600', temp_file
      backend.execute :sudo, 'chown', "#{postgres_user}:#{postgres_user}", temp_file

      cmd = [:sudo, '-u', postgres_user, 'psql']
      cmd << '-t' if tuples_only
      cmd += ['-p', port.to_s] if port
      cmd += ['-d', database.to_s] if database
      cmd += ['-f', temp_file]

      result = capture ? backend.capture(*cmd) : backend.execute(*cmd)
      result
    ensure
      backend.execute :sudo, 'rm', '-f', temp_file
    end

    def ensure_cluster_exists(host, version)
      execute_on_host(host) do
        data_dir = "/var/lib/postgresql/#{version}/main"

        if test(:sudo, 'test', '-d', data_dir)
          info "PostgreSQL #{version}/main cluster already exists, skipping creation"
        else
          info 'Creating PostgreSQL cluster...'
          execute :sudo, 'pg_createcluster', version.to_s, 'main', '--start'
        end
      end
    end

    def recreate_cluster(host, version)
      execute_on_host(host) do
        info 'Ensuring clean cluster state...'
        begin
          execute :sudo, 'systemctl', 'stop', 'postgresql'
        rescue StandardError
          nil
        end
        begin
          execute :sudo, 'pg_dropcluster', '--stop', version.to_s, 'main'
        rescue StandardError
          nil
        end
        begin
          execute :sudo, 'rm', '-rf', "/etc/postgresql/#{version}/main"
        rescue StandardError
          nil
        end
        begin
          execute :sudo, 'rm', '-rf', "/var/lib/postgresql/#{version}/main"
        rescue StandardError
          nil
        end

        info 'Creating fresh PostgreSQL cluster...'
        execute :sudo, 'pg_createcluster', version.to_s, 'main'
        execute :sudo, 'systemctl', 'start', 'postgresql'
      end
    end

    private

    def setup_sshkit
      if @quiet
        SSHKit.config.output_verbosity = ::Logger::FATAL
        SSHKit.config.format = :blackhole
      else
        SSHKit.config.output_verbosity = ::Logger::INFO
        SSHKit.config.format = :pretty
      end

      SSHKit::Backend::Netssh.configure do |ssh|
        options = {
          forward_agent: false,
          auth_methods: ['publickey'],
          verify_host_key: config.ssh_host_key_verification || :always,
          timeout: 10,
          number_of_password_prompts: 0
        }

        if config.ssh_key && File.exist?(config.ssh_key)
          options[:keys] = [config.ssh_key]
          options[:keys_only] = true
        end

        ssh.ssh_options = options
      end
    end
  end
end
