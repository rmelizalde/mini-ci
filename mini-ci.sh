#!/bin/bash
#
# Mini-CI is a small daemon to perform continuous integration (CI) for
# a single repository/project.
#
# AUTHOR: Andrew Phillips <theasp@gmail.com>
# LICENSE: GPLv2

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo "ERROR: You need at least version 4 of BASH" 1>&2
  exit 1
fi

set -e

readonly SHNAME=$(basename $0)

declare -A CUR_STATUS=()
declare -A CUR_STATUS_TIME=()

declare -x CONFIG_FILE
declare -x CONTROL_FIFO
declare -x DEBUG
declare -x EMAIL_ADDRESS
declare -x EMAIL_NOTIFY
declare -x JOB_DIR
declare -x LOG_DIR
declare -x PID_FILE
declare -x POLL_FREQ
declare -x POLL_LOG
declare -x STATE
declare -x STATUS_FILE
declare -x TASKS_DIR
declare -x TASKS_LOG
declare -x UPDATE_LOG
declare -x WORK_DIR

help() {
  cat <<EOF
Usage: $SHNAME [option ...] [command ...]

Options:
  -d|--job-dir <dir>       directory for job
  -c|--config-file <file>  config file to use, relative to job-dir
  -m|--message [timeout]   send commands to running daemon, then exit
  -o|--oknodo              exit quietly if already running
  -D|--debug               log debugging information
  -F|--foreground          do not become a daemon, run in foreground
  -h|--help                show usage information and exit

Commands:
  status  log the current status
  poll    poll the source code repository for updates, queue update if
          updates are available
  update  update the source code repository, queue tasks if updates are made
  tasks   run the tasks in the tasks directory
  clean   remove the work directory
  abort   abort the currently running command
  quit|shutdown
          shutdown the daemon, aborting any running command
  reload  reread the config file, aborting any running command

Commands given while not in message mode will be queued.  For instance
the following command will have a repository polled for updates (which
will trigger update and tasks if required) then quit.
  $SHNAME -d <dir> -F poll quit
EOF
}


main() {
  local temp=$(getopt -o c:,d:,m::,o,D,F,h --long timeout:,config-file:,job-dir:,message::,oknodo,debug,foreground,help -n 'test.sh' -- "$@")
  eval set -- "$temp"

  local message=no
  local timeout=5
  local daemon=yes
  local oknodo=no
  DEBUG=no
  JOB_DIR="."
  CONFIG_FILE="./config"

  while true; do
    case "$1" in
      -c|--config-file)
        CONFIG_FILE=$2; shift 2 ;;
      -d|--job-dir)
        JOB_DIR=$2; shift 2 ;;
      -m|--message)
        message=yes
        if [[ "$2" ]]; then

          timeout=$2
        fi
        shift 2
        ;;
      -o|--oknodo)
        oknodo=yes; shift 1 ;;
      -D|--debug)
        DEBUG=yes; shift 1 ;;
      -F|--foreground)
        daemon=no; shift 1 ;;
      -h|--help)
        help
        exit 0
        ;;
      --)
        shift ; break  ;;
      *)
        echo "ERROR: Problem parsing arguments" 1>&2; exit 1 ;;
    esac
  done

  cd $JOB_DIR
  load_config

  if [[ $message = "yes" ]]; then
    unset MINICI_LOG
    if [[ ! -e $CONTROL_FIFO ]]; then
      error "Control fifo $CONTROL_FIFO is missing"
    fi

    for cmd in $@; do
      send_message $timeout $cmd
    done
    exit 0
  fi

  acquire_lock $oknodo

  for cmd in $@; do
    queue $cmd
  done

  if [[ $daemon = "yes" ]]; then
    # Based on:
    # http://blog.n01se.net/blog-n01se-net-p-145.html
    [[ -t 0 ]] && exec </dev/null || true
    [[ -t 1 ]] && exec >/dev/null || true
    [[ -t 2 ]] && exec 2>/dev/null || true

    # Double fork will detach the process
    (main_loop &) &
  else
    main_loop
  fi
}

