module ActivePostgres
  module Components
    class Extensions < Base
      EXTENSION_PACKAGES = {
        'pgvector' => 'postgresql-{version}-pgvector',
        'postgis' => 'postgresql-{version}-postgis-3',
        'pg_trgm' => nil, # Built-in, no package needed
        'hstore' => nil, # Built-in
        'uuid-ossp' => nil, # Built-in
        'ltree' => nil, # Built-in
        'citext' => nil, # Built-in
        'unaccent' => nil, # Built-in
        'pg_stat_statements' => nil, # Built-in
        'timescaledb' => 'timescaledb-2-postgresql-{version}',
        'citus' => 'postgresql-{version}-citus-12.1',
        'pg_partman' => 'postgresql-{version}-partman'
      }.freeze

      def install
        extensions_config = config.component_config(:extensions)
        return unless extensions_config[:enabled]

        extensions = extensions_config[:list] || []
        return if extensions.empty?

        puts 'Installing PostgreSQL extensions...'

        install_on_primary(extensions)
        install_on_standbys(extensions) if config.standbys.any?
      end

      def uninstall
        puts 'Extensions uninstall not implemented (extensions remain in database)'
      end

      def restart
        puts 'Extensions do not require restart (loaded at database connection time)'
      end

      def install_on_standby(standby_host)
        extensions_config = config.component_config(:extensions)
        return unless extensions_config[:enabled]

        extensions = extensions_config[:list] || []
        return if extensions.empty?

        puts "Installing extension packages on standby #{standby_host}..."
        install_packages_on_host(standby_host, extensions)
      end

      private

      def install_packages_on_host(host, extensions)
        version = config.version
        packages_to_install = []

        extensions.each do |ext_name|
          package = EXTENSION_PACKAGES[ext_name]
          next unless package

          package = package.gsub('{version}', version.to_s)
          packages_to_install << package
        end

        return if packages_to_install.empty?

        ssh_executor.execute_on_host(host) do
          execute :sudo, 'apt-get', '-o', 'DPkg::Lock::Timeout=300', 'update', '-qq'
        end
        install_apt_packages(host, *packages_to_install)
      end

      def install_on_primary(extensions)
        host = config.primary_host
        db_name = config.secrets_config['database_name'] || 'postgres'
        postgres_user = config.postgres_user

        puts "  Installing extensions on primary (#{host})..."

        install_packages_on_host(host, extensions)

        ssh_executor.execute_on_host(host) do
          extensions.each do |ext_name|
            sql = "CREATE EXTENSION IF NOT EXISTS \"#{ext_name}\";"
            begin
              execute :sudo, '-u', postgres_user, 'psql', '-d', db_name, '-c', sql
              info "✓ Extension #{ext_name} created/verified"
            rescue StandardError => e
              warn "⚠ Could not create extension #{ext_name}: #{e.message}"
            end
          end
        end
      end

      def install_on_standbys(extensions)
        config.standby_hosts.each do |host|
          puts "  Installing extension packages on standby (#{host})..."
          install_packages_on_host(host, extensions)
        end
      end
    end
  end
end
