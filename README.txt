                           ━━━━━━━━━━━━━━━━━
                                MINI-CI


                            Andrew Phillips
                           ━━━━━━━━━━━━━━━━━


Table of Contents
─────────────────

1 Introduction
2 Features
3 Installation
.. 3.1 Ubuntu PPA
.. 3.2 From Source
4 Usage
5 Configuration
6 Contents of a Job Directory
.. 6.1 config
.. 6.2 tasks.d
7 Examples
.. 7.1 Mini-CI Job Directory
.. 7.2 Starting the Mini-CI Daemon as a User
.. 7.3 Notifying a Mini-CI Daemon from GIT
8 Plugin API
.. 8.1 Repository Plugins
.. 8.2 Notification Plugins
.. 8.3 Generic Hooks
.. 8.4 Example Plugin





1 Introduction
══════════════

  Mini-CI is a small daemon to perform continuous integration (CI) for a
  single repository/project.  Most other CI software is complicated to
  setup and use due to feature bloat and hiding what is going on
  underneath with GUIs.  If you know how to build your project from the
  command line, setting up Mini-CI should be easy.


2 Features
══════════

  • NO web interface!
    • Configuration is done with a small config file and shell scripts.
    • Daemon controlled through a command.
  • NO user authentication!
    • Unix already has multiple users, use groups or make a shared
      account.
  • NO support for multiple projects!
    • You can run it more than once…
  • Plugin system
  • Low resource requirements.
    • Just a small bash script.
  • Can monitor any repository and use any build system.
    • The only limits are the scripts you provide.


3 Installation
══════════════

