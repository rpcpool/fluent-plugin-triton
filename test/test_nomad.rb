# frozen_string_literal: true

require 'test/unit'
require 'net/http'
require 'json'
require 'socket'
require 'uri'
require 'nomad' # Assuming the class is in `nomad_client.rb`

class TestNomadClientIntegration < Test::Unit::TestCase
  def setup
    @nomad_client = Nomad::NomadClient.load_from_env
  end

  def test_list_nodes
    # Perform a real API request to list nodes
    nodes = @nomad_client.list_nodes
    assert_not_nil nodes, 'Nodes should not be nil'
    assert nodes.is_a?(Array), 'Response should be an array'
    assert_operator nodes.size, :>, 0, 'There should be at least one node in the list'
  end

  def test_get_node_id_for
    # Make sure the node exists in the cluster
    nodes = @nomad_client.list_nodes
    assert_operator nodes.size, :>, 0, 'There should be at least one node in the list'
    node = nodes.first
    node_id = @nomad_client.get_node_id_for(node['Name'])
    assert node_id, 'Node ID should not be nil'
    assert_equal node['ID'], node_id, 'Node ID should match'
  end

  def test_list_allocations
    # Perform a real API request to list allocations
    allocations = @nomad_client.list_allocations
    assert_not_nil allocations, 'Allocations should not be nil'
    assert allocations.is_a?(Hash), 'Response should be a hash'
    assert_operator allocations.size, :>, 0, 'There should be at least one allocation'
  end

  def test_get_allocation_info
    # Make sure you have an allocation ID to test with
    alloc_id, = @nomad_client.list_allocations.first
    allocation_info = @nomad_client.get_allocation_info(alloc_id)
    assert_not_nil allocation_info, 'Allocation info should not be nil'
    assert_equal allocation_info[:alloc_id], alloc_id, 'Allocation ID should match'
  end

  def test_it_should_raise_nomad_client_error
    broken_nomad_client = Nomad::NomadClient.new('http://invalid-url:4646', 'invalid-token')
    actual_err = assert_raise do
      broken_nomad_client.list_allocations
    end

    assert actual_err.is_a?(Nomad::NomadError), 'Should raise NomadError'
  end

  def test_load_from_env_with_invalid_url
    temp = ENV['NOMAD_ADDR']

    ENV['NOMAD_ADDR'] = 'http://invalid-url:4646'
    Nomad::NomadClient.load_from_env
  ensure
    ENV['NOMAD_ADDR'] = temp
  end
end
