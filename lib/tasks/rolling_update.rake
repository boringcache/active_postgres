namespace :postgres do
  namespace :update do
    desc 'Rolling update PostgreSQL version (zero downtime)'
    task :version, [:new_version] => :environment do |_t, args|
      require 'active_postgres'

      new_version = args[:new_version]
      unless new_version
        puts 'Usage: rake postgres:update:version[18]'
        puts 'Example: rake postgres:update:version[18] (upgrade from 16 to 18)'
        exit 1
      end

      config = ActivePostgres::Configuration.load
      ssh_executor = ActivePostgres::SSHExecutor.new(config)
      current_version = config.version

      if current_version.to_s == new_version.to_s
        puts "Already running version #{new_version}"
        exit 0
      end

      puts "🔄 Rolling update: PostgreSQL #{current_version} → #{new_version}"
      puts ''
      puts 'This will:'
      puts '  1. Update standby to new version'
      puts '  2. Verify standby health'
      puts '  3. Promote standby to primary (brief switchover ~5-10s)'
      puts '  4. Update old primary to new version'
      puts '  5. Optionally switchback to original primary'
      puts ''
      puts '⚠️  IMPORTANT: Test this in staging first!'
      puts ''
      print 'Continue? (yes/no): '
      response = $stdin.gets.chomp.downcase
      exit 0 unless %w[yes y].include?(response)

      primary = config.primary_host
      standby = config.standby_hosts.first

      unless standby
        puts '❌ No standby configured - cannot do rolling update'
        puts 'For single-node updates, use: rake postgres:update:in_place'
        exit 1
      end

      puts "\n📋 Cluster Status:"
      puts "  Primary: #{primary} (version #{current_version})"
      puts "  Standby: #{standby} (version #{current_version})"
      puts ''

      puts '=' * 60
      puts 'STEP 1: Update standby to new version'
      puts '=' * 60

      puts "\nUpdating #{standby}..."
      ssh_executor.execute_on_host(standby) do
        execute :sudo, 'systemctl', 'stop', "postgresql@#{current_version}-main"
        execute :sudo, 'apt-get', '-o', 'DPkg::Lock::Timeout=300', 'update'
        execute :sudo, 'DEBIAN_FRONTEND=noninteractive', 'apt-get',
                '-o', 'DPkg::Lock::Timeout=300', 'install', '-y',
                "postgresql-#{new_version}", "postgresql-contrib-#{new_version}"

        puts "Upgrading cluster from #{current_version} to #{new_version}..."
        execute :sudo, 'pg_upgradecluster', current_version.to_s, 'main'
        execute :sudo, 'pg_dropcluster', '--stop', current_version.to_s, 'main'
      end

      puts "✓ Standby upgraded to version #{new_version}"
      puts ''

      puts '=' * 60
      puts 'STEP 2: Verify standby health'
      puts '=' * 60

      Rake::Task['postgres:verify'].invoke
      puts ''

      puts '=' * 60
      puts 'STEP 3: Promote standby to primary'
      puts '=' * 60

      puts '⚠️  Brief downtime during switchover (~5-10 seconds)'
      puts ''
      print 'Promote standby? (yes/no): '
      response = $stdin.gets.chomp.downcase
      exit 0 unless %w[yes y].include?(response)

      Rake::Task['postgres:repmgr:promote'].invoke(standby)
      puts ''

      puts '✓ Switchover complete'
      puts "  New primary: #{standby} (version #{new_version})"
      puts "  Old primary: #{primary} (version #{current_version})"
      puts ''

      puts '=' * 60
      puts 'STEP 4: Update old primary'
      puts '=' * 60

      puts "\nUpdating #{primary}..."
      ssh_executor.execute_on_host(primary) do
        execute :sudo, 'systemctl', 'stop', "postgresql@#{current_version}-main"
        execute :sudo, 'apt-get', '-o', 'DPkg::Lock::Timeout=300', 'update'
        execute :sudo, 'DEBIAN_FRONTEND=noninteractive', 'apt-get',
                '-o', 'DPkg::Lock::Timeout=300', 'install', '-y',
                "postgresql-#{new_version}", "postgresql-contrib-#{new_version}"

        puts "Upgrading cluster from #{current_version} to #{new_version}..."
        execute :sudo, 'pg_upgradecluster', current_version.to_s, 'main'
        execute :sudo, 'pg_dropcluster', '--stop', current_version.to_s, 'main'
      end

      puts "✓ All nodes upgraded to version #{new_version}"
      puts ''

      puts '=' * 60
      puts '✅ Rolling update complete!'
      puts '=' * 60
      puts ''
      puts "Cluster is now running PostgreSQL #{new_version}"
      puts "Current primary: #{standby}"
      puts ''
      puts '📋 Next steps:'
      puts "  1. Update config/postgres.yml: version: #{new_version}"
      puts '  2. Test application thoroughly'
      puts "  3. Optionally switchback: rake postgres:repmgr:promote[#{primary}]"
      puts '  4. Commit config changes'
    end

    desc 'Patch current PostgreSQL version (zero downtime)'
    task patch: :environment do
      require 'active_postgres'

      config = ActivePostgres::Configuration.load
      ssh_executor = ActivePostgres::SSHExecutor.new(config)
      version = config.version

      primary = config.primary_host
      standby = config.standby_hosts.first

      unless standby
        puts '❌ No standby configured - cannot do rolling patch'
        puts 'For single-node patching, use: rake postgres:update:in_place_patch'
        exit 1
      end

      puts '🔄 Rolling security patch update'
      puts ''
      puts 'This will:'
      puts '  1. Patch standby and restart'
      puts '  2. Verify standby health'
      puts '  3. Promote standby (brief switchover ~5s)'
      puts '  4. Patch old primary'
      puts '  5. Switchback'
      puts ''
      print 'Continue? (yes/no): '
      response = $stdin.gets.chomp.downcase
      exit 0 unless %w[yes y].include?(response)

      puts "\n📋 Step 1: Patch standby #{standby}"
      ssh_executor.execute_on_host(standby) do
        execute :sudo, 'apt-get', '-o', 'DPkg::Lock::Timeout=300', 'update'
        execute :sudo, 'DEBIAN_FRONTEND=noninteractive', 'apt-get',
                '-o', 'DPkg::Lock::Timeout=300', 'install', '--only-upgrade', '-y', "postgresql-#{version}"
        execute :sudo, 'systemctl', 'restart', "postgresql@#{version}-main"
      end
      puts '✓ Standby patched and restarted'
      sleep 5

      puts "\n📋 Step 2: Promote standby"
      Rake::Task['postgres:repmgr:promote'].invoke(standby)
      sleep 5

      puts "\n📋 Step 3: Patch old primary #{primary}"
      ssh_executor.execute_on_host(primary) do
        execute :sudo, 'apt-get', '-o', 'DPkg::Lock::Timeout=300', 'update'
        execute :sudo, 'DEBIAN_FRONTEND=noninteractive', 'apt-get',
                '-o', 'DPkg::Lock::Timeout=300', 'install', '--only-upgrade', '-y', "postgresql-#{version}"
        execute :sudo, 'systemctl', 'restart', "postgresql@#{version}-main"
      end
      puts '✓ Old primary patched'
      sleep 5

      puts "\n📋 Step 4: Switchback to #{primary}"
      Rake::Task['postgres:repmgr:promote'].invoke(primary)

      puts ''
      puts '✅ Security patches applied!'
      puts '  Total downtime: ~10 seconds (during switchovers)'
    end

    desc 'In-place update (requires downtime)'
    task :in_place, [:new_version] => :environment do |_t, args|
      require 'active_postgres'

      new_version = args[:new_version]
      unless new_version
        puts 'Usage: rake postgres:update:in_place[18]'
        exit 1
      end

      config = ActivePostgres::Configuration.load
      ssh_executor = ActivePostgres::SSHExecutor.new(config)
      current_version = config.version
      host = config.primary_host

      puts '⚠️  WARNING: In-place update requires downtime'
      puts '   For zero-downtime updates, use a standby server'
      puts ''
      puts "Updating PostgreSQL #{current_version} → #{new_version} on #{host}"
      puts ''
      print 'Continue? (yes/no): '
      response = $stdin.gets.chomp.downcase
      exit 0 unless %w[yes y].include?(response)

      puts "\n🔄 Starting in-place upgrade..."
      ssh_executor.execute_on_host(host) do
        execute :sudo, 'systemctl', 'stop', "postgresql@#{current_version}-main"
        execute :sudo, 'apt-get', '-o', 'DPkg::Lock::Timeout=300', 'update'
        execute :sudo, 'DEBIAN_FRONTEND=noninteractive', 'apt-get',
                '-o', 'DPkg::Lock::Timeout=300', 'install', '-y', "postgresql-#{new_version}"

        execute :sudo, 'pg_upgradecluster', current_version.to_s, 'main'
        execute :sudo, 'pg_dropcluster', '--stop', current_version.to_s, 'main'
        execute :sudo, 'systemctl', 'start', "postgresql@#{new_version}-main"
      end

      puts "✅ Upgraded to PostgreSQL #{new_version}"
      puts "   Update config/postgres.yml: version: #{new_version}"
    end
  end

  namespace :repmgr do
    desc 'Promote standby to primary (switchover)'
    task :promote, [:host] => :environment do |_t, args|
      require 'active_postgres'

      host = args[:host]
      unless host
        puts 'Usage: rake postgres:repmgr:promote[host]'
        exit 1
      end

      config = ActivePostgres::Configuration.load
      ssh_executor = ActivePostgres::SSHExecutor.new(config)

      puts "🔄 Promoting #{host} to primary..."
      puts '⏱️  Expected downtime: 5-10 seconds'
      puts ''

      ssh_executor.execute_on_host(host) do
        execute :sudo, '-u', 'postgres', 'repmgr', 'standby', 'promote'
      end

      sleep 3

      puts '✅ Promotion complete!'
      puts "   New primary: #{host}"
      puts ''
      puts '📋 Verify cluster:'
      puts '   rake postgres:verify'
    end
  end
end
