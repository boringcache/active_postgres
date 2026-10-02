module ActivePostgres
  class Configuration
    module NodeIdentity
      def node_id_for(host)
        node = node_config_for(host)
        raise Error, "Unknown PostgreSQL host: #{host}" unless node

        value = node.fetch('node_id') { host == primary_host ? 1 : standby_hosts.index(host) + 2 }
        raise Error, "node_id for #{host} must be a positive 32-bit integer" unless value.is_a?(Integer) && value.between?(1, 2_147_483_647)

        value
      end

      private

      def validate_node_ids!
        node_ids = all_hosts.map { |host| node_id_for(host) }
        raise Error, 'PostgreSQL node_id values must be unique' unless node_ids.uniq.size == node_ids.size
      end
    end
  end
end
