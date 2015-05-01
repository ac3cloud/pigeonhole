#!/usr/bin/env ruby

$:.push(File.expand_path(File.join(__FILE__, '..', '..', 'lib')))

require 'time'
require 'methadone'
require 'influx'

include Methadone::Main
include Methadone::CLILogging

main do
  raise "Sort by must be one of frequency, percentile, or incident_key" unless %w(frequency percentile incident_key).include?(options[:s])
  influxdb    = Influx::Db.new
  opts = {
    :start_date  => "#{options[:t]} ago",
    :finish_date => 'now',
    :percentage  => options[:p],
    :more_than  => options[:m],
    :recover_within => options[:r],
    :sort_by     => options[:s]
  }
  recommendations = influxdb.threshold_recommendations(opts)
  recommendations.each do |r|
    puts "#{r[:incident_key]}: #{r[:fixed]} out of #{r[:count]} alerts would not have been generated with a threshold of #{r[:formatted_threshold]}"
  end
  puts "Total: #{recommendations.count}"
end

use_log_level_option

description "Calculates suggested alert thresholds for removing X% of alerts over a given time period"

on("-p percent", "--percent-to-remove", "The percent of alerts to remove")
on("-t duration", "--time-period", "The amount of time we should look back")
on("-m more-than", "--more-than", "Only return results that have more than x occurences")
on("-r recover-within", "--recover-within", "Only return results that recover within this amount of time")
on("-s sort-by", "--sort-by", "The field we should sort the returned data by - frequency, percentile, or incident_key")

go!
