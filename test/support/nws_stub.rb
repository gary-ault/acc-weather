# frozen_string_literal: true

# Loaded only by subprocess tests via ruby -r; never shipped in the plugin.
require 'net/http'
require 'json'

module TemperatureTestHTTP
  def get_response(uri)
    expected = "https://api.weather.gov/stations/#{ENV.fetch('TEST_NWS_STATION', 'KSJC')}/observations/latest"
    raise "Unexpected request: #{uri}" unless uri.to_s == expected
    raise Net::ReadTimeout, 'simulated timeout' if ENV['TEST_NWS_ERROR'] == 'timeout'
    code = ENV.fetch('TEST_NWS_STATUS', '200')
    response = Net::HTTPResponse::CODE_TO_OBJ.fetch(code).new('1.1', code, 'test response')
    response.instance_variable_set(:@read, true)
    response.body = ENV.fetch('TEST_NWS_BODY')
    response
  end
end

Net::HTTP.singleton_class.prepend(TemperatureTestHTTP)
