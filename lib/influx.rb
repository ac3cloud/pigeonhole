require 'influxdb'
require 'time'
require 'chronic'
require 'toml'
require 'active_support/core_ext/numeric/time'

module Influx
  class Db
    def initialize
      @config     = TOML.load_file('config.toml')['influxdb']
      raise "Could not load credentials file at config.toml" if @config.nil? || @config.empty?
      database    = @config['database']
      credentials = {
        :host           => @config['host'],
        :username       => @config['username'],
        :password       => @config['password'],
        :port           => @config['port'],
        :time_precision => 's'
      }
      @influxdb = InfluxDB::Client.new(database, credentials)
      # FIXME: @influx.stopped? always returns nil in the 0.8 series
      fail("could not connect to influxdb") if @influxdb.stopped?
    end

    def insert_incident(incident)
      timeseries = @config['series']
      begin
        existing = @influxdb.query "select id, time_to_resolve from #{timeseries} where id='#{incident[:id]}'"
      rescue InfluxDB::Error => e
        if e.message.match(/^Couldn't find series/)
          existing = []
        else
          raise
        end
      end
      # Incidents can be in three states:
      # Not in InfluxDB (write as new point)
      # In InfluxDB, not resolved (re-write existing point with any new information)
      # In InfluxDB, resolved (point is final, nothing happens)
      if existing.empty?
        puts "inserting #{incident}"
        incident[:time] = Time.parse(incident[:created_on]).to_i
      else
        if existing[timeseries].first['time_to_resolve'].nil?
          puts "Incident #{incident[:id]} is already in influxDB - updating"
          incident['time'] = existing[timeseries].first['time']
          incident['sequence_number'] = existing[timeseries].first['sequence_number']
        else
          puts "Incident #{incident[:id]} is already in influxDB and has been resolved - skipping"
          return
        end
      end
      incident.delete(:created_on)
      @influxdb.write_point(timeseries, incident)
    end

    def find_incidents(start_date = nil, end_date = nil, query_input = nil)
      timeseries = @config['series']
      start_date = Chronic.parse(start_date, :guess => false).first unless start_date.nil?
      end_date = Chronic.parse(end_date, :guess => false).last unless end_date.nil?

      # If we couldn't parse the given date, use the last 24 hours.
      end_date = end_date.nil? ? Time.now.to_i : end_date.to_i
      start_date = start_date.nil? ? end_date - (24 * 60 * 60) : start_date.to_i

      # As a default, select * from the timeframe.  Otherwise, use what the input query gave us
      query_select = 'select *'
      if query_input && query_input[:query_select]
        query_select = query_input[:query_select]
      end
      influx_query = "#{query_select} from #{timeseries} \
                      where time > #{start_date}s and time < #{end_date}s "
      influx_query << query_input[:conditions] if query_input && query_input[:conditions]
      incidents = @influxdb.query(influx_query)
      incidents[timeseries] ? incidents[timeseries] : []
    end

    def incident_frequency(start_date = nil, end_date = nil)
      query_input = {
        :query_select => "select count(incident_key), incident_key",
        :conditions => "group by incident_key"
      }
      incidents = find_incidents(start_date, end_date, query_input).sort_by { |k| k["count"] }.reverse
      return [] if incidents.empty?
      incidents.map { |incident|
        next if incident['incident_key'].nil?
        entity, check = incident['incident_key'].split(':', 2)
        {
          'count'  => incident['count'],
          'entity' => entity,
          'check'  => check
        }
      }.compact
    end

    def alert_response(start_date = nil, end_date = nil)
      incidents = find_incidents(start_date, end_date)
      return {} if incidents.empty?
      results = incidents.map { |incident|
        next if incident['incident_key'].nil?
        time_to_ack = incident['time_to_ack'].nil? ? 0 : (incident['time_to_ack'] / 60.0).ceil
        time_to_resolve = incident['time_to_resolve'].nil? ? 0 : (incident['time_to_resolve'] / 60.0).ceil
        ack_by = incident['acknowledge_by']
        {
          'id' => incident['id'],
          'alert_time' => incident['time'],
          'incident_key' => incident['incident_key'].to_s.strip,
          'ack_by' => ack_by,
          'time_to_ack' => time_to_ack,
          'time_to_resolve' => time_to_resolve
        }
      }.compact

      # The rest of this function is to make the graph work:
      # Only a certain number of points are meaningful.
      # When we request data over long time periods, we show averages on the graph instead
      # Under one week: every point
      # Under one month: one point per hour
      # Under one year: one point per 8 hours
      # Over one year: one point per day
      first, last = results.minmax_by { |x| x['alert_time'] }.map { |x| x['alert_time'] }
      group_by = case
      when (last - first) < 1.week
        nil
      when (last - first).between?(1.week, 4.weeks)
        '1h'
      when (last - first) < 52.weeks
        '8h'
      else
        '24h'
      end

      unless group_by.nil?
        aggregated = find_incidents(start_date, end_date,
                                    :query_select => "select mean(time_to_ack) as mean_ack, mean(time_to_resolve) as mean_resolve",
                                    :conditions => "group by time(#{group_by})"
                    )
        aggregated.each do |incident|
          incident['mean_ack'] = incident['mean_ack'].nil? ? 0 : (incident['mean_ack'] / 60.0).ceil
          incident['mean_resolve'] = incident['mean_resolve'].nil? ? 0 : (incident['mean_resolve'] / 60.0).ceil
        end
      end

      # However, we always want to do the count over at least one hour (or matching the aggregation above)
      count_group_by = group_by.nil? ? '1h' : group_by
      count = find_incidents(start_date, end_date,
                             :query_select => "select count(incident_key)",
                             :conditions => "group by time(#{count_group_by}) fill(0)"
              ).sort_by { |k| k["count"] }.reverse

      {
        :incidents      => results,
        :aggregated     => aggregated,
        :count          => count,
        :count_group_by => count_group_by
      }
    end

    def noise_candidates(start_date = nil, end_date = nil)
      query_input = {
        :query_select => "select count(incident_key), incident_key, mean(time_to_resolve)",
        :conditions => "and time_to_resolve < 120 group by incident_key"
      }
      incidents = find_incidents(start_date, end_date, query_input).sort_by { |k| k["count"] }.reverse
      return [] if incidents.empty?
      incidents.map { |incident|
        next if incident['incident_key'].nil?
        entity, check = incident['incident_key'].split(':', 2)
        {
          'count'  => incident['count'],
          'entity' => entity,
          'check'  => check,
          'mean_time_to_resolve' => incident['mean'].to_i
        }
      }.compact
    end

    def save_categories(data)
      timeseries = @config['series']
      data.each do |incident, category|
        query = "select * from #{timeseries} where id = '#{incident}'"
        current_point = @influxdb.query(query)[timeseries].first
        current_point['category'] = category
        @influxdb.write_point(timeseries, current_point)
      end
    end
  end
end
