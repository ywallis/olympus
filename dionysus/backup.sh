#/bin/bash

SOURCE="/home/$USER/dionysus"
DESTINATION="rsync@hera.olympus:/volume1/Backup/"
DATE=$(date +"%Y-%m-%d %H:%M:%S")
LOGDIR="/home/$USER/logs"
LOGFILE="$LOGDIR/daily_backup.log"

mkdir -p "$LOGDIR"
echo "Backup started at $DATE" >> "$LOGFILE"
rsync -az --delete "$SOURCE" "$DESTINATION" >> "$LOGFILE" 2>&1
echo "Backup completed at $DATE" >> "$LOGFILE"
