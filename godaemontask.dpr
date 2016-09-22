{ --------------------------------------------------------------------------
  godaemon

  A daemon wrapper for daemons written in go.
  You cannot write a "real" daemon in go due to issues with forking and
  goroutines (from the official documentation). Instead, you are supposed
  to daemonise your go app using another solution.
  There are some other solutions, but I wrote this one because:
    - This is much more simple than the other tools I found
    - Automatically restarts the daemon if it crashes, but with throttleback
      incase the daemon is crashing too often)
    - Some of the other daemoniser tools are heavy (replacing the way init
      works or other sillyness)
    - Provides proper logging support
    - PID files to prevent multiple instances starting (if you want)
    - Hardened, should keep going no matter what (careful about errors)

  This is generic enough that it can be used to quickly daemonise any program
  with nice logging and auto restart capability.
  
  The program is called godaemontask rather than godaemon for historical
  reasons, and changing it would break older scripts/etc.

  Copyright (c) Michael Nixon 2015.
  Please see the LICENSE file for licensing information.
  -------------------------------------------------------------------------- }

{ --------------------------------------------------------------------------
  -------------------------------------------------------------------------- }
program godaemontask;

{ We can only compile in Delphi compatible mode with FPC }
{$ifdef fpc}
  {$ifndef fpc_delphi}
    {$fatal Delphi mode is required (-Sd) to compile godaemon.}
  {$endif}
  {$if (fpc_version < 3)}
    {$info WARNING - compilation with freepascal version 3.0.0 or less is unsupported and untested.}
  {$endif}
{$endif}

uses
  { Our stuff }
  mainapp, settings, logger, actions, commandline,
  { System units }
  classes, baseunix, sysutils;

{ --------------------------------------------------------------------------
  Program entrypoint
  -------------------------------------------------------------------------- }
begin
  { By default assume a bad exit status }
  ExitCode := 1;

  { To prevent mistakes }
  if GetEnvironmentVariable('GODAEMON') <> '' then begin
    writeln('FATAL: I spawned a copy of myself (stopping)');
    halt;
  end;

  { Initialise system libraries [mainapp] }
  if not InitialiseSystem then begin
    writeln('FATAL: InitialiseSystem failed!');
    exit;
  end;

  { Initialise default settings [settings] }
  InitialiseGlobalSettings;

  { If invalid command line parameters were specified, CheckCommandLine will
    return false here }
  if not CheckCommandLine then exit;

  { Handle actions }
  case _settings.action of
    eaStart: begin
      ExitCode := DoActionStart;
    end;
    eaStop: begin
      ExitCode := DoActionStop;
    end;
    eaStatus: begin
      ExitCode := DoActionStatus;
    end;
    eaNagiosStatus: begin
      ExitCode := DoActionNagiosStatus;
    end;
    eaInfo: begin
      ExitCode := DoActionInfo;
    end;
    eaReload: begin
      ExitCode := DoActionReload;
    end;
    eaForceStop: begin
      ExitCode := DoActionForceStop;
    end;
  end;
end.

