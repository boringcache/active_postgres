module ActivePostgres
  module Components
    class Base
      attr_reader :config, :ssh_executor, :secrets

      def initialize(config, ssh_executor, secrets)
        @config = config
        @ssh_executor = ssh_executor
        @secrets = secrets
      end

      def install
        raise NotImplementedError, 'Subclass must implement #install'
      end

      def uninstall
        raise NotImplementedError, 'Subclass must implement #uninstall'
      end

      def restart
        raise NotImplementedError, 'Subclass must implement #restart'
      end

      protected

      def substitute_private_ip(pg_config, private_ip)
        pg_config.transform_values do |value|
          if value.is_a?(String)
            value.gsub('${private_ip}', private_ip)
          else
            value
          end
        end
      end

      def render_template(template_name, binding_context)
        template_path = File.join(ActivePostgres.root, 'templates', template_name)
        template = ERB.new(File.read(template_path), trim_mode: '-')
        template.result(binding_context)
      end

      def upload_template(host, template_name, remote_path, binding_context, mode: '644', owner: nil)
        content = render_template(template_name, binding_context)
        ssh_executor.upload_file(host, content, remote_path, mode: mode, owner: owner)
      end
    end
  end
end
