#!/usr/bin/env ruby

$:.push(File.expand_path(File.join(__FILE__, '..', 'lib')))

require 'sinatra'
require 'influx'
require 'haml'
require 'date'

influxdb = Influx::Db.new

get '/' do
  today = Time.now.strftime("%Y-%m-%d")
  redirect "/#{today}"
end

get '/breakdown/?' do
  today = Time.now.strftime("%Y-%m-%d")
  redirect "/breakdown/#{today}/#{today}"
end

get '/:date' do
  @categories = [
    'not set',
    'real',
    'improved',
    'self recovered',
    'needs documentation',
    'unclear, needs discussion',
  ]
  @date = params["date"]
  @incidents = influxdb.incidents(@date)
  haml :"index"
end

get '/breakdown/:start_date/:end_date' do
  @start_date = params["start_date"]
  @end_date   = params["end_date"]
  @incidents  = influxdb.breakdown_incidents(@start_date, @end_date)
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
  haml :"breakdown"
end

post '/:date' do
  uri = params["date"]
  params.delete("date")
  params.delete("splat")
  params.delete("captures")
  influxdb.save_categories(params)
  redirect "/#{uri}"
end
