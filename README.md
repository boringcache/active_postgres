# active_postgres

Production-grade PostgreSQL HA for Rails.

## Features

- **High Availability**: Primary/standby replication with automatic failover (repmgr)
- **Connection Pooling**: PgBouncer integration
- **Rails Integration**: Automatic database.yml config, migration guard, read replica routing
- **Modular Components**: Core, Performance Tuning (opt-in), repmgr, PgBouncer, pgBackRest, Monitoring, SSL, Extensions

## Quick Start

### 1. Install

```bash
gem install active_postgres
# or add to Gemfile: gem 'active_postgres'
```

### 2. Configure (Rails)

```bash
rails generate active_postgres:install
```

Edit `config/postgres.yml`:

```yaml
production:
  version: 18
  user: ubuntu
  ssh_key: ~/.ssh/id_rsa

  primary:
    host: 34.12.234.81        # Public IP for SSH
    private_ip: 10.8.0.10     # Private IP for database connections

  standby:
    - host: 52.23.45.67
      private_ip: 10.8.0.11

  components:
    repmgr: {enabled: true}
    pgbouncer: {enabled: true}

  secrets:
    superuser_password: $POSTGRES_SUPERUSER_PASSWORD
    replication_password: $POSTGRES_REPLICATION_PASSWORD
    repmgr_password: $POSTGRES_REPMGR_PASSWORD
    monitoring_password: $POSTGRES_MONITORING_PASSWORD
    app_password: $POSTGRES_APP_PASSWORD
```

Add credentials (`rails credentials:edit`):

```yaml
postgres:
  username: myapp
  password: "your_app_password"
  database: myapp_production
  primary_host: 10.8.0.10
  replica_host: 10.8.0.11
  port: 6432  # 6432 for PgBouncer, 5432 for direct
```

### 3. Deploy

```bash
rake postgres:setup   # Deploy cluster
rake postgres:status  # Check health
```

## Common Operations

### Rake Tasks

```bash
rake postgres:setup                    # Deploy HA cluster
rake postgres:status                   # Check cluster status
rake postgres:verify                   # Comprehensive health check
rake postgres:promote[host]            # Promote standby to primary

# Backups (requires pgBackRest)
rake postgres:backup:full
rake postgres:backup:list
rake postgres:backup:restore[backup_id]

# Credential rotation (zero downtime)
rake postgres:credentials:rotate_random
rake postgres:credentials:rotate_all

# Rolling updates (zero downtime)
rake postgres:update:version[18]       # Major version upgrade
rake postgres:update:patch             # Security patches
```

### CLI (Standalone)

```bash
active_postgres setup --environment=production
active_postgres setup-standby HOST
active_postgres status
active_postgres promote HOST
active_postgres backup --type=full
active_postgres cache-secrets
```

## Components

| Component | Description | Config |
|-----------|-------------|--------|
| **Core** | PostgreSQL installation | Always enabled |
| **Performance Tuning** | Auto-optimization | Disabled by default |
| **repmgr** | HA & automatic failover | `repmgr: {enabled: true}` |
| **PgBouncer** | Connection pooling | `pgbouncer: {enabled: true}` |
| **pgBackRest** | Backup & restore | `pgbackrest: {enabled: true}` |
| **Monitoring** | postgres_exporter (configures a dedicated pg_monitor user) | `monitoring: {enabled: true}` |
| **SSL** | Encrypted connections | `ssl: {enabled: true}` |
| **Extensions** | pgvector, PostGIS, etc. | `extensions: {enabled: true, list: [pgvector]}` |

### Monitoring credentials

`postgres_exporter` uses a dedicated `pg_monitor` user. Provide a password in secrets and optionally set the username:

```yaml
components:
  monitoring: {enabled: true, user: postgres_exporter}
secrets:
  monitoring_password: $POSTGRES_MONITORING_PASSWORD
```

### pgBackRest S3-compatible endpoints

For Tigris/MinIO/Wasabi/DO Spaces, set a custom endpoint and use path-style URLs:

```yaml
components:
  pgbackrest:
    enabled: true
    repo_type: s3
    s3_bucket: myapp-backups
    s3_region: auto
    s3_endpoint: t3.storage.dev
    s3_uri_style: path
```

### Stable app endpoint with PgBouncer

If you run PgBouncer on each PostgreSQL node and want a fixed app URL, enable `follow_primary`.
Each PgBouncer instance periodically repoints to the current primary using repmgr metadata.
Put a TCP load balancer or DNS record in front of the PgBouncer nodes.

```yaml
components:
  pgbouncer:
    enabled: true
    follow_primary: true
    follow_primary_interval: 5
```

### Automatic DNS updates on failover (dnsmasq)

If you use Messhy’s mesh DNS (dnsmasq), repmgr can update writer/reader DNS records on failover.
Enable `dns_failover` under `repmgr` and provide DNS server IPs or hostnames.
If you run setup from outside the mesh, use objects with both the public SSH host
and the private WireGuard IP so setup can SSH in and failover updates stay on the mesh.
If you run setup from inside the mesh, you can use a simple list of private IPs.

```yaml
components:
  repmgr:
    enabled: true
    dns_failover:
      enabled: true
      provider: dnsmasq
      domain: mesh.internal
      dns_servers:
        - host: 18.170.173.14
          private_ip: 10.8.0.10
        - host: 98.85.183.175
          private_ip: 10.8.0.110
      primary_record: db-primary.mesh.internal
      replica_record: db-replica.mesh.internal
```

This installs an event hook so repmgr updates `/etc/dnsmasq.d/active_postgres.conf`
on the DNS servers whenever the primary changes.
DNS servers must be reachable over the private network and allow SSH from the
database nodes (active_postgres installs SSH keys on first setup).

## Secrets Management

```yaml
secrets:
  # Environment variables
  password: $POSTGRES_PASSWORD

  # Command execution
  password: $(op read "op://vault/item/field")
  password: rails_credentials:postgres.password
  password: credentials:postgres.password

  # AWS Secrets Manager
  password: $(aws secretsmanager get-secret-value --secret-id myapp/postgres --query SecretString)
```

## Read/Write Splitting (Rails 6+)

```ruby
class ApplicationRecord < ActiveRecord::Base
  connects_to database: { writing: :primary, reading: :primary_replica }
end

# Writes go to primary, reads go to replica
User.create(name: "Alice")  # → Primary
User.all                     # → Replica
```

## Requirements

- Ruby 3.0+
- PostgreSQL 12+
- Ubuntu 20.04+ / Debian 11+ with systemd
- SSH key-based authentication (hosts must be in `~/.ssh/known_hosts`)
- Rails 6.0+ (optional)

### SSH host key verification

By default, host keys are verified strictly (`always`). For first-time provisioning you can set:

```yaml
ssh_host_key_verification: accept_new
```

This trusts a host key the first time and then pins it; prefer `always` once hosts are known.

## License

MIT
