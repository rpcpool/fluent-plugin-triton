# frozen_string_literal: true

require 'net/http'
require 'json'
require 'socket'
require 'uri'

module Nomad
  def self.if_lookup_ipv4(ifname)
    interfaces = Socket.getifaddrs.select do |ifaddr|
      ifaddr.name == ifname && ifaddr.addr && ifaddr.addr.ipv4?
    end

    raise "Error: No IPv4 address found for the `#{ifname}` interface." if interfaces.empty?

    interfaces.first.addr.ip_address
  end

  def self.summarize_alloc_resp(alloc)
    return nil if alloc.nil?

    {
      alloc_id: alloc['ID'],
      job_id: alloc['JobID'],
      task_group: alloc['TaskGroup'],
      namespace: alloc['Namespace'],
      node_name: alloc['NodeName']
    }
  end

  def self.resolv_nomad_addr(ifname = nil)
    # Nomad server address dynamically determined
    nomad_addr = ENV['NOMAD_ADDR']
    nomad_addr = if nomad_addr.nil? || nomad_addr.empty?
                   nomad_ip = if ifname.nil?
                                '127.0.0.1'
                              else
                                Nomad.if_lookup_ipv4(ifname)
                              end
                   "http://#{nomad_ip}:4646"
                 else
                   nomad_addr
                 end

    nomad_addr_uri = URI.parse(nomad_addr)
    nomad_host = nomad_addr_uri.host
    nomad_port = nomad_addr_uri.port
    # Test the connection

    begin
      _sock = Socket.tcp(nomad_host, nomad_port, connect_timeout: 5)
      nomad_addr
    rescue StandardError
      raise 'Error: Unable to connect to Nomad server.'
    end
  end

  class NomadClient
    def self.load_from_env(**kwargs)
      nomad_addr = if kwargs.key?(:nomad_addr)
                     kwargs[:nomad_addr]
                   else
                     Nomad.resolv_nomad_addr(ifname: kwargs[:nomad_ifname])
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
      node = nodes.find do |n|
        n['Name'] == node_name
      end
      node&.[]('ID')
    end

    def list_allocations
      allocations = get_request('/v1/allocations')
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
        nil
      end
    end
  end
end
