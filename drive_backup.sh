#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# INFO
#
# This is a template script that you can use instead of setting up everything
# in your crontab. To install it, just change the user variables below
# to match your setup, then rename the script if you like. I like to
# have the script name match my drive name, but you can keep it as-is
# if you only back up to a single external drive.
#
# Once you have that set up, you can add a simple crontab entry that
# calls this script regularly. It will do the drive checking for you,
# and exit cleanly if it's not attached.
#
# An example crontab entry could look like this:
# */10 * * * * /bin/bash /home/lorentrogers/sabrent_backup.sh
# This runs the backup script (for my sabrent USB drive) every 10 min.
# -----------------------------------------------------------------------------


# -----------------------------------------------------------------------------
# VARIABLES
#
# Change these to match your system setup.
# Impotant: don't add a slash to the end! That's done later.
# -----------------------------------------------------------------------------


SOURCE_DIR="/home/lorentrogers"
BACKUP_DIR="/mnt/sabrent/backup/thinkpad-x201"
IGNORE_FILE="$SOURCE_DIR/backup_ignore"
SCRIPT_DIR="/home/lorentrogers/bin/rsync-time-backup"


# -----------------------------------------------------------------------------
# RUNTIME
# -----------------------------------------------------------------------------


# Set up variables
markerfile="$BACKUP_DIR/backup.marker"

# Run the backup if the marker is in place (drive is mounted.)
if [ -f "$markerfile" ]
then
  echo "$markerfile found, backup starting."
  eval "$SCRIPT_DIR/rsync_tmbackup.sh backup \
    $SOURCE_DIR/ $BACKUP_DIR $IGNORE_FILE"
else
  echo "$markerfile not found!"
fi


