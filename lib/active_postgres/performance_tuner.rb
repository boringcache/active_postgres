module ActivePostgres
  # Automatic PostgreSQL performance tuning based on hardware specs
  # Following best practices from PGTune and PostgreSQL documentation
  class PerformanceTuner
    attr_reader :config, :ssh_executor, :logger

    def initialize(config, ssh_executor, logger = Logger.new)
      @config = config
      @ssh_executor = ssh_executor
      @logger = logger
    end

    def tune_for_host(host, db_type: 'web')
      @logger.info 'Analyzing hardware for optimal PostgreSQL configuration...'

      hardware = analyze_hardware(host)
      settings = calculate_optimal_settings(hardware, db_type)

      @logger.info 'Hardware detected:'
      @logger.info "  CPU Cores: #{hardware[:cpu_cores]}"
      @logger.info "  RAM: #{format_bytes(hardware[:total_memory])}"
      @logger.info "  Storage: #{hardware[:storage_type]}"

      settings
    end

    private

    def analyze_hardware(host)
      hardware = {}
      pg_version = @config.version.to_f # Capture before SSH block

      @ssh_executor.execute_on_host(host) do
        # Get CPU cores
        hardware[:cpu_cores] = capture(:nproc).strip.to_i

        # Get total memory in KB
        mem_info = capture(:cat, '/proc/meminfo')
        hardware[:total_memory] = mem_info.match(/MemTotal:\s+(\d+)/)[1].to_i * 1024

        # Detect storage type (SSD vs HDD) - inline to avoid scope issues
        disk_info = begin
          capture(:lsblk, '-d', '-o', 'name,rota', '2>/dev/null')
        rescue StandardError
          ''
        end
        # rota=0 means SSD, rota=1 means HDD
        hardware[:storage_type] = if disk_info.include?('nvme') || disk_info.match(/\s0$/)
                                    'ssd'
                                  else
                                    'hdd'
                                  end

        # Get PostgreSQL version
        hardware[:pg_version] = pg_version
      end

      hardware
    end

    def calculate_optimal_settings(hardware, db_type)
      settings = {}

      total_memory = hardware[:total_memory]
      cpu_cores = hardware[:cpu_cores]

      # Calculate based on database type
      case db_type
      when 'web'
        # Web application (many connections, mixed read/write)
        settings[:shared_buffers] = calculate_shared_buffers(total_memory, 0.25)
        settings[:effective_cache_size] = calculate_effective_cache_size(total_memory, 0.75)
        settings[:maintenance_work_mem] = calculate_maintenance_work_mem(total_memory, 0.05)
        settings[:work_mem] = calculate_work_mem(total_memory, 200)
        settings[:max_connections] = [200, cpu_cores * 25].min

      when 'oltp'
        # Online Transaction Processing (many small transactions)
        settings[:shared_buffers] = calculate_shared_buffers(total_memory, 0.25)
        settings[:effective_cache_size] = calculate_effective_cache_size(total_memory, 0.75)
        settings[:maintenance_work_mem] = calculate_maintenance_work_mem(total_memory, 0.05)
        settings[:work_mem] = calculate_work_mem(total_memory, 300)
        settings[:max_connections] = [300, cpu_cores * 40].min

      when 'dw'
        # Data Warehouse (complex queries, fewer connections)
        settings[:shared_buffers] = calculate_shared_buffers(total_memory, 0.4)
        settings[:effective_cache_size] = calculate_effective_cache_size(total_memory, 0.8)
        settings[:maintenance_work_mem] = calculate_maintenance_work_mem(total_memory, 0.1)
        settings[:work_mem] = calculate_work_mem(total_memory, 50)
        settings[:max_connections] = [50, cpu_cores * 10].min

      when 'desktop'
        # Development/Desktop (conservative settings)
        settings[:shared_buffers] = calculate_shared_buffers(total_memory, 0.1)
        settings[:effective_cache_size] = calculate_effective_cache_size(total_memory, 0.25)
        settings[:maintenance_work_mem] = '64MB'
        settings[:work_mem] = '4MB'
        settings[:max_connections] = 20
      end

      # Common optimizations for all types
      settings[:checkpoint_completion_target] = 0.9
      settings[:wal_buffers] = calculate_wal_buffers(settings[:shared_buffers])
      settings[:default_statistics_target] = 100
      settings[:random_page_cost] = hardware[:storage_type] == 'ssd' ? 1.1 : 4
      settings[:effective_io_concurrency] = hardware[:storage_type] == 'ssd' ? 200 : 2
      settings[:max_worker_processes] = cpu_cores
      settings[:max_parallel_workers_per_gather] = [(cpu_cores / 2).to_i, 4].min
      settings[:max_parallel_workers] = cpu_cores
      settings[:max_parallel_maintenance_workers] = [(cpu_cores / 2).to_i, 4].min

      # WAL settings for replication
      if @config.component_enabled?(:repmgr)
        settings[:wal_level] = 'replica'
        settings[:max_wal_senders] = [10, @config.standby_hosts.size * 2].max
        settings[:max_replication_slots] = [10, @config.standby_hosts.size * 2].max
        settings[:wal_keep_size] = '1GB'
        settings[:hot_standby] = 'on'
        settings[:wal_compression] = 'on'
        settings[:archive_mode] = 'on'
        settings[:archive_command] = '/bin/true' # Will be overridden by pgbackrest if enabled
      end

      # Huge pages optimization for large memory systems
      settings[:huge_pages] = 'try' if total_memory > 32 * 1024 * 1024 * 1024 # > 32GB

      # JIT compilation for PG11+
      settings[:jit] = 'on' if hardware[:pg_version] >= 11

      # Additional settings for PG13+
      if hardware[:pg_version] >= 13
        settings[:shared_memory_type] = hardware[:storage_type] == 'ssd' ? 'sysv' : 'mmap'
        settings[:wal_init_zero] = 'off'
        settings[:wal_recycle] = 'on'
      end

      # Logging optimizations
      settings[:log_checkpoints] = 'on'
      settings[:log_connections] = 'on'
      settings[:log_disconnections] = 'on'
      settings[:log_lock_waits] = 'on'
      settings[:log_temp_files] = 0
      settings[:log_autovacuum_min_duration] = '0'
      settings[:log_min_duration_statement] = '1000' # Log slow queries > 1s

      # Statement tracking
      settings[:shared_preload_libraries] = 'pg_stat_statements'
      settings['pg_stat_statements.max'] = 10_000
      settings['pg_stat_statements.track'] = 'all'

      settings
    end

    def calculate_shared_buffers(total_memory, ratio)
      value = (total_memory * ratio).to_i

      # Cap at 40% of RAM for large memory systems
      max_value = (total_memory * 0.4).to_i
      value = [value, max_value].min

      # Minimum 128MB
      value = [value, 128 * 1024 * 1024].max

      format_memory_value(value)
    end

    def calculate_effective_cache_size(total_memory, ratio)
      value = (total_memory * ratio).to_i
      format_memory_value(value)
    end

    def calculate_maintenance_work_mem(total_memory, ratio)
      value = (total_memory * ratio).to_i

      # Cap at 2GB
      max_value = 2 * 1024 * 1024 * 1024
      value = [value, max_value].min

      # Minimum 64MB
      value = [value, 64 * 1024 * 1024].max

      format_memory_value(value)
    end

    def calculate_work_mem(total_memory, max_connections)
      # Formula: (Total RAM - shared_buffers) / (max_connections * 3)
      shared_buffers = total_memory * 0.25
      available_memory = total_memory - shared_buffers
      value = (available_memory / (max_connections * 3)).to_i

      # Reasonable bounds: 4MB to 256MB
      value = value.clamp(4 * 1024 * 1024, 256 * 1024 * 1024)

      format_memory_value(value)
    end

    def calculate_wal_buffers(shared_buffers)
      # 3% of shared_buffers, capped at 16MB
      value = parse_memory_value(shared_buffers)
      wal_buffers = (value * 0.03).to_i
      wal_buffers = [wal_buffers, 16 * 1024 * 1024].min
      format_memory_value(wal_buffers)
    end

    def format_memory_value(bytes)
      if bytes >= 1024 * 1024 * 1024
        "#{(bytes / (1024 * 1024 * 1024)).to_i}GB"
      elsif bytes >= 1024 * 1024
        "#{(bytes / (1024 * 1024)).to_i}MB"
      else
        "#{(bytes / 1024).to_i}kB"
      end
    end

    def parse_memory_value(value)
      return value if value.is_a?(Integer)

      match = value.match(/(\d+)\s*(GB|MB|kB|B)?/i)
      return 0 unless match

      number = match[1].to_i
      unit = match[2]&.upcase || 'B'

      case unit
      when 'GB' then number * 1024 * 1024 * 1024
      when 'MB' then number * 1024 * 1024
      when 'KB' then number * 1024
      else number
      end
    end

    def format_bytes(bytes)
      units = %w[B KB MB GB TB]
      unit_index = 0
      value = bytes.to_f

      while value >= 1024 && unit_index < units.length - 1
        value /= 1024
        unit_index += 1
      end

      format('%.2f %s', value, units[unit_index])
    end
  end
end
