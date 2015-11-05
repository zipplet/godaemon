{ --------------------------------------------------------------------------
  godaemon

  Main application unit

  Copyright (c) Michael Nixon 2015.
  Please see the LICENSE file for licensing information.
  -------------------------------------------------------------------------- }

{ --------------------------------------------------------------------------
  -------------------------------------------------------------------------- }

unit mainapp;

interface

uses baseunix, unix, unixutil, sockets, sysutils, classes, logger, lsignal;

{ Non-class functions and procedures }
function InitialiseSystem: boolean;
function StartTaskProcess: longint;
procedure StartLogger;
procedure StopLogger;
procedure StartSignalHandler;
procedure StopSignalHandler;
procedure HandleSignalStop(sig: cint); cdecl;
procedure HandleSignalHup(sig: cint); cdecl;
procedure HandleSignalUsr1(sig: cint); cdecl;
function SleepAndWatchSignals(delayTime: longint): boolean;

{ --------------------------------------------------------------------------
  -------------------------------------------------------------------------- }
implementation

uses btime, settings, strutils, process, email, ipcpipe, sandbox, nrpe,
     tasksandbox;

{ --------------------------------------------------------------------------
  Sleep for <delayTime> while also checking if we have received a signal
  to stop the program.
  Returns TRUE if we stopped early due to a signal.
  Returns FALSE if we slept for the entire <delayTime>.
  -------------------------------------------------------------------------- }
function SleepAndWatchSignals(delayTime: longint): boolean;
const
  timeNibble = 1000; { Sleep interval }
var
  timeLeft: longint;
begin
  result := true;

  timeLeft := delayTime;
  while timeLeft > 0 do begin
    if timeLeft > timeNibble then begin
      sleep(timeNibble);
      timeLeft -= timeNibble;
    end else begin
      sleep(timeLeft);
      timeLeft := 0;
    end;
    { Check the signal flag and stop if a signal was caught }
    if _signalstop then exit;
  end;

  result := false;
end;

{ --------------------------------------------------------------------------
  Signal handler for stop signals.
  -------------------------------------------------------------------------- }
procedure HandleSignalStop(sig: cint);
const
  SIGNAL_TERM = 'TERM';
var
  endpoint: tipcPipeEndpoint;
begin
  if assigned(_pipes.controlPipe) then begin
    endpoint := _pipes.controlPipe.GetParentEndpoint;
    endpoint.SendString(SIGNAL_TERM);
  end;
  _signalstop := true;
end;

{ --------------------------------------------------------------------------
  Signal handler for usr1 (force stop).
  -------------------------------------------------------------------------- }
procedure HandleSignalUsr1(sig: cint);
const
  SIGNAL_FORCE = 'FORCE';
var
  endpoint: tipcPipeEndpoint;
begin
  if assigned(_pipes.controlPipe) then begin
    endpoint := _pipes.controlPipe.GetParentEndpoint;
    endpoint.SendString(SIGNAL_FORCE);
  end;
end;

{ --------------------------------------------------------------------------
  Signal handler for hup signals.
  -------------------------------------------------------------------------- }
procedure HandleSignalHup(sig: cint);
const
  SIGNAL_HUP = 'HUP';
var
  endpoint: tipcPipeEndpoint;
begin
  if assigned(_pipes.controlPipe) then begin
    endpoint := _pipes.controlPipe.GetParentEndpoint;
    endpoint.SendString(SIGNAL_HUP);
  end;
end;

{ --------------------------------------------------------------------------
  Install and start a signal handler.
  -------------------------------------------------------------------------- }
procedure StartSignalHandler;
var
  actions: psigactionrec;
