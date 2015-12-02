#!/bin/bash

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
# USER VARIABLES
#
# Change these to match wherever you want your backups to go
# Impotant: don't add a slash to the end! That's done later.
# -----------------------------------------------------------------------------

SOURCE_DIR="/home/username"
BACKUP_DIR="/mnt/drive_name/backup_dir"
IGNORE_FILE="$SOURCE_DIR/backup_ignore"


# -----------------------------------------------------------------------------
# MAIN SCRIPT
# -----------------------------------------------------------------------------

# Set up variables
markerfile="$BACKUP_DIR/backup.marker"

# Run the backup if the marker is in place (drive is mounted.)
if [ -f "$markerfile" ]
then
  echo "$markerfile found, backup starting."
  ./rsync_tmbackup.sh "$SOURCE_DIR/" "$BACKUP_DIR" "$IGNORE_FILE"
else
  echo "$markerfile not found!"
fi


