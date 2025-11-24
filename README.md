# active_postgres

> PostgreSQL High Availability for Rails, made simple.

A Ruby gem that provides production-grade PostgreSQL HA with deep Rails integration.

## Core Features

### 1. Rails-Native Integration
- ✅ Automatic `database.yml` management
- ✅ Rails credentials integration
- ✅ Rake tasks for common operations
- ✅ Generator for quick setup
- ✅ Migration guard (prevents migrations on replicas)
- ✅ Read replica routing (Rails 6+)

### 2. High Availability
- ✅ Primary/standby replication
- ✅ Automatic failover (repmgr)
- ✅ Health monitoring
- ✅ Manual promotion support

### 3. Modular Components
- ✅ **Core**: PostgreSQL installation & configuration
- ✅ **Performance Tuning**: Automatic optimization based on hardware
- ✅ **repmgr**: High availability & failover
- ✅ **PgBouncer**: Connection pooling
- ✅ **pgBackRest**: Backup & restore
- ✅ **Monitoring**: postgres_exporter for Prometheus
- ✅ **SSL/TLS**: Encrypted connections
- ✅ **Extensions**: PostgreSQL extensions (pgvector, PostGIS, etc.)

### 4. Flexible Secrets
- ✅ Rails credentials
- ✅ Environment variables
- ✅ Command execution (any secret manager)
- ✅ Local files

## Installation

```bash
gem install active_postgres
```

Or add to your Gemfile:

```ruby
gem 'active_postgres'
```

## Quick Start (Rails)

1. **Install**:

```bash
bundle install
rails generate active_postgres:install
```

2. **Configure** `config/postgres.yml`:

```yaml
production:
  version: 18
  user: ubuntu
  ssh_key: ~/.ssh/id_rsa
  
  primary:
    host: 34.12.234.81        # Public IP for SSH (like Kamal)
    private_ip: 10.8.0.10     # Private network IP (WireGuard/VPC/etc.) for database connections
  
  standby:
    - host: 52.23.45.67       # Public IP for SSH
      private_ip: 10.8.0.11   # Private/VPC IP for replication traffic
  
  components:
    repmgr: {enabled: true}
    pgbouncer: {enabled: true}

  secrets:
    superuser_password: $(rails runner "puts Rails.application.credentials.dig(:postgres, :superuser_password)")
    replication_password: $POSTGRES_REPLICATION_PASSWORD
```

**Important:** 
- `host`: Public IP for SSH deployment (like Kamal)
- `private_ip`: Preferred private/VPC/WireGuard IP for replication traffic (optional, falls back to `host`)
- PostgreSQL listens on `0.0.0.0` (all interfaces) automatically

3. **database.yml** (production):

`rails generate active_postgres:install` creates `config/database.active_postgres.yml` which renders a fully-populated `production.primary` / `production.primary_replica` block using your HA inventory. Include it near the bottom of `config/database.yml` (after your development/test configs):

```yaml
# ActivePostgres production config
<%= ERB.new(
      File.read(
        File.expand_path('database.active_postgres.yml', __dir__)
      )
    ).result(binding) %>
```

Set these environment variables (or use your preferred secret manager) so Rails never stores plaintext credentials:

- `POSTGRES_APP_USER` / `POSTGRES_APP_PASSWORD`
- `POSTGRES_DATABASE` (defaults to `app_environment`)
- `POSTGRES_PRIMARY_HOST` / `POSTGRES_PRIMARY_PORT` (use `6432` for PgBouncer, `5432` for direct PostgreSQL)
- `POSTGRES_REPLICA_HOST` / `POSTGRES_REPLICA_PORT` (use `6432` for PgBouncer, `5432` for direct PostgreSQL)

Fallback values come from `config/postgres.yml`, so you can start without setting every variable and override them per deploy target later.

4. **Setup**:

```bash
rake postgres:setup
```

5. **Check status**:

```bash
rake postgres:status
```

## CLI Usage (Standalone)

