#!/bin/bash

USER=$(whoami)
SOURCE="rsync@hera.olympus:/volume1/Backup/dionysus/"
DESTINATION="/home/$USER/dionysus/"
ENV_SOURCE="rsync@hera.olympus:/volume1/Backup/dionysus/.env"
ENV_DESTINATION="/home/$USER/olympus/dionysus/"
DATE=$(date +"%Y-%m-%d %H:%M:%S")
LOGDIR="/home/$USER/logs"
LOGFILE="$LOGDIR/daily_import.log"

mkdir -p "$LOGDIR"
echo "Import started at $DATE" >> "$LOGFILE"
rsync -az "$SOURCE" "$DESTINATION" >> "$LOGFILE" 2>&1
rsync -az "$ENV_SOURCE" "$ENV_DESTINATION" >> "$LOGFILE" 2>&1
echo "Import completed at $DATE" >> "$LOGFILE"
