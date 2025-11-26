if defined?(Rails::Railtie)
  require 'rails/railtie'

  module ActivePostgres
    class Railtie < ::Rails::Railtie
      railtie_name :active_postgres

      rake_tasks do
        Dir[File.expand_path('../tasks/**/*.rake', __dir__)].each { |f| load f }
      end

      generators do
        require_relative 'generators/active_postgres/install_generator'
      end

      initializer 'active_postgres.migration_guard' do
        ::ActiveSupport.on_load(:active_record) do
          require_relative 'rails/migration_guard'
          ::ActiveRecord::Migration.prepend(ActivePostgres::Rails::MigrationGuard)
        end
      end

      console do
        puts 'ActivePostgres loaded. Try: ActivePostgres.status'
      end
    end
  end
end