begin
  _signalstop := false;
  new(actions);
  actions^.sa_handler := SigActionHandler(@HandleSignalStop);
  fillchar(actions^.sa_mask, sizeof(actions^.sa_mask), #0);
  { We don't want SIGCLD as we don't want to reap our children }
  actions^.sa_flags := SA_NOCLDSTOP;
  actions^.sa_restorer := nil;
  { Capture SIGTERM }
  fpSigAction(sigterm, actions, nil);
  dispose(actions);

  new(actions);
  actions^.sa_handler := SigActionHandler(@HandleSignalHup);
  fillchar(actions^.sa_mask, sizeof(actions^.sa_mask), #0);
  { We don't want SIGCLD as we don't want to reap our children }
  actions^.sa_flags := SA_NOCLDSTOP;
  actions^.sa_restorer := nil;
  { Capture SIGHUP }
  fpSigAction(sighup, actions, nil);
  dispose(actions);

  new(actions);
  actions^.sa_handler := SigActionHandler(@HandleSignalUsr1);
  fillchar(actions^.sa_mask, sizeof(actions^.sa_mask), #0);
  { We don't want SIGCLD as we don't want to reap our children }
  actions^.sa_flags := SA_NOCLDSTOP;
  actions^.sa_restorer := nil;
  { Capture SIGHUP }
  fpSigAction(sigusr1, actions, nil);
  dispose(actions);
end;

{ --------------------------------------------------------------------------
  Stop the signal handler.
  -------------------------------------------------------------------------- }
procedure StopSignalHandler;
begin
end;

{ --------------------------------------------------------------------------
  Shut down logging.
  -------------------------------------------------------------------------- }
procedure StopLogger;
begin
  if not assigned(_logger) then begin
    FGLog('StopLogger(): Bug: <logger> is nil');
    exit;
  end;
  _logger.Free;
  _logger := nil;
end;

{ --------------------------------------------------------------------------
  Create a sandbox for the child task, and start it.
  The code forks here:
    - The parent fork will return
    - The child fork will NOT return (--> tasksandbox.pas: RunTaskSandbox)
  Returns:
    - a non negative number (child PID) if we could create the sandbox, and
      the task is running inside it
    - 0 if we could not create the sandbox
  -------------------------------------------------------------------------- }
function MakeTaskSandbox: longint;
const
  OUTPUT_BUFFER_SIZE = 1024;
  CHECK_INTERVAL_MS = 250;
  funcname = 'MakeTaskSandbox(): ';
var
  childPID: longint;
  sandboxControl: tipcPipeEndpoint;
begin
  childPID := StartSandbox;
  if childPID = -1 then begin
    { We are the sandbox fork }
    sandboxControl := _pipes.controlPipe.GetChildEndpoint;
    try
      RunTaskSandbox;
    except
      on e: exception do begin
        sandboxControl.SendString('FATAL: Uncaught exception - terminated sandbox: ' + e.message);
        halt;
      end;
    end;
    { Should never get here, but lets be paranoid }
    halt;
  end else begin
    { We are the sandbox parent or failure has occured }
    result := childPID;
  end;
end;

{ --------------------------------------------------------------------------
  Start the task / monitor the task.
  Returns the exitcode value that we should return to the shell.
  -------------------------------------------------------------------------- }
function StartTaskProcess: longint;
const
  { Size of buffer when reading data from sandbox }
  OUTPUT_BUFFER_SIZE = 1024;
  { Number of seconds to allow task to run for before we signal the parent
    to tell them that we are OK }
  SECONDS_BEFORE_SIGNAL = 3;
  { Size of buffer for log flushing }
  LOG_BUFFER_SIZE = 8192;
  { Flush the log buffer to disk at least every this many seconds }
  FLUSH_INTERVAL = 5;
  { Milliseconds between checking if the task has log data to read }
  CHECK_INTERVAL_MS = 250;
  LOG_BUFFER_MAX = LOG_BUFFER_SIZE - OUTPUT_BUFFER_SIZE;
  funcname = 'StartTaskProcess(): ';
  { Control signals to send to the sandbox control pipe }
  SIGNAL_TERM = 'TERM';
  SIGNAL_HUP = 'HUP';
var
  { log buffer and tracking for log buffer } 
  logbuffer: array[0..LOG_BUFFER_SIZE - 1] of byte;
  bytesAvailable, bytesRead, logStashed: longint;

  { buffer to read data from sandbox }
  outputbuffer: array[0..OUTPUT_BUFFER_SIZE - 1] of char;

  lastFlush: longint;           { ts of last log file flush }
  timeNow: longint;             { current ts }
  restartJob: boolean;
  firstFailureTime: longint;    { ts of first failure }
  failureCount: longint;
  currentDelay: longint;
  delayMilliseconds: longint;
  shouldSignalParent: boolean;  { true if we need to signal our parent process }
  taskStartedTS: longint;       { timestamp the task started }
  sandboxPID: longint;          { sandbox process PID }
  sandboxRunning: boolean;      { true if sandbox is running }
  sandboxExitCode: longint;     { PID exit code from sandbox process }
  sandboxState: longint;        { sandbox process status - running, dead, etc }
  nagiosParser: tNRPEMessageScraper;  { NRPE log parser }

  { String received from the sandbox control pipe }
  sandboxControlRX: ansistring;
  { Pipe endpoint to communicate with the parent when starting a task }
  endpoint: tipcPipeEndpoint;
  { Pipe endpoint to send control messages to the sandbox }
  sandboxControl: tipcPipeEndpoint;
begin
  { By default, assume failure }
  result := 1;

  restartJob := _settings.daemonRestartOnFailure;
  firstFailureTime := 0;
  failureCount := 0;
  currentDelay := 1;
  _settings.recentlyFailed := false;

  { If the parent process is waiting for us to signal them that the task is
    OK, set a flag so we will signal them soon }
  shouldSignalParent := not _settings.foregroundMode;
  endpoint := _pipes.taskStartupPipe.GetChildEndpoint;

  { Prepare a control pipe for us to use with the sandbox }
  _pipes.controlPipe := tipcPipe.Create;
  if not _pipes.controlPipe.CreateEndpoints then begin
    _logger.Log(funcname + 'Failed to create a sandbox control pipe, stopping!');
    result := 0;
    if shouldSignalParent then begin
      endpoint.SendString('Failed to create a sandbox control pipe');
      shouldSignalParent := false;
    end;
    exit;
  end else begin
    sandboxControl := _pipes.controlPipe.GetParentEndpoint;
  end;

  { Prepare NRPE log scraper if advanced monitoring is on }
  if _settings.daemonNRPEStatusMonitoring then begin
    nagiosParser := tNRPEMessageScraper.Create(_settings.daemonNRPEEyecatch);
    { Important: We never destroy this instance, we don't need to worry about
      it as we don't call this function more than once. If this changes later,
      then this needs to be taken into consideration }
  end else begin
    nagiosParser := nil;
  end;

  repeat
    { Create a sandbox process to manage the child task. The task runs inside 
      this sandbox process and log output is fed back to us via a pipe }
    sandboxPID := MakeTaskSandbox;
    if sandboxPID = 0 then begin
      { Check if the sandbox told us why it couldn't start. It does this by
        posting a string to the sandboxControl pipe. }
      _logger.Log(funcname + 'Failed to create a sandbox, internal error (out of memory?)');
      { If we can't make the sandbox, we can't do anything so abort }
      result := 0;
      if shouldSignalParent then begin
        { Tell them why we stopped }
        endpoint.SendString('Failed to create a sandbox, internal error'); 
        shouldSignalParent := false;
      end;
      exit;
    end;

    taskStartedTS := unixtimeint;
    _logger.Log(funcname + 'Task started in sandbox - ' + _settings.daemonName);
    if _settings.daemonCaptureOutput then begin
      _logger.Log('-------- Task output ----------');
    end;

    { If we are using nagios advanced status monitoring, set a default status }
    if _settings.daemonNRPEStatusMonitoring then begin
      SetDefaultNagiosStatus;
    end;

    { Wait on the task - keep waiting as long as the task runs, or there is
      output to be read }
    logStashed := 0;
    lastFlush := unixtimeint;
    sandboxRunning := true;
    sandboxExitCode := 0;

    { -------- Main run loop ------------ }

    while sandboxRunning or (_pipes.sandboxReadPipe.NumBytesAvailable > 0) do begin
      { Check if the sandbox is still running }
      if sandboxRunning then begin
        sandboxState := FPWaitPid(sandboxPID, sandboxExitCode, WNOHANG);
        if sandboxState = -1 then begin
          { This should never happen. If this happens, the best way to deal with
            it is try to destroy the sandbox, causing a task restart. }
          _logger.Log(funcname + 'Internal error: FPWaitPid failed (system out of memory?), trying to kill sandbox');
          FpKill(sandboxPID, SIGKILL);
          sandboxRunning := false;
          { Fake exit code, as we don't know the real one. 1 = failure }
          sandboxExitCode := 1;
        end;
        if sandboxState <> 0 then begin
          { Sandbox has stopped }
          _logger.Log(funcname + 'Sandbox stopped with exit code: ' + inttostr(sandboxExitCode));
          sandboxRunning := false;
        end;
      end;

      { Is our parent waiting for a notification of task status? }
      if shouldSignalParent then begin
        { If the task has been running long enough, notify them of success }
        if ((unixtimeint - taskStartedTS) >= SECONDS_BEFORE_SIGNAL) and sandboxRunning then begin
          shouldSignalParent := false;
          endpoint.SendString(''); 
        end;
      end;

      { If the task has written anything to stdout/stderr, consume it }
      bytesAvailable := _pipes.sandboxReadPipe.NumBytesAvailable;
      if bytesAvailable > 0 then begin
        if bytesAvailable > OUTPUT_BUFFER_SIZE then begin
          bytesAvailable := OUTPUT_BUFFER_SIZE;
        end;
        bytesRead := _pipes.sandboxReadPipe.read(outputbuffer[0], bytesAvailable);
        { If we are using advanced monitoring, scan the log output }
        if _settings.daemonNRPEStatusMonitoring then begin
          nagiosParser.ParseBuffer(outputbuffer[0], bytesRead);
        end;
        if _settings.daemonCaptureOutput then begin
          { Buffer the output and write it to a log periodically }
          move(outputbuffer[0], logbuffer[logStashed], bytesRead);
          inc(logStashed, bytesRead);
          { If there is a chance we could overflow the buffer on the next call
            then flush it }
          if logStashed > LOG_BUFFER_MAX then begin
            _logger.LogRaw(@logbuffer, logStashed);
            logStashed := 0;
            lastFlush := unixtimeint;
          end;
        end;
        { We don't sleep here because we want to consume data as quickly as
          possible if there is still data to consume }
      end else begin
        { Throttle our checks }
        sleep(CHECK_INTERVAL_MS);
        { If log capture is enabled, flush partially filled log buffers if it has
          not been flushed for a while to avoid a stale buffer. A side effect of
          the way I do this is that if the task does not output anything for a
          while, the next time it does it will be flushed immediately (good if
          something is about to crash) }
        if _settings.daemonCaptureOutput and (logStashed > 0) then begin
          timeNow := unixtimeint;
          if (timeNow - lastFlush) > FLUSH_INTERVAL then begin
            _logger.LogRaw(@logbuffer, logStashed);
            logStashed := 0;
            lastFlush := unixtimeint;
          end;
        end;
      end;

      { Check if we need to reset the recently failed status }
      if _settings.recentlyFailed then begin
        timenow := unixtimeint;
        if (timenow - firstFailureTime) > _settings.throttleTimespan then begin
          _settings.recentlyFailed := false;
          { Change nagios status }
          if _settings.daemonNRPEStatusMonitoring and _settings.daemonNRPEAlertRecentlyFailed then begin
            _settings.daemonNRPEStatusTS := unixtimeint;
            SetNagiosStatusRaw(_nagios_status_ok, 'Task recovered and has not failed recently', _settings.daemonNRPEStatusTS);
          end;
        end;
      end;
    end;

    { -------- End of main loop ------------ }

    { Handle any data left in the buffer }
    if logStashed > 0 then begin
      _logger.LogRaw(@logbuffer, logStashed);
    end;
    if _settings.daemonCaptureOutput then begin
      _logger.Log('-');
      _logger.Log('-------- End of task output ----------');
    end;

    { Check for any control messages }
    if sandboxControl.Pump then begin
      if not sandboxControl.GetString(sandboxControlRX) then sandboxControlRX := '';
    end else begin
      sandboxControlRX := '';
    end;
    if sandboxControlRX <> '' then begin
      _logger.Log(funcname + 'Sandbox message: ' + sandboxControlRX);
    end;

    result := sandboxExitCode;
    _logger.Log(funcname + 'Task stopped with exit code: ' + inttostr(sandboxExitCode));
    CloseSandbox;

    if _signalstop then begin
      _logger.Log(funcname + 'Exiting now due to signal.');
      { Rare case, but was the parent waiting for us? }
      if shouldSignalParent then begin
        { Tell them why we stopped }
        endpoint.SendString('Stopping due to a signal'); 
        shouldSignalParent := false;
      end;
      exit;
    end;

    { If the parent was still waiting for a signal from us and the task has
      failed already, it means the task is defective. We will stop here. }
    if shouldSignalParent then begin
      if sandboxControlRX <> '' then begin
        endpoint.SendString('Sandbox error: ' + sandboxControlRX);
      end else begin
        endpoint.SendString('Task process failed within ' + inttostr(SECONDS_BEFORE_SIGNAL) +
          ' seconds, deemed defective. Stopping.');
      end;
      _logger.Log(funcname + 'Task failed almost immediately after starting, ' +
        'during first time startup. Defective task.');
      exit;
    end;

    { Safety throttling, if enabled }
    if _settings.daemonSafetyThrottle then begin
      timenow := unixtimeint;

      { Change nagios status }
      _settings.recentlyFailed := true;
      if _settings.daemonNRPEStatusMonitoring and _settings.daemonNRPEAlertRecentlyFailed then begin
        _settings.daemonNRPEStatusTS := unixtimeint;
        SetNagiosStatusRaw(_nagios_status_warning, 'Task failed and is being restarted', _settings.daemonNRPEStatusTS);
      end;

      { Is this the first failure since we started, or was the last failure
        a long time ago? }
      if (firstFailureTime = 0) or ((timenow - firstFailureTime) > _settings.throttleTimespan) then begin
        { Reset the safety throttle and consider this the first failure }
        if firstFailureTime <> 0 then begin
          _logger.Log(funcname + 'Safety throttle reset');
        end;
        firstFailureTime := timenow;
        failureCount := 1;
        currentDelay := 1;
      end else begin
        { No, we failed recently - add this to the failure count }
        inc(failureCount);

        { Have we exceeded the threshold for failures during the timespan? }
        { -1 means there is no limit }
        if (failureCount > _settings.throttleCount) and (_settings.throttleCount <> -1) then begin
          restartJob := false;
          _logger.Log(funcname + 'Task failed too many times - triggered safety limit - daemon shutting down');
          _logger.Log(funcname + 'Failed more than ' +
            inttostr(_settings.throttleCount) + ' times in ' +
            inttostr(_settings.throttleTimespan) + ' seconds');
        end;
      end;
      _logger.Log(funcname + 'Task has failed ' + inttostr(failureCount) +
        ' times in a timespan of ' + inttostr(_settings.throttleTimespan) + ' seconds');
    end;

    { If we will be restarting the task then write an informative log entry }
    if restartJob then begin
      { If the safety throttle is in use, add a retry delay }
      if _settings.daemonSafetyThrottle then begin
        if _settings.throttleExponential then begin
          { Exponential backoff mode - limit our maximum }
          currentDelay := currentDelay shl 1;
          if currentDelay > _settings.throttleExponentialLimit then begin
            currentDelay := _settings.throttleExponentialLimit;
          end;
          delayMilliseconds := currentDelay * 1000;
          { Make sure we still adhere to the minimum delay }
          if delayMilliseconds < _settings.throttleDelay then begin
            delayMilliseconds := _settings.throttleDelay;
          end;
        end else begin
          { Just delay by the minimum }
          delayMilliseconds := _settings.throttleDelay;
        end;
        _logger.Log(funcname + 'Safety throttle - waiting ' + inttostr(delayMilliseconds div 1000) + 's');
        { If we just use a single sleep delay, the program cannot respond to
          unix signals during the sleep. This means that attempts to stop
          godaemon neatly will fail. Instead, sleep in intervals and check
          for the signal regularly }
        if SleepAndWatchSignals(delayMilliseconds) then begin
          { Got a terrible signal }
          _logger.Log(funcname + 'Sleep interrupted by a signal - exiting');
          exit;
        end;
      end;
      _logger.Log(funcname + 'Restarting the task...');
    end;

    { Send an email to the administrator }
    if _settings.daemonEmailOnFailure then begin
      { Complete failure? }
      if not restartJob then begin
        SendEmailForTaskCompleteFailure;
      end else begin
        SendEmailForTaskRestart(failureCount, _settings.throttleCount, _settings.throttleTimespan);
      end;
    end;

  until not restartJob;

  { Finished }
  _logger.Log(funcname + 'Not restarting the task.');
end;

{ --------------------------------------------------------------------------
  Setup logging and return a tLogger instance.
  Returns nil and writes an error to the foreground log  if there was an
  error setting up logging.
  -------------------------------------------------------------------------- }
procedure StartLogger;
begin
  _logger := tLogger.Create(_settings.logFile);
  _logger.Log(_programname + ' (' + _version + ') - log opened');
end;

{ --------------------------------------------------------------------------
  Initialise system libraries needed by the application
  -------------------------------------------------------------------------- }
function InitialiseSystem: boolean;
begin
  result := false;

  btime.init;
  result := true;
end;

end.
