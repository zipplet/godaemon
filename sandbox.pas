{ --------------------------------------------------------------------------
  godaemon

  Sandbox unit (run the task as a lower privilege user)

  Copyright (c) Michael Nixon 2015.
  Please see the LICENSE file for licensing information.
  -------------------------------------------------------------------------- }

{ --------------------------------------------------------------------------
  -------------------------------------------------------------------------- }
unit sandbox;

interface

uses baseunix, unix, unixutil, sockets, sysutils, classes;

function StartSandbox: longint;
procedure CloseSandbox;

implementation

uses settings, pipes, fork, ipcpipe;

{ --------------------------------------------------------------------------
  Close down the remnants of a previously created sandbox.
  -------------------------------------------------------------------------- }
procedure CloseSandbox;
begin
  FreeAndNil(_pipes.sandboxReadPipe);
  FreeAndNil(_pipes.sandboxWritePipe);
end;

{ --------------------------------------------------------------------------
  Create a sandbox. This forks the process.
  A pipe is created so that the child can send data outside the sandbox to
  the parent.
  The child process is modified:
   - The user id / group id are changed to a lesser-privileged user
  If we are the parent (outside of the sandbox), return the pid of the child.
  If we are the child (inside the sandbox), return -1.
  If we could not make a sandbox, return 0.
  -------------------------------------------------------------------------- }
function StartSandbox: longint;
var
  forkResult: longint;
  sandboxControl: tipcPipeEndpoint;
begin
  sandboxControl := _pipes.controlPipe.GetChildEndpoint;

  { Before we fork we need to make the log traffic pipe }
  try
    CreatePipeStreams(_pipes.sandboxReadPipe, _pipes.sandboxWritePipe);
  except
    on e: exception do begin
      sandboxControl.SendString('Failure creating the log pipe: ' + e.message);
      { just incase }
      _pipes.sandboxReadPipe := nil;
      _pipes.sandboxWritePipe := nil;
      result := 0;
      exit;
    end;
  end;

  forkResult := fpfork;
  if forkResult < 0 then begin
    { Couldn't fork }
    sandboxControl.SendString('Fork failed');
    result := 0;
    exit;
  end;

  if forkResult <> 0 then begin
    { We are the parent. Give the child/sandbox PID to the caller }
    result := forkResult;
    exit;
  end;

  { We are the child / sandbox. }
  { If anything goes wrong while setting up the rest of the sandbox we must
    immediately halt the program so that the parent knows something went
    wrong and exits as well }

  try
    RenameCurrentProcess('[godaemon-sandbox] ' + _settings.daemonName);

    { Set uid / gid if requested }
    if _settings.daemonChangeUser then begin
      { Change the group first, as once root permissions are dropped by changing
        the user it is impossible to change the group }
      if fpsetgid(_settings.daemonGroupID) <> 0 then begin
        sandboxControl.SendString('Failed to set gid to ' + inttostr(_settings.daemonGroupID));
        halt;
      end;
      if fpsetuid(_settings.daemonUserID) <> 0 then begin
        sandboxControl.SendString('Failed to set uid to ' + inttostr(_settings.daemonUserID));
        halt;
      end;
    end;

    { Sandbox created }
    result := -1;
  except
    on e: exception do begin
      sandboxControl.SendString('FATAL: Uncaught exception in StartSandbox - terminated sandbox: ' + e.message);
      halt;
    end;
  end;
end;

end.
