#!/usr/bin/env ruby

$LOAD_PATH.push(File.expand_path(File.join(__FILE__, '..', 'lib')))

require 'sinatra'
require 'influx'
require 'tilt/haml'
require 'date'
require 'highcharts'
require 'd3'
require 'uri'
require 'pagerduty'
require 'methadone'
require 'version'

include Methadone::CLILogging

influxdb = Influx::Db.new
pagerduty = Pagerduty.new
@config     = TOML.load_file('config.toml')['pigeonhole']
raise 'Could not load credentials file at config.toml' if @config.nil? || @config.empty?
@pigeonhole_domain    = @config['domain']

def today
  Time.now.strftime('%Y-%m-%d')
end

def last_week
  now = Date.today
  last_week = (now - 7)
  last_week.strftime('%Y-%m-%d')
end

def parse_incidents(incidents)
  incidents.each do |incident|
    incident['acknowledge_by'] = 'N/A' if incident['acknowledge_by'].nil?
    incident['time_to_ack'] = 'N/A' if incident['time_to_ack'] == 0
    case incident['time_to_ack']
      when 'N/A'
        incident['time_to_ack_unit'] = ''
      when 1;
        incident['time_to_ack_unit'] = 'minute'
      else
        incident['time_to_ack_unit'] = 'minutes'
    end
    incident['time_to_resolve'] = 'N/A' if incident['time_to_resolve'] == 0
    case incident['time_to_resolve']
      when 'N/A'
        incident['time_to_resolve_unit'] = ''
      when 1
        incident['time_to_resolve_unit'] = 'minute'
      else
        incident['time_to_resolve_unit'] = 'minutes'
    end

  end
end

get '/' do
  @mapper = {
    'ack' => 'Acknowleged',
    'resolve' => 'Resolved',
    'stddev' => 'Std Dev (σ)',
    '95_percentile' => '95th Percentile',
    'mean' => 'Average (x̄)'
  }
  @types = %w(ack resolve)
  @stats = %w(mean stddev 95_percentile)
  @stat_summary = influxdb.generate_stats
  @pagerduty_url = pagerduty.pagerduty_url
  @acked, @unacked = influxdb.unaddressed_alerts
  @acked = parse_incidents(@acked)
  @unacked = parse_incidents(@unacked)
  haml :index
end



get '/categorisation/?' do
  redirect "/categorisation/#{last_week}/#{today}"
end

get '/alert-frequency/?' do
  redirect "/alert-frequency/#{last_week}/#{today}"
end

get '/check-frequency/?' do
  redirect "/check_frequency/#{last_week}/#{today}"
end

get '/alert-response/?' do
  redirect "/alert-response/#{last_week}/#{today}"
end

get '/noise-candidates/?' do
  redirect "/noise-candidates/#{last_week}/#{today}"
end

get '/status' do
  begin
    influxdb.healthcheck
    status 200
  rescue
    status 503
  end
  body ''
end

def search_precondition
  return '' unless @search
  "and (input_type =~ /.*#{@search}.*/i or description =~ /.*#{@search}.*/i or incident_key =~ /.*#{@search}.*/i or check =~ /.*#{@search}.*/i or entity =~ /.*#{@search}.*/i)"
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
  @start_date    = params["start_date"]
  @end_date      = params["end_date"]
  @search        = params["search"]
  @pagerduty_url = pagerduty.pagerduty_url
  @incidents     = parse_incidents(influxdb.find_incidents(@start_date, @end_date, {:conditions => search_precondition }))
  haml :categorisation
end

get '/alert-frequency/:start_date/:end_date' do
  @start_date = params['start_date']
  @end_date   = params['end_date']
  @search     = params['search']
  @incidents  = parse_incidents(influxdb.incident_frequency(@start_date, @end_date, search_precondition))
  @pagerduty_url = pagerduty.pagerduty_url
  @total      = @incidents.map { |x| x['count'] }.inject(:+) || 0
  @series     = HighCharts.alert_frequency(@incidents)
  haml :"alert-frequency"
end

get '/check-frequency/:start_date/:end_date' do
  @start_date = params['start_date']
  @end_date   = params['end_date']
  @search     = params['search']
  @incidents  = parse_incidents(influxdb.check_frequency(@start_date, @end_date, search_precondition))
  @pagerduty_url = pagerduty.pagerduty_url
  @total      = @incidents.map { |x| x['count'] }.inject(:+) || 0
  @series     = HighCharts.alert_frequency(@incidents)
  haml :"check-frequency"
end

get '/alert-response/:start_date/:end_date' do
  @start_date = params['start_date']
  @end_date   = params['end_date']
  @search     = params['search']
  resp = influxdb.alert_response(@start_date, @end_date, search_precondition)
  @series     = HighCharts.alert_response(resp)
  # Build table data
  @incidents  = resp[:incidents] || []
  @total      = @incidents.count
  @acked      = @incidents.count { |x| x['time_to_ack'] != 0 }
  @pagerduty_url = pagerduty.pagerduty_url
  @incidents = parse_incidents(@incidents)
  haml :"alert-response"
end

get '/noise-candidates/:start_date/:end_date' do
  @start_date = params['start_date']
  @end_date   = params['end_date']
  @search     = params['search']
  @incidents  = parse_incidents(influxdb.noise_candidates(@start_date, @end_date, search_precondition))
  @pagerduty_url = pagerduty.pagerduty_url
  @total      = @incidents.count
  #@series     = HighCharts.noise_candidates(@incidents)
  @series     = D3.noise_candidates(@incidents)
  haml :"noise-candidates"
end

get '/history/:client/:check' do
  @client = params['client']
  @check = params['check']
  @incidents  = influxdb.get_history(@client, @check)
  @pagerduty_url = pagerduty.pagerduty_url
  haml :"alert-history"
end

post '/categorisation/:start_date/:end_date' do
  uri = "#{params['start_date']}/#{params['end_date']}"
  uri += "?search=#{params['search']}" if params['search']
  opts = {
    :start_date => params[:start_date],
    :end_date   => params[:end_date],
    :search     => params[:search]
  }
  params.delete('start_date')
  params.delete('end_date')
  params.delete('search')
  params.delete('splat')
  params.delete('captures')

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
