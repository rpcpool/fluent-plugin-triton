require 'fluent/plugin/filter'
require 'net/http'
require 'json'
require 'socket'
require 'uri'

# Function to get the IP address bound to the `rpcpool` interface
def get_rpcpool_ip(ifname)
  interfaces = Socket.getifaddrs.select do |ifaddr|
    ifaddr.name == ifname && ifaddr.addr && ifaddr.addr.ipv4?
  end

  if interfaces.empty?
    puts "Error: No IPv4 address found for the `rpcpool` interface."
    exit 1
  end

  interfaces.first.addr.ip_address
end

def default_interface
  # Get the default route using the Socket library
  addr_info = Socket.getifaddrs.find { |ifaddr| ifaddr.addr&.ipv4? && ifaddr.addr.ipv4_private? }
  addr_info&.name
end


# Function to make GET requests with headers
def nomad_api_get(endpoint, path, nomad_token)
  uri = URI("#{endpoint}#{path}")
  request = Net::HTTP::Get.new(uri)
  request['X-Nomad-Token'] = nomad_token

  response = Net::HTTP.start(uri.hostname, uri.port) do |http|
    http.request(request)
  end

  case response
  when Net::HTTPSuccess
    JSON.parse(response.body)
  else
    puts "HTTP request failed: #{response.code} #{response.message}"
    exit 1
  end
end


def resolv_nomad_addr
   # Nomad server address dynamically determined
  nomad_addr = ENV['NOMAD_ADDR']
  
  nomad_addr = if nomad_addr.nil? || nomad_addr.empty?
    rpcpool_ip = get_rpcpool_ip(default_interface)
    "http://#{rpcpool_ip}:4646"
  else
    nomad_addr
  end

  nomad_addr_uri = URI.parse(nomad_addr)
  nomad_host = nomad_addr_uri.host
  nomad_port = nomad_addr_uri.port
  # Test the connection

  begin
    _sock = Socket.tcp(nomad_host, nomad_port, connect_timeout: 5)
    return nomad_addr
  rescue StandardError
    raise 'Error: Unable to connect to Nomad server.'
  end
end

class NomadClient

  def self.from_env(target_node)
    nomad_addr = resolv_nomad_addr
    nomad_token = ENV['NOMAD_TOKEN']

    nodes = nomad_api_get(nomad_addr, "/v1/nodes", nomad_token)

    nodes.select

    node = nodes.find do |node|
      node['Name'] == target_node
    end
    if node.nil?
      raise "Error: Node #{target_node} not found."
    end

    p "Node ID: #{node['ID']}"

    NomadClient.new(nomad_addr, nomad_token, node['ID'])
  end

  def initialize(nomad_addr, nomad_token, node)
    @nomad_addr = nomad_addr
    @nomad_token = nomad_token
    @node_id = node
  end

  def list_allocations
    allocations = get_request("/v1/node/#{@node_id}/allocations")
    allocations.map { |alloc|
      {
        :id => alloc['ID'],
        :job_id => alloc['JobID'],
        :task_group => alloc['TaskGroup'],
        :namespace => alloc['Namespace'],
      }
    }
    # allocations.each do |alloc|

    #   puts "  - keys: #{alloc.keys}"
    #   puts "  - Allocation ID: #{alloc['ID']}"
    #   puts "    Name: #{alloc['EvalID']}"
    #   puts "    Name: #{alloc['Name']}"
    #   puts "    Job ID: #{alloc['JobID']}"
    #   puts "    Task Group: #{alloc['TaskGroup']}"
    #   puts "    Status: #{alloc['ClientStatus']}"
    #   puts
    # end
  end

  # Function to make GET requests with headers
  def get_request(path)
    nomad_api_get(@nomad_addr, path, @nomad_token)
  end

end

module Fluent::Plugin
  class PassThruFilter < Filter
    # Register this filter as "passthru"
    Fluent::Plugin.register_filter('nomad', self)


    # Loader Thread helper to run the Nomad client in background
    helpers :thread

    # config_param works like other plugins

    desc 'The record field containing the path to alloc directory'
    config_param :path_field, :string

    desc 'Current host name in ansible inventory'
    config_param :ansible_host, :string

    def configure(conf)
      super
      # Do the usual configuration here
    end


    def start
      super
      # thread_create(:nomad_client, &method(:nomad_client))
    end

    def filter(tag, time, record)
      record['alloc_id'] = record[@path_field].split('alloc/')[1].split('/')[0]
      record['task_name'] = record[@path_field].split('alloc/')[1].split('/')[1]
      record['target'] = record['target']
      record
    end
  end
end