3.1 Ubuntu PPA
──────────────

  • Stable release:
    [https://launchpad.net/~theasp/+archive/ubuntu/mini-ci]
  • Snapshot release:
    [https://launchpad.net/~theasp/+archive/ubuntu/mini-ci-snapshot]


3.2 From Source
───────────────

  To install into /usr/local:
  ┌────
  │ make clean install
  └────

  To install into your home directory (~/opt/mini-ci):
  ┌────
  │ make clean install prefix=~/opt/mini-ci
  └────


4 Usage
═══════

  From the output of mini-ci --help:
  ┌────
  │ Usage: mini-ci [option ...] [command ...]
  │ 
  │ Options:
  │   -d|--job-dir <dir>       directory for job
  │   -c|--config-file <file>  config file to use, relative to job-dir
  │   -m|--message [timeout]   send commands to running daemon, then exit
  │   -o|--oknodo              exit quietly if already running
  │   -D|--debug               log debugging information
  │   -F|--foreground          do not become a daemon, run in foreground
  │   -h|--help                show usage information and exit
  │ 
  │ Commands:
  │   status  log the current status
  │   poll    poll the source code repository for updates, queue update if
  │           updates are available
  │   update  update the source code repository, queue tasks if updates are made
  │   tasks   run the tasks in the tasks directory
  │   clean   remove the work directory
  │   abort   abort the currently running command
  │   quit|shutdown
  │           shutdown the daemon, aborting any running command
  │   reload  reread the config file, aborting any running command
  │ 
  │ Commands given while not in message mode will be queued.  For instance
  │ the following command will have a repository polled for updates (which
  │ will trigger update and tasks if required) then quit.
  │   mini-ci -d <dir> -F poll quit
  └────


5 Configuration
═══════════════

  You can configure a Mini-CI job by copying the skeleton directory
  somewhere and then editing where required.  This directory is referred
  to has the "job directory".  The skeleton contains the file config and
  the directory tasks.d, see their description later.  Once you have the
  configuration in place you can try it by running mini-ci -F in the
  directory you created, which will run Mini-CI in the foreground.


6 Contents of a Job Directory
═════════════════════════════

  • config: The configuration file for the job.
  • tasks.d: Contains all the tasks that would be executed during a
    build of your repository
  • plugins.d: Contains any additional plugins to be used for this job.
  • builds: The builds directory contains the output of each build of a
    job in numbered directories.
  • workspace: The directory your repository is checked out into, and
    built in.
  • mini-ci.log: The main log for Mini-CI.
  • poll.log: The log for the last poll operation.
  • tasks.log: The log for the last tasks operation.
  • update.log: The log for the last update operation.
  • control.fifo: This is a FIFO used to communicate with the Mini-CI
    daemon.


6.1 config
──────────

  The config file is a shell script that is sourced when Mini-CI is
  started which contains the configuration to use for your job.  Every
  option should have sane defaults, so feel free to only have the
  entries you wish to use.  If you want a variable exported during your
  job, for instance PATH, this would also be a good place to do so.

  The config file in skeleton is:
  ┌────
  │ # All paths are relative to the job directory.
  │ 
  │ ####################
  │ # Main Configuration
  │ 
  │ # JOB_NAME: The name of the job.  Defaults to "$(basename $JOB_DIR)"
  │ JOB_NAME="$(basename $JOB_DIR)"
  │ 
  │ # REPO_PLUGIN: This is the name of a plugin that will handle
  │ # repository actions.  The following plugins come with Mini-CI:
  │ # - git
  │ # - svn
  │ # - external
  │ REPO_PLUGIN="<plugin>"
  │ 
  │ # POLL_FREQ: If this is set to a number greater than zero, it will
  │ # poll the repository using the repo-handler every this many seconds,
  │ # starting at startup.  To have a more complicated scheme, use cron.
  │ # Defaults to 600.
  │ POLL_FREQ=600
  │ 
  │ # POLL_DELAY: If this is set to a number greater than zero, mini-ci
  │ # will sleep this many seconds after a poll that indicates a change
  │ # was made in the repository.  Use this to delay doing an update to
  │ # allow a series of commits to take place.  Defaults to 0.
  │ POLL_DELAY=0
  │ 
  │ # WORKSPACE: The directory where the repository will be checked out
  │ # into, and where tasks are launched.  Defaults to "./workspace".
  │ WORKSPACE="./workspace"
  │ 
  │ # TASKS_DIR: The directory which holds the tasks to be performed on
  │ # the checked out repository.  Defaults to "./tasks.d"
  │ TASKS_DIR="./tasks.d"
  │ 
  │ # BUILDS_DIR: The directory which stores the output of each build when
  │ # tasks run.  Defaults to "./builds".
  │ BUILDS_DIR="./builds"
  │ 
  │ # CONTROL_FIFO: The fifo that mini-ci will read to accept commands.
  │ # Defaults to "./control.fifo".
  │ CONTROL_FIFO="./control.fifo"
  │ 
  │ # PID_FILE: The file containing the process ID for mini-ci.  Defaults
  │ # to "./minici.pid".
  │ PID_FILE="./mini-ci.pid"
  │ 
  │ # STATUS_FILE: A file where status information is kept.  Defaults to
  │ # "./status".
  │ STATUS_FILE="./status"
  │ 
  │ # POLL_LOG: Name of the poll log.  Defaults to "./poll.log".
  │ POLL_LOG="./poll.log"
  │ 
  │ # UPDATE_LOG: Name of the update log.  Defaults to "./update.log".
  │ UPDATE_LOG="./update.log"
  │ 
  │ # TASKS_LOG: Name of the tasks log.  Defaults to "./tasks.log".
  │ TASKS_LOG="./tasks.log"
  │ 
  │ # MINICI_LOG: Name of the mini-ci log.  Defaults to "./mini-ci.log".
  │ MINICI_LOG="./mini-ci.log"
  │ 
  │ ####################
  │ # Plugin Configuration
  │ 
  │ # GIT_URL: The URL to the repository.  Fetching the URL must not ask
  │ # for a username or password.  Use ~/.netrc or ssh keys for remote
  │ # repositories.
  │ #GIT_URL="<url>"
  │ 
  │ # GIT_BRANCH: The branch of the repository.  Only affects the initial
  │ # checkout.  Defaults to "master".
  │ GIT_BRANCH="master"
  │ 
  │ # SVN_URL: The URL to the repository.  Fetching the URL must not ask
  │ # for a username or password.  Use ~/.netrc or ssh keys for remote
  │ # repositories.
  │ #SVN_URL="<url>"
  │ 
  │ # EMAIL_NOTIFY: A space and/or comma separated list of conditions to
  │ # notify about.  Valid options are "NEVER", "ERROR", "OK", "UNKNOWN",
  │ # "RECOVER" (when a state changes from "ERROR" or "UNKNOWN" to "OK")
  │ # and "NEWPROB" (when a state changes from "OK" to "ERROR" or
  │ # "UNKNOWN").  Defaults to "NEWPROB, RECOVER".
  │ EMAIL_NOTIFY="NEWPROB, RECOVER"
  │ 
  │ # EMAIL_ADDRESS: A space and/or comma separated list of addresses to
  │ # email.  If not specified, will be sent to the user that is running
  │ # the script.  Defaults to "".
  │ EMAIL_ADDRESS=""
  │ 
  │ # EMAIL_SUBJECT: The subject to have for notification emails.
  │ # Defaults to "Mini-CI Notification - $JOB_NAME".
  │ EMAIL_SUBJECT="Mini-CI Notification - $JOB_NAME"
  │ 
  │ # BUILD_ARCHIVE_WORKSPACE: When set to "yes" will copy the workspace into
  │ # the $BUILDS_DIR/$BUILD_NUM/workspace.  Defaults to "no".
  │ BUILD_ARCHIVE_WORKSPACE=""
  │ 
  │ # BUILD_KEEP: If this is set to a number greater than zero, only this
  │ # many build log directories will be kept.  Defaults to "0".
  │ BUILD_KEEP=0
  │ 
  │ # BUILD_DEPENDENCY_LIST: This is a list of status files, seperated by
  │ # spaces, for other Mini-CI jobs that will cause tasks to wait until
  │ # they are "idle" and the status of their tasks is "OK".  Defaults to
  │ # "".
  │ BUILD_DEPENDENCY_LIST=""
  │ 
  │ # BUILD_DEPENDENCY_TIMEOUT: The number of seconds to wait for
  │ # dependencies to be ready.  Defaults to "1200" (20 minutes).
  │ BUILD_DEPENDENCY_TIMEOUT=1200
  └────


6.2 tasks.d
───────────

  The tasks.d directory contains all the tasks that would be executed
  during a build of your repository.  The skeleton contains a few
  examples.  Each script must match the regular expression
  ^[a-zA-Z0-9_-]+$ and will be ran in sort order, therefore it is
  recommended that each script be named in the form
  <nnn>-<description_of_task>.  If a script exits with a return code
  that is not zero, it is considered a build error and no further
  scripts are executed.

  Mini-CI exports the following variables:
  • MINI_CI_DIR: The data directory for Mini-CI
  • MINI_CI_VER: The version of the Mini-CI running
  • BUILD_DISPLAY_NAME: The build number with "#" prepended.
    i.e. "#123"
  • BUILD_ID: The date and time the build started in the following
    format: %Y-%m-%d_%H-%M-%S
  • BUILD_OUTPUT_DIR: The directory used for storage for the current
    build
  • BUILD_NUMBER: The current build number.
  • BUILD_TAG: A string of the form: mini-ci-${JOB_NAME}-${JOB_NUMBER}
  • JOB_DIR: The directory where the job is stored
  • JOB_NAME: Name of the the job
  • WORKSPACE: The current workspace directory
  • GIT_URL: The URL of the GIT repository (when using the GIT plugin)
  • SVN_URL: The URL of the Subversion repository (when using the
    Subversion plugin)


7 Examples
══════════

7.1 Mini-CI Job Directory
─────────────────────────

  This example will configure to monitor Mini-CI's GIT repository and
  run tests whenever it's updated.

  Create and enter a directory called mini-ci-job, then place the
  following in config:
  ┌────
  │ REPO_PLGUIN="git"
  │ GIT_URL="https://github.com/theasp/mini-ci"
  │ POLL_FREQ=600
  └────

  This configuration will use the GIT repository handler with the URL to
  the Mini-CI repository, and then poll it every 10 minutes.

  Create the directory tasks.d, then place the following file in
  tasks.d/100-make
  ┌────
  │ #!/bin/sh
  │ 
  │ set -ex
  │ 
  │ # Override the prefix to install into ~/opt/mini-ci
  │ make prefix=~/opt/mini-ci
  └────

  Place the following file in tasks.d/500-run_tests:
  ┌────
  │ #!/bin/sh
  │ make test
  └────

  Run chmod +x tasks.d/500-run_tests to make the script executable.  Now
  when you run mini-ci -F in the job directory you will get:

  ┌────
  │ 2014-12-18 17:20:03 mini-ci/7145 Starting up
  │ 2014-12-18 17:20:05 mini-ci/7369 Missing workdir, doing update instead
  │ 2014-12-18 17:20:05 mini-ci/7145 Updating workspace
  │ 2014-12-18 17:20:06 mini-ci/7145 Update finished sucessfully, queuing tasks
  │ 2014-12-18 17:20:06 mini-ci/7145 Mailing update notification to user due to RECOVER (New:OK Old:UNKNOWN)
  │ 2014-12-18 17:20:06 mini-ci/7145 Mailing poll notification to user due to RECOVER (New:OK Old:UNKNOWN)
  │ 2014-12-18 17:20:07 mini-ci/7145 Starting tasks as run number 1
  │ 2014-12-18 17:20:07 mini-ci/7145 Tasks finished sucessfully, run number 1
  │ 2014-12-18 17:20:07 mini-ci/7145 Mailing tasks notification to user due to RECOVER (New:OK Old:UNKNOWN)
  └────

  Mini-CI started in foreground mode, downloaded the repository, then
  ran all the tasks in the tasks.d directory.  Notice that it also sent
  3 mail notifications due to update, poll and tasks transitioning from
  UNKNOWN to RECOVER.  The default email settings will only send mail
  when they change state.  The process is still running and will check
  the repository for changes every 10 minutes.

  You can stop the daemon by pressing ctrl-c, or by running mini-ci -m
  quit in the job directory in another shell.


7.2 Starting the Mini-CI Daemon as a User
─────────────────────────────────────────

  The easiest way to run Mini-CI as a user is to have cron start it.
  For instance, the following crontab will start Mini-CI every 10
  minutes, and if it is already running for that job directory it will
  exit quietly, otherwise it will poll the repository for any updates it
  missed when it starts:
  ┌────
  │ */10 * * * * mini-ci --oknodo -d ~/some-mini-ci-job-directory poll
  └────

  Mini-CI will run in the background doing it's thing whenever it needs
  to.


7.3 Notifying a Mini-CI Daemon from GIT
───────────────────────────────────────

  You can have git notify Mini-CI upon every push to a repository, which
  makes polling the repository unnecessary.  Put this in
  hooks/post-update in your git repository directory (or
  .git/hooks/post-update if you aren't using a bare repository), and it
  will send a message to Mini-CI to do an update, which will trigger a
  build.
  ┌────
  │ #!/bin/sh
  │ 
  │ set -e
  │ mini-ci -d ~/some-mini-ci-job-directory -m update
  └────

  You can easily change the above script to SSH to another system, or
  user.


8 Plugin API
════════════

  Mini-CI can be extended with plugins written as bash functions.  Any
  plugin matching *.sh in the plugins.d directory in either the Mini-CI
  installation path or the current job directory will be sourced when
  Mini-CI starts up.  Plugins must declare their variables using declare
  (or declare -x if the variable is to be exported).  Variables that are
  to be set using the config file should be set the default value using
  a function of the name plugin_on_load_config_pre_<name>.  In most
  cases the plugin's functions will run in the same shell as the rest of
  Mini-CI so that the plugin can modify variables, but this also
  introduces the chance that a plugin will introduce unwanted
  side-effects.


8.1 Repository Plugins
──────────────────────

  Repository plugins are ran in a subshell with STDOUT redirected to the
  appropriate logfile.  A repository plugin must provide the following
  functions:
  • plugin_repo_update_<name>
    • Must exit with a return code of 0 if successful.
  • plugin_repo_poll_<name>
    • Must exit with a return code of 0 if successful.
    • Must exit with a return code of 1 if there is an error.
    • Must exit with a return code of 2 if the repository is out of
      date.


8.2 Notification Plugins
────────────────────────

  A notification plugin must provide a function named
  plugin_notify_<name>, which accepts the following arguments:
  • item: The name of the state that triggered the notification,
    i.e. poll, update, tasks, etc.
  • old: The old status of that state, i.e. UNKNOWN, ERROR, or OK
  • old_time: The time in epoch seconds the old status was set
  • new: The new status of the state
  • new_time: The time in epoch seconds the new status was set
  • active_states: A string containing one of OK, ERROR, UNKNOWN,
    additionally it may contain NEWPROB or RECOVER.


8.3 Generic Hooks
─────────────────

  Your plugin can provide functions using the following names:
  • on_abort_post_<plugin_name>
  • on_abort_pre_<plugin_name>
  • on_acquire_lock_post_<plugin_name>
  • on_acquire_lock_pre_<plugin_name>
  • on_clean_post_<plugin_name>
  • on_clean_pre_<plugin_name>
  • on_load_config_post_<plugin_name>
  • on_load_config_pre_<plugin_name>
  • on_notify_status_post_<plugin_name>
  • on_notify_status_pre_<plugin_name>
  • on_poll_finish_post_<plugin_name>
  • on_poll_finish_pre_<plugin_name>
  • on_poll_start_post_<plugin_name>
  • on_poll_start_pre_<plugin_name>
  • on_process_queue_post_<plugin_name>
  • on_process_queue_pre_<plugin_name>
  • on_queue_post_<plugin_name>
  • on_queue_pre_<plugin_name>
  • on_quit_post_<plugin_name>
  • on_quit_pre_<plugin_name>
  • on_read_commands_post_<plugin_name>
  • on_read_commands_pre_<plugin_name>
  • on_read_status_post_<plugin_name>
  • on_read_status_pre_<plugin_name>
  • on_reload_config_post_<plugin_name>
  • on_reload_config_pre_<plugin_name>
  • on_run_cmd_pre_<plugin_name>
  • on_run_cmd_pre_<plugin_name>
  • on_run_tasks_post_<plugin_name>
  • on_run_tasks_pre_<plugin_name>
  • on_schedule_poll_post_<plugin_name>
  • on_schedule_poll_pre_<plugin_name>
  • on_send_message_post_<plugin_name>
  • on_send_message_pre_<plugin_name>
  • on_status_post_<plugin_name>
  • on_status_pre_<plugin_name>
  • on_tasks_finish_post_<plugin_name>
  • on_tasks_finish_pre_<plugin_name>
  • on_tasks_start_post_<plugin_name>
  • on_tasks_start_pre_<plugin_name>
  • on_update_finish_post_<plugin_name>
  • on_update_finish_pre_<plugin_name>
  • on_update_start_post_<plugin_name>
  • on_update_start_pre_<plugin_name>
  • on_update_status_post_<plugin_name>
  • on_update_status_pre_<plugin_name>
  • on_write_status_post_<plugin_name>
  • on_write_status_pre_<plugin_name>


8.4 Example Plugin
──────────────────

  The build-keep.sh plugin uses a variable BUILD_KEEP which is settable
  from the config file and used the tasks_finish_post hook:
  ┌────
  │ declare BUILD_KEEP
  │ 
  │ plugin_on_load_config_pre_build_keep() {
  │   BUILD_KEEP="0"
  │ }
  │ 
  │ plugin_on_tasks_finish_post_build_keep() {
  │   if [[ "$BUILD_KEEP" -gt 0 ]]; then
  │     while read num; do
  │       [[ -d "$BUILDS_DIR/$num" ]] && rm -r "$BUILDS_DIR/$num"
  │     done < <(seq 1 $(( $BUILD_NUMBER - $BUILD_KEEP)))
  │   fi
  │ }
  └────