main_loop() {
  log "Starting up"

  read_status_file

  rm -f $CONTROL_FIFO
  mkfifo $CONTROL_FIFO

  exec 3<> $CONTROL_FIFO

  trap reload_config SIGHUP
  trap quit SIGINT
  trap quit SIGTERM
  trap "queue update" SIGUSR1
  trap "queue build" SIGUSR2

  # Even though this was done before, make a new lock as your PID
  # may have changed if running as a daemon.
  acquire_lock

  RUN=yes
  STATE=idle
  NEXT_POLL=0

  while [[ "$RUN" = "yes" ]]; do
    # read_commands has a 1 second timeout
    read_commands
    process_queue
    handle_children
    if [[ $POLL_FREQ -gt 0 ]] && [[ $(printf '%(%s)T\n' -1) -ge $NEXT_POLL ]] && [[ $STATE = "idle" ]]; then
      debug "Poll frequency timeout"
      queue "poll"
      schedule_poll
    fi
  done

  quit
}

handle_children() {
  local tmpPids=()
  local tmpCBs=()
  for ((i=0; i < ${#CHILD_PIDS[@]}; ++i)); do
    local pid=${CHILD_PIDS[$i]}
    local cb=${CHILD_CBS[$i]}

    if ! kill -0 $pid 2>/dev/null; then
      set +e
      wait $pid
      local RC=$?
      set -e
      debug "Child $pid done $RC"
      if [[ "$cb" ]]; then
        $cb $RC
      fi
    else
      tmpPids=(${tmpPids[@]} $pid)
      tmpCBs=(${tmpCBs[@]} $cb)
    fi
  done

  CHILD_PIDS=(${tmpPids[@]})
  CHILD_CBS=(${tmpCBs[@]})
}

queue() {
  local cmd=$1
  case $cmd in
    status|poll|update|tasks|clean|abort|quit|shutdown|reload)
    ;;
    *)
      error "Unknown command: $cmd"
      exit 1
      ;;
  esac

  QUEUE=(${QUEUE[@]} $@)
  debug "Queued $@"
}

add_child() {
  debug "Added child $@"
  CHILD_PIDS=(${CHILD_PIDS[@]} $1)
  CHILD_CBS=(${CHILD_CBS[@]} $2)
}

clean() {
  log "Cleaning workspace"
  if [[ -e "$WORK_DIR" ]]; then
    log "Removing workspace $WORK_DIR"
    rm -rf $WORK_DIR
  fi
  a  queue "update"
}

schedule_poll() {
  if [[ $POLL_FREQ ]] && [[ $POLL_FREQ -gt 0 ]]; then
    NEXT_POLL=$(( $(printf '%(%s)T\n' -1) + $POLL_FREQ))
  fi
}

repo_run() {
  local operation=$1
  local callback=$2

  if [[ $REPO_URL ]]; then
    if [[ $REPO_HANDLER ]]; then
      case $REPO_HANDLER in
        git|svn) # These are built in
          cmd="_$REPO_HANDLER"
          ;;

        *)
          if [[ -x $REPO_HANDLER ]]; then
            cmd=$REPO_HANDLER
          else
            warning "Unable to $operation on $REPO_URL, $REPO_HANDLER is not executable"
            return 1
          fi
          ;;
      esac

      ($cmd $operation "$WORK_DIR" $REPO_URL > $POLL_LOG 2>&1) &
      add_child $! $callback
      return 0
    else
      warning "Unable to $operation on $REPO_URL, REPO_HANDLER not set"
      return 1
    fi
  else
    warning "No REPO_URL defined"
    return 1
  fi
}

repo_poll_start() {
  if [[ ! -e $WORK_DIR ]]; then
    repo_update_start
  else
    STATE="poll"
    log "Polling job"

    if ! repo_run poll "repo_poll_finish"; then
      STATE="idle"
      update_status "poll" "ERROR"
    fi
  fi
}

