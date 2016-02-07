#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# global variables
# -----------------------------------------------------------------------------

readonly APPNAME=$(basename "${0%.sh}")
readonly SSH_CMD="ssh"

# backup config defaults (overridden by backup marker configuration)
UTC="false"  # compatibility setting for old backups without marker config
RETENTION_WIN_ALL=$((4 * 3600))        # 4 hrs
RETENTION_WIN_01H=$((1 * 24 * 3600))   # 24 hrs
RETENTION_WIN_04H=$((3 * 24 * 3600))   # 3 days
RETENTION_WIN_08H=$((14 * 24 * 3600))  # 2 weeks
RETENTION_WIN_24H=$((28 * 24 * 3600))  # 4 weeks

# command line argument defaults
OPT_VERBOSE="false"
OPT_SYSLOG="false"
OPT_KEEP_EXPIRED="false"
SSH_ARG=""

# other
DEST_HOST=""
DEST_FOLDER=""
BACKUP_MARKER_FILE=""
EXPIRED_DIR=""
TMP_RSYNC_LOG=""

# -----------------------------------------------------------------------------
# functions
# -----------------------------------------------------------------------------

fn_usage() {
  fn_log info "Usage: $APPNAME [OPTIONS] command [ARGS]"
  fn_log info
  fn_log info "Commands:"
  fn_log info
  fn_log info "  init <backup_location> [--local-time]"
  fn_log info "      initialize <backup_location> by creating a backup marker file."
  fn_log info
  fn_log info "         --local-time"
  fn_log info "             name all backups using local time, per default backups"
  fn_log info "             are named using UTC."
  fn_log info
  fn_log info "  backup <src_location> <backup_location> [<exclude_file>]"
  fn_log info "      create a Time Machine like backup from <src_location> at <backup_location>."
  fn_log info "      optional: exclude files in <exclude_file> from backup"
  fn_log info
  fn_log info "  diff <backup1> <backup2>"
  fn_log info "      show differences between two backups."
  fn_log info
  fn_log info "Options:"
  fn_log info
  fn_log info "  -s, --syslog"
  fn_log info "      log output to syslogd"
  fn_log info
  fn_log info "  -k, --keep-expired"
  fn_log info "      do not delete expired backups until they can be reused by subsequent backups or"
  fn_log info "      the backup location runs out of space."
  fn_log info
  fn_log info "  --ssh-opt <option>"
  fn_log info "      pass options to ssh, e.g. '-p 22'"
  fn_log info
  fn_log info "  -v, --verbose"
  fn_log info "      increase verbosity"
  fn_log info
  fn_log info "  -h, --help"
  fn_log info "      this help text"
  fn_log info
}

fn_log() {
  local TYPE="$1"
  local MSG="${@:2}"
  [[ $TYPE == "verbose" ]] && { [[ $OPT_VERBOSE == "true" ]] && TYPE="info" || return ; }
  [[ $TYPE == "info" ]] && echo "${MSG[@]}" || { MSG=("[${TYPE^^}]" "${MSG[@]}") ; echo "${MSG[@]}" 1>&2 ; }
  [[ $OPT_SYSLOG == "true" ]] && echo "${MSG[@]}" >&40
}

fn_cleanup() {
  if [ -f "$TMP_RSYNC_LOG" ]; then
    rm -f -- "$TMP_RSYNC_LOG"
  fi
  # close redirection to logger
  if [ "$OPT_SYSLOG" == "true" ]; then
    exec 40>&-
  fi
}

