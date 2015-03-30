#!/usr/bin/env ruby

$:.push(File.expand_path(File.join(__FILE__, '..', 'lib')))

require 'sinatra'
require 'influx'
require 'haml'
require 'date'

influxdb = Influx::Db.new

get '/' do
  today = Time.now.strftime("%Y-%m-%d")
  redirect "/#{today}/#{today}"
end

get '/alert-frequency/?' do
  today = Time.now.strftime("%Y-%m-%d")
  redirect "/alert-frequency/#{today}/#{today}"
end

get '/alert-response/?' do
  today = Time.now.strftime("%Y-%m-%d")
  redirect "/alert-response/#{today}/#{today}"
end

get '/noise-candidates/?' do
  today = Time.now.strftime("%Y-%m-%d")
  redirect "/noise-candidates/#{today}/#{today}"
end

get '/:start_date/:end_date' do
  @categories = [
    'not set',
    'real',
    'improved',
    'self recovered',
    'needs documentation',
    'unclear, needs discussion',
  ]
  @start_date = params["start_date"]
  @end_date   = params["end_date"]
  @incidents = influxdb.find_incidents(@start_date, @end_date)
  haml :"index"
end

get '/alert-frequency/:start_date/:end_date' do
  @start_date = params["start_date"]
  @end_date   = params["end_date"]
  @incidents  = influxdb.incident_frequency(@start_date, @end_date)
  @total      = @incidents.map { |x| x['count'] }.inject(:+)
  @series = @incidents.map { |incident|
    name = incident['entity'].gsub(/.bulletproof.net$/, '')
    # Truncate long check names by removing everything after and including the second -
    name << ":#{incident['check'].gsub(/-.+(-.+)/, '')}" unless incident['check'].nil?
    {
      :name => name,
      :data => [incident['count']]
    }
  }.slice(0, 50).to_json
  haml :"alert-frequency"
end

get '/alert-response/:start_date/:end_date' do
  @start_date = params["start_date"]
  @end_date   = params["end_date"]
  @incidents  = influxdb.alert_response(@start_date, @end_date)
  # Build graph data
  ack_data = @incidents.map { |i|
    {
      name: i['incident_key'],
      x: i['alert_time'] * 1000,
      y: i['time_to_ack']
    }
  }.compact.sort_by { |k| k[:x] }
  resolve_data = @incidents.map { |i|
    {
      name: i['incident_key'],
      x: i['alert_time'] * 1000,
      y: i['time_to_resolve']
    }
  }.compact.sort_by { |k| k[:x] }
  @series = [
    {
      :name => 'Time until acknowledgement of alert',
      :data => ack_data
    },
    {
      :name => "Time until alert was resolved",
      :data => resolve_data
    }
  ].to_json
  # Build table data
  @total      = @incidents.count
  @acked      = @incidents.reject { |x| x['ack_by'].nil? }.count
  @incidents.each do |incident|
    incident['entity'], incident['check'] = incident['incident_key'].split(':', 2)
    incident['ack_by'] = 'N/A' if incident['ack_by'].nil?
    incident['time_to_ack'] = 'N/A' if incident['time_to_ack'] == 0
    incident['time_to_resolve'] = 'N/A' if incident['time_to_resolve'] == 0
  end
  haml :"alert-response"
end

get '/noise-candidates/:start_date/:end_date' do
  @start_date = params["start_date"]
  @end_date   = params["end_date"]
  @incidents  = influxdb.noise_candidates(@start_date, @end_date)
  @total      = @incidents.count
  haml :"noise-candidates"
end

post '/:date' do
  uri = params["date"]
  params.delete("date")
  params.delete("splat")
  params.delete("captures")
  influxdb.save_categories(params)
  redirect "/#{uri}"
end
