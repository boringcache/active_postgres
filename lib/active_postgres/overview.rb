require 'shellwords'
require 'timeout'

module ActivePostgres
  class Overview
    DEFAULT_TIMEOUT = 10

    def initialize(config)
      @config = config
      @executor = SSHExecutor.new(config, quiet: true)
      @health_checker = HealthChecker.new(config)
    end

    def show
      puts
      puts "ActivePostgres Control Tower (#{config.environment})"
      puts '=' * 70
      puts

      health_checker.show_status

      show_system_stats
      show_repmgr_cluster if config.component_enabled?(:repmgr)
      show_pgbouncer_targets if config.component_enabled?(:pgbouncer)
      show_dns_status if dns_failover_enabled?
      show_backups if config.component_enabled?(:pgbackrest)

      puts
    end

    private

    attr_reader :config, :executor, :health_checker

    def show_repmgr_cluster
      output = nil
      postgres_user = config.postgres_user
      with_timeout('repmgr cluster') do
        executor.execute_on_host(config.primary_host) do
          output = capture(:sudo, '-u', postgres_user, 'repmgr', '-f', '/etc/repmgr.conf',
                           'cluster', 'show', raise_on_non_zero_exit: false).to_s
        end
      end

      puts '==> repmgr cluster'
      puts LogSanitizer.sanitize(output) if output && !output.strip.empty?
      puts
    rescue StandardError => e
      puts "==> repmgr cluster (error: #{e.message})"
      puts
    end

    def show_system_stats
      hosts = config.all_hosts
      return if hosts.empty?

      paths = system_stat_paths

      puts '==> System stats (DB nodes)'
      hosts.each do |host|
        label = config.node_label_for(host)
        stats = fetch_system_stats(host, paths)
        if stats.nil?
          puts "  #{host}#{label ? " (#{label})" : ''}: unavailable"
          next
        end

        mem_used_kb = stats[:mem_total_kb] - stats[:mem_avail_kb]
        mem_pct = stats[:mem_total_kb].positive? ? (mem_used_kb.to_f / stats[:mem_total_kb] * 100).round : 0

        puts "  #{host}#{label ? " (#{label})" : ''}: load #{stats[:loadavg]} | cpu #{stats[:cpu]}% | " \
             "mem #{format_kb(mem_used_kb)}/#{format_kb(stats[:mem_total_kb])} (#{mem_pct}%)"

        stats[:disks].each do |disk|
          puts "    disk #{disk[:mount]}: #{format_kb(disk[:used_kb])}/#{format_kb(disk[:total_kb])} (#{disk[:use_pct]})"
        end
      end
      puts
    rescue StandardError => e
      puts "==> System stats (error: #{e.message})"
      puts
    end

    def show_pgbouncer_targets
      puts '==> PgBouncer targets'
      config.all_hosts.each do |host|
        status = pgbouncer_status(host)
        target = pgbouncer_target(host)
        puts "  #{host}: #{status} -> #{target || 'unknown'}"
      end
      puts
    end

    def pgbouncer_status(host)
      status = nil
      executor.execute_on_host(host) do
        status = capture(:systemctl, 'is-active', 'pgbouncer', raise_on_non_zero_exit: false).to_s.strip
      end
      status == 'active' ? '✓ running' : '✗ down'
    rescue StandardError
      '✗ down'
    end

    def pgbouncer_target(host)
      ini = nil
      executor.execute_on_host(host) do
        ini = capture(:sudo, 'cat', '/etc/pgbouncer/pgbouncer.ini', raise_on_non_zero_exit: false).to_s
      end
      ini[/^\* = host=([^\s]+)/, 1]
    rescue StandardError
      nil
    end

    def show_dns_status
      dns_config = dns_failover_config
      dns_servers = normalize_dns_servers(dns_config[:dns_servers])
      dns_user = (dns_config[:dns_user] || config.user).to_s

      primary_records = normalize_dns_records(dns_config[:primary_records] || dns_config[:primary_record],
                                              default_prefix: 'db-primary',
                                              domains: normalize_dns_domains(dns_config))
      replica_records = normalize_dns_records(dns_config[:replica_records] || dns_config[:replica_record],
                                              default_prefix: 'db-replica',
                                              domains: normalize_dns_domains(dns_config))
      records = primary_records + replica_records

      puts '==> DNS (dnsmasq)'
      puts "  Servers: #{dns_servers.map { |s| s[:ssh_host] }.join(', ')}"

      record_map = Hash.new { |h, k| h[k] = [] }
      dns_servers.each do |server|
        content = dnsmasq_config(server[:ssh_host], dns_user)
        next if content.to_s.strip.empty?

        content.each_line do |line|
          next unless line.start_with?('address=/')

          match = line.strip.match(%r{\Aaddress=/([^/]+)/(.+)\z})
          next unless match

          name = match[1]
          ip = match[2]
          next unless records.include?(name)

          record_map[name] << ip
        end
      end

      records.uniq.each do |record|
        ips = record_map[record].uniq
        display = ips.empty? ? 'missing' : ips.join(', ')
        warn_suffix = if primary_records.include?(record) && ips.size > 1
                        ' ⚠️'
                      else
                        ''
                      end
        puts "  #{record}: #{display}#{warn_suffix}"
      end
      puts
    rescue StandardError => e
      puts "==> DNS (error: #{e.message})"
      puts
    end

    def dnsmasq_config(host, dns_user)
      content = nil
      with_timeout("dnsmasq #{host}") do
        executor.execute_on_host_as(host, dns_user) do
          content = capture(:sudo, 'sh', '-c',
                            'cat /etc/dnsmasq.d/active_postgres.conf 2>/dev/null || ' \
                            'cat /etc/dnsmasq.d/messhy.conf 2>/dev/null || true',
                            raise_on_non_zero_exit: false).to_s
        end
      end
      content
    rescue StandardError
      nil
    end

    def normalize_dns_servers(raw_servers)
      Array(raw_servers).map do |server|
        if server.is_a?(Hash)
          ssh_host = server[:ssh_host] || server['ssh_host'] || server[:host] || server['host']
          private_ip = server[:private_ip] || server['private_ip'] || server[:ip] || server['ip']
          private_ip ||= ssh_host
          ssh_host ||= private_ip
          { ssh_host: ssh_host.to_s, private_ip: private_ip.to_s }
        else
          value = server.to_s
          { ssh_host: value, private_ip: value }
        end
      end
    end

    def normalize_dns_domains(dns_config)
      Array(dns_config[:domains] || dns_config[:domain]).map(&:to_s).map(&:strip).reject(&:empty?)
    end

    def normalize_dns_records(value, default_prefix:, domains:)
      records = Array(value).map(&:to_s).map(&:strip).reject(&:empty?)
      return records unless records.empty?

      domains = ['mesh'] if domains.empty?
      domains.map { |domain| "#{default_prefix}.#{domain}" }
    end

    def show_backups
      output = nil
      postgres_user = config.postgres_user
      with_timeout('pgbackrest info') do
        executor.execute_on_host(config.primary_host) do
          output = capture(:sudo, '-u', postgres_user, 'pgbackrest', 'info',
                           raise_on_non_zero_exit: false).to_s
        end
      end

      puts '==> Backups (pgBackRest)'
      puts output if output && !output.strip.empty?
      puts
    rescue StandardError => e
      puts "==> Backups (error: #{e.message})"
      puts
    end

    def fetch_system_stats(host, paths)
      output = nil
      with_timeout("system stats #{host}") do
        ssh_executor = executor
        safe_paths = paths.map { |p| Shellwords.escape(p) }.join(' ')
        script = <<~'BASH'
          set -e
          loadavg=$(cut -d' ' -f1-3 /proc/loadavg)

          read _ user nice system idle iowait irq softirq steal _ _ < /proc/stat
          sleep 0.2
          read _ user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2 _ _ < /proc/stat

          total1=$((user + nice + system + idle + iowait + irq + softirq + steal))
          total2=$((user2 + nice2 + system2 + idle2 + iowait2 + irq2 + softirq2 + steal2))
          total=$((total2 - total1))
          idle_delta=$((idle2 + iowait2 - idle - iowait))

          cpu=0
          if [ "$total" -gt 0 ]; then
            cpu=$(( (100 * (total - idle_delta)) / total ))
          fi

          mem_total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
          mem_avail=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)

          echo "loadavg=${loadavg}"
          echo "cpu=${cpu}"
          echo "mem_total_kb=${mem_total}"
          echo "mem_avail_kb=${mem_avail}"
        BASH

        ssh_executor.execute_on_host(host) do
          output = capture(:bash, '-lc', "#{script}\n df -kP #{safe_paths} 2>/dev/null | tail -n +2 | " \
                                        "awk '{print \"disk=\" $6 \"|\" $2 \"|\" $3 \"|\" $4 \"|\" $5}'",
                           raise_on_non_zero_exit: false).to_s
        end
      end

      parse_system_stats(output)
    rescue StandardError
      nil
    end

    def parse_system_stats(output)
      stats = { disks: [] }
      output.to_s.each_line do |line|
        line = line.strip
        next if line.empty?

        if line.start_with?('loadavg=')
          stats[:loadavg] = line.split('=', 2)[1]
        elsif line.start_with?('cpu=')
          stats[:cpu] = line.split('=', 2)[1].to_i
        elsif line.start_with?('mem_total_kb=')
          stats[:mem_total_kb] = line.split('=', 2)[1].to_i
        elsif line.start_with?('mem_avail_kb=')
          stats[:mem_avail_kb] = line.split('=', 2)[1].to_i
        elsif line.start_with?('disk=')
          _, payload = line.split('=', 2)
          mount, total, used, _avail, pct = payload.split('|')
          stats[:disks] << {
            mount: mount,
            total_kb: total.to_i,
            used_kb: used.to_i,
            use_pct: pct
          }
        end
      end

      stats[:loadavg] ||= 'n/a'
      stats[:cpu] ||= 0
      stats[:mem_total_kb] ||= 0
      stats[:mem_avail_kb] ||= 0
      stats
    end

    def format_kb(kb)
      kb = kb.to_f
      gb = kb / 1024 / 1024
      return format('%.1fG', gb) if gb >= 1

      mb = kb / 1024
      format('%.0fM', mb)
    end

    def system_stat_paths
      paths = ['/']
      paths << '/var/lib/postgresql'
      repo_path = pgbackrest_repo_path
      paths << repo_path if repo_path
      paths.compact.uniq
    end

    def pgbackrest_repo_path
      return nil unless config.component_enabled?(:pgbackrest)

      pg_config = config.component_config(:pgbackrest)
      return pg_config[:repo_path] if pg_config[:repo_path]

      pg_config[:repo_type].to_s == 'local' ? '/var/lib/pgbackrest' : '/backups'
    end

    def dns_failover_config
      repmgr_config = config.component_config(:repmgr)
      dns_config = repmgr_config[:dns_failover]
      return nil unless dns_config && dns_config[:enabled]

      dns_config
    end

    def dns_failover_enabled?
      dns_failover_config != nil
    end

    def overview_timeout
      value = ENV.fetch('ACTIVE_POSTGRES_OVERVIEW_TIMEOUT', DEFAULT_TIMEOUT.to_s).to_i
      value.positive? ? value : DEFAULT_TIMEOUT
    end

    def with_timeout(label)
      Timeout.timeout(overview_timeout) { yield }
    rescue Timeout::Error
      raise StandardError, "#{label} timed out after #{overview_timeout}s"
    end
  end
end
