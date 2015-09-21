require "pp"

class Parse
  def incidents(incidents)
    data_centers = ["sfo2", "iad1", "linode"]

    incidents.each do |incident|
      if incident[:input_type].include? "Zabbix"
        if !incident[:incident_key].start_with? "sensu"
          if incident[:description]
            incident[:entity] = incident[:description].match(/.*\s([a-zA-Z0-9-]*).*/)[1]
            incident[:check] = incident[:description]
          end
        end
      end

      if incident[:input_type].include? "Cloudwatch"
        if incident[:description]
          incident[:check] = incident[:description]
        end
      end

      # SignalFX Unique ID regex
      if incident[:description].match(/.*\[([a-zA-Z0-9-]{11})\]/)
        incident[:check]  = incident[:description].match(/(.*)\((.*for.*)\)/)[1]
        incident[:entity] = incident[:description].match(/(.*)\((.*for.*)\)/)[2]
      end

      if incident[:input_type].include? "Operations Email"
        incident[:entity] = incident[:incident_key].match(/(.*)service\s(.*)/)[1]
        incident[:check]  = incident[:incident_key].match(/(.*)service\s(.*)/)[2]
      end

      if incident[:incident_key] and (incident[:incident_key].start_with? "nagios" or incident[:incident_key].start_with? "sensu")
        partitioned_elements = incident[:incident_key].split(' ')
        if data_centers.include?(partitioned_elements[1])
          incident[:source] = "#{partitioned_elements[0]} #{partitioned_elements[1]}"
          incident[:entity] = partitioned_elements[2]
        elsif !partitioned_elements[1].include?('-')
          incident[:source] = "#{partitioned_elements[0]} #{partitioned_elements[1]}"
          incident[:entity] = partitioned_elements[2]
        else
          incident[:source] = partitioned_elements[0]
          incident[:entity] = partitioned_elements[1]
        end
        last_count = partitioned_elements.count.to_i - 3
        last_count = last_count < 1 ? last_count = 1 : last_count
        incident[:check] = partitioned_elements.last(last_count).join(' ')
      end

      if incident[:incident_key].to_s.include? "/"
        incident[:entity], incident[:check] = incident[:incident_key].split('/', 2)
      end

      if incident[:incident_key].to_s.include? ":"
        incident[:entity], incident[:check] = incident[:incident_key].split(':', 2)
      end

      if !incident[:entity]
        incident[:entity] = incident[:incident_key]
      end
    end
  end

end