repo_poll_finish() {
  STATE="idle"
  local line=$(tail -n 1 $POLL_LOG)
  if [[ $1 -eq 0 ]]; then
    if [[ "$line" = "OK POLL NEEDED" ]]; then
      log "Poll finished sucessfully, queuing update"
      #STATUS_UPDATE=EXPIRED
      #STATUS_TASKS=EXPIRED
      queue "update"
    else
      log "Poll finished sucessfully, no update required"
    fi
    update_status "poll" "OK"
  else
    warning "Poll did not finish sucessfully"
    update_status "poll" "ERROR"
  fi
}

repo_update_start() {
  STATE="update"
  log "Updating workspace"

  test -e $WORK_DIR || mkdir $WORK_DIR

  if ! repo_run update "repo_update_finish"; then
    STATE="idle"
    update_status "update" "ERROR"
  fi
}

repo_update_finish() {
  STATE="idle"
  if [[ $1 -eq 0 ]]; then
    #STATUS_TASKS=EXPIRED
    log "Update finished sucessfully, queuing tasks"
    update_status "update" "OK"
    queue "tasks"
  else
    warning "Update did not finish sucessfully"
    update_status "update" "ERROR"
  fi
}

tasks_start() {
  STATE="tasks"
  log "Starting tasks"

  if [[ -e $TASKS_DIR ]]; then
    (run_tasks) > $TASKS_LOG 2>&1 &
    add_child $! "tasks_finish"
  else
    warning "The tasks directory $TASKS_DIR does not exist"
    STATE="idle"
    update_status "tasks" "ERROR"
  fi
}

tasks_finish() {
  STATE="idle"
  if [[ $1 -eq 0 ]]; then
    update_status "tasks" "OK"
    log "Tasks finished sucessfully"
  else
    warning "Tasks did not finish sucessfully"
    update_status "tasks" "ERROR"
  fi
}

