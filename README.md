# Pigeonhole

Pigeonhole is an alert analysis and categorisation tool. It takes data from PagerDuty and generates graphs based on this data over a configurable time period.

At present it offers a graph of alert frequency, but we're also looking to and analysis of acknowledgement and resolution times as well as breakdowns over day and time.

## Installation

Pigeonhole requires the following:

  - InfluxDB
  - Ruby 2.2.1 (and rbenv, or your preferred Ruby management tool)

After these have been installed, copy the config.toml.example file to config.toml, and update it with your details.

Pigeonhole operates as a read-only user with the exception of the categorisation. If you're using the categorisation feature you'll have to add a read-write user as well.

To setup the two users, the following commands can be invoked (works for InfluxDB 0.8.8):

```
INFLUX=http://localhost:8086
USER=root
PASS=root
AUTH="u=$USER&p=$PASS"

# Create a read-only user
curl -X POST "$INFLUX/db/pigeonhole/users?$AUTH" -d '{"name": "pigeonhole",    "password": "pigeonhole__password"}'
curl -X POST "$INFLUX/db/pigeonhole/users/pigeonhole?$AUTH" -d '{ "readFrom": ".*",  "writeTo": "^$"}'

# Create a user that can read and write, for categorisation and data importing
curl -X POST "$INFLUX/db/pigeonhole/users?$AUTH" -d '{"name": "pigeonhole_rw", "password": "pigeonhole_otherpass"}'

# check the listing
curl "$INFLUX/db/pigeonhole/users?$AUTH"

```


## Usage

There are multiple parts to Pigeonhole:

### Import from PagerDuty

Pigeonhole will receive events from your PagerDuty account and import them.  This can be done in one of two ways:

#### Pull in data via a script (including historical data)

```
➤ ./bin/import_from_pd --help
Usage: import_from_pd [options] [start_date] [finish_date]

Takes an optional start and an optional finish date in the form of
'YYYY-MM-DD' or 'YYYY-MM-DDTHH:MM:SS+10:00' and imports all PagerDuty incidents
within those dates into InfluxDB. If no start date is specified, it will
default to today, 00:00:00h. If no finish date is specified it will use now as
finish date.

Options:
    -h, --help                       Show command line help
        --log-level LEVEL            Set the logging level
                                     (debug|info|warn|error|fatal)
                                     (Default: info)
```

#### Listen for data from Pagerduty Webhooks

Pigeonhole will also listen for Pagerduty Webhooks, which [sends data](https://developer.pagerduty.com/documentation/rest/webhooks) whenever something happens on an incident.

To configure this, follow [the Webhook setup guide](http://www.pagerduty.com/docs/guides/hipchat-integration-guide/), with the endpoint URL set as http://your.pigeonhole.url:9393/pagerduty.  There is no need for an auth_token or room_id.

### Web UI
After this is been completed as you can load up the pigeonhole interface by running:

```
bundle exec shotgun
```

Pigeonhole is now able to be viewed at http://127.0.0.1:9393/

### Alert Threshold Recommender

Many monitoring tools are based on static thresholding.  Based on PagerDuty data, you can now estimate what thresholds should be used to stop X% of alerts occurring over a given timeframe:

```
➤ bundle exec ruby bin/alert_threshold_recommendations.rb --help
Usage: alert_threshold_recommendations.rb [options]

Calculates suggested alert thresholds for removing X% of alerts over a given time period

Options:
    -h, --help                       Show command line help
        --log-level LEVEL            Set the logging level
                                     (debug|info|warn|error|fatal)
                                     (Default: info)
    -p, --percent-to-remove percent  The percent of alerts to remove
    -t, --time-period duration       The amount of time we should look over
    -m, --more-than more-than        Only return results that have more than Y occurences
    -r recover-within,               Only return results that recover within this amount of time
        --recover-within
    -s, --sort-by sort-by            The field we should sort the returned data by - frequency, threshold, or incident_key
```

### Alert Categorisation Reminder

To aid in alert categorisation, Pigeonhole includes a script to remind recent people on call to categorise the alerts they received.  This can be run using:

```
➤ ./bin/email_reminder_to_oncall --help
Usage: email_reminder_to_oncall [oncall_date]

Takes an optional date (defaults to today) in the form of 'YYYY-MM-DD' and
sends an email reminder to whoever was on call.
    -h, --help                       Show command line help
```

So, to work out thresholds required to remove 70% of the alerts over the last 3 months that recovered within 5 minutes and occurred more than 5 times, run:

```
bundle exec ruby bin/alert_threshold_recommendations.rb --percent-to-remove 70 --time-period '3 months' --sort-by threshold --recover-within '5 minutes' --more-than 5
```

## Screenshots

### Statistics (default) mode

![Statistics Mode](screenshots/statistics.png?raw=true "Statistics Mode")

### Categorisation mode

![Categorisation Mode](screenshots/categorisation.png?raw=true "Categorisation Mode")

### Frequency mode

![Frequency Mode](screenshots/frequency.png?raw=true "Frequency Mode")

### Acknowledgement and resolution times mode

![Alert Response Mode](screenshots/alert-response.png?raw=true "Alert Response Mode")

### Noise candidate mode

![Noise Candidates Mode](screenshots/noise-candidates.png?raw=true "Noise Candidates Mode")

We hope you find this useful!
