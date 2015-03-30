require 'influxdb'
require 'time'
require 'chronic'
require 'toml'

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
      existing = @influxdb.query "select id, time_to_resolve from #{timeseries} where id='#{incident[:id]}'"
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

    def incidents(date=nil)
      timeseries = @config['series']
      unless date.nil?
        start_date = Chronic.parse(date, :guess => false).first
        end_date = Chronic.parse(date, :guess => false).last
      end

      # If we couldn't parse the given date, use the last 24 hours.
      end_date = end_date.nil? ? Time.now.to_i : end_date.to_i
      start_date = start_date.nil? ? end_date - (24 * 60 * 60) : start_date.to_i

      query = "select * from #{timeseries} where time > #{start_date.to_i}s and time < #{end_date.to_i}s"
      incidents = @influxdb.query(query)
      incidents[timeseries] ? incidents[timeseries] : []
    end

    def breakdown_incidents(start_date=nil, end_date=nil)
      timeseries = @config['series']
      start_date = Chronic.parse(start_date, :guess => false).first unless start_date.nil?
      end_date = Chronic.parse(end_date, :guess => false).last unless end_date.nil?

      # If we couldn't parse the given date, use the last 24 hours.
      end_date = end_date.nil? ? Time.now.to_i : end_date.to_i
      start_date = start_date.nil? ? end_date - (24 * 60 * 60) : start_date.to_i

      query = "select count(incident_key), incident_key from #{timeseries} where time > #{start_date}s and time < #{end_date}s group by incident_key"
      resp = @influxdb.query(query)
      return [] if resp.empty?
      incidents = resp[timeseries].sort_by { |k| k["count"] }.reverse
      results = []
      incidents.each do |incident|
        entity, check = incident['incident_key'].split(':', 2)
        results.push(
          {
            'count'  => incident['count'],
            'entity' => entity,
            'check'  => check
          }
        )
      end
      results
    end

    def save_categories(data)
      timeseries = @config['series']
      data.each do |incident,category|
        query = "select * from #{timeseries} where id = '#{incident}'"
        current_point = @influxdb.query(query)[timeseries].first
        current_point['category'] = category
        @influxdb.write_point(timeseries, current_point)
      end
    end
  end
end