abort() {
  unset QUEUE

  local tmpPids=()
  local sleeptime=1
  for SIGNAL in TERM TERM KILL; do
    for ((i=0; i < ${#CHILD_PIDS[@]}; ++i)); do
      local pid=${CHILD_PIDS[$i]}

      if kill -0 $pid 2>/dev/null; then
        killtree $pid $SIGNAL
        debug "Killed child $pid with SIG$SIGNAL"
        tmpPids=(${tmpPids[@]} $pid)
      fi
    done
    if [[ ${#tmpPids} -gt 0 ]]; then
      sleep $sleeptime;
      sleeptime=5
    fi
  done

  if [[ ${#_tmpPids} -gt 0 ]]; then
    error "Processes remaining after abort: ${#CHILD_PIDS}"
  fi

  CHILD_PIDS=()
  CHILD_CBS=()

  case $STATE in
    poll|update|tasks)
      CUR_STATUS[$STATE]="UNKNOWN" ;;
  esac

  STATE="idle"
}

write_status_file() {
  debug "Write status file $STATUS_FILE"

  local tmpfile=$STATUS_FILE.tmp

  cat > $TMPFILE <<EOF
# Generated $(printf '%(%c)T\n' -1)
local OLD_STATE=$STATE
EOF

  for state in ${!CUR_STATUS[@]}; do
    echo "CUR_STATUS[$state]=${CUR_STATUS[$state]}"
  done >> $tmpfile

  mv $tmpfile $STATUS_FILE
}

read_status_file() {
  debug "Reading status file in $STATUS_FILE"

  for state in poll update tasks; do
    CUR_STATUS[$state]=UNKNOWN
  done

  if [[ -f $STATUS_FILE ]]; then
    source $STATUS_FILE
  fi

  if [[ "$OLD_STATE" ]] && [[ "$OLD_STATE" != "idle" ]]; then
    debug "Setting status of $STATE to UNKNOWN, previous active state"
    CUR_STATUS[$STATE]=UNKNOWN
  fi
}

update_status() {
  local item=$1
  local new_status=$2
  local new_status_TIME=$(printf '%(%s)T\n' -1)

  debug "Setting status of $item to $NEW_STATUS"

  local old_status=${CUR_STATUS["$item"]}
  local old_status_time=${CUR_STATUS["$item"]}

  CUR_STATUS["$item"]=$new_status
  CUR_STATUS_TIME["$item"]=$new_status_time

  write_status_file

  notify_status $item $old_status $old_status_time $new_status $new_status_time
}

notify_status() {
  local item=$1
  local old=$1
  local old_time=$2
  local new=$3
  local new_time=$4

  local -A notify_status

  case $new in
    OK)
      notify_status["OK"]=1
      if [[ $old = "ERROR" ]] || [[ $old = "UNKNOWN" ]]; then
        notify_status["RECOVER"]=1
      fi
      ;;
    ERROR|UNKNOWN)
      notify_status["$new"]=1
      if [[ $old = "OK" ]]; then
        notify_status["NEWPROB"]=1
      fi
      ;;
  esac

  local active_states
  for i in ${!notify_status[@]}; do
    if [[ ${notify_status[$i]} -eq 1 ]]; then
      active_states="$i ";
    fi
  done

  do_email_notification $old $old_time $new $new_time $active_states
}

do_email_notification() {
  local old=$1
  local old_time=$2
  local new=$3
  local new_time=$4
  local active_states=$5
  local send_reason

  debug "Active States:$active_states"

  for notifyState in $EMAIL_NOTIFY; do
    if [[ "$notifyState" = "NEVER" ]]; then
      debug "Email notification set to never"
      return
    fi

    for i in $active_states; do
      if [[ "$i" = "$notifyState" ]]; then
        send_reason=$notifyState
        break
      fi
    done

    if [[ "$send_reason" ]]; then
      break
    fi
  done

  if [[ "$send_reason" ]]; then
    local tmpfile=$(mktemp /tmp/$SHNAME-email_notication-XXXXXX)
    local email_subject='Mini-CI Notification - $(basename $JOB_DIR)'
    email_subject=$(eval echo $email_subject)
    cat > $tmpfile <<EOF
Mini-CI Job Directory: $(pwd)
Reason: $send_reason
New State: $new
Old State: $old
EOF
    for address in $EMAIL_ADDRESS; do
      debug "Mailing notification to $address due to $send_reason (New:$new Old:$old)"
      (mail -s "$email_subject" $address < $tmpfile; rm -f $tmpfile) &
      add_child $! ""
    done
  fi
}

run_tasks() {
  log "Running tasks"

  if [[ ! -d $TASKS_DIR ]]; then
    error "Can't find tasks directory $TASKS_DIR"
  fi

  cd $WORK_DIR

  for task in $(ls -1 $TASKS_DIR | grep -E -e '^[a-zA-Z0-9_-]+$' | sort); do
    local file="$TASKS_DIR/$task"
    if [[ -x $file ]]; then
      local log_file="${LOG_DIR}/${task}.log"
      log "Running $task"
      if ! $file > $log_file 2>&1; then
        error "Bad return code $?"
      fi
    fi
  done

  cd -
}

status() {
  debug ${!CUR_STATUS[@]}
  log "PID:$$ State:$STATE Queue:[${QUEUE[@]}] Poll:${CUR_STATUS[poll]} Update:${CUR_STATUS[update]} Tasks:${CUR_STATUS[tasks]}" #
}

read_commands() {
  while read -t 1 cmd args <&3; do
    #read CMD ARGS
    if [[ "$cmd" ]]; then
      cmd=$(echo $cmd | tr '[:upper:]' '[:lower:]')

      case $cmd in
        poll|update|clean|tasks) queue "$cmd" ;;
        status) status ;;
        abort) abort ;;
        reload) reload_config ;;
        quit|shutdown)
          RUN=no
          break
          ;;
        *)
          warning "Unknown command $cmd" ;;
      esac
    fi
  done
}

