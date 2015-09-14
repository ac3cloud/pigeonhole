#!/usr/bin/env ruby

$LOAD_PATH.push(File.expand_path(File.join(__FILE__, '..', 'lib')))

require 'sinatra'
require 'influx'
require 'tilt/haml'
require 'date'
require 'highcharts'
require 'uri'
require 'pagerduty'
require 'methadone'
require 'version'

include Methadone::CLILogging

influxdb = Influx::Db.new
pagerduty = Pagerduty.new

def today
  Time.now.strftime('%Y-%m-%d')
end

def parse_incidents(incidents)
  puts incidents.length
  incidents.each do |incident|
    if incident['input_type'].include? "Zabbix"
      if !incident['incident_key'].start_with? "sensu"
        if incident['description']
          incident['incident_key'] = incident['description'].match(/.*\s([a-zA-Z0-9-]*).*/)[1]
          incident['check'] = incident['description']
        end
      end
    end

    if incident['incident_key'] and (incident['incident_key'].start_with? "nagios" or incident['incident_key'].start_with? "sensu")
      partitioned_elements = incident['incident_key'].split(' ')
      if partitioned_elements[1] == "sfo2" || partitioned_elements[1] == "iad1"
        incident['source'] = "#{partitioned_elements[0]} #{partitioned_elements[1]}"
        incident['incident_key'] = partitioned_elements[2]
      elsif !partitioned_elements[1].include?('-')
        incident['source'] = "#{partitioned_elements[0]} #{partitioned_elements[1]}"
        incident['incident_key'] = partitioned_elements[2]
      else
        incident['source'] = partitioned_elements[0]
        incident['incident_key'] = partitioned_elements[1]
      end
      last_count = partitioned_elements.count.to_i - 3
      last_count = last_count < 1 ? last_count = 1 : last_count
      incident['check'] = partitioned_elements.last(last_count).join(' ')
    end

    if incident['incident_key'].to_s.include? "/"
      incident['entity'], incident['check'] = incident['incident_key'].split('/', 2)
    end

    if incident['incident_key'].to_s.include? ":"
      incident['entity'], incident['check'] = incident['incident_key'].split(':', 2)
    end

    if !incident['entity']
      incident['entity'] = incident['incident_key']
    end
    incident['ack_by'] = 'N/A' if incident['ack_by'].nil?
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

get '/status' do
  status 200
  body ''
end

def search_precondition
  return '' unless @search
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
  @total      = @incidents.map { |x| x['count'] }.inject(:+) || 0
  @series     = HighCharts.alert_frequency(@incidents)
  haml :"alert-frequency"
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
  @total      = @incidents.count
  @series     = HighCharts.noise_candidates(@incidents)
  haml :"noise-candidates"
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
