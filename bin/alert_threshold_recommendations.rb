#!/usr/bin/env ruby

$LOAD_PATH.push(File.expand_path(File.join(__FILE__, '..', '..', 'lib')))

require 'time'
require 'methadone'
require 'influx'

include Methadone::Main
include Methadone::CLILogging

main do
  raise 'Sort by must be one of frequency, threshold, or incident_key' unless %w(frequency threshold incident_key).include?(options[:s])
  influxdb = Influx::Db.new
  opts = {
    :start_date  => "#{options[:t]} ago",
    :finish_date => 'now',
    :percentage  => options[:p],
    :more_than  => options[:m],
    :recover_within => options[:r],
    :sort_by     => options[:s]
  }
  recommendations = influxdb.threshold_recommendations(opts)
  fixed = 0
  total = 0
  incident_key_total = recommendations.count
  recommendations.each do |r|
    fixed += r[:fixed]
    total += r[:count]
    puts "#{r[:incident_key]}: #{r[:fixed]} out of #{r[:count]} alerts would not have been generated with a threshold of #{r[:formatted_threshold]}"
  end
  puts "Total: #{fixed} out of #{total} alerts would not have been generated over #{incident_key_total} incident_keys"
end

use_log_level_option

description 'Calculates suggested alert thresholds for removing X% of alerts over a given time period'

on('-p percent', '--percent-to-remove', 'The percent of alerts to remove')
on('-t duration', '--time-period', 'The amount of time we should look over')
on('-m more-than', '--more-than', 'Only return results that have more than Y occurences')
on('-r recover-within', '--recover-within', 'Only return results that recover within this amount of time')
on('-s sort-by', '--sort-by', 'The field we should sort the returned data by - frequency, threshold, or incident_key')

go!
