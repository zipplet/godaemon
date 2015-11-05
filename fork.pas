{ --------------------------------------------------------------------------
  godaemon

  Fork unit (deals with PID files, forking and user/group state)

  Copyright (c) Michael Nixon 2015.
  Please see the LICENSE file for licensing information.
  -------------------------------------------------------------------------- }

{ --------------------------------------------------------------------------
  -------------------------------------------------------------------------- }
unit fork;

interface

uses baseunix, unix, unixutil, sockets, sysutils, classes;

function Daemonise(renameProcess: boolean; newName: ansistring): boolean;
procedure RenameCurrentProcess(newName: ansistring);
function StartAllowOneProcess: boolean;
procedure FinishAllowOneProcess;
function PIDFileExists: boolean;
function PIDIsAlive(pid: longint): boolean;
function PIDIsGoDaemon(pid: longint): boolean;
function PIDReadFromFile: longint;
procedure PIDRemoveFile;
procedure PIDCreateFile;
function GetUserAndGroupIDs: boolean;
procedure DetermineLongestProcessName;

implementation

uses settings, pipes, utils, users, parentstart, logger;

var
  _maxProcessNameLength: longint;

{ --------------------------------------------------------------------------
  Determine the longest allowed process name for RenameCurrentProcess.
  Must be done at startup as it cannot be computed after RenameCurrentProcess
  has been called.
  -------------------------------------------------------------------------- }
procedure DetermineLongestProcessName;
var
  i: longint;
