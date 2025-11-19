#!/usr/bin/env bash
# Simple Log Backup Script - COMPLETE VERSION
# Usage: ./backup_logs.sh [backup|add <path>|remove <path>|schedule|report|restore <file>]

# Load configuration file
CONFIG_FILE="$HOME/log_backup.conf"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: $CONFIG_FILE"
    exit 1
fi

# Read the configuration
source "$CONFIG_FILE"

# Convert comma-separated directories to array
IFS=',' read -r -a SOURCE_DIRS_ARRAY <<< "$SOURCE_DIRS"

# Get current hostname
HOSTNAME=$(hostname -s)

# Create folders if they don't exist
mkdir -p "$TEMP_PATH" "$CSV_PATH"
touch "$LOG_FILE"

# Function to get current timestamp
get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Function to get timestamp for filenames
get_filename_timestamp() {
    date '+%Y%m%d_%H%M%S'
}

# Function to log actions
log_action() {
    local action="$1"
    local status="$2"
    echo "$(get_timestamp),$(whoami),$action,$status" >> "$LOG_FILE"
}

# Function to send Discord notification
send_discord() {
    local message="$1"
    if [ -n "$DISCORD_WEBHOOK_URL" ]; then
        curl -s -X POST -H "Content-Type: application/json" \
             -d "{\"content\":\"$message\"}" "$DISCORD_WEBHOOK_URL" > /dev/null 2>&1
    fi
}

# Function to create and update CSV report
create_csv_report() {
    local csv_file="$CSV_PATH/${HOSTNAME}_backup_$(get_filename_timestamp).csv"
    
    # Create CSV header
    echo "Date,Hostname,Directory,Status" > "$csv_file"
    
    # Add each directory to CSV with PENDING status
    for dir in "${SOURCE_DIRS_ARRAY[@]}"; do
        echo "$(get_timestamp),$HOSTNAME,$dir,PENDING" >> "$csv_file"
    done
    
    # Send initial CSV to backup server
    scp -i "$SSH_KEY" "$csv_file" "$DEST_USER@$DEST_HOST:$CSV_DEST_PATH/" 2>/dev/null
    
    log_action "Created CSV report: $(basename $csv_file)" "SUCCESS"
    echo "Created report: $(basename $csv_file)"
    
    # Return just the filename (no extra text)
    echo "$csv_file"
}

# Function to update CSV status
update_csv_status() {
    local csv_file="$1"
    local directory="$2"
    local status="$3"
    
    # Create a new temporary CSV file
    local temp_file="${csv_file}.tmp"
    
    # Read the original CSV and update the status
    while IFS= read -r line; do
        if [[ "$line" == *"$directory"* ]] && [[ "$line" == *"PENDING"* ]]; then
            # Replace PENDING with the actual status
            echo "${line/PENDING/$status}"
        else
            echo "$line"
        fi
    done < "$csv_file" > "$temp_file"
    
    # Replace the original file with the updated one
    mv "$temp_file" "$csv_file"
    
    # Send updated CSV to backup server
    scp -i "$SSH_KEY" "$csv_file" "$DEST_USER@$DEST_HOST:$CSV_DEST_PATH/" 2>/dev/null
}

# Function to backup a single directory
backup_directory() {
    local dir="$1"
    local csv_file="$2"
    local timestamp=$(get_filename_timestamp)
    local archive_name="${HOSTNAME}_$(basename $dir)_${timestamp}.tar.gz"
    local temp_archive="$TEMP_PATH/$archive_name"
    
    echo "Backing up: $dir"
    
    # Create compressed archive
    if tar -czf "$temp_archive" -C "$(dirname $dir)" "$(basename $dir)" 2>/dev/null; then
        # Send to backup server
        if scp -i "$SSH_KEY" "$temp_archive" "$DEST_USER@$DEST_HOST:$DEST_PATH/" 2>/dev/null; then
            log_action "Backed up: $dir" "SUCCESS"
            update_csv_status "$csv_file" "$dir" "SUCCESS"
            echo "Success: $dir"
            # Clean up local temp file
            rm -f "$temp_archive"
            return 0
        else
            log_action "Failed to send: $dir" "FAILED"
            update_csv_status "$csv_file" "$dir" "FAILED"
            echo "Failed to send: $dir"
            rm -f "$temp_archive"
            return 1
        fi
    else
        log_action "Failed to compress: $dir" "FAILED"
        update_csv_status "$csv_file" "$dir" "FAILED"
        echo "Failed to compress: $dir"
        return 1
    fi
}

