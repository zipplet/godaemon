{ --------------------------------------------------------------------------
  godaemon

  Email notification unit

  Copyright (c) Michael Nixon 2015.
  Please see the LICENSE file for licensing information.
  -------------------------------------------------------------------------- }

{ --------------------------------------------------------------------------
  -------------------------------------------------------------------------- }

unit email;

interface

uses baseunix, unix, unixutil, sockets, sysutils, classes, logger;

{ Non-class functions and procedures }
function SendEmail(recipient, subject, body: ansistring): boolean;
procedure SendEmailForTaskRestart(failcount, faillimit, failtimespan: longint);
procedure SendEmailForTaskCompleteFailure;
function EmailDetailedInformation: ansistring;
procedure SendEmailToList(receipients, subject, body: ansistring);
function EmailLogTail: ansistring;

{ --------------------------------------------------------------------------
  -------------------------------------------------------------------------- }
implementation

uses settings, strutils, process, btime;

{ --------------------------------------------------------------------------
  Email body text: Return the last few lines of the task log 
  -------------------------------------------------------------------------- }
function EmailLogTail: ansistring;
var
  strings: tstringlist;
  i: longint;
  s: ansistring;
begin
  strings := _logger.TailLog(_settings.logTailCount);
  if assigned(strings) then begin
    s := '';
    for i := strings.count - 1 downto 0 do begin
      s := s + strings.Strings[i] + #10;
    end;

    result := '===== Last ' + inttostr(_settings.logTailCount) + ' lines of task log output =====' + #10#10 + s;
  end else begin
    result := '***** UNABLE TO READ LAST LOG OUTPUT *****' + #10;
  end;
end;

{ --------------------------------------------------------------------------
  Send an email to a list of receipients.
  <receipients> is a comma seperated list of email addresses.
  -------------------------------------------------------------------------- }
procedure SendEmailToList(receipients, subject, body: ansistring);
const
  funcname = 'SendEmailToList(): ';
var
  oneAddress: ansistring;
  s: ansistring;
  i: longint;
begin
  s := trim(receipients);
  if length(s) = 0 then begin
    _logger.Log(funcname + 'Receipient list empty?');
    exit;
  end;
  repeat
    i := pos(',', s);
    if i > 0 then begin
      if i > 1 then begin
        oneAddress := copy(s, 1, i - 1);
      end else begin
        oneAddress := '';
      end;
      if i < length(s) then begin
        s := copy(s, i + 1, length(s) - i);
      end else begin
        s := '';
      end;
    end else begin
      oneAddress := s;
      s := '';
    end;
    if oneAddress <> '' then begin
      SendEmail(oneAddress, subject, body);
    end;
  until (i = 0) or (s = '');
end;

{ --------------------------------------------------------------------------
  Send an email, because the task is being restarted.
  <failcount> is the number of times the task has failed in the time span
  <faillimit> is the maximum number of times the task is allowed to fail in
    the time span before godaemon gives up
  <failtimespan> is the time span used to calculating failure limits (the
    time between the first and last failure) in seconds
  -------------------------------------------------------------------------- }
procedure SendEmailForTaskRestart(failcount, faillimit, failtimespan: longint);
begin
  SendEmailToList(_settings.emailAddress,
    '[' + _settings.daemonName + '] - GoDaemon WARNING: Task was restarted',

    '***** GoDaemon Notification *****' + #10#10 +
      'The task "' + _settings.daemonName + '" has failed. GoDaemon will ' +
      'restart the task.' + #10#10 +

    EmailDetailedInformation +
      'Failure count (current timespan): ' + inttostr(failcount) + #10 +
      'Failure limit: ' + inttostr(faillimit) + #10 +
      'Time span: ' + inttostr(failtimespan) + ' seconds' + #10 + #10 +
    EmailLogTail
  );
end;

{ --------------------------------------------------------------------------
  Send an email, because the task has failed and is not going to be
  restarted as it has failed too many times.
  -------------------------------------------------------------------------- }
procedure SendEmailForTaskCompleteFailure;
begin
  SendEmailToList(_settings.emailAddress,
    '[' + _settings.daemonName + '] - GoDaemon CRITICAL: Task has failed',

    '***** GoDaemon CRITICAL Notification *****' + #10#10 +
      'The task "' + _settings.daemonName + '" has failed too many times. ' +
      'GoDaemon will not restart the task. Diagnose the problem and then ' +
      'manually start the task.' + #10#10 +

    EmailDetailedInformation + #10 + #10 + EmailLogTail
  );
end;

{ --------------------------------------------------------------------------
  Email body text: Generate the detailed information section.
  -------------------------------------------------------------------------- }
function EmailDetailedInformation: ansistring;
begin
  result :=
    '===== Detailed information =====' + #10#10 +
    'Task name: ' + _settings.daemonName + #10 +
    'Time: ' + timestring(unixtimeint) + #10;
end;

{ --------------------------------------------------------------------------
  Send an email to <recipient> with subject <subject> and the body text
  containing <bosy>. Uses the system mail program.
  Returns true if the email was successfully handled to the system email
  program for delivery, or false if the system mail program could not be
  invoked or returned an error status.
  -------------------------------------------------------------------------- }
function SendEmail(recipient, subject, body: ansistring): boolean;
const
  emailprogram = '/usr/bin/mail';
  funcname = 'SendEmail(): ';
  emailtimeout = 100;
var
  emailtask: tprocess;
  timer: longint;
begin
  _logger.Log(funcname + 'Sending email to ' + recipient + ' - subject: ' + subject);

  if not fileexists(emailprogram) then begin
    _logger.Log(funcname + 'Can''t find the system email program: ' + emailprogram);
    result := false;
    exit;
  end;

  { Create mail process }
  emailtask := tprocess.Create(nil);
  emailtask.Options := [poUsePipes, poStderrToOutPut];
  emailtask.Executable := emailprogram;
  emailtask.InheritHandles := false;
  emailtask.Parameters.Add('-s');
  emailtask.Parameters.Add(subject);
  emailtask.Parameters.Add(recipient);
  emailtask.Execute;

  { Pass in email body (mail will read from stdin) }
  emailtask.Input.Write(body[1], length(body));
  { Close stdin so that mail knows we don't want to send any more }
  emailtask.CloseInput;

  timer := 0;
  while emailtask.Running do begin
    sleep(100);
    inc(timer);
    if timer > emailtimeout then begin
      emailtask.Terminate(1);
      _logger.Log(funcname + 'Error: Timed out executing mail process');
      result := false;
      exit;
    end;
  end;
  emailtask.Free;
  _logger.Log(funcname + 'Sent email successfully.');

  result := true;
end;

end.
