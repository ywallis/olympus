#!/bin/bash

USER=$(whoami)
SOURCE="rsync@hera.olympus:/volume1/Backup/narcissus/.env"
DESTINATION="/home/$USER/olympus/narcissus/"
DATE=$(date +"%Y-%m-%d %H:%M:%S")
LOGDIR="/home/$USER/logs"
LOGFILE="$LOGDIR/daily_import.log"

mkdir -p "$LOGDIR"
echo "Import started at $DATE" >> "$LOGFILE"
rsync -az "$SOURCE" "$DESTINATION" >> "$LOGFILE" 2>&1
echo "Import completed at $DATE" >> "$LOGFILE"
