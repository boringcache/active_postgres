require 'test_helper'

class SqlFilePermissionsTest < Minitest::Test
  def test_all_sql_uploads_have_chmod
    files_to_check = [
      'lib/active_postgres/components/pgbouncer.rb',
      'lib/active_postgres/components/core.rb',
      'lib/active_postgres/components/repmgr.rb',
      'lib/active_postgres/connection_pooler.rb',
      'lib/active_postgres/rollback_manager.rb',
      'lib/tasks/postgres.rake',
      'lib/tasks/rotate_credentials.rake',
      'lib/tasks/rolling_update.rake'
    ]

    files_to_check.each do |file_path|
      full_path = File.expand_path("../../#{file_path}", __FILE__)
      next unless File.exist?(full_path)

      content = File.read(full_path)
      check_sql_uploads_have_chmod(content, file_path)
    end
  end

  private

  def check_sql_uploads_have_chmod(content, file_path)
    lines = content.split("\n")

    lines.each_with_index do |line, index|
      # Find lines that upload SQL files to /tmp
      next unless line.match?(/upload!.*\.sql['"]/)

      sql_file = extract_sql_filename(line)
      next unless sql_file&.start_with?('/tmp/')

      # Check if chmod follows within the next 3 lines
      has_chmod = (1..3).any? do |offset|
        next_line = lines[index + offset]
        next_line&.include?('chmod') && next_line.include?(sql_file)
      end

      assert has_chmod,
             "#{file_path}:#{index + 1} - SQL upload '#{sql_file}' missing chmod 644 command.\n" \
             "Add: execute :chmod, '644', '#{sql_file}' after the upload"
    end
  end

  def extract_sql_filename(line)
    # Extract the SQL filename from the upload line
    # Matches patterns like: '/tmp/something.sql'
    match = line.match(%r{['"](/tmp/[^'"]+\.sql)['"]})
    match ? match[1] : nil
  end
end
