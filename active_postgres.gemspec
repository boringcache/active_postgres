require_relative 'lib/active_postgres/version'

Gem::Specification.new do |spec|
  spec.name = 'active_postgres'
  spec.version = ActivePostgres::VERSION
  spec.authors = ['BoringCache']
  spec.email = ['oss@boringcache.com']

  spec.summary = 'PostgreSQL High Availability for Rails, made simple'
  spec.description = 'Production-grade PostgreSQL HA with deep Rails integration. ' \
                     'Automated deployment, replication, failover, and monitoring.'
  spec.homepage = 'https://github.com/boringcache/active_postgres'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 4.0.0'

  spec.metadata['source_code_uri'] = 'https://github.com/boringcache/active_postgres'
  spec.metadata['documentation_uri'] = 'https://github.com/boringcache/active_postgres/blob/main/README.md'
  spec.metadata['changelog_uri'] = 'https://github.com/boringcache/active_postgres/blob/main/CHANGELOG.md'
  spec.metadata['bug_tracker_uri'] = 'https://github.com/boringcache/active_postgres/issues'
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir.glob(%w[
                          lib/**/*.rb
                          lib/**/*.erb
                          lib/tasks/**/*.rake
                          templates/**/*
                          exe/*
                          CHANGELOG.md
                          LICENSE
                          README.md
                          SECURITY.md
                        ])
  spec.bindir = 'exe'
  spec.executables = ['activepostgres']
  spec.require_paths = ['lib']

  spec.add_dependency 'bcrypt_pbkdf', '~> 1.1'
  spec.add_dependency 'ed25519', '~> 1.4'
  spec.add_dependency 'pg', '~> 1.6'
  spec.add_dependency 'railties', '>= 8.1', '< 9.0'
  spec.add_dependency 'sshkit', '~> 1.25'
  spec.add_dependency 'thor', '~> 1.5'
end
