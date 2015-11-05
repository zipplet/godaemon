{ --------------------------------------------------------------------------
  godaemon

  Actions unit

  Copyright (c) Michael Nixon 2015.
  Please see the LICENSE file for licensing information.
  -------------------------------------------------------------------------- }

{ --------------------------------------------------------------------------
  -------------------------------------------------------------------------- }

unit actions;

interface

uses baseunix, unix, unixutil, sysutils, classes, logger;

function DoActionStart: longint;
function DoActionStatus: longint;
function DoActionStop: longint;
function DoActionNagiosStatus: longint;
function DoActionInfo: longint;
function DoActionReload: longint;
function DoActionForceStop: longint;

{ --------------------------------------------------------------------------
  -------------------------------------------------------------------------- }
implementation

uses settings, mainapp, fork, commandline, nrpe, ipcpipe;

{ --------------------------------------------------------------------------
  Handle the "force stop" action - send SIGKILL to the task
  Returns 0 if the task is running, or 1 if it is not running
  -------------------------------------------------------------------------- }
function DoActionForceStop: longint;
const
  waittimeout = 3000;
var
  pid: longint;
  killError: longint;
begin
  if PIDFileExists then begin
    pid := PIDReadFromFile;
    if PIDIsAlive(pid) then begin
      if PIDIsGoDaemon(pid) then begin
        { Try to stop this process }
        FGLog(_settings.daemonName + ' is alive with pid = ' + inttostr(pid));
        fpkill(pid, SIGUSR1);
        killError := fpgeterrno;
        if (killError = ESysEINVAL) or (killError = ESysESRCH) or (killError = ESysEPERM) then begin
          writeln('Could not signal the daemon. Do you have enough permissions? (sudo)');
          result := 1;
          exit;
        end;
        writeln('Requested a forceful stop.');
        writeln('Waiting...');
        sleep(waittimeout);
        if PIDFileExists then begin
          pid := PIDReadFromFile;
          if PIDIsAlive(pid) then begin
            if PIDIsGoDaemon(pid) then begin
              writeln('FATAL: Task is still running! (Try using sudo)');
              result := 1;
              exit;
            end;
          end;
        end;
        writeln('Successfully stopped the task.');
        result := 0;
        exit;
      end;
    end;
  end;

  FGLog('Task was not running');
  FGLog(_settings.daemonName + ' status: Stopped');

  result := 1;
end;

{ --------------------------------------------------------------------------
  Handle the "reload" action - send SIGHUP to the task
  Returns 0 if the task is running, or 1 if it is not running
  -------------------------------------------------------------------------- }
function DoActionReload: longint;
var
  pid: longint;
  killError: longint;
begin
  if PIDFileExists then begin
    pid := PIDReadFromFile;
    if PIDIsAlive(pid) then begin
      if PIDIsGoDaemon(pid) then begin
        { Try to stop this process }
        FGLog(_settings.daemonName + ' is alive with pid = ' + inttostr(pid));
        fpkill(pid, SIGHUP);
        killError := fpgeterrno;
        if (killError = ESysEINVAL) or (killError = ESysESRCH) or (killError = ESysEPERM) then begin
          writeln('Could not signal the daemon. Do you have enough permissions? (sudo)');
          result := 1;
          exit;
        end;
        writeln('SIGHUP sent to daemon.');
        result := 0;
        exit;
      end;
    end;
  end;

  FGLog('Task was not running');
  FGLog(_settings.daemonName + ' status: Stopped');

  result := 1;
end;

{ --------------------------------------------------------------------------
  Handle the "info" action
  Returns the process exit code
  -------------------------------------------------------------------------- }
function DoActionInfo: longint;
const
  funcname = 'DoActionInfo(): ';
begin
  PrintInfo;
  result := 0;
end;

{ --------------------------------------------------------------------------
  Act as a nagios plugin and check on the status of the task.
  Prints the nagios status to stdout in the standard nagios format and
  returns a process exit code of:
    0: Status OK (task is running and no problems)
    1: Status WARNING (task is running, but some problems - failures)
    2: Status CRITICAL (task is not running)
    3: Status UNKNOWN (could not determine task status)
i -------------------------------------------------------------------------- }
function DoActionNagiosStatus: longint;
const
  funcname = 'DoActionNagiosStatus(): ';
  MAX_CHECK_ATTEMPTS = 3;
  CHECK_ATTEMPT_DELAY = 300; { Must be different to the usual tick rate }
  { MAX_CHECK_ATTEMPTS * CHECK_ATTEMPT_DELAY must be lower than icinga's
    maximum waiting time for a check }
var
  status: longint;
  statusMessage: ansistring;
  timestamp: longint;
  running: boolean;
  pid: longint;
  checkAttempt: longint;
begin
  running := false;

  if PIDFileExists then begin
    pid := PIDReadFromFile;
    if PIDIsAlive(pid) then begin
      if PIDIsGoDaemon(pid) then begin
        running := true;
      end;
    end;
  end;

  if running then begin
    { Task is running so proceed with other checks }
    if _settings.daemonNRPEStatusMonitoring then begin
      { Advanced monitoring }

      { There is a small chance that the status file is being updated at the
        exact time we read it. We will try several times to mitigate this.
        Due to the godaemon design, this will not fail on successive attempts
        unless there is another cause }
      checkAttempt := 0;
      while not GetNagiosStatus(status, statusMessage, timestamp) do begin
        inc(checkAttempt);
        if checkAttempt >= MAX_CHECK_ATTEMPTS then begin
          writeln('godaemon (advanced monitoring): Daemon is running, but could not get status');
          result := _nagios_status_unknown;
          exit;
        end;
        sleep(CHECK_ATTEMPT_DELAY);
      end;
      writeln(statusMessage);
      result := status;
    end else begin
      { Simple monitoring }
      writeln('godaemon (simple monitoring): Daemon is running');
      result := _nagios_status_ok;
    end;
  end else begin
    { Task is not running - critical status }
    writeln('godaemon: Daemon is not running');
    result := _nagios_status_critical;
  end;
