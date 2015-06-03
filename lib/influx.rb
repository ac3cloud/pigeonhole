require 'influxdb'
require 'time'
require 'chronic'
require 'chronic_duration'
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
      credentials_rw = {
        :username       => @config['username_rw'],
        :password       => @config['password_rw']
      }
      @influxdb = InfluxDB::Client.new(database, credentials)
      if credentials_rw[:username] && credentials_rw[:password]
        @influxdb_rw = InfluxDB::Client.new(database, credentials.merge(credentials_rw))
      end
      # FIXME: @influx.stopped? always returns nil in the 0.8 series
      fail("could not connect to influxdb") if @influxdb.stopped?
    end

    def insert_incidents(incidents)
      return if incidents.empty?
      fail("no read-write user defined, cannot insert records") unless @influxdb_rw
      timeseries = @config['series']
      oldest = incidents.map { |x| Time.parse(x[:created_on]).to_i }.min - 1
      newest = incidents.map { |x| Time.parse(x[:created_on]).to_i }.max + 1
      begin
        entries = @influxdb.query "select id, time_to_resolve from #{timeseries} where time > #{oldest}s and time < #{newest}s"
        entries = entries.empty? ? [] : entries[timeseries]
      rescue InfluxDB::Error => e
        if e.message.match(/^Couldn't find series/)
          entries = []
        else
          raise
        end
      end
      incidents.each do |incident|
        existing = entries.select { |x| x['id'] == incident[:id] }
        # Incidents can be in three states:
        # Not in InfluxDB (write as new point)
        # In InfluxDB, not resolved (re-write existing point with any new information)
        # In InfluxDB, resolved (point is final, nothing happens)
        if existing.empty?
          puts "inserting #{incident}"
          incident[:time] = Time.parse(incident[:created_on]).to_i
        else
          if existing.first['time_to_resolve'].nil?
            puts "Incident #{incident[:id]} is already in influxDB - updating"
            incident['time'] = existing.first['time']
            incident['sequence_number'] = existing.first['sequence_number']
          else
            puts "Incident #{incident[:id]} is already in influxDB and has been resolved - skipping"
            next
          end
        end
        incident.delete(:created_on)
        @influxdb_rw.write_point(timeseries, incident)
      end
    end

    def find_incidents(start_date = nil, end_date = nil, query_input = nil)
      timeseries = @config['series']
      start_date = Chronic.parse(start_date, :guess => false).first unless start_date.nil? || start_date.is_a?(Time)
      end_date = Chronic.parse(end_date, :guess => false).last unless end_date.nil? || end_date.is_a?(Time)

      # If we couldn't parse the given date, use the last 24 hours.
      end_date = (end_date.nil? || end_date.to_i > Time.now.to_i) ? Time.now.to_i : end_date.to_i
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

    def incident_frequency(start_date = nil, end_date = nil, precondition = "")
      query_input = {
        :query_select => "select count(incident_key), incident_key",
        :conditions => "#{precondition} group by incident_key"
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

    def alert_response(start_date = nil, end_date = nil, precondition = "")
      incidents = find_incidents(start_date, end_date, :conditions => precondition )
      return {} if incidents.empty?
      results = incidents.map do |incident|
        next if incident['incident_key'].nil?
        time_to_ack = incident['time_to_ack'].nil? ? 0 : (incident['time_to_ack'] / 60.0).ceil
        time_to_resolve = incident['time_to_resolve'].nil? ? 0 : (incident['time_to_resolve'] / 60.0).ceil
        {
          'id'              => incident['id'],
          'alert_time'      => incident['time'],
          'incident_key'    => incident['incident_key'].to_s.strip,
          'ack_by'          => incident['acknowledge_by'],
          'time_to_ack'     => time_to_ack,
          'time_to_resolve' => time_to_resolve
        }
      end.compact

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
                                    :conditions => "group by time(#{group_by}) #{precondition}"
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
                             :conditions => "group by time(#{count_group_by}), fill(0) #{precondition}"
              ).sort_by { |k| k["count"] }.reverse

      {
        :incidents      => results,
        :aggregated     => aggregated,
        :count          => count,
        :count_group_by => count_group_by
      }
    end

    def noise_candidates(start_date = nil, end_date = nil, precondition = "")
      query_input = {
        :query_select => "select count(incident_key), incident_key, mean(time_to_resolve)",
        :conditions => "#{precondition} and time_to_resolve < 120 group by incident_key"
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

    def threshold_recommendations(opts)
      data = find_incidents(opts[:start_date], opts[:end_date],
                            :query_select => "select count(incident_key), percentile(time_to_resolve, #{opts[:percentage]}), max(time_to_resolve)",
                            :conditions => "group by incident_key"
             )
      # Firstly, don't try to provide analysis for data where we have less than 5 instances of it
      # Also remove alerts that don't have an incident key, or haven't been resolved yet.
      recover_within = ChronicDuration.parse(opts[:recover_within]).to_i
      raise "Failed to parse recover within" unless recover_within > 0
      data.reject! { |x| x['percentile'].nil? || x['percentile'].to_i > recover_within || x['count'] < opts[:more_than].to_i || x['incident_key'].nil? }

      sort_by = case options[:sort_by]
      when 'frequency'
        'count'
      when 'threshold'
        'percentile'
      else
        opts[:sort_by]
      end
      data = data.sort_by { |x| x[sort_by] }
      data.reverse! if sort_by == 'frequency'

      data.map do |d|
        threshold = d['percentile'] + 5
        formatted_threshold = case
        when threshold < 60
          "#{threshold} seconds"
        when threshold < 120
          div, mod = threshold.divmod(60)
          "#{div} minute and #{mod} seconds"
        else
          div, mod = threshold.divmod(60)
          "#{div} minutes and #{mod} seconds"
        end
        {
          :incident_key => d['incident_key'],
          :count => d['count'],
          :fixed => (d['count'] * opts[:percentage].to_i / 100).floor,
          :threshold => threshold,
          :formatted_threshold => formatted_threshold
        }
      end
    end

    def unaddressed_alerts
      start_date = Date.today.prev_day.strftime('%F')
      end_date = Date.today.strftime('%F')
      incidents = find_incidents(start_date, end_date) ##TODO eep
      return [] if incidents.empty?
      unacked = []
      unresolved = []
      incidents.map { |incident|
        next if incident['incident_key'].nil?
        entity, check = incident['incident_key'].split(':', 2)
        member = {
          'alert_time' => incident["time"],
          'id' => incident['id'],
          'entity' => entity,
          'check'  => check,
          'ack_by' => incident['acknowledge_by'],
          'time_to_ack' => incident['time_to_ack'],
          'time_to_resolve' => incident['time_to_resolve']
        }
        if member["time_to_ack"].nil? && member["time_to_resolve"].nil?
 	    unacked << member
        elsif member["time_to_resolve"].nil?
            unresolved << member
        end
      }
      [unacked, unresolved]
    end

    def generate_stats
      shifts = TOML.load_file('config.toml')['shifts'] || {}
      Time.zone = shifts['time_zone'] || 'UTC'
      Chronic.time_class = Time.zone
      shifts.delete('time_zone')

      stat_matrix = [
        { title: "Last 24 hours", start: Chronic.parse('24 hours ago'), end: Chronic.parse('now')},
        { title: "Last month", start: Chronic.parse('1 month ago'), end: Chronic.parse('now')},
        { title: "Last 3 months", start: Chronic.parse('3 months ago'), end: Chronic.parse('now')}
      ]

      # We want to show data for one full shift each, plus the current shift.
      # Due to timezones, this sometimes means we need to look back over the last 3 days
      shift_matrix = []
      [
        Date.today.prev_day.prev_day.strftime('%F'),
        Date.today.prev_day.strftime('%F'),
        Date.today.strftime('%F')
      ].each do |day|
        shift_times = shifts.each do |_, shift|
          start_time = shift['start_time']
          duration = shift['duration'].to_i
          start_date = Chronic.parse("#{day} #{start_time}:00")
          # Eliminate any shifts starting in the future
          next if start_date.to_i > Time.now.to_i
          end_date = start_date + duration * 60
          shift_matrix << { title: shift['name'], start: start_date, end: end_date }
        end
      end
      # Now we remove any full shifts that are older than the most recent full shift
      num_shifts = shifts.length + 1
      stat_matrix << shift_matrix.sort_by{ |x| x[:start] }.reverse.take(num_shifts).reverse
      stat_matrix.flatten!

      aggregate_select_str = "select count(incident_key), " + %w(ack resolve).map { |type|
        "MEAN(time_to_#{type}) as #{type}_mean, STDDEV(time_to_#{type}) as #{type}_stddev, PERCENTILE(time_to_#{type}, 95) as #{type}_95_percentile"
      }.join(', ')

      stat_matrix.each do |shift|
        aggregated = find_incidents(shift[:start], shift[:end],
                                    :query_select => aggregate_select_str).first || {}
        ack_percent_in_60s = ack_percent_before_timeout(:start_date => shift[:start], :end_date => shift[:end],
                                    :timeout => 60)
        aggregated["ack_percent_in_60s"] = ack_percent_in_60s
        shift[:data] = aggregated
      end
      stat_matrix
    end

    def ack_percent_before_timeout(opts)
      select_str = "select time_to_ack"
      incidents = find_incidents(opts[:start_date], opts[:end_date], :query_select => select_str)
      total = incidents.count
      return 0 if total == 0
      timeout = opts[:timeout] || 60
      under = incidents.reject { |x| x['time_to_ack'].nil? || x['time_to_ack'] > timeout }
      100 * under.count / total
    end

    def save_categories(opts)
      return if opts[:data].empty?
      fail("no read-write user defined, cannot save categories") unless @influxdb_rw
      timeseries = @config['series']
      oldest =  Chronic.parse(opts[:start_date], :guess => false).first.to_i
      newest =  Chronic.parse(opts[:end_date], :guess => false).last.to_i
      begin
        entries = @influxdb.query "select * from #{timeseries} where time > #{oldest}s and time < #{newest}s"
        entries = entries.empty? ? [] : entries[timeseries]
      rescue InfluxDB::Error => e
        if e.message.match(/^Couldn't find series/)
          entries = []
        else
          raise
        end
      end
      opts[:data].each do |incident, category|
        current_point = entries.select { |x| x['id'] == incident }.first
        current_point['category'] = category
        @influxdb_rw.write_point(timeseries, current_point)
      end
    end
  end
end
