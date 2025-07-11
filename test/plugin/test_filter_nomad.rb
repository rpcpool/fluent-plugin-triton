# frozen_string_literal: true

require 'test/unit'
# Load the module that defines common initialization method (Required)
require 'fluent/test'
# Load the module that defines helper methods for testing (Required)
require 'fluent/test/helpers'
# Load the test driver (Required)
require 'fluent/test/driver/filter'

# your own plugin
require 'fluent/plugin/filter_nomad'

class FilterNomadTest < Test::Unit::TestCase
  include Fluent::Test::Helpers
  def setup
    Fluent::Test.setup # this is required to setup router and others
  end

  class MockNomadClient
    attr_reader :calls

    attr_accessor :list_allocations_return_value

    def initialize(list_allocations_return_value = nil)
      @calls = Hash.new(0)
      @list_allocations_return_value = list_allocations_return_value || {}
    end

    def list_allocations
      @calls[:list_allocations] += 1
      @list_allocations_return_value
    end

    def get_allocation_info(alloc_id)
      @calls[:get_allocation_info] += 1
      {
        alloc_id: alloc_id,
        job_id: 'test-job',
        task_group: 'test-task-group',
        namespace: 'test'
      }
    end
  end

  class BrokenNomadClient
    attr_reader :calls

    # Simulate a broken Nomad client that raises an error on API calls

    def initialize
      @calls = Hash.new(0)
    end

    def list_allocations
      @calls[:list_allocations] += 1
      raise Nomad::NomadConnectError, 'Connection error'
    end
  end

  # default configuration for tests
  CONFIG = %(
    alloc_id_field alloc_id
    nomad_addr http://localhost:4646
    nomad_token secret
  )

  def create_driver(conf = CONFIG)
    Fluent::Test::Driver::Filter.new(Fluent::Plugin::FilterNomad).configure(conf)
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

      mock_client = MockNomadClient.new(
        {
          'abcde' => {
            alloc_id: 'abcde',
            job_id: 'test-job',
            task_group: 'test-task-group',
            namespace: 'test'
          }
        }
      )

      Fluent::Plugin::FilterNomad.registry_nomad_client_factory(factory_name) do |_opts|
        mock_client
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
      assert_equal(1, mock_client.calls[:list_allocations])
      assert_equal(expected, filtered_records)
    end
  end

  sub_test_case 'plugin should not fail on nomad client error' do
    test 'Nomad client error' do
      random_suffix = (0...6).map { rand(65..90).chr }.join
      factory_name = "factory_#{random_suffix}"

      conf = %(
        alloc_id_field alloc_id
        nomad_addr http://localhost:4646
        nomad_token secret
        nomad_client_factory #{factory_name}
      )

      Fluent::Plugin::FilterNomad.registry_nomad_client_factory(factory_name) do |_opts|
        BrokenNomadClient.new
      end

      messages = [
        { alloc_id: 'abcde', message: 'This is test message' }
      ]
      # Expected output should be the same as input even if the client fails
      output = filter(conf, messages)
      assert_equal(messages, output)
    end
  end

  sub_test_case 'plugin should periodically update the allocation cache' do
    test 'allocation list should update every 1s' do
      random_suffix = (0...6).map { rand(65..90).chr }.join
      factory_name = "factory_#{random_suffix}"
      refresh_interval = 1
      conf = %(
        alloc_id_field alloc_id
        nomad_addr http://localhost:4646
        nomad_token secret
        nomad_client_factory #{factory_name}
        nomad_alloc_cache_refresh_interval 1
      )

      # Initially, the mock client can only allocation for 'abcde', not 'abcdf'
      mock_client = MockNomadClient.new(
        {
          'abcde' => {
            alloc_id: 'abcde',
            job_id: 'test-job',
            task_group: 'test-task-group',
            namespace: 'test'
          }
        }
      )

      Fluent::Plugin::FilterNomad.registry_nomad_client_factory(factory_name) do |_opts|
        mock_client
      end

      messages = [
        { alloc_id: 'abcde', message: 'This is test message' },
        { alloc_id: 'abcdf', message: 'This is test message' }
      ]

      d = create_driver(conf)
      d.run(default_tag: 'input.access') do
        d.feed(messages[0])
        # 2nd : we make sure the cache is updated before the 2nd message is processed
        mock_client.list_allocations_return_value = {
          'abcdf' => {
            alloc_id: 'abcdf',
            job_id: 'test-job',
            task_group: 'test-task-group',
            namespace: 'test'
          }
        }
        sleep(refresh_interval + 0.1) # ensure the cache is updated
        d.feed(messages[1])
      end
      expected = [
        {
          alloc_id: 'abcde',
          message: 'This is test message',
          job_id: 'test-job',
          task_group: 'test-task-group',
          namespace: 'test'
        },
        {
          alloc_id: 'abcdf',
          message: 'This is test message',
          job_id: 'test-job',
          task_group: 'test-task-group',
          namespace: 'test'
        }
      ]
      filtered_records = d.filtered_records
      assert(mock_client.calls[:list_allocations] >= 2)
      assert_equal(expected, filtered_records)
    end

    test 'allocation cache refresh should not propagate internal errors' do
      random_suffix = (0...6).map { rand(65..90).chr }.join
      factory_name = "factory_#{random_suffix}"
      refresh_interval = 1
      conf = %(
        alloc_id_field alloc_id
        nomad_addr http://localhost:4646
        nomad_token secret
        nomad_client_factory #{factory_name}
        nomad_alloc_cache_refresh_interval 1
      )

      # Initially, the mock client can only allocation for 'abcde', not 'abcdf'
      broken_client = BrokenNomadClient.new

      Fluent::Plugin::FilterNomad.registry_nomad_client_factory(factory_name) do |_opts|
        broken_client
      end

      messages = [
        { alloc_id: 'abcde', message: 'This is test message' },
        { alloc_id: 'abcdf', message: 'This is test message' }
      ]
      d = create_driver(conf)
      d.run(default_tag: 'input.access') do
        d.feed(messages[0])
        # 2nd : we make sure the cache is updated before the 2nd message is processed
        sleep(refresh_interval + 0.1) # ensure the cache is updated
        d.feed(messages[1])
      end
      expected = [
        {
          alloc_id: 'abcde',
          message: 'This is test message'
        },
        {
          alloc_id: 'abcdf',
          message: 'This is test message'
        }
      ]
      filtered_records = d.filtered_records
      assert_equal(expected, filtered_records)
      assert(broken_client.calls[:list_allocations] >= 2)
    end
  end
end
