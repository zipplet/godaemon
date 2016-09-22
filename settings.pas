{ --------------------------------------------------------------------------
  godaemon

  Settings unit

  Copyright (c) Michael Nixon 2015.
  Please see the LICENSE file for licensing information.
  -------------------------------------------------------------------------- }

{ --------------------------------------------------------------------------
  -------------------------------------------------------------------------- }

unit settings;

interface

uses sysutils, classes, logger, pipes, ipcpipe;

{ --------------------------------------------------------------------------
  Globals
  -------------------------------------------------------------------------- }
const
  { Program information }
  _programname = 'godaemon';
  _version = 'v1.6-20160922.' +
    {$ifdef fpc}
      'fpc.' +
    {$else}
      'unknown_compiler.' +
    {$endif}
    {$ifdef CPUAMD64}
      'amd64.' +
    {$else}
      {$ifdef CPU386}
        'x86.' +
      {$else}
        'unknown_arch.' +
      {$endif}
    {$endif}
    {$ifdef LINUX}
      'linux';
    {$else}
      'unknown_os';
    {$endif}


  { Default: Time in seconds between resetting the throttle }
  _safety_throttle_timespan = 900;
  { Default: Number of failures before stopping }
  _safety_throttle_count = 5;
  { Default: Number of milliseconds to wait as a minimum between restarts }
  _safety_throttle_delay_ms = 3000;

  { Task actions }
  _action_list_count = 7;
  _action_list: array[0.._action_list_count - 1] of ansistring = (
    'start', 'stop', 'status', 'nagios-status', 'info', 'reload', 'force-stop'
  );

  { Blacklisted environment variable keys. Don't allow the user to set these }
  _forbidden_env_list_count = 1;
  _forbidden_env_list: array[0.._forbidden_env_list_count - 1] of ansistring = (
    'GODAEMON'
  );

  { Default system paths for PID and log files, suitable for linux }
  _system_pid_path = '/var/run';
  _system_log_path = '/var/log';

  { Nagios plugin status codes }
  _nagios_status_ok = 0;
  _nagios_status_warning = 1;
  _nagios_status_critical = 2;
  _nagios_status_unknown = 3;

type
  { Task action codes }
  eAction = (eaStart, eaStop, eaStatus, eaNagiosStatus, eaInfo, eaReload, eaForceStop);

  rPipes = record
    { A pair of pipes used to communicate between the godaemon "daemon"
      process and the child task (sandbox) godaemon process to transfer log
      output from the task to the parent }
    sandboxReadPipe: TInputPipeStream;
    sandboxWritePipe: TOutputPipeStream;

    { A pipe used to communicate between the godaemon shell process and the
      daemon child when starting a new task }
    taskStartupPipe: tipcPipe;

    { A pipe used to send control information between the daemon process
      and the sandbox }
    controlPipe: tipcPipe;
  end;

  rGlobalSettings = record
    { The number of lines to tail from the log file when sending an email }
    logTailCount: longint;

    { Time in seconds between resetting the throttle }
    throttleTimespan: longint;
    { Number of failures before stopping }
    throttleCount: longint;
    { Number of milliseconds to wait as a minimum between restarts }
    throttleDelay: longint;
    { Use exponential retry backoff ? }
    throttleExponential: boolean;
    { Maximum seconds to limit exponential backoff delay to }
    throttleExponentialLimit: longint;

    { true of we are running in the foreground }
    foregroundMode: boolean;
    { The log file we are writing to }
    logFile: ansistring;
    { The email address we will send notices to if enabled }
    emailAddress: ansistring;

    { The program name we are daemonising }
    daemonName: ansistring;
    { The full path and filename of the daemon }
    daemonFilename: ansistring;
    { The full path to the daemon }
    daemonPath: ansistring;
    { The full path and filename to the PID fike }
    daemonPIDFile: ansistring;
    { Use system paths instead of the local directory for state files }
    useSystemPaths: boolean;

    { Full path to status filename for enhanced monitoring (nagios) }
    daemonStatusFilename: ansistring;

    { Write the daemon output to the log file? }
    daemonCaptureOutput: boolean;
    { Restart the program if it fails? }
    daemonRestartOnFailure: boolean;
    { Use safe restart throttling? }
    daemonSafetyThrottle: boolean;
    { Use a PID file to limit concurrent instances? }
    daemonUsePIDFile: boolean;
    { Send an email if the program fails? }
    daemonEmailOnFailure: boolean;

    { Timeout when stopping the task (in seconds) }
    daemonStopTimeout: longint;
    { Forcefully stop the task if the timeout is exceeded? }
    daemonForceStop: boolean;

    { Change to a different user id / group id? }
    daemonChangeUser: boolean;
    { User ID to change to }
    daemonUserID: longint;
    { Raw field of User ID to change to from task file }
    daemonUserIDField: ansistring;
    { Group ID to change to }
    daemonGroupID: longint;
    { Raw field of Group ID to change to from task file }
    daemonGroupIDField: ansistring;
    { Username to change to (used for display purposes) }
    daemonUserName: ansistring;
    { Group name to change to (used for display purposes) }
    daemonGroupName: ansistring;

    { True if we send a WARNING for a recently failed task }
    daemonNRPEAlertRecentlyFailed: boolean;
    { True if we want to use advanced nagios monitoring }
    daemonNRPEStatusMonitoring: boolean;
    { Eyecatch string to look for when using advanced nagios monitoring }
    daemonNRPEEyecatch: ansistring;
    { Default status string to use when using advanced nagios monitoring }
    daemonNRPEDefaultStatus: ansistring;
    { ID code of default nagios status }
    daemonNRPEDefaultStatusID: longint;
    { String for default nagios status }
    daemonNRPEDefaultStatusString: ansistring;
    { Timestamp of custom NRPE status update }
    daemonNRPEStatusTS: longint;

    { Index of first arg to pass to the daemonised program }
    firstParamArgIndex: longint;

    { Parameters for daemonised program }
    params: tstringlist;

    { Additional environment variables to pass to the task. Key=value pairs }
    environment: tstringlist;

    { Currently a daemon? }
    daemonised: boolean;

    { Task recently failed? }
    recentlyFailed: boolean;

    { Action to perform }
    action: eAction;
  end;

var
  _pipes: rPipes;
  _settings: rGlobalSettings;
  _logger: tLogger;
  _signalstop: boolean;

procedure InitialiseGlobalSettings;

{ --------------------------------------------------------------------------
  -------------------------------------------------------------------------- }
implementation

{ --------------------------------------------------------------------------
  Set global settings to sane defaults
  Most of these are task file defaults as well (if they are missing from
  the task file).
  -------------------------------------------------------------------------- }
procedure InitialiseGlobalSettings;
begin
  _settings.foregroundMode := false;
  _settings.logFile := '';
  _settings.emailAddress := '';
  _settings.daemonName := '';
  _settings.daemonFilename := '';
  _settings.daemonPath := '';
  _settings.daemonPIDFile := '';
  _settings.daemonCaptureOutput := false;
  _settings.daemonRestartOnFailure := false;
  _settings.daemonSafetyThrottle := true;
  _settings.daemonUsePIDFile := true;
  _settings.daemonEmailOnFailure := false;
  _settings.daemonised := false;
  _settings.useSystemPaths := false;
  _settings.logTailCount := 50;
  
  _settings.throttleTimespan := _safety_throttle_timespan;
  _settings.throttleCount := _safety_throttle_count;
  _settings.throttleDelay := _safety_throttle_delay_ms;
  _settings.throttleExponential := false;
  _settings.throttleExponentialLimit := 30;

  _settings.daemonStopTimeout := 10;
  _settings.daemonForceStop := false;

  _settings.daemonChangeUser := false;
  _settings.daemonUserID := -1;
  _settings.daemonGroupID := -1;
  _settings.daemonUserIDField := '';
  _settings.daemonGroupIDField := '';
  _settings.daemonUserName := '';
  _settings.daemonGroupName := '';

  _settings.params := tstringlist.Create;
  _settings.environment := tstringlist.Create;

  _settings.daemonNRPEAlertRecentlyFailed := true;
  _settings.daemonNRPEStatusMonitoring := false;
  _settings.daemonNRPEEyecatch := '';
  _settings.daemonNRPEDefaultStatus := 'UNKNOWN:No report yet';
  _settings.daemonNRPEStatusTS := 0;
end;

initialization
begin
  { Safety }
  _logger := nil;
  _pipes.sandboxReadPipe := nil;
  _pipes.sandboxWritePipe := nil;
  _pipes.taskStartupPipe := nil;
  _pipes.controlPipe := nil;
end;

end.
