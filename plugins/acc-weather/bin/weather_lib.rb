# frozen_string_literal: true

require 'json'
require 'net/http'
require 'openssl'
require 'optparse'
require 'time'
require 'uri'
require 'timeout'

module Weather
  VERSION = '0.1.1'

  class Error < StandardError
  end

  INPUT_UNITS = {
    'wmoUnit:km_h-1' => 1.0 / 3.6,
    'wmoUnit:m_s-1' => 1.0,
    'wmoUnit:mi_h-1' => 0.44704,
    'wmoUnit:kn' => 1852.0 / 3600
  }.freeze

  OUTPUT_UNITS = {
    'mph' => 1.0 / 0.44704,
    'kph' => 3.6,
    'mps' => 1.0,
    'knots' => 3600.0 / 1852
  }.freeze

  def self.number(value, name)
    unless value.is_a?(Numeric) && value.finite?
      raise Error, "#{name} must be a finite number"
    end

    value.to_f
  end

  class Client
    def initialize(user_agent:, timeout: 10)
      @user_agent = user_agent
      @timeout = timeout
    end

    def get(url)
      uri = URI.parse(url)

      unless uri.scheme == 'https' &&
             uri.host == 'api.weather.gov' &&
             uri.port == 443 &&
             !uri.userinfo
        raise Error, 'API link must use https://api.weather.gov'
      end

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = @timeout
      http.read_timeout = @timeout
      http.write_timeout = @timeout if http.respond_to?(:write_timeout=)
      http.max_retries = 0 if http.respond_to?(:max_retries=)

      request = Net::HTTP::Get.new(uri.request_uri)
      request['User-Agent'] = @user_agent
      request['Accept'] = 'application/geo+json'

      response = Timeout.timeout(@timeout) { http.request(request) }

      unless response.is_a?(Net::HTTPSuccess)
        raise Error, "NWS HTTP #{response.code} for #{uri.path}"
      end

      data = JSON.parse(response.body)
      raise Error, 'NWS response must be a JSON object' unless data.is_a?(Hash)

      data
    rescue JSON::ParserError
      raise Error, 'NWS returned invalid JSON'
    rescue URI::InvalidURIError
      raise Error, 'NWS returned an invalid API link'
    rescue Timeout::Error, IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError => e
      raise Error, "NWS request failed (#{e.class})"
    end
  end

  class Reader
    def initialize(client, clock: nil)
      @client = client
      @clock = clock || lambda { Time.now }
    end

    def self.distance_km(lat1, lon1, lat2, lon2)
      rad = Math::PI / 180
      a = Math.sin((lat2 - lat1) * rad / 2)**2 +
          Math.cos(lat1 * rad) * Math.cos(lat2 * rad) *
          Math.sin((lon2 - lon1) * rad / 2)**2

      6371.0088 * 2 * Math.asin(Math.sqrt([[a, 0].max, 1].min))
    end

    def station_info(feature, options)
      return nil unless feature.is_a?(Hash)

      properties = feature['properties']
      geometry = feature['geometry']
      return nil unless properties.is_a?(Hash)
      return nil unless geometry.is_a?(Hash) && geometry['type'] == 'Point'

      identifier = properties['stationIdentifier']
      coords = geometry['coordinates']

      return nil unless identifier.is_a?(String)
      return nil unless identifier.match?(/\A[A-Za-z0-9_-]{1,32}\z/)
      return nil unless coords.is_a?(Array) && coords.size >= 2

      lon, lat = coords.first(2)
      return nil unless [lon, lat].all? { |value| value.is_a?(Numeric) && value.finite? }
      return nil unless (-180..180).cover?(lon) && (-90..90).cover?(lat)

      distance = self.class.distance_km(
        options[:latitude],
        options[:longitude],
        lat,
        lon
      )

      [identifier, distance]
    end

    def read(options)
      station = if options[:station]
                  configured = @client.get(
                    "https://api.weather.gov/stations/#{options[:station]}"
                  )
                  result = station_info(configured, options)

                  unless result && result[0] == options[:station]
                    raise Error, 'Configured station has invalid metadata'
                  end

                  result
                else
                  point_url = format(
                    'https://api.weather.gov/points/%.4f,%.4f',
                    options[:latitude],
                    options[:longitude]
                  )
                  point = @client.get(point_url)
                  link = point.dig('properties', 'observationStations')

                  unless link.is_a?(String)
                    raise Error, 'No observation stations link for location'
                  end

                  collection = @client.get(link)
                  features = collection['features']

                  unless features.is_a?(Array)
                    raise Error, 'Invalid observation stations response'
                  end

                  usable = features.map { |feature| station_info(feature, options) }.compact
                  nearest = usable.min_by { |item| [item[1], item[0]] }
                  raise Error, 'No usable observation stations for location' unless nearest

                  nearest
                end

      station_id, distance = station

      if distance > options[:max_distance_km]
        raise Error, format(
          'Station %s is %.1f km away; limit %.1f km',
          station_id,
          distance,
          options[:max_distance_km]
        )
      end

      observation_url = "https://api.weather.gov/stations/#{station_id}/observations/latest"
      data = @client.get(observation_url)
      properties = data['properties']
      raise Error, 'Missing observation properties' unless properties.is_a?(Hash)

      begin
        timestamp = Time.iso8601(properties.fetch('timestamp'))
      rescue KeyError, ArgumentError, TypeError
        raise Error, 'Missing or invalid observation timestamp'
      end

      age = @clock.call - timestamp

      if age < -300
        raise Error, 'Observation timestamp is more than 5 minutes in the future'
      end

      if age > options[:max_age_minutes] * 60
        raise Error, format(
          'Observation from %s is stale (%.1f minutes)',
          station_id,
          age / 60
        )
      end

      wind = properties['windSpeed']

      unless wind.is_a?(Hash) && !wind['value'].nil?
        raise Error, 'Wind speed is unavailable'
      end

      speed = Weather.number(wind['value'], 'Wind speed')
      raise Error, 'Wind speed cannot be negative' if speed.negative?

      factor = INPUT_UNITS[wind['unitCode']]

      unless factor
        raise Error, "Unsupported wind speed unit: #{wind['unitCode']}"
      end

      value = speed * factor * OUTPUT_UNITS.fetch(options[:units])
      raise Error, 'Converted wind speed is not finite' unless value.finite?

      {
        value: value,
        station: station_id,
        timestamp: timestamp,
        age_minutes: [age / 60, 0].max,
        distance_km: distance,
        units: options[:units]
      }
    end
  end

  class CLI
    def self.options(mode, argv)
      opts = {
        units: 'mph',
        max_age_minutes: 90.0,
        max_distance_km: 50.0,
        timeout: 10.0
      }

      parser = OptionParser.new do |option_parser|
        command = mode == :event ? 'check' : 'metrics'
        option_parser.banner = "Usage: #{command}_weather_wind.rb [options]"

        option_parser.on('--latitude NUMBER', Float, 'Data center latitude (required)') do |value|
          opts[:latitude] = value
        end
        option_parser.on('--longitude NUMBER', Float, 'Data center longitude (required)') do |value|
          opts[:longitude] = value
        end
        option_parser.on('--ci-id ID', 'Data center CI sys_id or stable safe identifier (required)') do |value|
          opts[:ci_id] = value
        end
        option_parser.on('--user-agent TEXT', 'Application/contact identification required by NWS') do |value|
          opts[:user_agent] = value
        end
        option_parser.on('--station ID', 'Pin a verified NWS station; otherwise choose nearest') do |value|
          opts[:station] = value
        end
        option_parser.on('--units UNIT', OUTPUT_UNITS.keys, 'mph (default), kph, mps, knots') do |value|
          opts[:units] = value
        end
        option_parser.on('--max-age-minutes NUMBER', Float, 'Freshness limit; default 90') do |value|
          opts[:max_age_minutes] = value
        end
        option_parser.on('--max-distance-km NUMBER', Float, 'Station distance limit; default 50') do |value|
          opts[:max_distance_km] = value
        end
        option_parser.on('--timeout NUMBER', Float, 'Seconds per HTTP request; default 10') do |value|
          opts[:timeout] = value
        end

        if mode == :event
          option_parser.on('-w', '--warning NUMBER', Float, 'Warning at or above this speed (required)') do |value|
            opts[:warning] = value
          end
          option_parser.on('-c', '--critical NUMBER', Float, 'Critical at or above this speed (required)') do |value|
            opts[:critical] = value
          end
        end

        option_parser.on('-h', '--help', 'Show options') do
          opts[:help] = true
        end
      end

      parser.parse!(argv)
      raise Error, 'Unexpected positional arguments' unless argv.empty?
      return [opts, parser] if opts[:help]

      [:latitude, :longitude, :ci_id, :user_agent].each do |key|
        raise Error, "Missing --#{key.to_s.tr('_', '-')}" unless opts.key?(key)
      end

      {
        latitude: (-90..90),
        longitude: (-180..180)
      }.each do |key, range|
        value = Weather.number(opts[key], key)
        raise Error, "Invalid #{key}" unless range.cover?(value)
      end

      unless opts[:ci_id].match?(/\A[A-Za-z0-9_-]{1,128}\z/)
        raise Error, 'CI ID must contain only letters, digits, underscores or hyphens (1-128 characters)'
      end

      unless opts[:user_agent].match?(/\A[\x20-\x7e]{3,256}\z/) && !opts[:user_agent].strip.empty?
        raise Error, 'User-Agent must be 3-256 printable ASCII characters'
      end

      if opts[:station] && !opts[:station].match?(/\A[A-Za-z0-9_-]{1,32}\z/)
        raise Error, 'Invalid station ID'
      end

      [:max_age_minutes, :max_distance_km, :timeout].each do |key|
        value = Weather.number(opts[key], key)
        raise Error, "#{key} must be positive" unless value.positive?
      end

      if opts[:timeout] > 30
        raise Error, 'Timeout must be at most 30 seconds per request'
      end

      if mode == :event
        [:warning, :critical].each do |key|
          raise Error, "Missing --#{key}" unless opts.key?(key)

          value = Weather.number(opts[key], key)
          raise Error, "#{key} cannot be negative" if value.negative?
        end

        unless opts[:critical] > opts[:warning]
          raise Error, 'Critical must be greater than warning'
        end
      end

      [opts, parser]
    end

    def self.run(mode, argv, out: $stdout, err: $stderr, reader: nil)
      opts, parser = options(mode, argv.dup)

      if opts[:help]
        out.puts parser
        return 0
      end

      reader ||= Reader.new(
        Client.new(
          user_agent: opts[:user_agent],
          timeout: opts[:timeout]
        )
      )

      sample = reader.read(opts)

      if mode == :metric
        out.puts format(
          'weather.%s.wind_speed_%s %.6f %d',
          opts[:ci_id],
          opts[:units],
          sample[:value],
          sample[:timestamp].to_i
        )
        return 0
      end

      code = if sample[:value] >= opts[:critical]
               2
             elsif sample[:value] >= opts[:warning]
               1
             else
               0
             end

      out.puts format(
        '%s - ci=%s wind_speed=%.2f %s warning=%g critical=%g station=%s distance=%.1fkm observed=%s age=%.1fmin',
        %w[OK WARNING CRITICAL][code],
        opts[:ci_id],
        sample[:value],
        opts[:units],
        opts[:warning],
        opts[:critical],
        sample[:station],
        sample[:distance_km],
        sample[:timestamp].utc.iso8601,
        sample[:age_minutes]
      )

      code
    rescue StandardError => e
      known_error = e.is_a?(Error) || e.is_a?(OptionParser::ParseError)
      message = known_error ? e.message : "Unexpected failure (#{e.class}): #{e.message}"
      destination = mode == :metric ? err : out
      destination.puts "UNKNOWN - #{message.gsub(/[\r\n]+/, ' ')}"
      3
    end
  end
end
