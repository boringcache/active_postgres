require 'test_helper'

class DeploymentFlowTest < Minitest::Test
  class DryRunFlow < ActivePostgres::DeploymentFlow
    attr_reader :deployed

    private

    def operation_name = 'Dry run'
    def print_targets; end
    def run_preflight_checks; end
    def list_deployment_steps; end
    def list_next_steps; end

    def deploy_components
      @deployed = true
    end
  end

  def test_dry_run_stops_before_confirmation_and_deployment
    config = Object.new
    config.define_singleton_method(:validate!) { true }
    config.define_singleton_method(:environment) { 'test' }
    logger = ActivePostgres::Logger.new

    flow = DryRunFlow.new(
      config,
      ssh_executor: Object.new,
      secrets: Object.new,
      logger:,
      rollback_manager: Object.new
    )

    flow.execute(dry_run: true)

    refute flow.deployed
  end
end
