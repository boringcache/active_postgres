module ActivePostgres
  module Rails
    module MigrationGuard
      def exec_migration(conn, direction)
        # Check if we're connected to a read replica
        if connection_is_replica?(conn)
          raise ActiveRecord::MigrationError,
                'Cannot run migrations on read replica! Connect to primary database.'
        end

        super
      end

      private

      def connection_is_replica?(conn)
        # Check if PostgreSQL is in recovery mode (i.e., it's a replica)
        result = conn.execute('SELECT pg_is_in_recovery();')
        result.first['pg_is_in_recovery'] == 't'
      rescue StandardError
        false
      end
    end
  end
end
