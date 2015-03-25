require 'httparty'
require 'json'
require 'toml'

class Pagerduty
  def initialize
    @config = TOML.load_file('config.toml')['pagerduty']
    raise "Could not load credentials file at config.toml" if @config.nil? || @config.empty?
    # Add trailing slash to API URL if it doesn't already exist
    @config['api_url'] += '/' unless @config['api_url'].end_with?('/')
    @config['auth_token'] = "Token token=#{@config['auth_token']}" unless @config['auth_token'].start_with?('Token token=')
  end

  def request(endpoint)
    response = HTTParty.get(
      endpoint,
      headers: {
        'Content-Type'  => 'application/json',
        'Authorization' => @config['auth_token']
      }
    )
    JSON.parse(response.body)
  end

  def incidents(start_date, finish_date=nil)
    pagination_limit  = 100
    pagination_offset = 0
    finish_clause     = finish_date ? finish_clause = "&until=#{finish_date}" : ""
    incidents         = []
    begin
      endpoint  = "#{@config['api_url']}incidents?since=#{start_date}#{finish_clause}&time_zone=#{@config['time_zone']}&sort_by=created_on:desc&offset=#{pagination_offset}"
      response  = request(endpoint)
      responses = response['incidents'].count
      debug("received #{responses} responses from pd")
      response['incidents'].each do |incident|
        tmp = {
          :id           => incident['id'],
          :created_on   => incident['created_on'],
          :description  => incident['trigger_summary_data']['description'],
          :incident_key => incident['incident_key'],
          :category     => 'not set',
        }
        if incident['trigger_summary_data']['description'] == nil
          # some alerts don't have a description (e.g.: website pulse), fall back on subject and service name
          tmp[:description] = "#{incident['service']['name']}: #{incident['trigger_summary_data']['subject']}"
        end
        incidents << tmp
      end
      pagination_offset += pagination_limit
    end while responses >= pagination_limit
    incidents
  end

  def oncall(given_date=nil)
    given_date ||= Time.now
    schedules  = @config['schedules']
    since_date = given_date
    until_date = given_date + 24 * 60 * 60
    #weekend?
    if since_date.saturday?
      until_date = until_date + 24 * 60 * 60 #set to Monday
      since_date = Time.parse("#{since_date.strftime("%F")} 09:30:00") #09:30h start
    elsif since_date.sunday?
      since_date = since_date - 24 * 60 * 60 #set to Saturday
      since_date = Time.parse("#{since_date.strftime("%F")} 09:30:00") #09:30h start
    else
      since_date = Time.parse("#{since_date.strftime("%F")} 17:00:00") #17:00h start
    end
    until_date = Time.parse("#{until_date.strftime("%F")} 09:30:00") #09:30h end
    oncall = {}
    schedules.each do |name,schedule|
      endpoint = "#{@config['api_url']}schedules/#{schedule}/users?since=#{since_date.iso8601}&until=#{until_date.iso8601}"
      response = request(endpoint)
      response['users'].each do |user|
        oncall[name.to_sym] ||= []
        oncall[name.to_sym] << user['email']
      end
    end
    oncall
  end
end