```bash
# Setup cluster (auto-detects primary-only vs HA based on config)
active_postgres setup --environment=production

# Setup a single standby (safe, doesn't touch primary)
active_postgres setup-standby 52.23.45.67 --environment=production

# Check status
active_postgres status

# Promote standby to primary
active_postgres promote 10.8.0.11

# Backup & restore
active_postgres backup --type=full
active_postgres restore 20240115120000
active_postgres list-backups

# Cache secrets locally
active_postgres cache-secrets
```

## Deployment Flows

### Cluster Setup (Primary + Standbys)

The `setup` command intelligently detects your configuration:

**Primary-Only Setup** (no standbys configured):
```bash
active_postgres setup --environment=production
```
- Installs PostgreSQL on primary
- Skips repmgr (no HA without standbys)
- Sets up optional components (pgbouncer, monitoring, etc.)
- Shows connection details for Rails config

**HA Cluster Setup** (standbys configured):
```bash
active_postgres setup --environment=production
```
- Installs PostgreSQL on ALL servers (primary + standbys)
- Configures repmgr for automatic failover
- Sets up replication between all nodes
- Sets up optional components on all nodes
- Shows connection details for all servers

**⚠️  Warning:** `setup` will **DROP and RECREATE** database clusters on all servers. All data will be lost!

### Adding Standbys Safely

After initial setup, add standbys **without touching the primary**:

```bash
# 1. Add standby to config/postgres.yml
production:
  standby:
    - host: 18.156.78.90
      private_ip: 10.8.0.12
      label: eu-west-1

# 2. Deploy only this standby
active_postgres setup-standby 18.156.78.90 --environment=production
```

**What happens:**
- Installs PostgreSQL packages on the standby
- Clones data from primary using repmgr
- Registers standby with repmgr cluster
- Sets up optional components on standby
- **Primary is NOT touched** - zero downtime!

**Safety checks:**
- Warns if standby already has PostgreSQL running
- Confirms before dropping existing data
- Validates standby is in config file
- Requires repmgr to be enabled

### Best Practices

**Initial Deployment:**
```bash
# 1. Start with primary only
# config/postgres.yml
production:
  primary:
    host: 34.12.234.81
    private_ip: 10.8.0.10
  standby: []  # Empty

# 2. Deploy primary
active_postgres setup --environment=production

# 3. Add standbys later (one at a time)
active_postgres setup-standby 52.23.45.67
active_postgres setup-standby 18.156.78.90
```

**Adding HA Later:**
```bash
# Already have primary running? Add standbys safely:
active_postgres setup-standby NEW_HOST --environment=production
```

**Rebuilding a Failed Standby:**
```bash
# Re-run setup-standby to rebuild from primary
active_postgres setup-standby FAILED_STANDBY_HOST --environment=production
# Confirms before dropping data
```

**Connection Details:**
After deployment, the tool shows:
```
Database Connection Details
---------------------------
Primary Host (Public):  34.12.234.81
Primary Host (Private): 10.8.0.10

Standbys:
  - 52.23.45.67 (Private: 10.8.0.11)

For Rails config/database.yml (production):
  host: 10.8.0.10  # Use private IP for internal connections
  port: 6432       # Use 6432 for PgBouncer, 5432 for direct PostgreSQL
  username: <%= Rails.application.credentials.dig(:postgres, :username) || 'app' %>
  password: <%= Rails.application.credentials.dig(:postgres, :password) %>
```

**Note:** Use port `6432` if PgBouncer is enabled, or port `5432` for direct PostgreSQL connections.

Copy these values to your Rails configuration!

## Rails Integration

### Generator

```bash
rails generate active_postgres:install
```

Creates:
- `config/postgres.yml`
- `config/database.active_postgres.yml`
- Updates `config/database.yml` with the production include snippet
- Shows credentials template

### Rake Tasks

