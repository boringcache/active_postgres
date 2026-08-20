# Contributing

Bug reports and focused pull requests are welcome. For a security issue, follow
[SECURITY.md](SECURITY.md) instead of opening a public issue.

Set up Ruby 4.0.6, install the bundle, and run the local verification commands:

```sh
bundle install
bundle exec rake test
bundle exec rubocop
bundle exec bundle-audit check --update
gem build active_postgres.gemspec
```

Keep deployment changes narrow and include tests for generated PostgreSQL,
PgBouncer, repmgr, backup, and monitoring configuration. Changes affecting
failover or recovery should document how they were exercised in a disposable
environment.
