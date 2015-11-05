{ --------------------------------------------------------------------------
  godaemon

  Logger unit

  Copyright (c) Michael Nixon 2015.
  Please see the LICENSE file for licensing information.
  -------------------------------------------------------------------------- }

{ --------------------------------------------------------------------------
  -------------------------------------------------------------------------- }

unit logger;

interface

uses baseunix, unix, unixutil, sockets, sysutils, classes;

type
  { ------------------------------------------------------------------------
    ------------------------------------------------------------------------ }
  byteArray = array[0..0] of byte;
  pByteArray = ^byteArray;

  tLogger = class(tobject)
    private
      logFilename: ansistring;
      logFile: textfile;
      rawLogFile: file;
    public
      constructor Create(filename: ansistring);
      destructor Destroy; override;

      procedure Log(logMessage: ansistring);
      procedure LogRaw(buffer: pByteArray; size: longint);
      function TailLog(lines: longint): tstringlist;
  end;

procedure FGLog(logMessage: ansistring);

{ --------------------------------------------------------------------------
  -------------------------------------------------------------------------- }
implementation

uses btime, settings, tail;

{ --------------------------------------------------------------------------
  Get <lines> from the end of the log file and return them in as a string
  list. Returns nil if the log file could not be tailed.
  -------------------------------------------------------------------------- }
function tLogger.TailLog(lines: longint): tstringlist;
begin
  result := TailFile(self.logFilename, lines); 
end;

{ --------------------------------------------------------------------------
  Write a raw buffer to the log file.
  -------------------------------------------------------------------------- }
procedure tLogger.LogRaw(buffer: pByteArray; size: longint);
const
  funcname = 'tLogger.LogRaw(): ';
var
  s: ansistring;
begin
  AssignFile(self.rawLogFile, self.logFilename);
  try
    filemode := fmOpenWrite;
    reset(self.rawLogFile, 1);
    seek(self.rawLogFile, filesize(self.rawLogFile));
  except
    on e: exception do begin
      { An exception is raised if the log file was deleted after the daemon
        was started and we try to append to it. Logrotate probably moved it.
        If this happens, create it }
      rewrite(self.rawLogFile, 1);
    end;
  end;
  blockwrite(self.rawLogFile, buffer^, size);
  { Also write to stdout if we are in foreground mode }
  if _settings.foregroundMode then begin
    setlength(s, size);
    move(buffer^, s[1], size);
    write(s);
  end;
  closefile(self.rawLogfile);
end;

{ --------------------------------------------------------------------------
  Write a message to stdout with the program name prefixed.
  If the program has been daemonised, this method will try to write the
  message to the main log instead.
  -------------------------------------------------------------------------- }
procedure FGLog(logMessage: ansistring);
begin
  if not _settings.daemonised then begin
    writeln(_programname + ': ' + logMessage);
  end else begin
    { If we are a daemon we will write this into the log file if a logger has
      been created }
    if assigned(_logger) then begin
      _logger.Log('*FGLog*: ' + logMessage);
    end;
  end;
end;

{ --------------------------------------------------------------------------
  Write a log message to the log file.
  -------------------------------------------------------------------------- }
procedure tLogger.Log(logMessage: ansistring);
var
  s: ansistring;
begin
  s := timestriso(unixtimeint) + ': ' + logMessage;
  AssignFile(self.logFile, self.logFilename);
  try
    append(self.logFile);
  except
    on e: exception do begin
      { An exception is raised if the log file was deleted after the daemon
        was started and we try to append to it. Logrotate probably moved it.
        If this happens, create it }
      rewrite(self.logFile);
    end;
  end;
  writeln(self.logFile, s);
  { Also write to stdout if we are in foreground mode but be a little bit
    more descriptive incase we forked but are still writing to the TTY }
  if _settings.foregroundMode then begin
    writeln(_programname + ': ' + s);
  end;
  closefile(self.logfile);
end;

{ --------------------------------------------------------------------------
  tLogger constructor.
  <filename> is the file to write the log to.
  -------------------------------------------------------------------------- }
constructor tLogger.Create(filename: ansistring);
begin
  inherited Create;
  
  self.logFilename := filename;
  if not FileExists(self.logFilename) then begin
    { Try to create the log file }
    AssignFile(self.logFile, self.logFilename);
    rewrite(self.logFile);
    writeln(self.logFile, timestriso(unixtimeint) + ': tLogger.Create: New log file created');
    closefile(self.logFile);
  end;
end;

{ --------------------------------------------------------------------------
  tLogger destructor.
  -------------------------------------------------------------------------- }
destructor tLogger.Destroy;
begin
  {}
  inherited Destroy;
end;

{ --------------------------------------------------------------------------
  -------------------------------------------------------------------------- }
end.