```bash
# Setup PostgreSQL HA cluster
rake postgres:setup

# Check cluster status
rake postgres:status

# Promote standby to primary (failover)
rake postgres:promote[10.8.0.11]

# Run migrations (primary only)
rake postgres:migrate

# Backup operations
rake postgres:backup:full
rake postgres:backup:incremental
rake postgres:backup:restore[backup_id]
rake postgres:backup:list

# Component management
rake postgres:setup:pgbouncer
rake postgres:setup:monitoring
rake postgres:setup:repmgr
```

### Migration Guard

Automatically prevents migrations from running on read replicas:

```ruby
# Automatic via Railtie
# If connected to replica, raises error:
# "Cannot run migrations on read replica! Connect to primary."
```

### Read/Write Splitting (Rails 6+)

```ruby
# Automatic read routing to standbys
class ApplicationRecord < ActiveRecord::Base
  connects_to database: { writing: :primary, reading: :replica }
end

# Usage:
User.create(name: "Alice")  # → Writes to primary
User.all                     # → Reads from replica

# Force primary for reads:
User.connected_to(role: :writing) { User.first }
```

### Rails Console

```ruby
# bin/rails console
>> ActivePostgres.status
=> {
  primary: { host: "10.8.0.10", status: "running", connections: 45 },
  standbys: [{ host: "10.8.0.11", status: "streaming", lag: "0 bytes" }]
}

>> ActivePostgres.failover_to("10.8.0.11")
=> "Promoted 10.8.0.11 to primary. Update database.yml and restart app."
```

## Configuration

### Architecture: How IPs Work (Like Kamal)

```yaml
production:
  primary:
    host: 34.12.234.81        # ← Public IP: Used for SSH deployment
    private_ip: 10.8.0.10     # ← Private/VPC IP: Used for database connections
```

- **`host` (public IP)**: Used for SSH to deploy PostgreSQL (just like Kamal)
- **`private_ip` (preferred private/VPC IP)**: Used for database connections from your app
- **PostgreSQL listens on `0.0.0.0`**: Accessible on all interfaces, secured by `pg_hba.conf`

### Basic Example

```yaml
production:
  version: 18
  user: ubuntu
  ssh_key: ~/.ssh/id_rsa
  
  primary:
    host: 34.12.234.81        # Public IP for SSH
    private_ip: 10.8.0.10     # Private network IP
    label: us-east-1
  
  standby:
    - host: 52.23.45.67       # Public IP for SSH
      private_ip: 10.8.0.11   # Private network IP
      label: us-west-2
    
    - host: 18.156.78.90      # Multiple standbys supported!
      private_ip: 10.8.0.12
      label: eu-west-1
  
  components:
    core:
      # Full postgresql.conf control
      postgresql:
        listen_addresses: '*'      # Listen on 0.0.0.0
        max_connections: 100
        shared_buffers: 256MB
      
      # Full pg_hba.conf control
      pg_hba:
        - type: host
          database: all
          user: all
          address: 10.8.0.0/24     # Allow from VPN
          method: scram-sha-256
    
    repmgr:
      enabled: true
      auto_failover: true
    
    pgbouncer:
      enabled: true
      pool_mode: transaction
      max_client_conn: 1000
```

See `config/postgres.example.yml` for complete configuration options.

### ERB Templating

**Yes!** All configuration files use ERB templating for maximum flexibility:

```erb
# templates/postgresql.conf.erb
listen_addresses = '<%= postgresql_config[:listen_addresses] || '*' %>'
port = <%= postgresql_config[:port] || 5432 %>
max_connections = <%= postgresql_config[:max_connections] || 100 %>

<% if config.component_enabled?(:ssl) %>
ssl = on
ssl_cert_file = '/etc/postgresql/<%= config.version %>/main/server.crt'
<% end %>
```

```erb
# templates/pg_hba.conf.erb
<% pg_hba_rules.each do |rule| %>
<%= rule[:type] %>  <%= rule[:database] %>  <%= rule[:user] %>  <%= rule[:address] %>  <%= rule[:method] %>
<% end %>
```

All templates support full ERB syntax, so you can add custom logic!

### Multiple Standbys

**Fully supported!** Add as many standbys as you need:

