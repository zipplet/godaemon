{ --------------------------------------------------------------------------
  testdaemon
  A program that can be used to test godaemon.

  Copyright (c) Michael Nixon 2015.
  Please see the LICENSE file for licensing information.
  -------------------------------------------------------------------------- }

{ --------------------------------------------------------------------------
  -------------------------------------------------------------------------- }
program testdaemon;

uses
  { System units }
  baseunix, sysutils;

var
  count: longint;

begin
  ExitCode := 0;
  writeln('testdaemon starting');
  writeln('paramcount is ' + inttostr(paramcount));
  for count := 1 to paramcount do begin
    writeln('[' + inttostr(count) + '] ' + paramstr(count));
  end;
  for count := 1 to 10000 do begin
    writeln('Dummy output line to capture to the log, ' + inttostr(count));
    sleep(100);
    if (count mod 10) = 0 then begin
      writeln('something for status: &nagios&{OK:Sent ' + inttostr(count) + ' lines}');
    end;
  end;
  sleep(2000);
  writeln('testdaemon is now exiting');
end.

