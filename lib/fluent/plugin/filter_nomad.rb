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
        nomad_client_factory_kwargs = {
          nomad_addr: @nomad_addr,
          nomad_token: @nomad_token,
          nomad_ifname: @nomad_ifname
        }
        @nomad_client = @@nomad_client_factory_repo[@nomad_client_factory.to_sym].call(nomad_client_factory_kwargs)
        @alloc_map_cache = @nomad_client.list_allocations
        log.info("Nomad client initialized with nomad addr: #{@nomad_addr}")
      end

      def start
        super
        timer_execute(:nomad_alloc_cache_update, @nomad_alloc_cache_refresh_interval, repeat: true) do
          allocation_map = @nomad_client.list_allocations
          @alloc_map_update_queue.push(allocation_map)
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

      def filter(_tag, _time, record)
        record = record.transform_keys(&:to_sym)
        alloc_id = record[@alloc_id_field.to_sym]
        if alloc_id.nil?
          log.warn("Record does not contain alloc_id field #{@alloc_id_field}")
          return record
        end
        alloc_summary = @alloc_map_cache[alloc_id]
        if alloc_summary.nil?
          log.warn("Allocation #{alloc_id} not found in cache")
        else
          record.merge!(alloc_summary)
        end
        record
      end
    end
  end
end
