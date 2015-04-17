require 'httparty'
require 'json'
require 'toml'
require 'parallel'

class Pagerduty
  def initialize
    @config = TOML.load_file('config.toml')['pagerduty']
    raise "Could not load credentials file at config.toml" if @config.nil? || @config.empty?
    # Add trailing slash to API URL if it doesn't already exist
    @config['api_url'] += '/' unless @config['api_url'].end_with?('/')
    @config['auth_token'] = "Token token=#{@config['auth_token']}" unless @config['auth_token'].start_with?('Token token=')
  end

  def request(endpoint)
    pagination_limit  = 100
    pagination_offset = 0
    result = []
    begin
      # Some endpoints have query strings already.  Detect this, and add onto the query string
      # if it exists, or otherwise create one
      char = endpoint.include?('?') ? '&' : '?'
      endpoint = "#{endpoint}#{char}sort_by=created_on:desc&offset=#{pagination_offset}"
      response = HTTParty.get(
        endpoint,
        headers: {
          'Content-Type'  => 'application/json',
          'Authorization' => 'Token token=hD4yx9TWsvR5kwEAJA1p'
        }
      )
      response = JSON.parse(response.body).values.first
      response_count = response.count
      debug("received #{response_count} responses from pd for #{endpoint}")
      response.each { |r| result << r }
      pagination_offset += pagination_limit
    end while response_count >= pagination_limit
    result
  end

  def incidents(start_date, finish_date = nil)
    finish_clause     = finish_date ? finish_clause = "&until=#{finish_date}" : ""
    time_zone = @config['time_zone']
    endpoint  = "https://bltprf.pagerduty.com/api/v1/incidents?since=#{start_date}#{finish_clause}&time_zone=#{time_zone}"
    response  = request(endpoint)
    incidents = response.map do |incident|
      tmp = {
        :id           => incident['id'],
        :created_on   => incident['created_on'],
        :description  => incident['trigger_summary_data']['description'],
        :incident_key => incident['incident_key'],
        :input_type   => incident['service']['name'],
        :category     => 'not set'
      }
      if incident['trigger_summary_data']['description'].nil?
        # some alerts don't have a description (e.g.: website pulse), fall back on subject and service name
        tmp[:description] = "#{incident['service']['name']}: #{incident['trigger_summary_data']['subject']}"
      end
      tmp
    end
    add_ack_resolve(incidents)
  end

  def add_ack_resolve(incidents)
    Parallel.each(incidents, :in_threads => 20) do |incident|
      incident_id      = incident[:id]
      log              = request("https://bltprf.pagerduty.com/api/v1/incidents/#{incident_id}/log_entries").sort_by { |x| x['created_at'] }
      problem          = log.select { |x| x['type'] == 'trigger' }.first
      problem_time     = Time.parse(problem['created_at'])
      acknowledge_by   = nil
      time_to_ack      = nil
      time_to_resolve  = nil

      if log.any? { |x| x['type'] == 'acknowledge' }
        acknowledge      = log.select { |x| x['type'] == 'acknowledge' }.first
        acknowledge_by   = acknowledge['agent']['email']
        acknowledge_time = Time.parse(acknowledge['created_at'])
        time_to_ack      = acknowledge_time - problem_time
      end

      if log.any? { |x| x['type'] == 'resolve' }
        resolve         = log.select { |x| x['type'] == 'resolve' }.first
        resolve_time    = Time.parse(resolve['created_at'])
        time_to_resolve = resolve_time - problem_time
      end

      incident[:acknowledge_by]  = acknowledge_by
      incident[:time_to_ack]     = time_to_ack
      incident[:time_to_resolve] = time_to_resolve
    end
    incidents
  end

  def oncall(given_date = nil)
    given_date ||= Time.now
    schedules  = @config['schedules']
    since_date = given_date
    until_date = given_date + 24 * 60 * 60
    # weekend?
    if since_date.saturday?
      until_date += 24 * 60 * 60 # set to Monday
      since_date = Time.parse("#{since_date.strftime('%F')} 09:30:00") # 09:30h start
    elsif since_date.sunday?
      since_date -= 24 * 60 * 60 # set to Saturday
      since_date = Time.parse("#{since_date.strftime('%F')} 09:30:00") # 09:30h start
    else
      since_date = Time.parse("#{since_date.strftime('%F')} 17:00:00") # 17:00h start
    end
    until_date = Time.parse("#{until_date.strftime('%F')} 09:30:00") # 09:30h end
    oncall = {}
    schedules.each do |name, schedule|
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
