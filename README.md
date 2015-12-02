# Time machine style backups using rsync
## Description

Time Machine style backups with rsync. Tested on Linux, but should work on any platform since this script has no operating system or file system specific dependencies like the original.

## Installation

	git clone https://github.com/eaut/rsync-time-backup

## Usage

```
rsync_tmbackup.sh [OPTIONS] command [ARGS]

Commands:

  init <backup_location> [--local-time]
      initialize <backup_location> by creating a backup marker file.

         --local-time
             name all backups using local time, per default backups
             are named using UTC.

  backup <src_location> <backup_location> [<exclude_file>]
      create a Time Machine like backup from <src_location> at <backup_location>.
      optional: exclude files in <exclude_file> from backup

  diff <backup1> <backup2>
      show differences between two backups.

Options:

  -s, --syslog
      log output to syslogd

  -k, --keep-expired
      do not delete expired backups until they can be reused by subsequent backups or
      the backup location runs out of space.

  -v, --verbose
      increase verbosity

  --version
      display version and exit

  -h, --help
      this help text
```

### crontab example

	# backup /home at quarter past every hour to /mnt/backup
	15 * * * * rsync_tmbackup.sh -v -s -k backup /home /mnt/backup /mnt/backup/backup.exclude

### customize backup rentention times

The backup marker file is also used as configuration file for backup retention times. Defaults shown below can be modified if needed.

```
RETENTION_WIN_ALL="$((4 * 3600))"        # 4 hrs
RETENTION_WIN_01H="$((1 * 24 * 3600))"   # 24 hrs
RETENTION_WIN_04H="$((3 * 24 * 3600))"   # 3 days
RETENTION_WIN_08H="$((14 * 24 * 3600))"  # 2 weeks
RETENTION_WIN_24H="$((28 * 24 * 3600))"  # 4 weeks
```

### backup over SSH

To send to a remote destination, start by setting up key-based authentication
between client and server. Passwords won't work here.

Only remote destinations are supported. Remote sources won't make any sense.

Destinations must be in the form of <user>@<host>:<directory>.

Example of backup to a NAS on the local network:

    /bin/bash /path/to/rsync_tmbackup.sh /path/to/source username@xxx.xxx.xxx.xxx:backup

## Features

### Improvements/changes compared to Laurent Cozic's version

* more priority for new backups:
  1. expire backups by moving them to an expired folder (fast!)
  2. create new backup
  3. delete old backups thereafter (slow!, all inodes have to be removed)
* shorter backup times: 
  - minimize inode deletions/creations by reusing expired backups - usually most files/inodes have not changed even compared to older backups
* backup.marker file can be used as config file
  - more flexible and configurable backup expiration windows
  - UTC & local time handling as part of backup.marker config
* flexible command line interface, new subcommands and options
  - compare to backups, initialize backup marker, ...
  - option to log to syslog

###  Unchanged

* Each backup is on its own folder named after the current timestamp. Files can be copied and restored directly, without any intermediate tool.

* Files that haven't changed from one backup to the next are hard-linked to the previous backup so take very little extra space.

* Safety check - the backup will only happen if the destination has explicitly been marked as a backup destination.

* Resume feature - if a backup has failed or was interrupted, the tool will resume from there on the next backup.

* Automatically purge old backups - within 24 hours, all backups are kept. Within one month, the most recent backup for each day is kept. For all previous backups, the most recent of each month is kept.

* "latest" symlink that points to the latest successful backup.

* The application is just one bash script that can be easily edited.

## LICENSE

The MIT License (MIT)

Copyright (c) 2013-2014 Laurent Cozic  
Copyright (c) 2015 eaut

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
