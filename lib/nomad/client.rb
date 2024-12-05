require 'net/http'
require 'json'
require 'socket'
require 'uri'

module Nomad
  # Function to get the IP address bound to the `rpcpool` interface
  def self.get_rpcpool_ip(ifname)
    interfaces = Socket.getifaddrs.select do |ifaddr|
      ifaddr.name == ifname && ifaddr.addr && ifaddr.addr.ipv4?
    end

    if interfaces.empty?
      puts "Error: No IPv4 address found for the `rpcpool` interface."
      exit 1
    end

    interfaces.first.addr.ip_address
  end

  def self.default_interface
    # Get the default route using the Socket library
    addr_info = Socket.getifaddrs.find { |ifaddr| ifaddr.addr&.ipv4? && ifaddr.addr.ipv4_private? }
    addr_info&.name
  end

  def self.summarize_alloc_resp(alloc)
    if alloc.nil?
      return nil
    end
    {
      :alloc_id => alloc['ID'],
      :job_id => alloc['JobID'],
      :task_group => alloc['TaskGroup'],
      :namespace => alloc['Namespace'],
      :node_name => alloc['NodeName'],
      # :region => alloc['Job']['Region'], 
    }
  end

  def self.resolv_nomad_addr
    # Nomad server address dynamically determined
    nomad_addr = ENV['NOMAD_ADDR']
    
    nomad_addr = if nomad_addr.nil? || nomad_addr.empty?
      rpcpool_ip = Nomad.get_rpcpool_ip(default_interface)
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

    def self.load_from_env(**kwargs)
      nomad_addr = if kwargs.key?(:nomad_addr)
        kwargs[:nomad_addr]
      else
        Nomad.resolv_nomad_addr
      end
      nomad_token = kwargs[:nomad_token] || ENV['NOMAD_TOKEN']
      NomadClient.new(nomad_addr, nomad_token)
    end

    def initialize(nomad_addr, nomad_token)
      @nomad_addr = nomad_addr
      @nomad_token = nomad_token
    end


    def list_nodes
      get_request('/v1/nodes')
    end

    def get_node_id_for(node_name)
      nodes = list_nodes
      node = nodes.find do |node| 
        node['Name'] == node_name
      end
      node&.[]('ID')
    end

    def list_allocations()
      allocations = get_request("/v1/allocations")
      allocations.to_h do |alloc|
        summ_alloc = Nomad.summarize_alloc_resp(alloc)
        [summ_alloc[:alloc_id], summ_alloc]
      end
    end

    def get_allocation_info(alloc_id)
      alloc = get_request("/v1/allocation/#{alloc_id}")
      if alloc.nil?
        nil
      else
        Nomad.summarize_alloc_resp(alloc)
      end
    end

    # Function to make GET requests with headers
    def get_request(path)
      uri = URI("#{@nomad_addr}#{path}")
      request = Net::HTTP::Get.new(uri)
      request['X-Nomad-Token'] = @nomad_token

      response = Net::HTTP.start(uri.hostname, uri.port) do |http|
        http.request(request)
      end

      case response
        when Net::HTTPSuccess
          JSON.parse(response.body)
        else
          puts "HTTP request failed: #{response.code} #{response.message}"
          return nil
      end
    end

  end

end