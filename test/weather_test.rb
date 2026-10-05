# frozen_string_literal: true

require 'minitest/autorun'
require 'stringio'
require 'open3'
require 'rbconfig'
require_relative '../plugins/acc-weather/bin/weather_lib'

class WeatherTest < Minitest::Test
  NOW = Time.iso8601('2026-10-05T00:00:00Z')
  class FakeClient
    attr_reader :calls
    def initialize(responses)
      @responses, @calls = responses, []
    end
    def get(url)
      @calls << url
      @responses.fetch(url)
    end
  end

  def setup
    @args = %w[--latitude 36 --longitude -94 --ci-id dc1 --user-agent acc-weather-tests]
    @opts = Weather::CLI.options(:metric, @args.dup)[0]
    @observation = {'properties' => {'timestamp' => (NOW - 600).iso8601,
                                     'windSpeed' => {'value' => 36, 'unitCode' => 'wmoUnit:km_h-1'}}}
    @responses = {
      'https://api.weather.gov/points/36.0000,-94.0000' => {'properties' => {'observationStations' => 'https://api.weather.gov/stations?point=36,-94'}},
      'https://api.weather.gov/stations?point=36,-94' => {'features' => [station('FAR', -94.4, 36), station('NEAR', -94.01, 36)]},
      'https://api.weather.gov/stations/NEAR' => station('NEAR', -94.01, 36),
      'https://api.weather.gov/stations/NEAR/observations/latest' => @observation
    }
    @client = FakeClient.new(@responses)
    @reader = Weather::Reader.new(@client, clock: -> { NOW })
  end

  def station(id, lon, lat)
    {'properties' => {'stationIdentifier' => id}, 'geometry' => {'type' => 'Point', 'coordinates' => [lon, lat]}}
  end

  def cli(mode, extra = [], reader = @reader)
    out, err = StringIO.new, StringIO.new
    code = Weather::CLI.run(mode, @args + extra, out: out, err: err, reader: reader)
    [code, out.string, err.string]
  end

  def test_nearest_station_and_mph_conversion
    sample = @reader.read(@opts)
    assert_equal 'NEAR', sample[:station]
    assert_in_delta 22.3693629, sample[:value], 0.000001
    assert_equal 10, sample[:age_minutes]
  end

  def test_all_input_units
    {'wmoUnit:km_h-1' => 36, 'wmoUnit:m_s-1' => 10,
     'wmoUnit:mi_h-1' => 22.369362920544, 'wmoUnit:kn' => 19.438444924406}.each do |unit, value|
      @observation['properties']['windSpeed'] = {'value' => value, 'unitCode' => unit}
      assert_in_delta 10, @reader.read(@opts.merge(units: 'mps'))[:value], 0.000001
    end
  end

  def test_output_units
    {'mph' => 22.369362920544, 'kph' => 36, 'mps' => 10, 'knots' => 19.438444924406}.each do |unit, value|
      assert_in_delta value, @reader.read(@opts.merge(units: unit))[:value], 0.000001
    end
  end

  def test_event_boundaries_and_no_metric_output
    [[9.999, 0], [10, 1], [19.999, 1], [20, 2]].each do |value, expected|
      @observation['properties']['windSpeed'] = {'value' => value, 'unitCode' => 'wmoUnit:m_s-1'}
      code, out, err = cli(:event, %w[--units mps -w 10 -c 20])
      assert_equal expected, code
      assert_match(/\A#{%w[OK WARNING CRITICAL][expected]} - ci=dc1/, out)
      refute_match(/weather\.dc1\./, out)
      assert_empty err
    end
  end

  def test_metric_is_one_line_with_observation_timestamp
    code, out, err = cli(:metric)
    assert_equal 0, code
    assert_equal "weather.dc1.wind_speed_mph 22.369363 #{(NOW - 600).to_i}\n", out
    assert_empty err
  end

  def test_calm_is_valid
    @observation['properties']['windSpeed']['value'] = 0
    assert_equal 0, cli(:metric)[0]
    assert_equal 0, cli(:event, %w[-w 10 -c 20])[0]
  end

  def test_missing_negative_non_numeric_and_unknown_unit_fail_without_metric
    [nil, -1, '10', Float::INFINITY].each do |value|
      @observation['properties']['windSpeed']['value'] = value
      code, out, err = cli(:metric)
      assert_equal 3, code
      assert_empty out
      assert_match(/UNKNOWN/, err)
    end
    @observation['properties']['windSpeed'] = {'value' => 10, 'unitCode' => 'other'}
    assert_equal 3, cli(:metric)[0]
  end

  def test_stale_future_and_invalid_timestamps
    [(NOW - 5401).iso8601, (NOW + 301).iso8601, nil, 'garbage'].each do |timestamp|
      @observation['properties']['timestamp'] = timestamp
      code, out, err = cli(:metric)
      assert_equal 3, code
      assert_empty out
      assert_match(/UNKNOWN/, err)
    end
    @observation['properties']['timestamp'] = (NOW - 5400).iso8601
    assert_equal 0, cli(:metric)[0]
  end

  def test_station_override_uses_same_distance_validation
    sample = @reader.read(@opts.merge(station: 'NEAR'))
    assert_equal 'NEAR', sample[:station]
    assert_equal 2, @client.calls.length
    assert_raises(Weather::Error) { @reader.read(@opts.merge(station: 'NEAR', max_distance_km: 0.01)) }
  end

  def test_empty_or_malformed_station_collection
    @responses['https://api.weather.gov/stations?point=36,-94']['features'] = [nil, {}, station('../unsafe', -94, 36)]
    assert_raises(Weather::Error) { @reader.read(@opts) }
  end

  def test_validation_and_event_threshold_requirements
    [%w[--latitude 91], %w[--longitude -181], %w[--max-age-minutes 0],
     %w[--timeout 31], %w[--ci-id dc.1], %w[--station ../bad], %w[--units invalid],
     %w[--max-distance-km -1], ['--user-agent', "bad\nheader"], %w[extra]].each do |extra|
      assert_equal 3, cli(:metric, extra)[0], extra.inspect
    end
    assert_equal 3, cli(:event)[0]
    assert_equal 3, cli(:event, %w[-w 20 -c 10])[0]
    assert_equal 3, cli(:event, %w[-w 20 -c 20])[0]
    assert_equal 3, cli(:event, %w[-w -1 -c 20])[0]
    assert_equal 3, cli(:metric, %w[-w 10])[0]
    assert_equal 3, Weather::CLI.run(:metric, [], out: StringIO.new, err: StringIO.new)
  end

  def test_missing_wind_event_is_unknown_not_ok
    @observation['properties']['windSpeed'] = nil
    code, out, = cli(:event, %w[-w 10 -c 20])
    assert_equal 3, code
    assert_match(/UNKNOWN/, out)
  end

  def test_network_failure_does_not_emit_metric
    reader = Object.new
    def reader.read(_opts)
      raise Weather::Error, 'NWS HTTP 503'
    end
    code, out, err = cli(:metric, [], reader)
    assert_equal 3, code
    assert_empty out
    assert_match(/503/, err)
  end

  def test_client_restricts_api_links
    client = Weather::Client.new(user_agent: 'test')
    ['http://api.weather.gov/stations', 'https://example.org/', 'https://api.weather.gov:444/',
     'https://user:password@api.weather.gov/'].each do |url|
      assert_raises(Weather::Error) { client.get(url) }
    end
  end

  def test_client_http_errors_and_headers
    client = Weather::Client.new(user_agent: 'test-agent', timeout: 2)
    http = Object.new
    class << http
      attr_accessor :use_ssl, :verify_mode, :open_timeout, :read_timeout, :write_timeout, :max_retries, :response, :request_seen
      def request(req)
        self.request_seen = req
        response
      end
    end
    ['429', '503', '404', '301'].each do |status|
      http.response = Net::HTTPResponse.new('1.1', status, 'Error')
      Net::HTTP.stub(:new, http) do
        assert_raises(Weather::Error) { client.get('https://api.weather.gov/points/36,-94') }
      end
    end
    assert_equal 'test-agent', http.request_seen['User-Agent']
    assert_equal 'application/geo+json', http.request_seen['Accept']
    assert_equal OpenSSL::SSL::VERIFY_PEER, http.verify_mode
    assert_equal 0, http.max_retries
  end

  def test_client_rejects_bad_json_and_handles_timeout
    client = Weather::Client.new(user_agent: 'test')
    http = Object.new
    class << http
      attr_accessor :use_ssl, :verify_mode, :open_timeout, :read_timeout, :write_timeout, :max_retries, :response
      def request(_req)
        raise Timeout::Error if response == :timeout
        response
      end
    end
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    response.instance_variable_set(:@read, true)
    response.body = 'not json'
    http.response = response
    Net::HTTP.stub(:new, http) { assert_raises(Weather::Error) { client.get('https://api.weather.gov/') } }
    http.response = :timeout
    Net::HTTP.stub(:new, http) { assert_raises(Weather::Error) { client.get('https://api.weather.gov/') } }
  end

  def test_real_entrypoints_help_and_exit_codes
    %w[check_weather_wind.rb metrics_weather_wind.rb].each do |script|
      path = File.expand_path("../plugins/acc-weather/bin/#{script}", __dir__)
      out, err, status = Open3.capture3(RbConfig.ruby, path, '--help')
      assert status.success?
      assert_match(/Usage:/, out)
      assert_empty err
      out, err, status = Open3.capture3(RbConfig.ruby, path)
      assert_equal 3, status.exitstatus
      assert_match(/UNKNOWN/, out + err)
      assert_empty out if script.start_with?('metrics')
    end
  end
end
