{ --------------------------------------------------------------------------
  godaemon

  Utility functions unit

  Copyright (c) Michael Nixon 2015.
  Please see the LICENSE file for licensing information.
  -------------------------------------------------------------------------- }

{ --------------------------------------------------------------------------
  -------------------------------------------------------------------------- }

unit utils;

interface

uses baseunix, unix, unixutil, sockets, sysutils, classes, logger, lsignal;

function strtok(s, sep: string; var index: integer; quoted: boolean; var output: string): boolean;
function StringIsInteger(s: ansistring): boolean;

{ --------------------------------------------------------------------------
  -------------------------------------------------------------------------- }
implementation

uses btime, settings, strutils, process, email;

{ ---------------------------------------------------------------------------
  Check if the string <s> is an integer.
  If the string only contains the numbers 0..9, TRUE is returned. Otherwise
  FALSE will be returned.
  --------------------------------------------------------------------------- }
function StringIsInteger(s: ansistring): boolean;
var
  i: longint;
begin
  result := false;

  for i := 1 to length(s) do begin
    if not (char(s[i]) in ['0'..'9']) then begin
      exit;
    end;
  end;

  result := true;
end;

{ ----------------------------------------------------------------------------
  String tokeniser. Returns the next token from the string. <start> is modified
  and always points to the next character to be read, and will > length(s) if
  there are no more tokens. Blank tokens are permitted. <quoted> if true will
  allow strtok to interpret quotes " " to allow spaces inside tokens.
  WARNING: Unsafe! Does not limit length of returned string.
  Boolean result: True = more tokens available, False = End reached.
 ---------------------------------------------------------------------------- }
function strtok(s, sep: string; var index: integer; quoted: boolean; var output: string): boolean;
var
  done, inquote: boolean;
  start: integer;
begin
  inquote := false;
  if index > length(s) then begin
    { Illegal start - no tokens }
    result := false;
    exit;
  end;

  { Loop past any whitespace at the beginning. This is required because when a
    token is found the index points at whitespace. }
  repeat
    done := true;
    if s[index] = sep then begin
      inc(index);
      done := false;
    end;
    if index > length(s) then begin
      { End of string }
      result := false;
      exit;
    end;
  until done;
  start := index;
  done := false;
  repeat
    if index > length(s) then begin
      { Can't possibly be more tokens }
      done := true;
    end else begin
      if quoted then begin
        if s[index] = #34 then begin
          if inquote then inquote := false else inquote := true;
        end;
      end;
      if not inquote then begin
        if s[index] = sep then begin
          done := true;
        end;
      end;
    end;
    inc(index);
  until done;
  output := copy(s, start, index - start - 1);
  result := true;
end;

end.
