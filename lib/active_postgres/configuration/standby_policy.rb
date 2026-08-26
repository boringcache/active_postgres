module ActivePostgres
  class Configuration
    module StandbyPolicy
      def standby_seed_method_for(host)
        (standby_config_for(host)&.fetch('seed_method', nil) || 'repmgr').to_s.to_sym
      end

      private

      def validate_standby_seed_methods!
        @standbys.each do |standby|
          host = standby.fetch('host')
          seed_method = standby_seed_method_for(host)
          unless %i[repmgr pgbackrest].include?(seed_method)
            raise Error, "Invalid seed_method '#{seed_method}' for standby #{host}. Use 'repmgr' or 'pgbackrest'."
          end
          if seed_method == :pgbackrest && !component_enabled?(:pgbackrest)
            raise Error, "Standby #{host} requires the pgbackrest component for seed_method 'pgbackrest'"
          end
        end
      end
    end
  end
end
