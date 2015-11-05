{ --------------------------------------------------------------------------
  godaemon

  Tail unit (read files backwards)

  Copyright (c) Michael Nixon 2015.
  Please see the LICENSE file for licensing information.
  -------------------------------------------------------------------------- }

{ --------------------------------------------------------------------------
  -------------------------------------------------------------------------- }

unit tail;

interface

uses baseunix, unix, unixutil, sockets, sysutils, classes, logger;

{ Non-class functions and procedures }
function TailFile(filename: ansistring; lines: longint): tstringlist;

{ --------------------------------------------------------------------------
  -------------------------------------------------------------------------- }
implementation

uses settings, strutils, process, btime;

{ --------------------------------------------------------------------------
  Return the last <lines> lines from the file <filename>.
  Returns a tstringlist containing the lines, or nil if the file could not
  be opened or could not be read properly.
  -------------------------------------------------------------------------- }
function TailFile(filename: ansistring; lines: longint): tstringlist;
const
  maxlinelength = 8192;
var
  handle: file;
  strings: tstringlist;
  endpos: longint;
  count: longint;
  readbuffer: array[0..maxlinelength - 1] of byte;
  readpos: longint;
  readcount: longint;
  scan: longint;
  linefound: boolean;
  s: ansistring;
  linelen: longint;
begin
  try
    filemode := fmOpenRead;
    assignfile(handle, filename);
    reset(handle, 1);
  except
    on e: exception do begin
      result := nil;
      exit;
    end;
  end;

  strings := tstringlist.create;
  endpos := filesize(handle);
  for count := 1 to lines do begin
    { Get next block }
    readpos := endpos - maxlinelength;
    if readpos < 0 then begin
      readpos := 0;
      readcount := endpos;
    end else begin
      readcount := maxlinelength;
    end;
    seek(handle, readpos);
    blockread(handle, readbuffer[0], readcount);

    { Scan backwards for linefeed }
    linefound := false;
    for scan := readcount - 1 downto 0 do begin
      if readbuffer[scan] = 10 then begin
        { Line found }
        linefound := true;
        linelen := readcount - scan;
        if linelen > 1 then begin
          { Skip LF }
          setlength(s, linelen - 1);
          move(readbuffer[scan + 1], s[1], linelen - 1);
          strings.Add(s);
        end else begin
          { Empty line }
          //strings.Add('');
        end;
        dec(endpos, linelen);
        break;
      end;
    end;

    { Abort if line is too long or no more lines in file }
    if not linefound then begin
      if readcount < maxlinelength then begin
        { No more lines so grab the last }
        setlength(s, readcount);
        move(readbuffer[0], s[1], readcount);
        strings.Add(s);
        result := strings;
      end else begin
        result := nil;
      end;
      closefile(handle);
      exit;
    end;
  end;

  closefile(handle);
  result := strings;
end;

end.
