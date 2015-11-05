{ --------------------------------------------------------------------------
  godaemon

  NRPE handling unit

  Copyright (c) Michael Nixon 2015.
  Please see the LICENSE file for licensing information.
  -------------------------------------------------------------------------- }

{ --------------------------------------------------------------------------
  -------------------------------------------------------------------------- }
unit nrpe;

interface

uses baseunix, unix, unixutil, sockets, sysutils, classes;

const
  StatusBufferSize = 1024;
  MatchBufferSize = 64;

type
  tmessagebuffer = array[0..0] of byte;

  tNRPEMessageScraper = class(tobject)
    private
      statusBuffer: array[0..StatusBufferSize - 1] of byte;
      statusBufferPtr: longint;
      matchBuffer: array[0..MatchBufferSize - 1] of byte;
      matchBufferLength: longint;
      matchBufferPos: longint;
      inMatch: boolean;
      function ProcessStatusBuffer: boolean;
    public
      constructor Create(prefixString: ansistring);
      function ParseBuffer(var buffer; size: longint): boolean;
  end;

procedure SetNagiosStatus(statusID: longint; statusMessage: ansistring; timestamp: longint);
procedure SetNagiosStatusRaw(statusID: longint; statusMessage: ansistring; timestamp: longint);
function GetNagiosStatus(var statusID: longint; var statusMessage: ansistring; var timestamp: longint): boolean;
function ParseNagiosStatusString(status: ansistring; var statusID: longint; var statusMessage: ansistring): boolean;
function GetNagiosStatusString(statusID: longint; statusMessage: ansistring): ansistring;
procedure SetDefaultNagiosStatus;
function SafelyDeleteFile(filename: ansistring): boolean;

implementation

uses settings, btime;

{ --------------------------------------------------------------------------
  Process a finished status buffer.
  Returns TRUE if we could process it without errors.
  Returns FALSE if we could not process it properly.
  -------------------------------------------------------------------------- }
function tNRPEMessageScraper.ProcessStatusBuffer: boolean;
var
  nagiosStatusID: longint;
  nagiosStatusMessage: ansistring;
  nagiosStatus: ansistring;
begin
  setlength(nagiosStatus, self.statusBufferPtr);
  move(self.statusBuffer[0], nagiosStatus[1], self.statusBufferPtr);
  if ParseNagiosStatusString(nagiosStatus, nagiosStatusID, nagiosStatusMessage) then begin
    _settings.daemonNRPEStatusTS := unixtimeint;
    SetNagiosStatus(nagiosStatusID, nagiosStatusMessage, _settings.daemonNRPEStatusTS);
    result := true;
  end else begin
    result := false;
  end;
end;

{ --------------------------------------------------------------------------
  tNRPEMessageScraper constructor
  -------------------------------------------------------------------------- }
constructor tNRPEMessageScraper.Create(prefixString: ansistring);
const
  funcname = 'tNRPEMessageScraper.Create: ';
var
  matchString: ansistring;
begin
  if length(prefixString) = 0 then begin
    raise exception.create(funcname + 'Invalid prefix string');
    exit;
  end;

  matchString := '&' + prefixString + '&{';

  if length(matchString) > MatchBufferSize then begin
    raise exception.create(funcname + 'Prefix string too long');
    exit;
  end;

  move(matchString[1], self.matchBuffer[0], length(matchString));
  self.matchBufferLength := length(matchString);

  matchBufferPos := 0;
  inMatch := false;
  statusBufferPtr := 0;
end;

{ --------------------------------------------------------------------------
  Parse a log buffer and look for NRPE messages.
  Returns TRUE if we found at least one NRPE status update (otherwise FALSE)
  -------------------------------------------------------------------------- }
function tNRPEMessageScraper.ParseBuffer(var buffer; size: longint): boolean;
const
  CLOSING_BRACE = 125;
var
  i: longint;
  b: byte;
  processed: boolean;
begin
  processed := false;
  for i := 0 to size - 1 do begin
    b := tmessagebuffer(buffer)[i];
    if self.inMatch then begin
      { If this is a closing brace, stop matching }
      if b = CLOSING_BRACE then begin
        self.inMatch := false;
        processed := self.ProcessStatusBuffer;
        self.statusBufferPtr := 0;
      end else begin
        { Keep adding to message }
        self.statusBuffer[self.statusBufferPtr] := b;
        inc(self.statusBufferPtr);
        if self.statusBufferPtr >= StatusBufferSize then begin
          { Status buffer full, have to cut off the message }
          self.inMatch := false;
          processed := self.ProcessStatusBuffer;
          self.statusBufferPtr := 0;
        end;
      end;
    end else begin
      { Matching }
      if b = self.matchBuffer[self.matchBufferPos] then begin
        inc(self.matchBufferPos);
        if self.matchBufferPos >= self.matchBufferLength then begin
          { Got a full match }
          self.inMatch := true;
          self.matchBufferPos := 0;
        end;
      end else begin
        { Fail, reset matching }
        self.matchBufferPos := 0;
      end;
    end;
  end;

  result := processed;
end;

{ --------------------------------------------------------------------------
  Assuming you know <filename> exists for sure, try to delete it safely.
  Returns TRUE on success, or FALSE if we could not.
  -------------------------------------------------------------------------- }
function SafelyDeleteFile(filename: ansistring): boolean;
begin
  try
    DeleteFile(filename);
  except
    on e: exception do begin
      result := false;
      exit;
    end;
  end;
  result := true;
end;

{ --------------------------------------------------------------------------
  Set the nagios status to the default status.
  -------------------------------------------------------------------------- }
