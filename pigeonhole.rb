#!/usr/bin/env ruby

$:.push(File.expand_path(File.join(__FILE__, '..', 'lib')))

require 'sinatra'
require 'influx'
require 'haml'
require 'date'
require 'highcharts'
require 'pry-debugger'

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

def search_query_input 
  if @search
     { :conditions => "and incident_key =~ /.*#{@search}.*/" }
  else
     {}
  end
end

get '/:start_date/:end_date' do
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
  @incidents = influxdb.find_incidents(@start_date, @end_date, search_query_input)
  haml :"index"
end

get '/alert-frequency/:start_date/:end_date' do
  @start_date = params["start_date"]
  @end_date   = params["end_date"]
  @search     = params["search"]
  @incidents  = influxdb.incident_frequency(@start_date, @end_date, search_query_input)
  @total      = @incidents.map { |x| x['count'] }.inject(:+)
  @series     = HighCharts.alert_frequency(@incidents)
  haml :"alert-frequency"
end

get '/alert-response/:start_date/:end_date' do
  @start_date = params["start_date"]
  @end_date   = params["end_date"]
  @search     = params["search"]
  resp = influxdb.alert_response(@start_date, @end_date, search_query_input)
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
  @search     = params["search"]
  @incidents  = influxdb.noise_candidates(@start_date, @end_date, search_query_input)
  @total      = @incidents.count
  haml :"noise-candidates"
end

post '/:start_date/:end_date' do
  uri = "#{params["start_date"]}/#{params["end_date"]}?search=#{params["search"]}"
  params.delete("start_date")
  params.delete("end_date")
  params.delete("search")
  params.delete("splat")
  params.delete("captures")

  influxdb.save_categories(params)
  redirect "/#{uri}"
end
