namespace :postgres do
  namespace :credentials do
    desc 'Rotate app user password (zero downtime)'
    task :rotate, [:new_password] => :environment do |_t, args|
      require 'active_postgres'

      config = ActivePostgres::Configuration.load
      ssh_executor = ActivePostgres::SSHExecutor.new(config)
      ActivePostgres::Secrets.new(config)

      new_password = args[:new_password]
      unless new_password
        puts 'Usage: rake postgres:credentials:rotate[new_password]'
        puts 'Or generate random: rake postgres:credentials:rotate_random'
        exit 1
      end

      app_user = config.app_user
      host = config.primary_host

      puts "Rotating password for user '#{app_user}' on #{host}..."
      puts '⚠️  IMPORTANT: Update Rails credentials after this completes!'
      puts ''

      ssh_executor.execute_on_host(host) do
        escaped_password = new_password.gsub("'", "''")

        sql = "ALTER USER #{app_user} WITH PASSWORD '#{escaped_password}';"
        upload! StringIO.new(sql), '/tmp/rotate_password.sql'
        execute :chmod, '644', '/tmp/rotate_password.sql'
        execute :sudo, '-u', 'postgres', 'psql', '-f', '/tmp/rotate_password.sql'
        execute :rm, '-f', '/tmp/rotate_password.sql'

        puts "✓ Updated PostgreSQL password for #{app_user}"
      end

      if config.component_enabled?(:pgbouncer)
        puts 'Updating PgBouncer userlist...'

        ssh_executor.execute_on_host(host) do
          postgres_user = config.postgres_user
          userlist_entries = []

          [postgres_user, app_user].compact.uniq.each do |user|
            sql = <<~SQL.strip
              SELECT concat('"', rolname, '" "', rolpassword, '"')
              FROM pg_authid
              WHERE rolname = '#{user}'
            SQL

            upload! StringIO.new(sql), '/tmp/get_user_hash.sql'
            execute :chmod, '644', '/tmp/get_user_hash.sql'
            user_hash = capture(:sudo, '-u', postgres_user, 'psql', '-t', '-f', '/tmp/get_user_hash.sql').strip
            execute :rm, '-f', '/tmp/get_user_hash.sql'

            userlist_entries << user_hash if user_hash && !user_hash.empty?
          end

          if userlist_entries.any?
            userlist_content = "#{userlist_entries.join("\n")}\n"
            upload! StringIO.new(userlist_content), '/tmp/userlist.txt'
            execute :sudo, 'mv', '/tmp/userlist.txt', '/etc/pgbouncer/userlist.txt'
            execute :sudo, 'chmod', '640', '/etc/pgbouncer/userlist.txt'
            execute :sudo, 'chown', 'postgres:postgres', '/etc/pgbouncer/userlist.txt'
            execute :sudo, 'systemctl', 'reload', 'pgbouncer'

            puts '✓ Updated PgBouncer userlist and reloaded (zero downtime)'
          end
        end
      end

      puts ''
      puts '✅ Password rotation complete!'
      puts ''
      puts '📋 Next steps:'
      puts '1. Update Rails credentials:'
      puts '   rails credentials:edit'
      puts ''
      puts '   Add/update:'
      puts '   postgres:'
      puts "     password: \"#{new_password}\""
      puts ''
      puts '2. Restart Rails app to use new password'
      puts '   cap production deploy:restart'
      puts ''
      puts '⚠️  Old password still works until Rails restarts'
    end

    desc 'Rotate app user password with random generated password (zero downtime)'
    task rotate_random: :environment do
      require 'securerandom'
      new_password = SecureRandom.base64(32)

      puts '🔐 Generated secure random password'
      puts ''

      Rake::Task['postgres:credentials:rotate'].invoke(new_password)
    end

    desc 'Rotate all passwords (app, repmgr, superuser) - zero downtime'
    task rotate_all: :environment do
      require 'active_postgres'
      require 'securerandom'

      config = ActivePostgres::Configuration.load
      ssh_executor = ActivePostgres::SSHExecutor.new(config)

      users = [
        { name: config.app_user, credential_key: 'password' },
        { name: config.repmgr_user, credential_key: 'repmgr_password' },
        { name: 'postgres', credential_key: 'superuser_password' }
      ]

      new_passwords = {}
      host = config.primary_host

      puts '🔐 Rotating all PostgreSQL passwords...'
      puts ''

      users.each do |user_info|
        username = user_info[:name]
        new_password = SecureRandom.base64(32)
        new_passwords[user_info[:credential_key]] = new_password

        puts "Rotating #{username}..."

        ssh_executor.execute_on_host(host) do
          escaped_password = new_password.gsub("'", "''")

          sql = "ALTER USER #{username} WITH PASSWORD '#{escaped_password}';"
          upload! StringIO.new(sql), '/tmp/rotate_password.sql'
          execute :chmod, '644', '/tmp/rotate_password.sql'
          execute :sudo, '-u', 'postgres', 'psql', '-f', '/tmp/rotate_password.sql'
          execute :rm, '-f', '/tmp/rotate_password.sql'
        end

        puts "✓ Updated #{username}"
      end

      if config.component_enabled?(:pgbouncer)
        puts ''
        puts 'Updating PgBouncer userlist...'

        ssh_executor.execute_on_host(host) do
          postgres_user = 'postgres'
          userlist_entries = []

          users.map { |u| u[:name] }.compact.uniq.each do |user|
            sql = <<~SQL.strip
              SELECT concat('"', rolname, '" "', rolpassword, '"')
              FROM pg_authid
              WHERE rolname = '#{user}'
            SQL

            upload! StringIO.new(sql), '/tmp/get_user_hash.sql'
            execute :chmod, '644', '/tmp/get_user_hash.sql'
            user_hash = capture(:sudo, '-u', postgres_user, 'psql', '-t', '-f', '/tmp/get_user_hash.sql').strip
            execute :rm, '-f', '/tmp/get_user_hash.sql'

            userlist_entries << user_hash if user_hash && !user_hash.empty?
          end

          if userlist_entries.any?
            userlist_content = "#{userlist_entries.join("\n")}\n"
            execute :sudo, 'tee', '/etc/pgbouncer/userlist.txt', stdin: StringIO.new(userlist_content)
            execute :sudo, 'chmod', '640', '/etc/pgbouncer/userlist.txt'
            execute :sudo, 'chown', 'postgres:postgres', '/etc/pgbouncer/userlist.txt'
            execute :sudo, 'systemctl', 'reload', 'pgbouncer'

            puts '✓ PgBouncer userlist updated and reloaded'
          end
        end
      end

      puts ''
      puts '✅ All passwords rotated!'
      puts ''
      puts '📋 New passwords to add to Rails credentials:'
      puts ''
      puts 'rails credentials:edit'
      puts ''
      puts 'postgres:'
      new_passwords.each do |key, password|
        puts "  #{key}: \"#{password}\""
      end
      puts ''
      puts '⚠️  Save these passwords securely before continuing!'
      puts ''
      puts 'After updating credentials:'
      puts '  cap production deploy:restart'
    end
  end
end