process_queue() {
  while [[ ${QUEUE[0]} ]]; do
    if [[ "$STATE" != "idle" ]]; then
      break
    fi

    local cmd=${QUEUE[0]}
    QUEUE=(${QUEUE[@]:1})
    case $cmd in
      clean)
        clean ;;
      poll)
        repo_poll_start ;;
      update)
        repo_update_start ;;
      tasks)
        tasks_start ;;
      *)
        error "Unknown job in queue: $cmd" ;;
    esac
  done
}

reload_config() {
  log "Reloading configuration"
  load_config
  # Abort needs to be after reading the config file so that the
  # status directory is valid.
  abort

  acquire_lock
}

load_config() {
  CONTROL_FIFO="./control.fifo"
  PID_FILE="./mini-ci.pid"
  WORK_DIR="./workspace"
  TASKS_DIR="./tasks.d"
  STATUS_FILE="./status"
  LOG_DIR="./log"
  POLL_LOG="${LOG_DIR}/poll.log"
  UPDATE_LOG="${LOG_DIR}/update.log"
  TASKS_LOG="${LOG_DIR}/tasks.log"
  POLL_FREQ=0
  EMAIL_NOTIFY="NEWPROB, RECOVER"
  EMAIL_ADDRESS=""

  if [[ -f $CONFIG_FILE ]]; then
    source $CONFIG_FILE
  else
    error "Unable to find configuration file $CONFIG_FILE"
  fi

  # Set this after sourcing the config file to hide the error when
  # running in an empty dir.
  if [[ -z $MINICI_LOG ]]; then
    MINICI_LOG="${LOG_DIR}/mini-ci.log"
  fi

  if [[ ! -d $LOG_DIR ]]; then
    mkdir $LOG_DIR
  fi

  # Fix up variables
  EMAIL_NOTIFY=${EMAIL_NOTIFY//,/ /}
  EMAIL_NOTIFY=${EMAIL_NOTIFY^^[[:alpha:]]}
  EMAIL_ADDRESS=${EMAIL_ADDRESS//,/ /}

  if [[ -z $EMAIL_ADDRESS ]]; then
    EMAIL_ADDRESS=$(whoami)
  fi
}

acquire_lock() {
  local oknodo=$1
  local cur_pid=$BASHPID

  if [[ -e $PID_FILE ]]; then
    local test_pid=$(< $PID_FILE)
    if [[ $test_pid && $test_pid -ne $cur_pid ]]; then
      debug "Lock file present $PID_FILE, has $test_pid"
      if kill -0 $test_pid >/dev/null 2>&1; then
        if [[ $oknodo = "yes" ]]; then
          debug "Unable to acquire lock.  Is minici running as PID ${TEST_PID}?"
          exit 0
        else
          error "Unable to acquire lock.  Is minici running as PID ${TEST_PID}?"
        fi
      fi
    fi
  fi

  debug "Writing $cur_pid to $PID_FILE"
  echo $cur_pid > $PID_FILE
}

send_message() {
  local timeout=$1
  local cmd=$1

  case $cmd in
    status|poll|update|tasks|clean|abort|quit|shutdown|reload) ;;
    *) error "Unknown command $cmd" ;;
  esac

  local end_time=$(( $(printf '%(%s)T\n' -1) + $timeout ))
  (echo $@ > $CONTROL_FIFO) &
  local echo_pid=$!

  while [[ $(printf '%(%s)T\n' -1) -lt $end_time ]]; do
    if ! kill -0 $echo_pid >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  if kill -0 $echo_pid >/dev/null 2>&1; then
    kill -KILL $echo_pid
    error "Timeout writing $cmd to $CONTROL_FIFO"
  fi

  wait $echo_pid
  if [[ $? -ne 0 ]]; then
    error "Error writing to $CONTROL_FIFO"
  fi
}

