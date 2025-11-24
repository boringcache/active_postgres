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

      private

      def install_on_primary(extensions)
        host = config.primary_host
        version = config.version
        db_name = config.secrets_config['database_name'] || 'postgres'
        postgres_user = config.postgres_user

        puts "  Installing extensions on primary (#{host})..."

        packages_to_install = []
        extensions.each do |ext_name|
          package = EXTENSION_PACKAGES[ext_name]
          next unless package

          package = package.gsub('{version}', version.to_s)
          packages_to_install << package
        end

        ssh_executor.execute_on_host(host) do
          unless packages_to_install.empty?
            execute :sudo, 'apt-get', 'update', '-qq'
            execute :sudo, 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'install', '-y', '-qq',
                    *packages_to_install
          end

          extensions.each do |ext_name|
            sql = "CREATE EXTENSION IF NOT EXISTS #{ext_name};"
            begin
              execute :sudo, '-u', postgres_user, 'psql', '-d', db_name, '-c', sql
            rescue StandardError
              nil
            end
          end
        end
      end

      def install_on_standbys(extensions)
        version = config.version

        config.standby_hosts.each do |host|
          puts "  Installing extensions on standby (#{host})..."

          packages_to_install = []
          extensions.each do |ext_name|
            package = EXTENSION_PACKAGES[ext_name]
            next unless package

            package = package.gsub('{version}', version.to_s)
            packages_to_install << package
          end

          ssh_executor.execute_on_host(host) do
            unless packages_to_install.empty?
              execute :sudo, 'apt-get', 'update', '-qq'
              execute :sudo, 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'install', '-y', '-qq',
                      *packages_to_install
            end
          end
        end
      end
    end
  end
end