# Main backup function
do_backup() {
    local start_time=$(date +%s)
    log_action "Backup started" "STARTED"
    
    echo "Starting backup process..."
    
    # Create CSV report and get the filename
    local csv_file
    csv_file=$(create_csv_report)
    
    # Remove any extra text - just get the filename
    csv_file=$(echo "$csv_file" | tail -1)
    
    # Backup each directory
    local success_count=0
    local fail_count=0
    
    for directory in "${SOURCE_DIRS_ARRAY[@]}"; do
        if [ -d "$directory" ]; then
            if backup_directory "$directory" "$csv_file"; then
                ((success_count++))
            else
                ((fail_count++))
            fi
        else
            echo "Directory not found: $directory"
            log_action "Directory missing: $directory" "FAILED"
            update_csv_status "$csv_file" "$directory" "NOT_FOUND"
            ((fail_count++))
        fi
    done
    
    # Clean up old backups (retention policy)
    ssh -i "$SSH_KEY" "$DEST_USER@$DEST_HOST" \
        "find $DEST_PATH -name '*.tar.gz' -mtime +$RETENTION_DAYS -delete" 2>/dev/null
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    # Log completion
    log_action "Backup completed: $success_count success, $fail_count failed" "COMPLETED"
    
    # Send Discord notification
    if [ $fail_count -eq 0 ]; then
        send_discord "Backup completed successfully on $HOSTNAME: $success_count directories backed up in ${duration}s"
        echo "Backup completed successfully! $success_count directories backed up."
    else
        send_discord "Backup completed with errors on $HOSTNAME: $success_count success, $fail_count failed in ${duration}s"
        echo "Backup completed with errors: $success_count success, $fail_count failed."
    fi
}

# Function to add a directory to backup list
add_directory() {
    local new_dir="$1"
    
    if [ -z "$new_dir" ]; then
        echo "Usage: ./backup_logs.sh add /path/to/directory"
        exit 1
    fi
    
    if [ ! -d "$new_dir" ]; then
        echo "Error: Directory does not exist: $new_dir"
        exit 1
    fi
    
    # Check if already in list
    if echo "$SOURCE_DIRS" | grep -q "$new_dir"; then
        echo "Directory already in backup list: $new_dir"
        exit 0
    fi
    
    # Add to SOURCE_DIRS in config file
    if [ -z "$SOURCE_DIRS" ]; then
        sed -i "s|^SOURCE_DIRS=.*|SOURCE_DIRS=\"$new_dir\"|" "$CONFIG_FILE"
    else
        sed -i "s|^SOURCE_DIRS=\"|SOURCE_DIRS=\"$new_dir,|" "$CONFIG_FILE"
    fi
    
    log_action "Added directory: $new_dir" "SUCCESS"
    echo "Added directory to backup list: $new_dir"
}

# Function to remove a directory from backup list
remove_directory() {
    local remove_dir="$1"
    
    if [ -z "$remove_dir" ]; then
        echo "Usage: ./backup_logs.sh remove /path/to/directory"
        exit 1
    fi
    
    # Remove from SOURCE_DIRS in config file
    sed -i "s|,$remove_dir||" "$CONFIG_FILE"
    sed -i "s|$remove_dir,||" "$CONFIG_FILE"
    sed -i "s|^SOURCE_DIRS=\"$remove_dir\"|SOURCE_DIRS=\"\"|" "$CONFIG_FILE"
    
    log_action "Removed directory: $remove_dir" "SUCCESS"
    echo "Removed directory from backup list: $remove_dir"
}

# Function to schedule automatic backups
schedule_backups() {
    # Create cron job for daily backups at 2 AM
    local cron_job="0 2 * * * $HOME/backup_logs.sh backup >> $HOME/backup_cron.log 2>&1"
    
    # Add to crontab
    (crontab -l 2>/dev/null | grep -v "backup_logs.sh"; echo "$cron_job") | crontab -
    
    log_action "Scheduled automatic backups" "SUCCESS"
    echo "Automatic backups scheduled: daily at 2:00 AM"
    echo "Cron log: $HOME/backup_cron.log"
}

