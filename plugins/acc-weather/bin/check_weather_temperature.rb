#!/usr/bin/env ruby

require 'json'
require 'net/http'
require 'optparse'
require 'time'
require 'uri'

options = {}

OptionParser.new do |opts|
  opts.banner = <<~TEXT
    Usage:
      check_weather_temperature.rb \
        --station KSJC \
        -w 30 \
        -c 35 \
        --above
  TEXT

  opts.on('--station STATION', 'NWS station identifier') do |v|
    options[:station] = v.upcase
  end

  opts.on('-w VALUE', Float, 'Warning threshold') do |v|
    options[:warning] = v
  end

  opts.on('-c VALUE', Float, 'Critical threshold') do |v|
    options[:critical] = v
  end

  opts.on('--above', 'Alert when value exceeds thresholds') do
    options[:direction] = :above
  end

  opts.on('--below', 'Alert when value falls below thresholds') do
    options[:direction] = :below
  end
end.parse!

raise 'Missing --station' unless options[:station]
raise 'Missing -w threshold' unless options.key?(:warning)
raise 'Missing -c threshold' unless options.key?(:critical)
raise 'Specify either --above or --below' unless options[:direction]

if options[:direction] == :above
  raise 'Critical must be greater than warning' \
    unless options[:critical] > options[:warning]
else
  raise 'Critical must be less than warning' \
    unless options[:critical] < options[:warning]
end

url = URI(
  "https://api.weather.gov/stations/#{options[:station]}/observations/latest"
)

response = Net::HTTP.get_response(url)

raise "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

json = JSON.parse(response.body)

temp = json.dig('properties', 'temperature', 'value')

raise 'Temperature missing' if temp.nil?

status = 0
state = 'OK'

if options[:direction] == :above
  if temp >= options[:critical]
    status = 2
    state = 'CRITICAL'
  elsif temp >= options[:warning]
    status = 1
    state = 'WARNING'
  end
else
  if temp <= options[:critical]
    status = 2
    state = 'CRITICAL'
  elsif temp <= options[:warning]
    status = 1
    state = 'WARNING'
  end
end

puts(
  "#{state} - " \
  "temperature=#{temp}C " \
  "station=#{options[:station]} " \
  "mode=#{options[:direction]} " \
  "warning=#{options[:warning]} " \
  "critical=#{options[:critical]}"
)

exit status