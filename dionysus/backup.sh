#/bin/bash

SOURCE="/home/$USER/dionysus"
DESTINATION="rsync@hera.olympus:/volume1/Backup/"
DATE=$(date +"%Y-%m-%d %H:%M:%S")
LOGFILE="~/logs/daily_backup.log"

rsync -az --delete "$SOURCE" "$DESTINATION" >> "$LOGFILE" 2>&1
echo "Backup completed at $DATE" >> "$LOGFILE"
