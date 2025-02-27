#!/usr/bin/env ruby
require 'logger'
require 'pry'
require 'sinatra'
require 'securerandom'
require 'digest/sha2'
require 'rack/throttle'
require 'redis'

STDOUT.sync = true
LOGGER = Logger.new(STDOUT)

if File.exist?(__dir__ + "/config.local.rb")
  require_relative 'config.local'
else
  require_relative 'config'
end

require_relative 'lib/nats'
require_relative 'lib/pow-cache'

NATSForwarder.start

class AODGate < Sinatra::Base
  configure do
    set :sessions, false
    set :logging, true
    set :show_exceptions, true
    set :run, false
    set bind: "0.0.0.0"
    set port: ENV['POW_PORT']
    set server: "puma"
  end

  def initialize
    super
  end

  use Rack::Throttle::Minute, :max => REQUEST_LIMIT[:per_minute]
  use Rack::Throttle::Hourly, :max => REQUEST_LIMIT[:per_hour]
  use Rack::Throttle::Daily, :max => REQUEST_LIMIT[:per_day]

  before do
  end

  get '/pow' do
    challange = { wanted: SecureRandom.hex(POW_RANDOMNESS).unpack("B*")[0][0..POW_DIFFICULITY-1], key: SecureRandom.hex(POW_RANDOMNESS) }
    return challange.to_json
  end

  post '/pow/:topic' do
    halt 404 unless TOPICS.include?(params[:topic])
    halt(905, "Payload too large") unless params[:natsmsg].bytesize <= NATS_PAYLOAD_MAX

    begin
      data = JSON.parse(params[:natsmsg])
    rescue
      halt(901, "Invalid JSON data")
    end

    if params[:topic] == "marketorders.ingest" && data['Orders'].count > 500
      LOGGER.warn("Error 904, Too Much Data. ip: #{request.ip}, topic: marketorders.ingest, order count: #{data['Orders'].count}")
      halt(906, "Too much data")
    end

    if params[:topic] == "goldprices.ingest" && data['Prices'].count > 6730
      LOGGER.warn("Error 904, Too Much Data. ip: #{request.ip}, topic: goldprices.ingest, order count: #{data['Prices'].count}")
      halt(904, "Too much data")
    end

    if params[:topic] == "markethistories.ingest"
      failed = false

      failed = true if data['Timescale'] == 0 && data['MarketHistories'].count > 250
      failed = true if data['Timescale'] == 1 && data['MarketHistories'].count > 290
      failed = true if data['Timescale'] == 2 && data['MarketHistories'].count > 1130


      if failed == true
        LOGGER.warn("Error 904, Too Much Data. ip: #{request.ip}, topic: markethistories.ingest, Timescale: #{data['Timescale']}, MarketHistories count: #{data['MarketHistories'].count}")
        halt(900, "Too much data")
      end
    end

    NATSForwarder.forward(params[:topic], data)
    $POW_MUTEX.synchronize { $POWS.delete(params[:key]) }
    halt(200, "OK")
  end
end

binding.pry if $0 == "pry"
LOGGER.info("Starting server...")