begin
  { Count the total length of the argument set. We are allowed to modify the
    argument list as long as we do not overwrite the buffer that was
    allocated when this process started }
  _maxProcessNameLength := 0;
  for i := 0 to argc - 1 do begin
    { Include 1 space character per paramater. Yes we include an extra one
      for the last param but thats okay as it's a null terminator }
    inc(_maxProcessNameLength, strlen(argv[i]) + 1);
  end;
end;

{ --------------------------------------------------------------------------
  Check the supplied userid and groupid (strings).
  If they are numeric, convert them to integers and verify these users and
  groups exist on this system.
  If they are names, convert them to IDs using the system password database.
  Returns TRUE if everything was OK, or FALSE if a problem occured.
  -------------------------------------------------------------------------- }
function GetUserAndGroupIDs: boolean;
const
  funcname = 'GetUserAndGroupIDs(): ';
var
  trimmedUser, trimmedGroup: ansistring;
begin
  result := false;

  trimmedUser := trim(_settings.daemonUserIDField);
  trimmedGroup := trim(_settings.daemonGroupIDField);

  if trimmedUser = '' then begin
    FGLog(funcname + 'User ID is empty');
    exit;
  end;
  if trimmedGroup = '' then begin
    FGLog(funcname + 'Group ID is empty');
    exit;
  end;

  { If the user entered a user ID, use that }
  if StringIsInteger(trimmedUser) then begin
    _settings.daemonUserID := strtoint(trimmedUser);
  end else begin
    { Try to convert username to user ID }
    try
      _settings.daemonUserID := GetUserId(trimmedUser);
    except
      on e: exception do begin
        FGLog(funcname + 'Cannot convert the username "' + trimmedUser +
          '" to a user ID. Does the user exist?');
        exit;
      end;
    end;
  end;

  { If the user entered a group ID, use that }
  if StringIsInteger(trimmedGroup) then begin
    _settings.daemonGroupID := strtoint(trimmedGroup);
  end else begin
    { Try to convert group name to group ID }
    try
      _settings.daemonGroupID := GetGroupId(trimmedGroup);
    except
      on e: exception do begin
        FGLog(funcname + 'Cannot convert the group name "' + trimmedGroup +
          '" to a group ID. Does the group exist?');
        exit;
      end;
    end;
  end;

  { Now we have valid user IDs and group IDs, convert them back to usernames
    using system calls to:
      - confirm they are valid IDs (in the case that the user supplied IDs
        instead of names)
      - get correct capitalisation (in the case that the user supplied names
        with the wrong capitalisation)
  }
  try
    _settings.daemonUserName := GetUserName(_settings.daemonUserID);
  except
    on e: exception do begin
      FGLog(funcname + 'Failed to convert user ID [' +
        inttostr(_settings.daemonUserID) + '] to a username. Invalid user ID.');
      exit;
    end;
  end;
  try
    _settings.daemonGroupName := GetUserName(_settings.daemonGroupID);
  except
    on e: exception do begin
      FGLog(funcname + 'Failed to convert group ID [' +
        inttostr(_settings.daemonGroupID) + '] to a group name. Invalid group ID.');
      exit;
    end;
  end;

  { All OK }
  result := true;
end;

{ --------------------------------------------------------------------------
  Create the PID file for the task.
  -------------------------------------------------------------------------- }
procedure PIDCreateFile;
var
  PIDfile: textfile;
begin
  filemode := fmOpenWrite;
  assign(PIDfile, _settings.daemonPIDFile);
  rewrite(PIDfile);
  writeln(PIDfile, inttostr(fpgetpid));
  close(PIDfile);
end;

{ --------------------------------------------------------------------------
  Delete the PID file for the task.
  -------------------------------------------------------------------------- }
procedure PIDRemoveFile;
const
  funcname = 'PIDRemoveFile(): ';
begin
  if fileexists(_settings.daemonPIDFile) then begin
    deletefile(_settings.daemonPIDFile);
    _logger.Log(funcname + 'PID file removed.');
  end else begin
    _logger.Log(funcname + 'PID file should exist, but was missing? bug?');
  end;
end;

{ --------------------------------------------------------------------------
  Read the task PID from the task PID file.
  Returns the task PID, or raises an exception if it could not read from
  the PID file due to it having invalid content or being nonexistent.
  -------------------------------------------------------------------------- }
function PIDReadFromFile: longint;
const
  funcname = 'PIDReadFromFile(): ';
var
  PIDfile: textfile;
  s: ansistring;
begin
  if not fileexists(_settings.daemonPIDFile) then begin
    raise exception.create(funcname + 'PID file does not exist - ' +
      _settings.daemonPIDFile);
  end;
  filemode := fmOpenRead;
  assign(PIDfile, _settings.daemonPIDFile);
  reset(PIDfile);
  readln(PIDfile, s);
  close(PIDfile);
  result := strtoint(s);
end;

{ --------------------------------------------------------------------------
  Returns true if a PID file exists for the task.
  -------------------------------------------------------------------------- }
function PIDFileExists: boolean;
begin
  if fileexists(_settings.daemonPIDFile) then begin
    result := true;
  end else begin
    result := false;
  end;
end;

{ --------------------------------------------------------------------------
  Returns true if <pid> is a valid process (alive) in the process table.
  -------------------------------------------------------------------------- }
function PIDIsAlive(pid: longint): boolean;
var
  cmdlineFile: ansistring;
begin
  { This is a special linux file that contains the process command line }
  cmdlineFile := '/proc/' + inttostr(pid) + '/cmdline';
  { If the file exists, there is a process running with this pid }
  if fileexists(cmdlineFile) then begin
    result := true;
  end else begin
    result := false;
  end;
end;

{ --------------------------------------------------------------------------
  Returns true if <pid> belongs to a running godaemon process.
  Raises an exception if we cannot access process information.
  -------------------------------------------------------------------------- }
function PIDIsGoDaemon(pid: longint): boolean;
const
  funcname = 'PIDIsGoDaemon(): ';
var
  cmdline: ansistring;
  cmdlinefilename: ansistring;
  cmdlinefile: textfile;
begin
  { This is a special linux file that contains the process command line }
  cmdlinefilename := '/proc/' + inttostr(pid) + '/cmdline';
  { If the file exists, there is a process running with this pid }
  if not fileexists(cmdlinefilename) then begin
    raise exception.create(funcname + 'Cannot open the cmdline file');
    exit;
  end;

  filemode := fmOpenRead;
  assign(cmdlinefile, cmdlinefilename);
  reset(cmdlinefile);
  readln(cmdlinefile, cmdline);
  close(cmdlinefile);
      
  if length(cmdline) > 10 then begin
    if copy(cmdline, 1, 10) = '[godaemon]' then begin
      result := true;
      exit;
    end;
  end;

  result := false;
end;

{ --------------------------------------------------------------------------
  Ensure only one copy of the task is running.
  Returns TRUE if everything is OK and we can continue, or FALSE if another
  copy of the task is running.
  If you call this function and it returns TRUE, you must make sure to call
  FunishAllowOneProcess() later to remove the "mutex".
  -------------------------------------------------------------------------- }
function StartAllowOneProcess: boolean;
const
  funcname = 'StartAllowOneProcess(): ';
var
  pid: longint;
begin
  result := false;

  if PIDFileExists then begin
    { PID file exists, so the task might already running, but we want to be
      sure as it could be a stale file }
    _logger.Log(funcname + 'Warning: PID file already exists - running already?');

    pid := PIDReadFromFile;
    if PIDIsAlive(pid) then begin
      if PIDIsGoDaemon(pid) then begin
        _logger.Log(funcname + 'PID belongs to godaemon - task already running!');
        exit;
      end else begin
        PIDRemoveFile;
        _logger.Log(funcname + 'PID belongs to another process that is not godaemon - stale, deleted');
      end;
    end else begin
      PIDRemoveFile;
      _logger.Log(funcname + 'PID does not belong to any process - stale, deleted');
    end;
  end;

  PIDCreateFile;
  _logger.Log(funcname + 'PID file created.');

  result := true;
end;

{ --------------------------------------------------------------------------
  Remove the mutex set by StartAllowOneProcess (a PID file).
  -------------------------------------------------------------------------- }
procedure FinishAllowOneProcess;
const
  funcname = 'FinishAllowOneProcess(): ';
begin
  PIDRemoveFile;
end;

{ --------------------------------------------------------------------------
  Rename the process to <newName>
  -------------------------------------------------------------------------- }
procedure RenameCurrentProcess(newName: ansistring);
var
  newNameLength: longint;
  newString: ansistring;
begin
  { HACK: Freepascal RTL does not let us modify paramstr() as it is trying
    to be turbo pascal/delphi compatible. Instead we modify argv, which luckily
    the RTL does pass to us }

  newNameLength := length(newName) + 1;
  if newNameLength > _maxProcessNameLength then begin
    { Trim our name and insert a null terminator (it should be there but be
      paranoid) }
    move(newName[1], argv[0]^, _maxProcessNameLength - 1);
    argv[0][_maxProcessNameLength - 1] := #0;
  end else begin
    { We can fit the entire process name. We need to pad our process name to
      be as long as the old name. }
    if newNameLength < _maxProcessNameLength then begin
      setlength(newString, _maxProcessNameLength - 1);
      fillchar(newString[1], length(newString), 32);
      newString[length(newString)] := #0;
      move(newName[1], newString[1], length(newName));
      move(newString[1], argv[0]^, _maxProcessNameLength);
    end else begin
      move(newName[1], argv[0]^, newNameLength);
    end;
  end;
end;

{ --------------------------------------------------------------------------
  Daemonise the current process.
  Returns true if we successfully daemonised, or false if we failed.
  -------------------------------------------------------------------------- }
function Daemonise(renameProcess: boolean; newName: ansistring): boolean;
var
  forkResult: longint;
begin
  result := false;

  if renameProcess then begin
    RenameCurrentProcess(newName);
  end;

  { First fork so that we will not be a process group leader. }
  forkResult := fpfork;

  if forkResult < 0 then begin
    { Fork failed - perhaps out of resources? }
    exit;
  end;

  if forkResult > 0 then begin
    { We are the parent - transfer to parentstart.pas }
    RunParentStart;
    halt;
  end;

  { We must be the child. We are not a process group leader, so now we can
    call setsid to become a process group leader and session group leader.
    This new session will not have a controlling terminal (so we will not catch
    bad signals such as ctrl+c or job control }
  fpsetsid;

  { We need to fork again - the parent will die and the child will carry on.
    This is so that we are not a session group leader and can never regain a
    controlling terminal. }
  forkResult := fpfork;

  if forkResult < 0 then begin
    { Fork failed - perhaps out of resources? }
    exit;
  end;

  if forkResult > 0 then begin
    { We are the parent - so exit immediately }
    ExitCode := 0; { success / running }
    halt;
  end;

  { We are now a child without a controlling terminal. We do not know what
    umask() we have inherited from the parent, so we will reset it to the
    default. }
  fpumask(0);

  { Here we might want to do something with stdin/stdout/stderr. TODO }

  { Success }
  result := true;
end;

initialization
  DetermineLongestProcessName;
end.
