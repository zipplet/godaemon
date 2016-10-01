{ --------------------------------------------------------------------------
  godaemon

  Command line processor unit

  Copyright (c) Michael Nixon 2015.
  Please see the LICENSE file for licensing information.
  -------------------------------------------------------------------------- }

{ --------------------------------------------------------------------------
  -------------------------------------------------------------------------- }

unit commandline;

interface

uses baseunix, unix, unixutil, sockets, sysutils, classes, lsignal;

{ Non-class functions and procedures }
function CheckCommandLine: boolean;
procedure PrintInfo;
function ParseEnvironmentList(envVars: string): boolean;
procedure PrintHelp;
function ProcessTaskFile(taskFilename: ansistring): boolean;

{ --------------------------------------------------------------------------
  -------------------------------------------------------------------------- }
implementation

uses btime, settings, strutils, email, logger, mainapp, utils, inifiles, users, nrpe;

{ --------------------------------------------------------------------------
  Read the task file <taskFilename> and configure the task/daemon.
  Returns TRUE if everything is OK. If there is a problem, an error message
  is printed to stdout and FALSE is returned.
  -------------------------------------------------------------------------- }
function ProcessTaskFile(taskFilename: ansistring): boolean;
const
  funcname = 'ProcessTaskFile(): ';
var
  ini: tinifile;
  s: ansistring;
  token: ansistring;
  strIndex: longint;
  keyList: tstringlist;
  i: longint;
  envKeys: tstringlist;
  envKey, envValue: ansistring;
  envKeyPos: longint;
  forbiddenIndex: longint;