fn_set_dest_folder() {
  # check if destination is remote
  if [[ $1 =~ ([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+):(.+) ]]; then
    DEST_HOST="${BASH_REMATCH[1]}"
    DEST_FOLDER="${BASH_REMATCH[2]}"
    fn_log info "backup location: $DEST_HOST:$DEST_FOLDER"
  else
    DEST_HOST=""
    DEST_FOLDER="$1"
    fn_log info "backup location: $DEST_FOLDER"
  fi
  if fn_run "[ ! -d '$DEST_FOLDER' ]"; then
    fn_log error "backup location $DEST_FOLDER does not exist."
    exit 1
  fi
}

fn_run() {
  # IMPORTANT:
  #   commands or command sequences that make use of pipes, redirection, 
  #   semicolons or conditional expressions have to passed as quoted strings
  if [[ -n $DEST_HOST ]]; then
    if [[ -n $SSH_ARG ]]; then
      "$SSH_CMD" "$SSH_ARG" -- "$DEST_HOST" "$@"
    else
      "$SSH_CMD" -- "$DEST_HOST" "$@"
    fi
    if [[ $? -eq 255 ]]; then
      fn_log error "ssh command failed: $SSH_CMD $SSH_ARG -- $DEST_HOST $@"
      exit 1
    fi
  else
    eval "$@"
  fi
}

fn_parse_date() {
  # Converts YYYY-MM-DD-HHMMSS to YYYY-MM-DD HH:MM:SS and then to Unix Epoch.
  local DATE_OPTIONS=()
  [[ $UTC == "true" ]] && DATE_OPTIONS+=("-u")
  case "$OSTYPE" in
    darwin*|*bsd*) DATE_OPTIONS+=("-j" "-f" "%Y-%m-%d-%H%M%S $1") ;;
    *)             DATE_OPTIONS+=("-d" "${1:0:10} ${1:11:2}:${1:13:2}:${1:15:2}") ;;
  esac
  date "${DATE_OPTIONS[@]}" "+%s"
}

fn_mkdir() {
  if ! fn_run mkdir -p -- "$1"; then
    fn_log error "creation of directory $1 failed."
    exit 1
  fi
}

fn_find_backups() {
  if [ "$1" == "expired" ]; then
    if fn_run "[ -d '$EXPIRED_DIR' ]"; then
      fn_run find "'$EXPIRED_DIR' -maxdepth 1 -type d -name '????-??-??-??????' | sort -r"
    fi
  else
    fn_run find "'$DEST_FOLDER' -maxdepth 1 -type d -name '????-??-??-??????' | sort -r"
  fi
}

fn_check_backup_marker() {
  #
  # TODO: check that the destination supports hard links
  #
  if fn_run "[ ! -f '$BACKUP_MARKER_FILE' ]"; then
    fn_log error "Destination does not appear to be a backup location - no backup marker file found."
    exit 1
  fi
  if ! fn_run "touch -c '$BACKUP_MARKER_FILE' &> /dev/null"; then
    fn_log error "no write permission for this backup location - aborting."
    exit 1
  fi
}

fn_import_backup_marker() {
  fn_check_backup_marker
  # read backup configuration from backup marker
  if [[ -n $(fn_run cat "$BACKUP_MARKER_FILE") ]]; then
    eval "$(fn_run cat "$BACKUP_MARKER_FILE")"
    fn_log info "configuration imported from backup marker"
  else
    fn_log info "no configuration imported from backup marker - using defaults"
  fi
}

fn_mark_expired() {
  fn_check_backup_marker
  fn_mkdir "$EXPIRED_DIR"
  fn_run mv -- "$1" "$EXPIRED_DIR/"
}

