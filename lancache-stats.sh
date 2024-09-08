#!/bin/bash

# Cache and Log file paths
CACHE_LOCATION="/mnt/lancache"
LOGS_LOCATION="$CACHE_LOCATION/logs"
LOG_FILE="$LOGS_LOCATION/access.log"

# MySQL database connection parameters
DB_HOST='10.10.10.40'
DB_USER='lancache'
DB_PASS='E1chhof$123!'
DB_NAME='lancachedb'

# Script variables
loop_interval=1 # check logs every second
unix_timeformat="%Y-%m-%d %H:%M:%S"
log_timeformat="%d/%b/%Y:%T"
LOCKFILE=/tmp/lancache-stats.lock

# Check if lock file exists
if [ -e "$LOCKFILE" ]; then
    echo "Script is already running. Exiting..."
    exit 1
fi

# Create lock file
touch "$LOCKFILE"
trap "rm -f $LOCKFILE" EXIT  # Remove lockfile on script exit

# Main
echo "Script started"
declare -A aggregated_data

while true; do
    start_time=$(date +%s.%N)  # Start time for the loop
	unix_datetime=$(date +"$unix_timeformat")  # Unix timestamp for MySQL insert
	log_datetime=$(date -d "$unix_datetime" +"$log_timeformat") # timestamp for log search

    # Use awk to filter and process log entries in one pass
    awk -v log_datetime="$log_datetime" '
    $0 ~ log_datetime {  # Filter lines matching log_datetime
        upstream = $3;
        status = $4;
        ip = $5;
        bytes = $7;
        url = $8;

        # Skip entries with irrelevant status
        if (status != "HIT" && status != "MISS") {
            next;
        }

        # Skip entries with missing values
        if (upstream == "" || status == "" || ip == "" || bytes == "") {
            next;
        }

        # Parse app from URL
        split(url, parts, "/ias/|/chunks|/depot/|/chunk|/manifest");
        app = (length(parts) > 2) ? parts[length(parts)-1] : "";

        # Create the key for aggregation
        key = ip "|" upstream "|" app "|" status;

        # Aggregate the data by key
        aggregated_data[key] += bytes;
    }
    END {
        # Print aggregated data for later processing
        for (key in aggregated_data) {
            print key "|" aggregated_data[key];
        }
    }
    ' "$LOG_FILE" | while IFS="|" read -r ip upstream app status bytes; do
        # Insert aggregated records into the database
        echo "$unix_datetime: Inserting into database: IP=$ip, Upstream=$upstream, App=$app, Status=$status, Bytes=$bytes"
        mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" \
            -e "INSERT INTO access_logs (Upstream, LStatus, IP, App, Bytes) VALUES ('$upstream', '$status', '$ip', '$app', '$bytes');"
    done

    # Get cache disk used and free space and log folder size
    read -r used_space_cache free_space_cache < <(df -k --output=used,avail "$CACHE_LOCATION" | tail -n 1 | awk '{print $1, $2}')
    used_space_logs=$(du -sk "$LOGS_LOCATION" | cut -f1)

    # Create SQL statements
    update_cache_usage_sql="UPDATE cache_disk SET KiBUsed='$used_space_cache', KiBFree='$free_space_cache' WHERE Location='data'"
    update_logs_usage_sql="UPDATE cache_disk SET KiBUsed='$used_space_logs', KiBFree='$free_space_cache' WHERE Location='logs'"

    # Insert cache usage data into MySQL
    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" \
        -e "$update_cache_usage_sql; $update_logs_usage_sql;"

    # Calculate elapsed time and adjust for next loop
    end_time=$(date +%s.%N)
    elapsed_time=$(echo "$end_time - $start_time" | bc)
    remaining_time=$(echo "$loop_interval - $elapsed_time" | bc)

    if (( $(echo "$remaining_time > 0" | bc -l) )); then
        sleep "$remaining_time"
    fi
done
