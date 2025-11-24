module ActivePostgres
  module ComponentResolver
    def component_class_for(component_name)
      case component_name.to_s.downcase
      when 'core'
        Components::Core
      when 'repmgr'
        Components::Repmgr
      when 'pgbouncer'
        Components::PgBouncer
      when 'pgbackrest'
        Components::PgBackRest
      when 'monitoring'
        Components::Monitoring
      when 'ssl'
        Components::SSL
      when 'extensions'
        Components::Extensions
      else
        raise Error, "Unknown component: #{component_name}"
      end
    end
  end
end