```yaml
production:
  primary:
    host: 34.12.234.81
    private_ip: 10.8.0.10
  
  standby:
    - host: 52.23.45.67        # Standby 1
      private_ip: 10.8.0.11
      label: us-west-2
    
    - host: 18.156.78.90       # Standby 2
      private_ip: 10.8.0.12
      label: eu-west-1
    
    - host: 35.178.45.23       # Standby 3
      private_ip: 10.8.0.13
      label: ap-southeast-1
```

All standbys will:
- Replicate from primary
- Be registered with repmgr
- Be available as read replicas
- Be ready for automatic failover

### PostgreSQL Extensions

`active_postgres` supports installing PostgreSQL extensions automatically:

```yaml
production:
  components:
    extensions:
      enabled: true
      list:
        - pgvector        # Vector similarity search for AI/ML
        - postgis         # Geospatial data
        - pg_trgm         # Text similarity (fuzzy search)
        - hstore          # Key-value store
        - uuid-ossp       # UUID generation
        - pg_stat_statements  # Query statistics
        - timescaledb     # Time-series data
```

#### Supported Extensions

**Built-in (no package required):**
- `pg_trgm` - Trigram similarity for fuzzy text search
- `hstore` - Key-value pairs in a single column
- `uuid-ossp` - UUID generation functions
- `ltree` - Hierarchical tree structures
- `citext` - Case-insensitive text type
- `unaccent` - Remove accents from text
- `pg_stat_statements` - Query execution statistics

**Requires package installation:**
- `pgvector` - Vector similarity search (for AI/ML embeddings)
- `postgis` - Geographic information system (GIS) support
- `timescaledb` - Time-series data optimization
- `citus` - Distributed PostgreSQL
- `pg_partman` - Partition table management

#### Using pgvector for AI/ML

```yaml
production:
  components:
    extensions:
      enabled: true
      list:
        - pgvector
  
  # Specify which database to install extensions in
  database_name: myapp_production
```

In your Rails migrations:

```ruby
class AddVectorSupport < ActiveRecord::Migration[7.0]
  def up
    execute 'CREATE EXTENSION IF NOT EXISTS vector'
    
    # Add vector column for embeddings
    add_column :documents, :embedding, :vector, limit: 1536
    add_index :documents, :embedding, using: :ivfflat, opclass: :vector_cosine_ops
  end
  
  def down
    remove_column :documents, :embedding
    execute 'DROP EXTENSION IF EXISTS vector'
  end
end
```

### pg_hba.conf Configuration

Full control over host-based authentication:

```yaml
components:
  core:
    pg_hba:
      # Local connections
      - type: local
        database: all
        user: all
        method: peer
      
      # VPN network
      - type: host
        database: all
        user: all
        address: 10.8.0.0/24
        method: scram-sha-256
      
      # Specific IP
      - type: host
        database: myapp_production
        user: myapp
        address: 10.8.0.20/32
        method: scram-sha-256
      
      # Replication
      - type: host
        database: replication
        user: repmgr
        address: 10.8.0.0/24
        method: scram-sha-256
```

Supports all pg_hba.conf options: `local`, `host`, `hostssl`, `hostnossl`, etc.

## Secrets Management

Multiple sources supported:

```yaml
secrets:
  # 1. Environment variables
  password: $POSTGRES_PASSWORD
  
  # 2. Command execution (any tool!)
  replication_password: $(op read "op://vault/item/field")

  # 3. Rails credentials (recommended)
  superuser_password: $(rails runner "puts Rails.application.credentials.dig(:postgres, :superuser_password)")
  
  # 4. AWS Secrets Manager
  ssl_cert: $(aws secretsmanager get-secret-value --secret-id cert --query SecretString)
  
  # 5. Local files (after caching)
  ca_cert: $(cat .secrets/ca.crt)
```

### Cache Secrets Locally

```bash
active_postgres cache-secrets

# Creates .secrets/ directory with all secrets
# Then update config to use cached files:
secrets:
  superuser_password: $(cat .secrets/superuser_password)
```

