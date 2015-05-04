#!/usr/bin/env ruby

$:.push(File.expand_path(File.join(__FILE__, '..', 'lib')))

require 'sinatra'
require 'influx'
require 'haml'
require 'date'
require 'highcharts'
require 'uri'
require 'pagerduty'
require 'methadone'

include Methadone::CLILogging

influxdb = Influx::Db.new
pagerduty = Pagerduty.new

def today
  Time.now.strftime('%Y-%m-%d')
end

get '/' do
  @mapper = {
    'ack' => 'Acknowleged',
    'resolve' => 'Resolved',
    'stddev' => 'Std Dev (σ)',
    '95_percentile' => '95th Percentile',
    'mean' => 'Average (x̄)'
  }
  @types = ["ack", "resolve"]
  @stats = ["mean", "stddev", "95_percentile"]
  @stat_summary = influxdb.generate_stats
  @pagerduty_url = pagerduty.pagerduty_url
  @acked, @unacked = influxdb.unaddressed_alerts
  haml :"index"
end

get '/categorisation/?' do
  redirect "/categorisation/#{today}/#{today}"
end

get '/alert-frequency/?' do
  redirect "/alert-frequency/#{today}/#{today}"
end

get '/alert-response/?' do
  redirect "/alert-response/#{today}/#{today}"
end

get '/noise-candidates/?' do
  redirect "/noise-candidates/#{today}/#{today}"
end

def search_precondition
  return "" unless @search
  "and incident_key =~ /.*#{@search}.*/i"
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
  @search     = params["search"]
  @pagerduty_url = pagerduty.pagerduty_url
  @incidents = influxdb.find_incidents(@start_date, @end_date, {:conditions => search_precondition })
  @incidents.each do |i|
    i['description'] = Digest::SHA512.hexdigest(i['description'])[0..20]
    i['id'] = rand(36**8).to_s(36).upcase
  end
  haml :"categorisation"
end

get '/alert-frequency/:start_date/:end_date' do
  @start_date = params["start_date"]
  @end_date   = params["end_date"]
  @search     = params["search"]
  @incidents  = influxdb.incident_frequency(@start_date, @end_date, search_precondition)
  @incidents.each do |i|
    i['entity'] = Digest::SHA512.hexdigest(i['entity'])[0..20]
    i['check'] = Digest::SHA512.hexdigest(i['check'])[0..20] unless i['check'].nil?
  end
  @total      = @incidents.map { |x| x['count'] }.inject(:+) || 0
  @series     = HighCharts.alert_frequency(@incidents)
  haml :"alert-frequency"
end

get '/alert-response/:start_date/:end_date' do
  @start_date = params["start_date"]
  @end_date   = params["end_date"]
  @search     = params["search"]
  resp = influxdb.alert_response(@start_date, @end_date, search_precondition)
  @series     = HighCharts.alert_response(resp)
  # Build table data
  @incidents  = resp[:incidents] || []
  @total      = @incidents.count
  @acked      = @incidents.reject { |x| x['time_to_ack'] == 0 }.count
  @pagerduty_url = pagerduty.pagerduty_url
  @incidents.each do |incident|
    incident['entity'], incident['check'] = incident['incident_key'].split(':', 2)
    incident['id'] = rand(36**8).to_s(36).upcase
    incident['entity'] = Digest::SHA512.hexdigest(incident['entity'])[0..20]
    incident['check'] = Digest::SHA512.hexdigest(incident['check'])[0..20]
    incident['ack_by'] = incident['ack_by'].nil? ? 'N/A' : rand(36**8).to_s(36).upcase + '@example.com'
    incident['time_to_ack'] = 'N/A' if incident['time_to_ack'] == 0
    incident['time_to_resolve'] = 'N/A' if incident['time_to_resolve'] == 0
  end
  haml :"alert-response"
end

get '/noise-candidates/:start_date/:end_date' do
  @start_date = params["start_date"]
  @end_date   = params["end_date"]
  @search     = params["search"]
  @incidents  = influxdb.noise_candidates(@start_date, @end_date, search_precondition)
  @incidents.each do |i|
    i['entity'] = Digest::SHA512.hexdigest(i['entity'])[0..20]
    i['check'] = Digest::SHA512.hexdigest(i['check'])[0..20] unless i['check'].nil?
  end
  @total      = @incidents.count
  haml :"noise-candidates"
end

post '/categorisation/:start_date/:end_date' do
  uri = "#{params["start_date"]}/#{params["end_date"]}"
  uri += "?search=#{params["search"]}" if params["search"]
  opts = {
    :start_date => params[:start_date],
    :end_date   => params[:end_date],
    :search     => params[:search]
  }
  params.delete("start_date")
  params.delete("end_date")
  params.delete("search")
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
  rescue => e
    status 500
    {
      :data  => data,
      :error => e.class,
      :message => e.message
    }.to_json
  end
end
