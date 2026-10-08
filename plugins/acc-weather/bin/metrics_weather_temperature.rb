#!/usr/bin/env ruby

require 'json'
require 'net/http'
require 'optparse'
require 'uri'
require 'time'

options = {}

OptionParser.new do |opts|
  opts.banner = 'Usage: metrics_weather_temperature.rb --station STATION'

  opts.on('--station STATION', 'NWS station identifier') do |v|
    options[:station] = v.upcase
  end
end.parse!

raise 'Missing --station' unless options[:station]

url = URI(
  "https://api.weather.gov/stations/#{options[:station]}/observations/latest"
)

response = Net::HTTP.get_response(url)

raise "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

json = JSON.parse(response.body)

temp = json.dig('properties', 'temperature', 'value')

raise 'Temperature missing' if temp.nil?

timestamp =
  Time.parse(json.dig('properties', 'timestamp')).to_i

puts "weather.temperature_c #{temp} #{timestamp}"
