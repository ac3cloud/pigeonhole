#!/usr/bin/env ruby

$:.push(File.expand_path(File.join(__FILE__, '..', 'lib')))

require 'sinatra'
require 'influx'
require 'haml'
require 'date'
require 'highcharts'
require 'pagerduty'
require 'methadone'

include Methadone::CLILogging

influxdb = Influx::Db.new
pagerduty = Pagerduty.new

get '/' do
  haml :"index"
end

get '/categorisation/?' do
  today = Time.now.strftime("%Y-%m-%d")
  redirect "/categorisation/#{today}/#{today}"
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

get '/categorisation/:start_date/:end_date' do
  @categories = [
    'not set',
    'real',
    'improved',
    'self recovered',
    'needs documentation',
    'unclear, needs discussion'
  ]
  @start_date = params["start_date"]
  @end_date   = params["end_date"]
  @incidents = influxdb.find_incidents(@start_date, @end_date)
  haml :"categorisation"
end

get '/alert-frequency/:start_date/:end_date' do
  @start_date = params["start_date"]
  @end_date   = params["end_date"]
  @incidents  = influxdb.incident_frequency(@start_date, @end_date)
  @total      = @incidents.map { |x| x['count'] }.inject(:+)
  @series     = HighCharts.alert_frequency(@incidents)
  haml :"alert-frequency"
end

get '/alert-response/:start_date/:end_date' do
  @start_date = params["start_date"]
  @end_date   = params["end_date"]
  resp = influxdb.alert_response(@start_date, @end_date)
  @series     = HighCharts.alert_response(resp)
  # Build table data
  @incidents  = resp[:incidents] || []
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

post '/:start_date/:end_date' do
  uri = "#{params["start_date"]}/#{params["end_date"]}"
  opts = {
    :start_date => params[:"start_date"],
    :end_date   => params[:end_date]
  }
  params.delete("start_date")
  params.delete("end_date")
  params.delete("splat")
  params.delete("captures")
  opts[:data] = params
  influxdb.save_categories(opts)
  redirect "/#{uri}"
end

post '/pagerduty' do
  request.body.rewind  # in case someone already read it
  data = JSON.parse(request.body.read)
  begin
    incidents = pagerduty.incidents_from_webhook(data)
    raise 'No incidents found' if incidents.empty?
    incident_ids = incidents.map { |x| x[:id] }
    influxdb.insert_incidents(incidents)
    status 200
    "Inserted incidents: #{incident_ids.join(', ')}"
  rescue RuntimeError => e
    status 500
    {
      :error => e.class,
      :message => e.message
    }.to_json
  end
end
