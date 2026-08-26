# Changelog

All notable changes to Active Postgres will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/).

## Unreleased

### Added

- Support strict operator SSH through declared jump hosts.
- Allow a standby to override repmgr failover and priority policy.
- Allow a standby to be seeded from the latest valid pgBackRest backup.
- Make deployment-flow `--dry-run` stop before confirmation or mutation.
- Fail standby setup before mutation when required credentials do not resolve.
- Scope standby rollback to the requested host and keep existing cluster nodes intact.

## 0.9.6 - 2026-08-20

### Changed

- Require Ruby 4.0 or newer and Rails 8.1 or newer for Rails integration.
- Align runtime and development dependencies with the maintained toolchain.
- Add blocking test, lint, dependency-audit, and package-build CI checks.
- Add automated Bundler and GitHub Actions dependency updates.
- Document network, credential, failover, and recovery responsibilities.

## 0.9.5

- Current published release. See the repository history for changes included in
  earlier releases.