begin
  result := false;

  if not FileExists(taskFilename) then begin
    FGLog('Can''t find the task file: ' + taskFilename);
    exit;
  end;
  ini := tinifile.Create(taskFilename);

  { ------------ Task properties ---------------- }
  s := ini.ReadString('task', 'name', '');
  if s <> '' then begin
    _settings.daemonName := s;
    _settings.daemonFilename := _settings.daemonPath + _settings.daemonName;
    _settings.daemonStatusFilename := _settings.daemonFilename + '.gdstatus';
  end;

  s := ini.ReadString('task', 'path', '');
  if s <> '' then begin
    _settings.daemonPath := s;
    { TODO: This wont work on Windows, but we don't need to care at the moment }
    if _settings.daemonPath[length(_settings.daemonPath)] <> '/' then begin
      _settings.daemonPath := _settings.daemonPath + '/';
    end;
    _settings.daemonFilename := _settings.daemonPath + _settings.daemonName;
    _settings.daemonStatusFilename := _settings.daemonFilename + '.gdstatus';
  end;

  s := ini.ReadString('task', 'commandline', '');
  if s <> '' then begin
    { Override passed command line params }
    _settings.params.Clear;
    strIndex := 1;
    while strtok(s, ' ', strIndex, true, token) do begin
      _settings.params.Add(token);
    end;
  end;

  _settings.daemonChangeUser := strtobool(
    ini.ReadString('task', 'changeuser', booltostr(_settings.daemonChangeUser)));
  _settings.daemonUserIDField :=
    ini.ReadString('task', 'userid', _settings.daemonUserIDField);
  _settings.daemonGroupIDField :=
    ini.ReadString('task', 'groupid', _settings.daemonGroupIDField);

  { ---------------- Safety throttle ------------------ }
  _settings.daemonSafetyThrottle := strtobool(
    ini.ReadString('safetythrottle', 'safetythrottle', booltostr(_settings.daemonSafetyThrottle)));
  _settings.throttleTimespan := strtoint(
    ini.ReadString('safetythrottle', 'timespan', inttostr(_settings.throttleTimespan)));
  _settings.throttleCount := strtoint(
    ini.ReadString('safetythrottle', 'maxfailures', inttostr(_settings.throttleCount)));
  _settings.throttleDelay := strtoint(
    ini.ReadString('safetythrottle', 'delay', inttostr(_settings.throttleDelay)));
  _settings.throttleExponential := strtobool(
    ini.ReadString('safetythrottle', 'exponentialbackoff', booltostr(_settings.throttleExponential)));
  _settings.throttleExponentialLimit := strtoint(
    ini.ReadString('safetythrottle', 'exponentialmaxtime', inttostr(_settings.throttleExponentialLimit)));

  { -------------- Notifications ---------------- }
  _settings.daemonEmailOnFailure := strtobool(
    ini.ReadString('notifications', 'sendemail', booltostr(_settings.daemonEmailOnFailure)));
  _settings.emailAddress :=
    ini.ReadString('notifications', 'emailaddresses', _settings.emailAddress); 
  _settings.logTailCount := strtoint(
    ini.ReadString('notifications', 'logtailcount', inttostr(_settings.logTailCount)));

  { ----------------- Logging ------------------ }
  _settings.daemonCaptureOutput := strtobool(
    ini.ReadString('logs', 'capturelogs', booltostr(_settings.daemonCaptureOutput)));
  if strtobool(ini.ReadString('logs', 'systempath', booltostr(_settings.useSystemPaths))) then begin
    _settings.logFile := _system_log_path + '/' + _settings.daemonName + '.log';
  end else begin
    _settings.logFile := _settings.daemonFilename + '.log';
  end;
  _settings.logFile := ini.ReadString('logs', 'custompath', _settings.logFile);

  { -------------- Process control -------------- }
  _settings.daemonRestartOnFailure := strtobool(
    ini.ReadString('control', 'restartonfailure', booltostr(_settings.daemonRestartOnFailure)));
  _settings.daemonUsePIDFile := strtobool(
    ini.ReadString('control', 'usepidfile', booltostr(_settings.daemonUsePIDFile)));
  if strtobool(ini.ReadString('control', 'systempath', booltostr(_settings.useSystemPaths))) then begin
    _settings.daemonPIDFile := _system_pid_path + '/' + _settings.daemonName + '.pid';
  end else begin
    _settings.daemonPIDFile := _settings.daemonFilename + '.pid';
  end;
  _settings.daemonPIDFile := ini.ReadString('control', 'custompath', _settings.daemonPIDFile);
  _settings.daemonStopTimeout := strtoint(
    ini.ReadString('control', 'stoptimeout', inttostr(_settings.daemonStopTimeout)));
  _settings.daemonForceStop := strtobool(
    ini.ReadString('control', 'forcestop', booltostr(_settings.daemonForceStop)));

  { ------------ Environment variables -------------- }

  { To preserve any environment variables the user has already set on the
    command line, read out their keys into a list we can compare with }
  envKeys := tstringlist.Create;
  for i := 0 to _settings.environment.Count - 1 do begin
    { It is assumed the keys are well-formed as they were previously validated
      before they were added to the list }
    envKeyPos := pos('=', _settings.environment.strings[i]);
    envKey := copy(_settings.environment.strings[i], 1, envKeyPos - 1);
    envKeys.Add(envKey);
  end;

  keyList := tstringlist.Create;
  ini.ReadSection('environment', keyList);
  for i := 0 to keyList.Count - 1 do begin
    { Ignore insane keys due to limitation in ReadSection() call }
    s := keyList.strings[i];
    if s <> '' then begin
      s := trim(s);
      if s <> '' then begin
        { Real key }
        s := uppercase(s);
        { Is it already defined? }
        if envKeys.IndexOf(s) <> -1 then begin
          { Do nothing but warn }
          FGLog(funcname + 'Key defined in task but overridden on command line: ' + s);
        end else begin
          { Is it a blacklisted key? }
          for forbiddenIndex := 0 to _forbidden_env_list_count - 1 do begin
            if s = _forbidden_env_list[forbiddenIndex] then begin
              FGLog(funcname + 'Forbidden key: ' + s);
              result := false;
              break;
            end;
          end;
          { All OK }
          envValue := ini.ReadString('environment', keyList.strings[i], '');
          _settings.environment.Add(s + '=' + envValue);
        end;
      end;
    end;
  end;
  freeandnil(keyList);

  { -------------- NRPE -------------- }
  _settings.daemonNRPEAlertRecentlyFailed := strtobool(
    ini.ReadString('nrpe', 'alertrecentlyfailed', booltostr(_settings.daemonNRPEAlertRecentlyFailed)));
  _settings.daemonNRPEStatusMonitoring := strtobool(
    ini.ReadString('nrpe', 'statusmonitoring', booltostr(_settings.daemonNRPEStatusMonitoring)));
  _settings.daemonNRPEEyecatch := ini.ReadString('nrpe', 'eyecatch', _settings.daemonNRPEEyecatch);
  if _settings.daemonNRPEStatusMonitoring and (_settings.daemonNRPEEyecatch = '') then begin
    FGLog(funcname + 'NRPE eyecatch not set, but NRPE advanced monitoring is enabled.');
    result := false;
    exit;
  end;
  _settings.daemonNRPEDefaultStatus := ini.ReadString('nrpe', 'defaultstatus', _settings.daemonNRPEDefaultStatus);
  if not ParseNagiosStatusString(_settings.daemonNRPEDefaultStatus,
                                 _settings.daemonNRPEDefaultStatusID,
                                 _settings.daemonNRPEDefaultStatusString) then begin
    FGLog(funcname + 'Malformatted NRPE default status string: ' + _settings.daemonNRPEDefaultStatus);
    result := false;
    exit;
  end;

  result := true;
end;

{ --------------------------------------------------------------------------
  Print information about what we would do (i.e. the program we will run,
  the log file we will use)
  -------------------------------------------------------------------------- }
procedure PrintInfo;
const
  COLWIDTH = 40;
var
  i: longint;
  s: ansistring;
begin
  writeln('--- Task details ---');
  writeln;
  writeln(PadRight('  Task name: ', COLWIDTH) +
    _settings.daemonName);
  writeln(PadRight('  Program file path: ', COLWIDTH) +
    _settings.daemonFilename);
  writeln(PadRight('  Program directory: ', COLWIDTH) +
    _settings.daemonPath);
  writeln(PadRight('  nagios status file: ', COLWIDTH) +
    _settings.daemonStatusFilename);
  writeln(PadRight('  PID file: ', COLWIDTH) +
    _settings.daemonPIDFile);
  writeln(PadRight('  Log file: ', COLWIDTH) +
    _settings.logFile);
  writeln(PadRight('  Capture task output to log file: ', COLWIDTH) +
    booltostr(_settings.daemonCaptureOutput, true));
  writeln(PadRight('  Control with PID file: ', COLWIDTH) +
    booltostr(_settings.daemonUsePIDFile, true));
  writeln(PadRight('  Restart task on failure: ', COLWIDTH) +
    booltostr(_settings.daemonRestartOnFailure, true));
  writeln(PadRight('  Run in the foreground: ', COLWIDTH) +
    booltostr(_settings.foregroundMode, true));
  writeln;

  writeln('--- Sandbox ---');
  writeln;
  writeln(PadRight('  Run as a different user/group: ', COLWIDTH) +
    booltostr(_settings.daemonChangeUser, true));
  writeln(PadRight('  User: ', COLWIDTH) +
    _settings.daemonUserIDField);
  writeln(PadRight('  Group: ', COLWIDTH) +
    _settings.daemonGroupIDField);
  writeln;

  writeln('--- Command line parameter list ---');
  writeln;
  for i := 0 to _settings.params.count - 1 do begin
    writeln('  [' + inttostr(i + 1) + '] ' + _settings.params.Strings[i]);
  end;
  writeln;

  writeln('--- Environment variable list ---');
  writeln;
  for i := 0 to _settings.environment.count - 1 do begin
    writeln('  ' + _settings.environment.Strings[i]);
  end;
  writeln;

  writeln('--- Safety throttle configuration ---');
  writeln;
  writeln(PadRight('  Safety throttle: ', COLWIDTH) +
    booltostr(_settings.daemonSafetyThrottle, true));
  writeln(PadRight('  Timespan (seconds): ', COLWIDTH) +
    inttostr(_settings.throttleTimespan));
  s := inttostr(_settings.throttleCount);
  if _settings.throttleCount = -1 then begin
    s := s + ' (unlimited)';
  end;
  writeln(PadRight('  Maximum failures: ', COLWIDTH) + s);
  writeln(PadRight('  Minimum delay (ms): ', COLWIDTH) +
    inttostr(_settings.throttleDelay));
  writeln(PadRight('  Exponential backoff: ', COLWIDTH) +
    booltostr(_settings.throttleExponential, true));
  writeln(PadRight('  Exponential max time: ', COLWIDTH) +
    inttostr(_settings.throttleExponentialLimit));
  writeln;

  writeln('--- Notification configuration ---');
  writeln;
  writeln(PadRight('  Send email on task failure: ', COLWIDTH) +
    booltostr(_settings.daemonEmailOnFailure, true));
  writeln(PadRight('  Email address list: ', COLWIDTH) +
    _settings.emailAddress);
  writeln(PadRight('  Log lines to send (tail): ', COLWIDTH) +
    inttostr(_settings.logTailCount));
  writeln;

  writeln('--- NRPE (nagios monitoring) configuration ---');
  writeln;
  writeln(PadRight('  Advanced monitoring enabled: ', COLWIDTH) +
    booltostr(_settings.daemonNRPEStatusMonitoring, true));
  writeln(PadRight('  Send WARNING for recent failures: ', COLWIDTH) +
    booltostr(_settings.daemonNRPEAlertRecentlyFailed, true));
  writeln(PadRight('  Eyecatch string: ', COLWIDTH) +
    _settings.daemonNRPEEyecatch);
  writeln(PadRight('  Initial nagios status: ', COLWIDTH) +
    _settings.daemonNRPEDefaultStatus);
end;

{ --------------------------------------------------------------------------
  Check the passed command line arguments and act on them.
  Return TRUE if the daemon can start, FALSE if it needs to exit.
  -------------------------------------------------------------------------- }
function CheckCommandLine: boolean;
var
  i: longint;
  s: ansistring;
  foundAction: boolean;
  optionalIndex: longint;
  tempString: ansistring;
  useTaskFile: boolean;
begin
  result := false;
  optionalIndex := 4;
  useTaskFile := false;

  if paramcount < 2 then begin
    PrintHelp;
    exit;
  end else begin
    { Parse action }
    s := lowercase(paramstr(1));
    foundAction := false;
    for i := 0 to _action_list_count - 1 do begin
      if s = _action_list[i] then begin
        _settings.action := eAction(i);
        foundAction := true;
        break;
      end;
    end;
    if not foundAction then begin
      FGLog('Unknown action: ' + s);
      exit;
    end;

    { Parse flags }
    if paramstr(2)[1] = '-' then begin
      _settings.firstParamArgIndex := 4;
      s := paramstr(2);
      for i := 2 to length(s) do begin
        case s[i] of
          'h': begin { Show help }
            PrintHelp;
            exit;
          end;
          'f': begin { Run in the foreground }
            _settings.foregroundMode := true;
          end;
          'r': begin { Restart if failed }
            _settings.daemonRestartOnFailure := true;
          end;
          'n': begin { Disable restart throttling }
            _settings.daemonSafetyThrottle := false;
          end;
          'x': begin { Don't use PID file }
            _settings.daemonUsePIDFile := false;
            FGLog('Warning: -x specified, not using a PID file, uncontrolled daemon');
          end;
          't': begin { Use task file to configure task }
            useTaskFile := true;
          end;
          'l': begin { Capture daemon output to the log }
            _settings.daemonCaptureOutput := true;
          end;
          'e': begin { Send an email on failure }
            _settings.daemonEmailOnFailure := true;
            if paramcount < optionalIndex then begin
              FGLog('Flag ''e'' passed, but not enough command line parameters specified');
              exit;
            end else begin
              inc(_settings.firstParamArgIndex);
              _settings.emailAddress := paramstr(optionalIndex);
              inc(optionalIndex);
              { Make sure it actually looks like an email address }
              if pos('@', _settings.emailAddress) = 0 then begin
                FGLog('The email address you supplied isn''t valid.');
                exit;
              end;
            end;
          end;
          'v': begin { Set environment variables for the task }
            _settings.daemonEmailOnFailure := true;
            if paramcount < optionalIndex then begin
              FGLog('Flag ''v'' passed, but not enough command line parameters specified.');
              exit;
            end else begin
              inc(_settings.firstParamArgIndex);
              tempString := paramstr(optionalIndex);
              inc(optionalIndex);
              { Make sure it looks like an environment variable list }
              if pos('=', tempString) = 0 then begin
                FGLog('The environment variable list you supplied isn''t valid.');
                exit;
              end else begin
                if not ParseEnvironmentList(tempString) then begin
                  FGLog('The environment variable list you supplied isn''t valid.');
                  exit;
                end;
              end;
            end;
          end;
          's': begin { Use system paths }
            _settings.useSystemPaths := true;
          end;
        else
          FGLog('Unknown flag: ' + s[i]);
          exit;
        end;
      end;
      _settings.daemonName := paramstr(3);
    end else begin
      _settings.firstParamArgIndex := 3;
      _settings.daemonName := paramstr(2);
    end;
  end;

  { Build parameter list }
  for i := _settings.firstParamArgIndex to paramcount do begin
    _settings.params.Add(paramstr(i));
  end;
  
  { Setup the programname and associated paths }
  _settings.daemonPath := extractfilepath(paramstr(0));
  _settings.daemonFilename := _settings.daemonPath + _settings.daemonName;
  _settings.daemonStatusFilename := _settings.daemonFilename + '.gdstatus';

  if _settings.useSystemPaths then begin
    _settings.daemonPIDFile := _system_pid_path + '/' +
      _settings.daemonName + '.pid';
    _settings.logFile := _system_log_path + '/' +
      _settings.daemonName + '.log';
  end else begin
    _settings.daemonPIDFile := _settings.daemonFilename + '.pid';
    _settings.logFile := _settings.daemonFilename + '.log';
  end;

  { Process the task file - these settings may override settings from the
    command line or those determined above for the paths }
  if useTaskFile then begin
    if not ProcessTaskFile(_settings.daemonFilename + '.task') then begin
      FGLog('Failed to process the task file - stopping');
      exit;
    end;
  end;

  { Verify that the files and paths we will be working with are sane }
  if not directoryexists(_settings.daemonPath) then begin
    FGLog('(probably a bug) Couldn''t find the program path: ' + _settings.daemonPath);
    exit;
  end;
  { On linux, fileexists returns true for a directory which is silly, so check that }
  if (not fileexists(_settings.daemonFilename)) or directoryexists(_settings.daemonFilename)  then begin
    FGLog('Couldn''t find the program to daemonise: ' + _settings.daemonFilename);
    exit;
  end;
  s := extractfilepath(_settings.logFile);
  if not directoryexists(s) then begin
    FGLog('The log directory does not exist: ' + s);
    exit;
  end;
  s := extractfilepath(_settings.daemonPIDFile);
  if not directoryexists(s) then begin
    FGLog('The pid directory does not exist: ' + s);
    exit;
  end;

  result := true;
end;

{ --------------------------------------------------------------------------
  Display the program help
  -------------------------------------------------------------------------- }
procedure PrintHelp;
begin
  writeln('godaemon - run a program as a daemon');
  writeln('Version: ' + _version + ' (compiled ' + _compiledate + ')');
  writeln;
  writeln('Usage  : godaemon <action> [-flags] [@]<programname> [emailaddress[,emailaddress]] [VAR=VALUE[,VAR2=VALUE]] [program args]');
  writeln('Example: godaemon start -rle my_go_program my.email@example.com some-param-here');
  writeln('         godaemon stop my_go_program');
  writeln('         godaemon start -rlv my_go_program ENVVAR=VALUE some-param-here');
  writeln('         godaemon start -lt taskname');
  writeln;
  writeln('Actions are:');
  writeln('  start: Start a task');
  writeln('  stop: Stop a running task.');
  writeln('  force-stop: Force a running task to stop.');
  writeln('  status: Get status of a task.');
  writeln('  nagios-status: Act as a nagios plugin and report status of task (use with NRPE)');
  writeln('  info: Display a report on how godaemon will launch this task');
  writeln('  reload: Send SIGHUP to the task');
  writeln;
  writeln('  For scripts, the exit code is 0 if the task is running/was started, 1 if it is not running/didn''t start or was stopped');
  writeln('  For foreground tasks, the only action that works is ''start''.');
  writeln;
  writeln('Flags are:');
  writeln('  h: Display this help text');
  writeln('  f: Run in the foreground for debugging purposes');
  writeln('  r: Restart the program if it stops or crashes (it will be logged)');
  writeln('  n: Disable restart throttling/restart protection (if -r is used)');
  writeln('     Warning: This will allow godaemon to restart the program repeatedly if it');
  writeln('              keeps crashing, without delay. The default behaviour if you don''t');
  writeln('              specify -n is to restart it after a few seconds, and if it crashes');
  writeln('              too often, then after a few minutes.');
  writeln('  x: Don''t use a PID file to control the daemon.');
  writeln('     With this flag, you will not be able to use the "stop" or "status" actions,');
  writeln('     and you will be able to start more than 1 instance of the same task.');
  writeln('  l: Capture the output of the program and write it to the godaemon log.');
  writeln('     Usually you want to use this option.');
  writeln('  e: Send an email to <emailaddress> if the program fails and is restarted.');
  writeln('     You can specify multiple email addresses by seperating them with ","');
  writeln('  s: Use system paths for files rather than the program directory:');
  writeln('     pid files -> ' + _system_pid_path);
  writeln('     log files -> ' + _system_log_path);
  writeln('  v: Pass environment variables to the task.');
  writeln('     If you need to pass many environment variables or complicated settings, it may');
  writeln('     be better to use a task setting file.');
  writeln('  t: Use task settings file to define settings and environment variables for the task.');
  writeln('     Please see the documentation for more information about task setting files.');
end;

{ --------------------------------------------------------------------------
  Parse the supplied environment variable list <envVars>, verify them and
  add them to the task environment variables (global settings).
  Return TRUE if everything was OK, FALSE if the list could not be parsed.
  -------------------------------------------------------------------------- }
function ParseEnvironmentList(envVars: string): boolean;
const
  funcname = 'ParseEnvironmentList(): ';
var
  strIndex: longint;
  token: ansistring;
  envSeperatorIndex: longint;
  envKeys: tstringlist;
  envKey, envValue: ansistring;
  forbiddenIndex: longint;
begin
  envKeys := tstringlist.Create;
  _settings.environment.Clear;
  strIndex := 1;
  result := true;

  while strtok(envVars, ',', strIndex, false, token) do begin
    { Sanity check it }
    envSeperatorIndex := pos('=', token);
    if (envSeperatorIndex < 1) or (envSeperatorIndex = (length(token) - 1)) then begin
      FGLog(funcname + 'Unparseable environment variable definition: ' + token);
      result := false;
      break;
    end;
    envKey := uppercase(copy(token, 1, envSeperatorIndex - 1));
    envValue := copy(token, envSeperatorIndex + 1, length(token) - envSeperatorIndex);
    
    { Dupe check }
    if envKeys.IndexOf(envKey) <> -1 then begin
      FGLog(funcname + 'Duplicate environment variable key: ' + envKey);
      result := false;
      break;
    end;

    { Forbidden keys check }
    for forbiddenIndex := 0 to _forbidden_env_list_count - 1 do begin
      if envKey = _forbidden_env_list[forbiddenIndex] then begin
        FGLog(funcname + 'Forbidden key: ' + envKey);
        result := false;
        break;
      end;
    end;

    envKeys.Add(envKey);
    _settings.environment.Add(envKey + '=' + envValue);
  end;

  FreeAndNil(envKeys);
end;

end.