# Function to generate performance report
generate_report() {
    local report_file="$CSV_PATH/${HOSTNAME}_performance_$(get_filename_timestamp).csv"
    
    echo "=== Generating Performance Report ==="
    
    # Get backup statistics from remote server
    local backup_count=$(ssh -i "$SSH_KEY" "$DEST_USER@$DEST_HOST" "find $DEST_PATH -name '*.tar.gz' | wc -l" 2>/dev/null || echo "0")
    local backup_size=$(ssh -i "$SSH_KEY" "$DEST_USER@$DEST_HOST" "du -sh $DEST_PATH 2>/dev/null | cut -f1" || echo "0B")
    local csv_count=$(ssh -i "$SSH_KEY" "$DEST_USER@$DEST_HOST" "find $CSV_DEST_PATH -name '*.csv' | wc -l" 2>/dev/null || echo "0")
    
    # Create performance report
    echo "ReportDate,Hostname,TotalBackups,BackupSize,TotalCSVReports,RetentionDays" > "$report_file"
    echo "$(get_timestamp),$HOSTNAME,$backup_count,$backup_size,$csv_count,$RETENTION_DAYS" >> "$report_file"
    
    # Send report to backup server
    scp -i "$SSH_KEY" "$report_file" "$DEST_USER@$DEST_HOST:$CSV_DEST_PATH/" 2>/dev/null
    
    log_action "Generated performance report" "SUCCESS"
    
    echo "Performance Report:"
    echo "=================="
    echo "Total Backup Files: $backup_count"
    echo "Total Backup Size: $backup_size"
    echo "Total CSV Reports: $csv_count"
    echo "Retention Policy: $RETENTION_DAYS days"
    echo "Report saved: $(basename $report_file)"
}

# Function to restore a backup
restore_backup() {
    local backup_file="$1"
    
    if [ -z "$backup_file" ]; then
        echo "Usage: ./backup_logs.sh restore <backup-filename>"
        echo ""
        echo "Available backups on $DEST_HOST:"
        ssh -i "$SSH_KEY" "$DEST_USER@$DEST_HOST" "ls -la $DEST_PATH/*.tar.gz | tail -10"
        exit 1
    fi
    
    echo "=== Restoring Backup: $backup_file ==="
    
    # Download the backup file from remote server
    if scp -i "$SSH_KEY" "$DEST_USER@$DEST_HOST:$DEST_PATH/$backup_file" "$TEMP_PATH/" 2>/dev/null; then
        local local_file="$TEMP_PATH/$backup_file"
        
        if [ -f "$local_file" ]; then
            echo "Backup file downloaded successfully"
            
            # Create a safe restore directory (don't overwrite system files)
            local restore_dir="$HOME/restore_test_$(get_filename_timestamp)"
            mkdir -p "$restore_dir"
            
            # Extract the backup
            if tar -xzf "$local_file" -C "$restore_dir"; then
                echo "Backup restored successfully to: $restore_dir"
                log_action "Restored backup: $backup_file to $restore_dir" "SUCCESS"
                
                # Show what was restored
                echo "Contents restored:"
                find "$restore_dir" -type f | head -10
                
            else
                echo "Error: Failed to extract backup file"
                log_action "Failed to extract backup: $backup_file" "FAILED"
            fi
            
            # Clean up
            rm -f "$local_file"
        else
            echo "Error: Backup file not found after download"
            log_action "Backup file not found: $backup_file" "FAILED"
        fi
    else
        echo "Error: Failed to download backup file from server"
        echo "Check if the filename is correct: $backup_file"
        log_action "Failed to download backup: $backup_file" "FAILED"
    fi
}

# Main script logic
case "${1:-backup}" in
    "backup")
        do_backup
        ;;
    "add")
        add_directory "$2"
        ;;
    "remove")
        remove_directory "$2"
        ;;
    "schedule")
        schedule_backups
        ;;
    "report")
        generate_report
        ;;
    "restore")
        restore_backup "$2"
        ;;
    *)
        echo "Simple Log Backup Script"
        echo "Usage: $0 [backup|add <path>|remove <path>|schedule|report|restore <file>]"
        echo ""
        echo "Commands:"
        echo "  backup           - Run backup now"
        echo "  add <dir>        - Add directory to backup"
        echo "  remove <dir>     - Remove directory from backup"  
        echo "  schedule         - Setup automatic daily backups"
        echo "  report           - Generate performance report"
        echo "  restore <file>   - Restore a backup file"
        echo ""
        echo "Examples:"
        echo "  $0 add /var/log"
        echo "  $0 restore VmSource_logs_20251117_005838.tar.gz"
        exit 1
        ;;
esac
