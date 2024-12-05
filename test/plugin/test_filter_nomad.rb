# frozen_string_literal: true

require 'test/unit'
# Load the module that defines common initialization method (Required)
require 'fluent/test'
# Load the module that defines helper methods for testing (Required)
require 'fluent/test/helpers'
# Load the test driver (Required)
require 'fluent/test/driver/filter'

# your own plugin
require './lib/fluent/plugin/triton'

class FilterNomadTest < Test::Unit::TestCase
  include Fluent::Test::Helpers
  def setup
    Fluent::Test.setup # this is required to setup router and others
  end

  class MockNomadClient
    def list_allocations
      {
        'abcde' => {
          alloc_id: 'abcde',
          job_id: 'test-job',
          task_group: 'test-task-group',
          namespace: 'test'
        }
      }
    end

    def get_allocation_info(alloc_id)
      {
        alloc_id: alloc_id,
        job_id: 'test-job',
        task_group: 'test-task-group',
        namespace: 'test'
      }
    end
  end

  # default configuration for tests
  CONFIG = %(
    alloc_id_field alloc_id
    nomad_addr http://localhost:4646
    nomad_token secret
  )

  def create_driver(conf = CONFIG)
    p Fluent::Plugin::Triton.constants
    Fluent::Test::Driver::Filter.new(Fluent::Plugin::Triton::FilterNomad).configure(conf)
  end

  def filter(config, messages)
    d = create_driver(config)
    d.run(default_tag: 'input.access') do
      messages.each do |message|
        d.feed(message)
      end
    end
    d.filtered_records
  end

  sub_test_case 'configured with invalid configuration' do
    # create_driver('')
    test 'empty configuration' do
      assert_raise(Fluent::ConfigError) do
        create_driver('')
      end
    end
  end

  sub_test_case 'plugin will add some fields' do
    test 'allocation information for valid alloc id' do
      random_suffix = (0...6).map { rand(65..90).chr }.join
      factory_name = "factory_#{random_suffix}"

      conf = %(
        alloc_id_field alloc_id
        nomad_addr http://localhost:4646
        nomad_token secret
        nomad_client_factory #{factory_name}
      )

      Fluent::Plugin::Triton::FilterNomad.registry_nomad_client_factory(factory_name) do |_opts|
        MockNomadClient.new
      end

      messages = [
        { 'alloc_id' => 'abcde', 'message' => 'This is test message' }
      ]
      expected = [
        {
          alloc_id: 'abcde',
          message: 'This is test message',
          job_id: 'test-job',
          task_group: 'test-task-group',
          namespace: 'test'
        }
      ]
      filtered_records = filter(conf, messages)
      assert_equal(expected, filtered_records)
    end
  end
end
