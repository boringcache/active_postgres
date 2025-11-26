require 'test_helper'

class ConfigurationAppUserTest < Minitest::Test
  def test_loads_app_user_from_core_config
    config_hash = {
      'production' => {
        'version' => 18,
        'user' => 'ubuntu',
        'primary' => { 'host' => 'db.example.com' },
        'components' => {
          'core' => {
            'app_user' => 'boring_cache_web',
            'app_database' => 'boring_cache_web_production'
          }
        }
      }
    }

    config = ActivePostgres::Configuration.new(config_hash, 'production')

    assert_equal 'boring_cache_web', config.app_user
    assert_equal 'boring_cache_web_production', config.app_database
  end

  def test_falls_back_to_defaults_when_not_specified
    config_hash = {
      'production' => {
        'version' => 18,
        'user' => 'ubuntu',
        'primary' => { 'host' => 'db.example.com' },
        'components' => {
          'core' => {}
        }
      }
    }

    config = ActivePostgres::Configuration.new(config_hash, 'production')

    assert_equal 'app', config.app_user
    assert_equal 'app_production', config.app_database
  end

  def test_component_config_includes_app_user_and_database
    config_hash = {
      'production' => {
        'version' => 18,
        'components' => {
          'core' => {
            'app_user' => 'myapp_user',
            'app_database' => 'myapp_db',
            'locale' => 'en_US.UTF-8'
          }
        }
      }
    }

    config = ActivePostgres::Configuration.new(config_hash, 'production')
    core_config = config.component_config(:core)

    assert_equal 'myapp_user', core_config[:app_user]
    assert_equal 'myapp_db', core_config[:app_database]
    assert_equal 'en_US.UTF-8', core_config[:locale]
  end

  def test_loads_app_user_with_yaml_anchors
    require 'yaml'
    require 'tempfile'

    yaml_content = <<~YAML
      shared: &shared
        version: 18
        user: ubuntu
        components:
          core:
            app_user: shared_app_user
            app_database: shared_app_database

      production:
        <<: *shared
        primary:
          host: db.example.com
    YAML

    Tempfile.create(['postgres', '.yml']) do |file|
      file.write(yaml_content)
      file.flush

      config = ActivePostgres::Configuration.load(file.path, 'production')

      assert_equal 'shared_app_user', config.app_user
      assert_equal 'shared_app_database', config.app_database
    end
  end

  def test_loads_different_app_users_per_environment
    config_hash = {
      'development' => {
        'version' => 18,
        'components' => {
          'core' => {
            'app_user' => 'dev_user',
            'app_database' => 'dev_db'
          }
        }
      },
      'production' => {
        'version' => 18,
        'components' => {
          'core' => {
            'app_user' => 'prod_user',
            'app_database' => 'prod_db'
          }
        }
      }
    }

    dev_config = ActivePostgres::Configuration.new(config_hash, 'development')
    prod_config = ActivePostgres::Configuration.new(config_hash, 'production')

    assert_equal 'dev_user', dev_config.app_user
    assert_equal 'dev_db', dev_config.app_database

    assert_equal 'prod_user', prod_config.app_user
    assert_equal 'prod_db', prod_config.app_database
  end

  def test_app_user_with_special_characters
    config_hash = {
      'production' => {
        'version' => 18,
        'components' => {
          'core' => {
            'app_user' => 'my_app-user.2024',
            'app_database' => 'my-app_db.production'
          }
        }
      }
    }

    config = ActivePostgres::Configuration.new(config_hash, 'production')

    assert_equal 'my_app-user.2024', config.app_user
    assert_equal 'my-app_db.production', config.app_database
  end

  def test_nil_app_user_uses_default
    config_hash = {
      'production' => {
        'version' => 18,
        'components' => {
          'core' => {
            'app_user' => nil,
            'app_database' => nil
          }
        }
      }
    }

    config = ActivePostgres::Configuration.new(config_hash, 'production')

    assert_equal 'app', config.app_user
    assert_equal 'app_production', config.app_database
  end

  def test_empty_string_app_user_uses_default
    config_hash = {
      'production' => {
        'version' => 18,
        'components' => {
          'core' => {
            'app_user' => '',
            'app_database' => ''
          }
        }
      }
    }

    config = ActivePostgres::Configuration.new(config_hash, 'production')

    assert_equal 'app', config.app_user
    assert_equal 'app_production', config.app_database
  end
end