quit() {
  log "Shutting down"
  abort
  rm -f $PID_FILE
  exit 0
}

_git() {
  local operation=$1
  local dir=$2
  local repo=$3

  if [ -z "$operation" ]; then
    error "Missing argument operation"
  fi

  if [ -z "$dir" ]; then
    error "Missing argument dir"
  fi

  if [ -z "$repo" ]; then
    error "Missing argument repo"
  fi

  cd $dir

  case $operation in
    update)
      if [ ! -d .git ]; then
        if ! git clone $repo .; then
          echo "ERR UPDATE CLONE"
          exit 1
        fi
      else
        if ! git pull --rebase; then
          echo "ERR UPDATE PULL"
          exit 1
        fi
      fi
      echo "OK UPDATE"
      exit 0
      ;;

    poll)
      if ! git remote update; then
        echo "ERR POLL UPDATE"
        exit 1
      fi

      local local=$(git rev-parse @)
      local remote=$(git rev-parse @{u})
      local base=$(git merge-base @ @{u})

      echo "Local: $local"
      echo "Remote: $remote"
      echo "Base: $base"

      if [ $local = $remote ]; then
        echo "OK POLL CURRENT"
        exit 0
      elif [ $local = $base ]; then
        echo "OK POLL NEEDED"
        exit 0
      elif [ $remote = $base ]; then
        echo "ERR POLL localCOMMITS"
        exit 1
      else
        echo "ERR POLL DIVERGED"
        exit 1
      fi
      ;;
    *)
      error "Unknown operation $operation"
      ;;
  esac

  cd -
}

_svn() {
  local operation=$1
  local dir=$2
  local repo=$3

  if [ -z "$operation" ]; then
    error "Missing argument operation"
  fi

  if [ -z "$dir" ]; then
    error "Missing argument dir"
  fi

  if [ -z "$repo" ]; then
    error "Missing argument repo"
  fi

  cd $dir

  case $operation in
    update)
      if [ ! -d .svn ]; then
        if ! svn checkout $repo .; then
          echo "ERR UPDATE CHECKOUT"
          exit 1
        fi
      else
        if ! svn update; then
          echo "ERR UPDATE UPDATE"
          exit 1
        fi
      fi
      echo "OK UPDATE"
      exit 0
      ;;

    poll)
      local local=$(svn info | grep '^Last Changed Rev' | cut -f 2 -d :)
      local remote=$(svn info -r HEAD| grep '^Last Changed Rev' | cut -f 2 -d :)

      echo "Local: $local"
      echo "Remote: $remote"

      if [[ $local -eq $remote ]]
      then
        echo "OK POLL CURRENT"
        exit 0
      else
        echo "OK POLL NEEDED"
        exit 0
      fi
      ;;
    *)
      error "Unknown operation $operation"
      ;;
  esac

  cd -
}

# http://stackoverflow.com/questions/392022/best-way-to-kill-all-child-processes
killtree() {
  local _pid=$1
  local _sig=${2:--TERM}
  kill -stop ${_pid} # needed to stop quickly forking parent from producing children between child killing and parent killing
  for _child in $(pgrep -P ${_pid}); do
    killtree ${_child} ${_sig}
  done
  kill -${_sig} ${_pid}
}

error() {
  log "ERROR: $@"
  exit 1
}

debug() {
  if [ "$DEBUG" = "yes" ]; then
    log "DEBUG: $@"
  fi
}

warning() {
  log "WARN: $@"
}

log() {
  msg="$(date '+%F %T') $SHNAME/$BASHPID $@"
  echo $msg 1>&2
  if [[ $MINICI_LOG ]]; then
    echo $msg >> $MINICI_LOG
  fi
}

main "$@"

# Local Variables:
# sh-basic-offset: 2
# sh-indentation: 2
# indent-tabs-mode: nil
# End:
