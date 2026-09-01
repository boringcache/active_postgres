module ActivePostgres
  class Configuration
    module PgBackRestPolicy
      private

      def validate_pgbackrest!
        return unless component_enabled?(:pgbackrest)

        pg_config = component_config(:pgbackrest)
        retention_full = pg_config[:retention_full]
        retention_archive = pg_config[:retention_archive]
        if retention_full && retention_archive && retention_archive.to_i < retention_full.to_i
          raise Error, 'pgbackrest.retention_archive must be >= retention_full for PITR safety'
        end
        raise Error, 'pgbackrest.repo_block requires repo_bundle' if pg_config[:repo_block] && !pg_config[:repo_bundle]
      end
    end
  end
end
