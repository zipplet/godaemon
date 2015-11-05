{ --------------------------------------------------------------------------
  godaemon

  Parent startup unit
  Handles the parent process when godaemon forks to start a task

  Copyright (c) Michael Nixon 2015.
  Please see the LICENSE file for licensing information.
  -------------------------------------------------------------------------- }

{ --------------------------------------------------------------------------
  -------------------------------------------------------------------------- }
unit parentstart;

interface

uses baseunix, unix, unixutil, sockets, sysutils, classes;

procedure RunParentStart;

implementation

uses settings, ipcpipe;

{ --------------------------------------------------------------------------
  Entrypoint for the godaemon process that did not become a daemon (parent)
  when starting a new task.
  -------------------------------------------------------------------------- }
procedure RunParentStart;
const
  funcname = 'RunParentStart(): ';
  bufferSize = 1024;
var
  readString: ansistring;
  endpoint: tipcPipeEndpoint;
  waiting: boolean;
begin
  endpoint := _pipes.taskStartupPipe.GetParentEndpoint;
  write('Waiting for the daemon to finish starting the task [');

  waiting := true;
  while waiting do begin
    sleep(500);
    write('. ');
    if endpoint.Pump then begin
      if endpoint.GetString(readString) then begin
        if length(readString) = 0 then begin
          { An empty string is received on success }
          writeln('.] - OK (running)');
          ExitCode := 0;
        end else begin
          { A non empty string is received on failure }
          writeln('.] - FAILED');
          writeln(readString);
          ExitCode := 1;
        end;
        waiting := false;
      end;
    end;
  end;

  halt;
end;

end.
