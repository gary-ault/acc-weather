# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'json'
require 'time'

class TemperatureTest < Minitest::Test
  BIN = File.expand_path('../plugins/acc-weather/bin', __dir__)
  STUB = File.expand_path('support/nws_stub.rb', __dir__)
  OBSERVED = '2026-10-07T12:00:00Z'
  EVENT = 'check_weather_temperature.rb'
  METRIC = 'metrics_weather_temperature.rb'

  def invoke(script, args, temperature: 25, timestamp: OBSERVED, body: nil, status: '200', error: '')
    payload = body || JSON.generate('properties' => {
      'temperature' => {'value' => temperature, 'unitCode' => 'wmoUnit:degC'},
      'timestamp' => timestamp
    })
    env = {'TEST_NWS_BODY' => payload, 'TEST_NWS_STATUS' => status, 'TEST_NWS_ERROR' => error,
           'TEST_NWS_STATION' => 'KSJC'}
    stdout, stderr, result = Open3.capture3(env, RbConfig.ruby, '-r', STUB, File.join(BIN, script), *args)
    [result.exitstatus, stdout, stderr]
  end

  def test_above_thresholds_are_inclusive
    [[29.9, 0, 'OK'], [30, 1, 'WARNING'], [34.9, 1, 'WARNING'], [35, 2, 'CRITICAL'], [40, 2, 'CRITICAL']].each do |value, code, label|
      actual, out, err = invoke(EVENT, %w[--station KSJC -w 30 -c 35 --above], temperature: value)
      assert_equal code, actual
      assert_match(/\A#{label} - temperature=#{value}C station=KSJC mode=above warning=30.0 critical=35.0\n\z/, out)
      assert_empty err
    end
  end

  def test_below_thresholds_are_inclusive
    [[5.1, 0, 'OK'], [5, 1, 'WARNING'], [0.1, 1, 'WARNING'], [0, 2, 'CRITICAL'], [-5, 2, 'CRITICAL']].each do |value, code, label|
      actual, out, err = invoke(EVENT, %w[--station KSJC -w 5 -c 0 --below], temperature: value)
      assert_equal code, actual
      assert_match(/\A#{label} - /, out)
      assert_match(/mode=below/, out)
      assert_empty err
    end
  end

  def test_station_is_uppercased_for_request_and_output
    code, out, err = invoke(EVENT, %w[--station ksjc -w 30 -c 35 --above])
    assert_equal 0, code
    assert_match(/station=KSJC/, out)
    assert_empty err
    assert_equal 0, invoke(METRIC, %w[--station ksjc])[0]
  end

  def test_metric_exact_output_with_observation_time
    code, out, err = invoke(METRIC, %w[--station KSJC], temperature: 21.75)
    assert_equal 0, code
    assert_equal "weather.temperature_c 21.75 #{Time.iso8601(OBSERVED).to_i}\n", out
    assert_empty err
  end

  def test_metric_accepts_zero_and_negative_temperature
    [0, -12.5].each do |value|
      code, out, err = invoke(METRIC, %w[--station KSJC], temperature: value)
      assert_equal 0, code
      assert_equal "weather.temperature_c #{value} #{Time.iso8601(OBSERVED).to_i}\n", out
      assert_empty err
    end
  end

  def assert_error(script, args, message, **response)
    code, out, err = invoke(script, args, **response)
    assert_equal 1, code
    assert_empty out
    assert_match message, err
  end

  def test_required_event_parameters
    assert_error(EVENT, [], /Missing --station/)
    assert_error(EVENT, %w[--station KSJC], /Missing -w threshold/)
    assert_error(EVENT, %w[--station KSJC -w 30], /Missing -c threshold/)
    assert_error(EVENT, %w[--station KSJC -w 30 -c 35], /Specify either --above or --below/)
  end

  def test_required_metric_station
    assert_error(METRIC, [], /Missing --station/)
  end

  def test_invalid_threshold_order
    [%w[-w 35 -c 30 --above], %w[-w 30 -c 30 --above],
     %w[-w 0 -c 5 --below], %w[-w 0 -c 0 --below]].each do |args|
      assert_error(EVENT, %w[--station KSJC] + args, /Critical must be/)
    end
  end

  def test_metric_rejects_event_threshold_flags
    assert_error(METRIC, %w[--station KSJC -w 30], /invalid option/)
  end

  def test_missing_temperature_never_emits_metric_or_ok_event
    assert_error(METRIC, %w[--station KSJC], /Temperature missing/, temperature: nil)
    assert_error(EVENT, %w[--station KSJC -w 30 -c 35 --above], /Temperature missing/, temperature: nil)
  end

  def test_http_failures
    [METRIC, EVENT].each do |script|
      args = %w[--station KSJC]
      args += %w[-w 30 -c 35 --above] if script == EVENT
      %w[429 503].each { |status| assert_error(script, args, /HTTP #{status}/, status: status) }
    end
  end

  def test_bad_json
    assert_error(METRIC, %w[--station KSJC], /JSON::ParserError/, body: 'not JSON')
    assert_error(EVENT, %w[--station KSJC -w 30 -c 35 --above], /JSON::ParserError/, body: 'not JSON')
  end

  def test_metric_invalid_timestamp
    assert_error(METRIC, %w[--station KSJC], /ArgumentError/, timestamp: 'bad time')
  end

  def test_request_timeout
    assert_error(METRIC, %w[--station KSJC], /Net::ReadTimeout/, error: 'timeout')
    assert_error(EVENT, %w[--station KSJC -w 30 -c 35 --above], /Net::ReadTimeout/, error: 'timeout')
  end
end