end;

{ --------------------------------------------------------------------------
  Handle the "stop" action - get information about a task
  Returns 0 if the task is running, or 1 if it is not running
  -------------------------------------------------------------------------- }
function DoActionStop: longint;
const
  tasknotrunning = 'Task was not running';
var
  pid: longint;
  timeout: longint;
  killError: longint;
  stoptimeout: longint;
begin
  if PIDFileExists then begin
    pid := PIDReadFromFile;
    if PIDIsAlive(pid) then begin
      if PIDIsGoDaemon(pid) then begin
        { Try to stop this process }
        FGLog(_settings.daemonName + ' is alive with pid = ' + inttostr(pid));
        write('Waiting for the task to stop [');
        fpkill(pid, SIGTERM);
        killError := fpgeterrno;
        if (killError = ESysEINVAL) or (killError = ESysESRCH) or (killError = ESysEPERM) then begin
          writeln('.] - FAILED');
          writeln('Could not signal the daemon. Do you have enough permissions? (sudo)');
          result := 0;
          exit;
        end;
        timeout := 0;
        stoptimeout := _settings.daemonStopTimeout * 2;
        while PIDIsAlive(pid) do begin
          sleep(500);
          write('. ');
          inc(timeout);
          { We need to time out incase this is called by a script }
          if timeout > stoptimeout then begin
            if _settings.daemonForceStop then begin
              writeln('.] - TIMED OUT');
              result := DoActionForceStop;
              exit;
            end else begin
              writeln('.] - FAILED');
              FGLog('Timed out while stopping the task. Try the ''force-stop'' action.');
              result := 0;
              exit;
            end;
          end;
        end;
        writeln('.] - OK');
      end else begin
        FGLog(tasknotrunning);
      end;
    end else begin
      FGLog(tasknotrunning);
    end;
  end else begin
    FGLog(tasknotrunning);
  end;

  FGLog(_settings.daemonName + ' status: Stopped');

  result := 1;
end;

{ --------------------------------------------------------------------------
  Handle the "status" action - get information about a task
  Returns 0 if the task is running, or 1 if it is not running
  -------------------------------------------------------------------------- }
function DoActionStatus: longint;
const
  funcname = 'DoActionStatus(): ';
var
  pid: longint;
  status: longint;
begin
  { default = not running }
  status := 1;

  if PIDFileExists then begin
    pid := PIDReadFromFile;
    if PIDIsAlive(pid) then begin
      if PIDIsGoDaemon(pid) then begin
        status := 0;
      end;
    end;
  end;

  if status = 0 then begin
    FGLog(_settings.daemonName + ' status: Running');
  end else begin
    FGLog(_settings.daemonName + ' status: Stopped');
  end;

  result := status;
end;

{ --------------------------------------------------------------------------
  Handle the "start" action
  Returns the process exit code
  -------------------------------------------------------------------------- }
function DoActionStart: longint;
const
  funcname = 'DoActionStart(): ';
var
  endpoint: tipcPipeEndpoint;
begin
  { We use a pipe to communicate a successful start to the parent. }
  _pipes.taskStartupPipe := tipcPipe.Create;
  if not _pipes.taskStartupPipe.CreateEndpoints then begin
    FGLog(funcname + 'Cannot create taskStartupPipe');
    result := 1;
    exit;
  end;

  FGLog('Starting job: ' + _settings.daemonName);

  { If we need to change user id / group id, validate these now }
  if _settings.daemonChangeUser then begin
    if not GetUserAndGroupIDs then begin
      FGLog(funcname + 'Cannot determine user/group IDs - stopping');
      result := 1;
      exit;
    end;
  end else begin
    FGLog(funcname + 'Running the task as the current user which might be unsafe.');
  end;

  if not _settings.foregroundMode then begin
    { Daemonise }
    if not Daemonise(true, '[godaemon] ' + _settings.daemonName) then begin
      FGLog(funcname + 'Daemonise() failed - out of resources?');
      result := 1;
      exit;
    end;
    { We are a daemon! Only the daemon child carries on executing here. The
      parent branches off inside Daemonise to parentstart.pas }
  end else begin
    { Foreground mode }
    FGLog(funcname + 'Running in the foreground.');
  end;

  { Prepare to communicate with the parent }
  endpoint := _pipes.taskStartupPipe.GetChildEndpoint;

  { Initialise the logger }
  StartLogger;

  { Only allow one copy of the task }
  if _settings.daemonUsePIDFile then begin
    if not StartAllowOneProcess then begin
      _logger.Log(funcname + 'This task is already running (PID file exists with valid PID) - stopping');
      if not _settings.foregroundMode then begin
        endpoint.SendString('This task is already running');
      end;
      StopLogger;
      result := 1;
      exit;
    end;
  end;

  { Start handling unix signals }
  StartSignalHandler;
  
  { Hand off to the task process (mainapp.pas). More communication with the
    parent process occurs there }
  result := StartTaskProcess;
  _logger.Log(funcname + 'Shutting down with ExitCode ' + inttostr(ExitCode));

  { Cleanup }
  if _settings.daemonUsePIDFile then begin
    FinishAllowOneProcess;
  end;
  StopSignalHandler;
  StopLogger;
end;

end.
