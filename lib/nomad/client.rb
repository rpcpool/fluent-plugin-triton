# frozen_string_literal: true

require 'net/http'
require 'json'
require 'socket'
require 'uri'
require 'logger'

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

    # Check if the address is valid
    _nomad_addr_uri = URI.parse(nomad_addr)
    nomad_addr
  end

  class NomadError < StandardError; end

  class NomadConnectError < NomadError
    def initialize(message)
      super
      @message = message
    end

    def to_s
      "NomadConnectError: #{@message}"
    end
  end

  class NomadClientRequestError < NomadError
    attr_reader :code, :message

    def initialize(code, message)
      super
      @code = code
      @message = message
    end

    def to_s
      "NomadClientRequestError: #{@code} - #{@message}"
    end
  end

  class NomadClient
    def self.load_from_env(**kwargs)
      nomad_addr = if !kwargs[:nomad_addr].nil?
                     kwargs[:nomad_addr]
                   else
                     Nomad.resolv_nomad_addr(ifname: kwargs[:nomad_ifname])
                   end
      if nomad_addr.nil?
        raise ArgumentError, 'Could not resolve Nomad address from the environment or the provided interface name.'
      end

      nomad_token = kwargs[:nomad_token] || ENV['NOMAD_TOKEN']
      if nomad_token.nil?
        raise ArgumentError, 'The NOMAD_TOKEN environment variable must be set or provided in the configuration.'
      end

      NomadClient.new(nomad_addr, nomad_token)
    end

    def initialize(nomad_addr, nomad_token)
      @nomad_addr = nomad_addr
      @nomad_token = nomad_token
      @logger = Logger.new(STDOUT)
      @logger.level = Logger::WARN # Log silent errors as warnings
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

      response = nil
      begin
        response = Net::HTTP.start(uri.hostname, uri.port) do |http|
          http.request(request)
        end
      rescue SocketError => e
        @logger.error("NomadConnectError: Could not connect to Nomad server at #{uri.hostname}:#{uri.port}: #{e.message}. Returning empty data.")
        return [] # Return an empty array for consistency
     rescue Timeout::Error => e
        @logger.error("NomadConnectError: Timeout connecting to Nomad server at #{uri.hostname}:#{uri.port}: #{e.message}. Returning empty data.")
        return [] # Return an empty array for consistency
      end

      case response
      when Net::HTTPSuccess
        JSON.parse(response.body)
      else
        @logger.error("NomadClientRequestError: Request to #{uri} failed with status #{response.code} - #{response.message}. Returning empty data.")
        return [] # Return an empty array for consistency
      end
    rescue JSON::ParserError => e
        @logger.error("JSONParseError: Failed to parse JSON response from #{uri}: #{e.message}. Returning empty data.")
        return []
    end
  end
end