fn_expire_backups() {
  local NOW_TS=$(fn_parse_date "$1")

  #
  # backup aggregation windows and retention times
  #
  local LIMIT_ALL_TS=$((NOW_TS - RETENTION_WIN_ALL))  # until this point in time all backups are retained
  local LIMIT_1H_TS=$((NOW_TS  - RETENTION_WIN_01H))  # max 1 backup per hour
  local LIMIT_4H_TS=$((NOW_TS  - RETENTION_WIN_04H))  # max 1 backup per 4 hours
  local LIMIT_8H_TS=$((NOW_TS  - RETENTION_WIN_08H))  # max 1 backup per 8 hours
  local LIMIT_24H_TS=$((NOW_TS - RETENTION_WIN_24H))  # max 1 backup per day

  # Default value for $PREV_BACKUP_DATE ensures that the most recent backup is never deleted.
  local PREV_BACKUP_DATE="0000-00-00-000000"
  local BACKUP
  for BACKUP in $(fn_find_backups); do

    # BACKUP_DATE format YYYY-MM-DD-HHMMSS
    local BACKUP_DATE=$(basename "$BACKUP")
    local BACKUP_TS=$(fn_parse_date "$BACKUP_DATE")

    # Skip if failed to parse date...
    if [[ $BACKUP_TS != +([0-9]) ]]; then
      fn_log warning "Could not parse date: $BACKUP_DATE"
      continue
    fi

    local BACKUP_MONTH=${BACKUP_DATE:0:7}
    local BACKUP_DAY=${BACKUP_DATE:0:10}
    local BACKUP_HOUR=${BACKUP_DATE:11:2}
    local BACKUP_HOUR=${BACKUP_HOUR#0}  # work around bash octal numbers
    local PREV_BACKUP_MONTH=${PREV_BACKUP_DATE:0:7}
    local PREV_BACKUP_DAY=${PREV_BACKUP_DATE:0:10}
    local PREV_BACKUP_HOUR=${PREV_BACKUP_DATE:11:2}
    local PREV_BACKUP_HOUR=${PREV_BACKUP_HOUR#0}  # work around bash octal numbers

    if [ $BACKUP_TS -ge $LIMIT_ALL_TS ]; then
      true
      fn_log verbose "  $BACKUP_DATE ALL retained"
    elif [ $BACKUP_TS -ge $LIMIT_1H_TS ]; then
      if [ "$BACKUP_DAY" == "$PREV_BACKUP_DAY" ] && \
         [ "$((BACKUP_HOUR / 1))" -eq "$((PREV_BACKUP_HOUR / 1))" ]; then
        fn_mark_expired "$BACKUP"
        fn_log info "  $BACKUP_DATE 01H expired"
      else
        fn_log verbose "  $BACKUP_DATE 01H retained"
      fi
    elif [ $BACKUP_TS -ge $LIMIT_4H_TS ]; then
      if [ "$BACKUP_DAY" == "$PREV_BACKUP_DAY" ] && \
         [ "$((BACKUP_HOUR / 4))" -eq "$((PREV_BACKUP_HOUR / 4))" ]; then
        fn_mark_expired "$BACKUP"
        fn_log info "  $BACKUP_DATE 04H expired"
      else
        fn_log verbose "  $BACKUP_DATE 04H retained"
      fi
    elif [ $BACKUP_TS -ge $LIMIT_8H_TS ]; then
      if [ "$BACKUP_DAY" == "$PREV_BACKUP_DAY" ] && \
         [ "$((BACKUP_HOUR / 8))" -eq "$((PREV_BACKUP_HOUR / 8))" ]; then
        fn_mark_expired "$BACKUP"
        fn_log info "  $BACKUP_DATE 08H expired"
      else
        fn_log verbose "  $BACKUP_DATE 08H retained"
      fi
    elif [ $BACKUP_TS -ge $LIMIT_24H_TS ]; then
      if [ "$BACKUP_DAY" == "$PREV_BACKUP_DAY" ]; then
        fn_mark_expired "$BACKUP"
        fn_log info "  $BACKUP_DATE 24H expired"
      else
        fn_log verbose "  $BACKUP_DATE 24H retained"
      fi
    else
      if [ "$BACKUP_MONTH" == "$PREV_BACKUP_MONTH" ]; then
        fn_mark_expired "$BACKUP"
        fn_log info "  $BACKUP_DATE 01M expired"
      else
        fn_log verbose "  $BACKUP_DATE 01M retained"
      fi
    fi
    PREV_BACKUP_DATE=$BACKUP_DATE
  done
}

fn_delete_backups() {
  fn_check_backup_marker
  local BACKUP
  for BACKUP in $(fn_find_backups expired); do
    # work-around: in case of no match, bash returns "*"
    if [ "$BACKUP" != '*' ] && [ -e "$BACKUP" ]; then
      fn_log info "deleting expired backup $(basename "$BACKUP")"
      fn_run rm -rf -- "$BACKUP"
    fi
  done
  if [[ -z $(fn_find_backups expired) ]]; then
    if fn_run "[ -d '$EXPIRED_DIR' ]"; then
      fn_run rmdir -- "$EXPIRED_DIR"
    fi
  fi
}

fn_backup() {

  fn_log info "backup start"

  local SRC_FOLDER="$1"
  if [[ -d $SRC_FOLDER ]]; then
    fn_log info "backup source path: $SRC_FOLDER"
  else
    fn_log error "backup source path $SRC_FOLDER does not exist."
    exit 1
  fi

  fn_set_dest_folder "$2"

  # load backup specific config
  BACKUP_MARKER_FILE="$DEST_FOLDER/backup.marker"
  fn_import_backup_marker

  local EXCLUDE_FILE="$3"

  # ---
  # Basic variables
  # ---
  local NOW
  if [ "$UTC" == "true" ]; then
    NOW=$(date -u +"%Y-%m-%d-%H%M%S")
    fn_log info "backup time base: UTC"
  else
    NOW=$(date +"%Y-%m-%d-%H%M%S")
    fn_log info "backup time base: local time"
  fi

  local DEST="$DEST_FOLDER/$NOW"
  local INPROGRESS_FILE="$DEST_FOLDER/backup.inprogress"
  EXPIRED_DIR="$DEST_FOLDER/expired"
  TMP_RSYNC_LOG=$(mktemp "/tmp/${APPNAME}_XXXXXXXXXX")

  # ---
  # Check for previous backup operations
  # ---
  local PREV_BACKUP="$(fn_find_backups | head -n 1)"

  if fn_run "[ -f '$INPROGRESS_FILE' ]"; then
    if pgrep -F "$INPROGRESS_FILE" "$APPNAME" > /dev/null 2>&1 ; then
      fn_log error "previous backup task is still active - aborting."
      exit 1
    fi
    fn_log info "previous backup $PREV_BACKUP was interrupted - resuming from there."
    fn_run "echo '$$' > '$INPROGRESS_FILE'"
    # last backup is moved to current backup folder so that it can be resumed.
    fn_run mv -- "$PREV_BACKUP" "$DEST"
    # 2nd to last backup becomes last backup.
    if [ "$(fn_find_backups | wc -l)" -gt 1 ]; then
      PREV_BACKUP="$(fn_find_backups | sed -n '2p')"
    else
      PREV_BACKUP=""
    fi
  else
    fn_run "echo '$$' > '$INPROGRESS_FILE'"
  fi

  # ---
  # expire existing backups
  # ---
  fn_log info "expiring backups..."
  fn_expire_backups "$NOW"

  # ---
  # create backup directory
  # ---
  local LAST_EXPIRED="$(fn_find_backups expired | head -n 1)"

  if [ -n "$LAST_EXPIRED" ]; then
    # reuse the newest expired backup as the basis for the next rsync
    # operation. this significantly speeds up backup times!
    # to work rsync needs the following options: --delete --delete-excluded
    fn_log info "reusing expired backup $(basename "$LAST_EXPIRED")"
    fn_run mv -- "$LAST_EXPIRED" "$DEST"
  else
    # a new backup directory is needed
    fn_mkdir "$DEST"
  fi

  # ---
  # Run in a loop to handle the "No space left on device" logic.
  # ---
  while ! fn_rsync "$SRC_FOLDER" "$DEST" "$PREV_BACKUP" "$EXCLUDE_FILE" ; do

    fn_log warning "rsync error exit code: $?"

    # Check if error was caused by to little space, TODO: find better way without log parsing
    local NO_SPACE_LEFT="$(grep "No space left on device (28)\|Result too large (34)" "$TMP_RSYNC_LOG")"

    if [ -n "$NO_SPACE_LEFT" ]; then
      if [ -z "$(fn_find_backups expired)" ]; then
        if [[ "$(fn_find_backups | wc -l)" -le 1 ]]; then
          fn_log error "no space left on backup device, and no old backup to expire"
          exit 1
        else
          fn_log warning "no space left on backup device, expiring oldest backup"
          fn_mark_expired "$(fn_find_backups | tail -n 1)"
        fi
      fi
      fn_delete_backups
    else
      fn_log error "rsync error - exiting"
      exit 1
    fi
  done

  # Add symlink to last successful backup
  fn_run rm -f -- "$DEST_FOLDER/latest"
  fn_run ln -s -- "$(basename "$DEST")" "$DEST_FOLDER/latest"

  # delete expired backups
  if [ "$OPT_KEEP_EXPIRED" != "true" ]; then
    fn_delete_backups
  fi

  # end backup
  fn_run rm -f -- "$INPROGRESS_FILE"
  fn_log info "backup $(basename "$DEST") completed"
}

fn_rsync() {

  local SRC="$1"
  local DST="$2"
  local PREV_DST="$3"
  local EXCLUDE_FILE="$4"

  local RS_ARG=()
  RS_ARG+=("--archive" "--hard-links" "--numeric-ids")
  RS_ARG+=("--delete" "--delete-excluded")
  RS_ARG+=("--one-file-system")
  RS_ARG+=("--itemize-changes" "--human-readable")
  RS_ARG+=("--log-file=$TMP_RSYNC_LOG")

  if [[ $OPT_VERBOSE == "true" ]]; then
    RS_ARG+=("--verbose")
  fi
  if [[ -n $SSH_ARG ]]; then
    RS_ARG+=("-e" "$SSH_RS_ARG $SSH_ARG")
  fi
  if [[ -n $EXCLUDE_FILE ]]; then
    RS_ARG+=("--exclude-from=$EXCLUDE_FILE")
  fi
  if [[ -n $PREV_DST ]]; then
    # If the path is relative, it needs to be relative to the destination. To keep
    # it simple, just use an absolute path. See http://serverfault.com/a/210058/118679
    PREV_DST="$(fn_run "cd '$PREV_DST'; pwd")"
    fn_log info "doing incremental backup from $(basename "$PREV_DST")"
    RS_ARG+=("--link-dest=$PREV_DST")
  fi

  RS_ARG+=("--" "${SRC%/}/")
  if [[ -n $DEST_HOST ]]; then
    RS_ARG+=("$DEST_HOST:$DST")
  else
    RS_ARG+=("$DST")
  fi

  fn_log info "rsync started for backup $(basename "$DST")"

  local G_ARG=("--line-buffered" "-v" "-E" "^[*]?deleting|^$|^.[Ld]\.\.t\.\.\.\.\.\.")

  # avoid separating array elements with newlines
  ( IFS=" " ; fn_log verbose "rsync ${RS_ARG[@]} | grep ${G_ARG[@]}" )

  if [[ $OPT_SYSLOG != "true" ]]; then
    rsync "${RS_ARG[@]}" | grep "${G_ARG[@]}"
  else
    rsync "${RS_ARG[@]}" | grep "${G_ARG[@]}" | tee /dev/stderr 2>&40
  fi

  local RSYNC_EXIT="${PIPESTATUS[0]}"
  fn_log info "rsync end"
  return "$RSYNC_EXIT"
}

fn_init() {
  fn_set_dest_folder "$1"
  BACKUP_MARKER_FILE="$DEST_FOLDER/backup.marker"
  if [[ $2 != "--local-time" ]]; then
    UTC="true"
  fi
  local DEFAULT_CONFIG=$(sed -E 's/^[[:space:]]+//' <<__EOF__
    UTC="$UTC"
    RETENTION_WIN_ALL=$RETENTION_WIN_ALL
    RETENTION_WIN_01H=$RETENTION_WIN_01H
    RETENTION_WIN_04H=$RETENTION_WIN_04H
    RETENTION_WIN_08H=$RETENTION_WIN_08H
    RETENTION_WIN_24H=$RETENTION_WIN_24H
__EOF__
  )
  fn_run "echo '$DEFAULT_CONFIG' >> '$BACKUP_MARKER_FILE'"
  # since we excute this file, access should be limited
  fn_run chmod -- 600 "$BACKUP_MARKER_FILE"
  fn_log info "created backup marker $BACKUP_MARKER_FILE"
}

fn_diff() {
  rsync --dry-run -auvi "${1%/}/" "${2%/}/" | grep -E -v '^sending|^$|^sent.*sec$|^total.*RUN\)'
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------

trap "exit 1" SIGINT # exit with error when CTRL+C is pressed
trap fn_cleanup EXIT # clean up on exit

export IFS=$'\n' # Better for handling spaces in filenames.

# parse command line arguments
while [ "$#" -gt 0 ]; do
  ARG="$1"
  shift
  case "$ARG" in
    -h|--help)
      fn_usage
      exit 0
      ;;
    -v|--verbose)
      OPT_VERBOSE="true"
      ;;
    -s|--syslog)
      OPT_SYSLOG="true"
      exec 40> >(exec logger -t "$APPNAME[$$]")
      ;;
    -k|--keep-expired)
      OPT_KEEP_EXPIRED="true"
      ;;
    --ssh-opt)
      if [ "$#" -lt 1 ]; then
        fn_log error "Wrong number of arguments for command '$ARG'."
        exit 1
      fi
      SSH_ARG="$1"
      shift
      ;;
    init)
      if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
        fn_log error "Wrong number of arguments for command '$ARG'."
        exit 1
      fi
      fn_init "$@"
      exit 0
      ;;
    diff)
      if [ "$#" -ne 2 ]; then
        fn_log error "Wrong number of arguments for command '$ARG'."
        exit 1
      fi
      fn_diff "$@"
      exit 0
      ;;
    backup)
      if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
        fn_log error "Wrong number of arguments for command '$ARG'."
        exit 1
      fi
      fn_backup "$@"
      exit 0
      ;;
    *)
      fn_log error "Invalid argument '$ARG'. Use --help for more information."
      exit 1
      ;;
  esac
done

fn_log info "Usage: $APPNAME [OPTIONS] command [ARGS]"
fn_log info "Try '$APPNAME --help' for more information."
exit 0