procedure SetDefaultNagiosStatus;
begin
  SetNagiosStatus(_settings.daemonNRPEDefaultStatusID,
    _settings.daemonNRPEDefaultStatusString,
    _settings.daemonNRPEStatusTS);
end;

{ --------------------------------------------------------------------------
  Get a nagios status string (suitable for use with ParseNagiosStatusString).
  Returns the nagios status string.
  -------------------------------------------------------------------------- }
function GetNagiosStatusString(statusID: longint; statusMessage: ansistring): ansistring;
var
  s: ansistring;
begin
  case statusID of
    _nagios_status_ok: begin
      s := 'OK';
    end;
    _nagios_status_warning: begin
      s := 'WARNING';
    end;
    _nagios_status_critical: begin
      s := 'CRITICAL';
    end;
    _nagios_status_unknown: begin
      s := 'UNKNOWN';
    end;
  end;
  result := s + ':' + statusMessage;
end;

{ --------------------------------------------------------------------------
  Parse a nagios status string of the format:
  STATUS:message
  Sets <statusID> and <statusMessage>.
  Returns TRUE if the status could be parsed, or FALSE if it could not.
  -------------------------------------------------------------------------- }
function ParseNagiosStatusString(status: ansistring; var statusID: longint; var statusMessage: ansistring): boolean;
var
  statusIDStr: ansistring;
  i: longint;
begin
  result := false;

  if length(status) < 3 then exit;
  i := pos(':', status);
  if (i < 2) or (i > (length(status) - 1)) then exit;

  statusIDStr := uppercase(copy(status, 1, i - 1));
  statusMessage := copy(status, i + 1, length(status) - i);
  if statusIDStr = 'OK' then begin
    statusID := _nagios_status_ok;
  end else if statusIDStr = 'WARNING' then begin
    statusID := _nagios_status_warning;
  end else if statusIDStr = 'CRITICAL' then begin
    statusID := _nagios_status_critical;
  end else if statusIDStr = 'UNKNOWN' then begin
    statusID := _nagios_status_unknown;
  end else begin
    { Invalid status }
    exit;
  end;

  result := true;
end;

{ --------------------------------------------------------------------------
  Set the nagios status for the task (writes the status file).
  <statusID> is the nagios status (_nagios_status_xxxxx)
  <statusMessage> is the status message.
  -------------------------------------------------------------------------- }
procedure SetNagiosStatusRaw(statusID: longint; statusMessage: ansistring; timestamp: longint);
const
  funcname = 'SetNagiosStatus(): ';
var
  statusTempFile: ansistring;
  f: textfile;
begin
  { To do this "semi atomically", first create a temp file with the status }
  statusTempFile := _settings.daemonStatusFilename + '.temp';
  if fileexists(statusTempFile) then begin
    SafelyDeleteFile(statusTempFile);
  end;

  filemode := fmOpenWrite;
  assignfile(f, statusTempFile);
  rewrite(f);
  writeln(f, GetNagiosStatusString(statusID, statusMessage));
  writeln(f, timestamp);
  closefile(f);

  { Delete the old file, if present }
  if fileexists(_settings.daemonStatusFilename) then begin
    if not SafelyDeleteFile(_settings.daemonStatusFilename) then begin
      { Probably in use, so sleep a little bit }
      sleep(250);
      { Now give it another try }
      if not SafelyDeleteFile(_settings.daemonStatusFilename) then begin
        { Shouldn't happen, make a note of it and clean up }
        SafelyDeleteFile(statusTempFile);
        _logger.Log(funcname + 'Failed to remove old status file!');
        exit;
      end;
    end;
  end;

  { Rename new file to old filename }
  if not RenameFile(statusTempFile, _settings.daemonStatusFilename) then begin
    { Failed, clean up }
    SafelyDeleteFile(statusTempFile);
    _logger.Log(funcname + 'Failed to rename new status file!');
    exit;
  end;
end;

{ --------------------------------------------------------------------------
  Get the nagios status of the task (by reading the nagios status file).
  Returns TRUE if we could get the status successfully.
  -------------------------------------------------------------------------- }
function GetNagiosStatus(var statusID: longint; var statusMessage: ansistring; var timestamp: longint): boolean;
var
  status: ansistring;
  tsString: ansistring;
  f: textfile;
begin
  result := false;
  if not fileexists(_settings.daemonStatusFilename) then exit;

  try
    filemode := fmOpenRead;
    assignfile(f, _settings.daemonStatusFilename);
    reset(f);
    readln(f, status);
    readln(f, tsString);
    closefile(f);
    timestamp := strtoint(tsString);
  except
    on e: exception do begin
      { Failed status as the file was unparseable }
      exit;
    end;
  end;

  result := ParseNagiosStatusString(status, statusID, statusMessage);
end;

{ --------------------------------------------------------------------------
  This is the same as SetNagiosStatus, except it will include information in
  the status about the failure count.
  -------------------------------------------------------------------------- }
procedure SetNagiosStatus(statusID: longint; statusMessage: ansistring; timestamp: longint);
var
  usedStatusID: longint;
begin
  if not _settings.daemonNRPEAlertRecentlyFailed then begin
    { Just set raw status }
    SetNagiosStatusRaw(statusID, statusMessage, timestamp);
  end else begin
    if not _settings.recentlyFailed then begin
      { Just set raw status }
      SetNagiosStatusRaw(statusID, statusMessage, timestamp);
    end else begin
      { Need to combine the 2 statuses }
      usedStatusID := _nagios_status_warning;
      if statusID = _nagios_status_critical then begin
        usedStatusID := statusID;
      end;
      SetNagiosStatusRaw(usedStatusID, 'Task has been restarted recently: ' +
        statusMessage, timestamp);
    end;
  end;
end;

end.