## Components

### Core (Always Installed)

PostgreSQL installation and basic configuration.

### Performance Tuning (Enabled by Default)

```yaml
components:
  performance_tuning:
    enabled: true   # Enabled by default
    db_type: web    # Options: web, oltp, dw (data warehouse), desktop
```

Features:
- Automatic analysis of CPU cores, RAM, and storage type (SSD/HDD)
- Calculates optimal PostgreSQL settings (shared_buffers, work_mem, etc.)
- User overrides in `core.postgresql` configuration always take precedence
- Can be disabled by setting `enabled: false`

### repmgr (High Availability)

```yaml
components:
  repmgr:
    enabled: true
    auto_failover: true
    priority: 100
    reconnect_attempts: 6
```

Features:
- Automatic failover detection
- Cluster monitoring
- Switchover support

### PgBouncer (Connection Pooling)

```yaml
components:
  pgbouncer:
    enabled: true
    listen_port: 6432      # Default port for PgBouncer
    pool_mode: transaction
    max_client_conn: 1000
    default_pool_size: 25
```

Benefits:
- Reduced connection overhead
- Better performance under load
- Applications connect to port 6432, PgBouncer pools connections to PostgreSQL on port 5432

### pgBackRest (Backup & Restore)

```yaml
components:
  pgbackrest:
    enabled: true
    repo_type: s3
    s3_bucket: myapp-backups
    s3_region: us-east-1
    schedule: "0 2 * * *"
    retention_full: 7
```

Features:
- Full, differential, incremental backups
- Point-in-time recovery
- S3/GCS/Azure storage

### Monitoring (postgres_exporter)

```yaml
components:
  monitoring:
    enabled: true
    exporter_port: 9187
```

Metrics exposed for Prometheus:
- Connection count
- Replication lag
- Query performance

### SSL/TLS (Encryption)

```yaml
components:
  ssl:
    enabled: true
    mode: require
```

## Private Network Setup

`active_postgres` works seamlessly with private networks (VPC, WireGuard, etc.):

```yaml
production:
  primary:
    host: 34.12.234.81        # Public IP for SSH deployment
    private_ip: 10.8.0.10     # Private network IP for database connections

  standby:
    - host: 52.23.45.67
      private_ip: 10.8.0.11
```

**Benefits:**
- ✅ Replication traffic on private network
- ✅ Secure database connections
- ✅ Works with any private network solution (WireGuard, VPC, etc.)
- ✅ Works across clouds/regions

## Standbys vs Read Replicas

**They're the same server!**

- **Standby** = HA purpose (can be promoted to primary)
- **Read Replica** = Performance purpose (handles read queries)

Your standby servers serve both purposes:
1. HA: Can become primary if current primary fails
2. Performance: Handle read queries from your app

## Rails vs Standalone Usage

`active_postgres` works with **both Rails and standalone Ruby applications**:

### With Rails

Get automatic integration:
- Generator creates config files
- Rake tasks for deployment
- Automatic `database.yml` management
- Rails credentials integration
- Migration guard (prevents migrations on replicas)
- Read replica routing

```bash
# Rails workflow
rails generate active_postgres:install
rake postgres:setup
rake postgres:status
```

### Without Rails (Standalone Ruby)

Use the CLI directly:
```bash
# Standalone workflow
active_postgres setup --environment=production
active_postgres status
active_postgres setup-standby HOST
```

**Configuration:** Both use the same `config/postgres.yml` file. Rails adds the generator and rake tasks for convenience, but the core functionality works identically in both environments.

## Requirements

- Ruby 3.0+
- Target servers with systemd (Ubuntu 20.04+, Debian 11+)
- SSH key-based authentication
- PostgreSQL 12+ support
- Rails 6.0+ (optional, for Rails integration features)

## Development

```bash
bundle install
bundle exec rspec      # Run tests
bundle exec exe/active_postgres version
```

## Contributing

Bug reports and pull requests are welcome on GitHub.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## About

Built with ❤️ for the Rails community
