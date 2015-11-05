{ --------------------------------------------------------------------------
  godaemon

  Task sandbox unit
  - Deals with the task running in the sandbox

  Copyright (c) Michael Nixon 2015.
  Please see the LICENSE file for licensing information.
  -------------------------------------------------------------------------- }

{ --------------------------------------------------------------------------
  -------------------------------------------------------------------------- }

unit tasksandbox;

interface

uses baseunix, unix, unixutil, sockets, sysutils, classes, logger, lsignal;

{ Non-class functions and procedures }
procedure RunTaskSandbox;

{ --------------------------------------------------------------------------
  -------------------------------------------------------------------------- }
implementation

uses btime, settings, strutils, process, sandbox, ipcpipe;

{ --------------------------------------------------------------------------
  This is the procedure that is called inside the child task sandbox once
  the sandbox has been created.

  Our job is to run the task and stream the output back to the parent
  godaemon process using a pipe that has been setup for us. We must never
  return to the caller.

  If the task fails, we halt (and the parent deals with destroying the
  sandbox and creating a new one).

  We can communicate with the parent daemon using the sandboxControl pipe.

  Any exceptions that occur here are sent to the controlling daemon.
  -------------------------------------------------------------------------- }
procedure RunTaskSandbox;
const
  OUTPUT_BUFFER_SIZE = 1024;
  CHECK_INTERVAL_MS = 250;
  funcname = 'RunTaskSandbox(): ';
  SIGNAL_TERM = 'TERM';
  SIGNAL_HUP = 'HUP';
  SIGNAL_FORCE = 'FORCE';
var
  task: tprocess;
  outputbuffer: array[0..OUTPUT_BUFFER_SIZE - 1] of char;
  bytesAvailable, bytesRead: longint;
  i: longint;
  sandboxControl: tipcPipeEndpoint;
  sandboxMessage: ansistring;
begin
  sandboxControl := _pipes.controlPipe.GetChildEndpoint;

  { Change to the directory the process lives in as some programs will not be
    able to find their configuration files/etc otherwise. This wont affect the
    caller because we will have forked by now (unless we are running in the
    foreground, but we don't care about that) }
  chdir(_settings.daemonPath);

  task := tprocess.Create(nil);
  task.Options := [poUsePipes, poStderrToOutPut];
  task.Executable := _settings.daemonFilename;
  task.InheritHandles := false;
  for i := 0 to _settings.params.count - 1 do begin
    task.Parameters.Add(_settings.params.strings[i]);
  end;
  for i := 0 to _settings.environment.count - 1 do begin
    task.Environment.Add(_settings.environment.strings[i]);
  end;
  { Pass a special environment variable to the task - this is used to stop
    godaemon from running itself }
  task.Environment.Add('GODAEMON=TASK');

  { Start the task }
  try
    task.Execute;
  except
    on e: exception do begin
      sandboxControl.SendString('tprocess exception: ' + e.message);
      halt;
    end;
  end;

  { Wait on the task - keep waiting as long as the task runs, or there is
    output to be read }
  while task.Running or (task.Output.NumBytesAvailable > 0) do begin
    { Check the control pipe for control requests }
    if sandboxControl.Pump then begin
      if sandboxControl.GetString(sandboxMessage) then begin
        if task.Running then begin
          if sandboxMessage = SIGNAL_TERM then begin
            FPKill(task.ProcessID, SIGTERM);
          end;
          if sandboxMessage = SIGNAL_HUP then begin
            FPKill(task.ProcessID, SIGHUP);
          end;
          if sandboxMessage = SIGNAL_FORCE then begin
            FPKill(task.ProcessID, SIGKILL);
          end;
        end;
      end;
    end;

    { If the task has written anything to stdout/stderr, consume it }
    bytesAvailable := task.Output.NumBytesAvailable;
    if bytesAvailable > 0 then begin
      if bytesAvailable > OUTPUT_BUFFER_SIZE then begin
        bytesAvailable := OUTPUT_BUFFER_SIZE;
      end;
      bytesRead := task.Output.Read(outputbuffer[0], bytesAvailable);
      if _settings.daemonCaptureOutput then begin
        { Send output to parent }
        _pipes.sandboxWritePipe.write(outputbuffer[0], bytesRead);
      end;
      { We don't sleep here because we want to consume data as quickly as
        possible if there is still data to consume }
    end else begin
      { Throttle our checks }
      sleep(CHECK_INTERVAL_MS);
    end;
  end;

  { The process MUST stop here as we are the child sandbox }
  ExitCode := task.ExitStatus;
  task.Free;
  halt;
end;

end.
