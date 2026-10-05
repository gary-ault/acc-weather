#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'weather_lib'
exit Weather::CLI.run(:metric, ARGV)
