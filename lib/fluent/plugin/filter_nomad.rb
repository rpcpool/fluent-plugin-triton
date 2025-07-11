# frozen_string_literal: true

require 'fluent/plugin/filter'
require 'nomad'

module Fluent
  module Plugin
    class FilterNomad < Fluent::Plugin::Filter
      @@nomad_client_factory_repo = {}

      def self.registry_nomad_client_factory(name, &factory)
        @@nomad_client_factory_repo[name.to_sym] = factory
      end

      registry_nomad_client_factory(:default) do |opts|
        Nomad::NomadClient.load_from_env(**opts)
      end

      # Register this filter as "passthru"
      Fluent::Plugin.register_filter('nomad', self)

      # Loader Thread helper to run the Nomad client in background
      helpers :timer

      # config_param works like other plugins

      desc 'The record field containing the alloc id'
      config_param :alloc_id_field, :string

      desc '(Optional) Nomad server address to execute API calls'
      config_param :nomad_addr, :string, default: nil

      desc '(Optional) Network interface name to use for local Nomad client is running locally'
      config_param :nomad_ifname, :string, default: nil

      desc '(Optional) Nomad token to authenticate API calls'
      config_param :nomad_token, :string, secret: true, default: nil

      desc '(Optional) Nomad client factory to create Nomad client'
      config_param :nomad_client_factory, :string, default: :default

      desc '(Optional) Nomad allocation cache refresh interval in seconds'
      config_param :nomad_alloc_cache_refresh_interval, :time, default: 15

      def configure(conf)
        super
        @alloc_map_update_queue = Queue.new
        @filter_tick = 0
        nomad_client_factory_kwargs = {
          nomad_addr: @nomad_addr,
          nomad_token: @nomad_token,
          nomad_ifname: @nomad_ifname
        }
        @nomad_client = @@nomad_client_factory_repo[@nomad_client_factory.to_sym].call(nomad_client_factory_kwargs)
        begin
          @alloc_map_cache = @nomad_client.list_allocations
        rescue Nomad::NomadError => e
          @alloc_map_cache = {}
          log.warn("Nomad client error: #{e}")
        end
        initial_cache_entries = @alloc_map_cache.size
        log.info("Nomad client initialized with nomad addr: #{@nomad_addr}, initial cache entries: #{initial_cache_entries}")
      end

      def start
        super
        log.info('Starting allocation cache update timer thread')
        timer_execute(:nomad_alloc_cache_update, @nomad_alloc_cache_refresh_interval, repeat: true) do
          log.info('Updating allocation cache')
          begin
            allocation_map = @nomad_client.list_allocations
          rescue Nomad::NomadError => e
            allocation_map = {}
            log.error("Nomad client error: #{e}")
          end
          @alloc_map_update_queue.push(allocation_map)
        end
      end

      # Tries to fetch the allocation summary from the cache.
      # If the allocation is not found, it tries to see if any cache update is pending, thus the "forgiving" prefix.
      #
      # @param alloc_id [String] The allocation ID to fetch.
      # @return [Hash, nil] The allocation summary if found, otherwise nil..
      def forgiving_fetch_alloc_summary(alloc_id)
        @alloc_map_cache[alloc_id] || begin
          log.warn("Allocation #{alloc_id} not found in cache, fetching from Nomad")
          try_update_alloc_cache
          @alloc_map_cache[alloc_id]
        end
      end

      def try_update_alloc_cache
        return if @alloc_map_update_queue.empty?

        begin
          loop do
            @alloc_map_cache = @alloc_map_update_queue.pop(true)
          end
        rescue ThreadError
          # ignore
        end
        log.info('Updated allocation cache')
      end

      # This method is called for each record to filter it.
      # It retrieves the allocation summary for the given alloc_id and merges it into the record.
      # # If the alloc_id is not present in the record, it logs a warning and returns the original
      #
      # @param _tag [String] The tag of the record (not used in this filter).
      # @param _time [Integer] The time of the record (not used in this filter).
      # @param record [Hash] The record to filter.
      def filter(_tag, _time, record)
        try_update_alloc_cache
        record = record.transform_keys(&:to_sym)
        alloc_id = record[@alloc_id_field.to_sym]
        if alloc_id.nil?
          log.warn("Record does not contain alloc_id field #{@alloc_id_field}")
          return record
        end
        alloc_summary = forgiving_fetch_alloc_summary alloc_id
        log.warn("Allocation #{alloc_id} not found in cache") if alloc_summary.nil?
        record.merge!(alloc_summary || {})
      end
    end
  end
end
