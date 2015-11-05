{ --------------------------------------------------------------------------
  godaemon

  IPC pipe unit
  - tipcPipe: interprocess communication pipe class
  - tipcPipeEndpoint: Endpoint of a tipcPipe

  Used for 2-way communication between a parent and child process

  Copyright (c) Michael Nixon 2015.
  Please see the LICENSE file for licensing information.
  -------------------------------------------------------------------------- }

{ --------------------------------------------------------------------------
  -------------------------------------------------------------------------- }
unit ipcpipe;

interface

uses baseunix, unix, unixutil, sockets, sysutils, classes, pipes;

const
  IPCPIPE_MAX_PACKET_SIZE = 65536;
  { message: len(packet) + packet }
  IPCPIPE_MAX_MESSAGE_SIZE = 4 + IPCPIPE_MAX_PACKET_SIZE;

type
  rByteArray = array[0..99999] of byte;
  pByteArray = ^rByteArray;

  tipcPipeEndpoint = class;
  { A class to create a pair of pipe endpoints (tipcPipeEndpoint) for IPC }
  tipcPipe = class(tobject)
    private
      parentEndpoint: tipcPipeEndpoint;
      childEndpoint: tipcPipeEndpoint;
    public
      constructor Create;
      destructor Destroy; override;
      function CreateEndpoints: boolean;
      function GetParentEndpoint: tipcPipeEndpoint;
      function GetChildEndpoint: tipcPipeEndpoint;
  end;

  { An individual endpoint for pipe IPC }
  tipcPipeEndpoint = class(tobject)
    private
      readPipe: TInputPipeStream;
      writePipe: TOutputPipeStream;

      { Holds data read from the readPipe }
      readBuffer: pByteArray;

      { Holds the packet to retrieve via GetPacket }
      tempBuffer: pByteArray;
      tempLength: longint;

      { Used to building output packets }
      workBuffer: pByteArray;

      { Read position in readBuffer }
      readPos: longint;
      { state: true if we have the packet size }
      gotLength: boolean;
      { size of the packet to read in bytes }
      packetLength: longint;
      { state: true if we are ready for a packet to be consumed }
      packetReady: boolean;
    public
      constructor Create(rPipe: TInputPipeStream; wPipe: TOutputPipeStream);
      destructor Destroy; override;
      function Pump: boolean;
      function SendPacket(size: longint; const data): boolean;
      function GetPacket(var size: longint; var data): boolean;
      function PeekPacketLength(var size: longint): boolean;
      function SendString(s: ansistring): boolean;
      function GetString(var s: ansistring): boolean;
  end;

implementation

{ --------------------------------------------------------------------------
  -------------------------------------------------------------------------- }

{ --------------------------------------------------------------------------
  Send a string down the pipe.
  The string length must be at most IPCPIPE_MAX_PACKET_SIZE bytes long.
  TRUE is returned on success, and FALSE is returned on failure.
  -------------------------------------------------------------------------- }
function tipcPipeEndpoint.SendString(s: ansistring): boolean;
begin
  result := self.SendPacket(length(s), s[1]);
end;

{ --------------------------------------------------------------------------
  Retrieve a string from the pipe.
  For this to work, a packet must have been prepared by a call to <Pump>.
  Returns TRUE if a string has been read and returned, or FALSE otherwise.
  -------------------------------------------------------------------------- }
function tipcPipeEndpoint.GetString(var s: ansistring): boolean;
var
  sLength: longint;
begin
  result := false;
  if not self.PeekPacketLength(sLength) then exit;
  setlength(s, sLength);
  result := self.GetPacket(sLength, s[1]);
end;

{ --------------------------------------------------------------------------
  Check for received packets on this pipe endpoint.
  The application must call Pump regularly otherwise the sender may block.
  Returns TRUE if a message is ready to read with GetPacket, or FALSE if
  there are no messages to read.
  If a message is available but the application does not read it before
  calling Pump again, the received message may be lost.
  -------------------------------------------------------------------------- }
function tipcPipeEndpoint.Pump: boolean;
const
  funcname = 'tipcPipeEndpoint.Pump: ';
var
  bytesToRead: longint;
  bytesRead: longint;
  bytesAvailable: longint;
begin
  result := false;

  { Need to get the packet length? }
  if not gotLength then begin
    { Try to get it, drop out if we cannot read it in one go }
    bytesAvailable := self.readPipe.NumBytesAvailable;
    if bytesAvailable < sizeof(longint) then exit;
    bytesRead := self.readPipe.Read(self.packetLength, sizeof(longint));
    if bytesRead <> sizeof(longint) then begin
      { This should never happen }
      raise exception.create(funcname + 'bytesRead <> sizeof(longint)');
      exit;
    end;
    self.gotLength := true;
    self.readPos := 0;
    { Zero byte packets don't need to be processed further }
    if self.packetLength = 0 then begin
      self.tempLength := self.packetLength;
      self.packetReady := true;
      self.gotLength := false;
      result := true;
      exit;
    end;
  end;

  { Reading the packet body }
  bytesToRead := self.packetLength - self.readPos;
  bytesAvailable := self.readPipe.NumBytesAvailable;
  if bytesAvailable < bytesToRead then bytesToRead := bytesAvailable;
  bytesRead := self.readPipe.Read(self.readBuffer^[self.readPos], bytesToRead);
  inc(self.readPos, bytesRead);

  { If we have a full packet, make it available to read }
  if self.readPos >= self.packetLength then begin
    move(self.readBuffer^, self.tempBuffer^, self.packetLength);
    self.tempLength := self.packetLength;
    self.packetReady := true;
    self.gotLength := false;
    result := true;
    exit;
  end;

  { We don't read messages in a loop, the app needs a chance to process them }
end;

{ --------------------------------------------------------------------------
  Retrieve a packet from the pipe.
  For this to work, a packet must have been prepared by a call to <Pump>.
  Returns TRUE if a packet has been read and returned, or FALSE otherwise.
  -------------------------------------------------------------------------- }
function tipcPipeEndpoint.GetPacket(var size: longint; var data): boolean;
begin
  result := false;
  if not self.packetReady then exit;
  size := self.tempLength;
  if size <> 0 then begin
    move(self.tempBuffer^, data, size);
  end;
  self.packetReady := false;
  result := true;
end;

{ --------------------------------------------------------------------------
  Peek the length of a packet waiting to be read.
  For this to work, a packet must have been prepared by a call to <Pump>.
  Returns TRUE if a packet can be read and <size> is valid, or FALSE otherwise.
  -------------------------------------------------------------------------- }
function tipcPipeEndpoint.PeekPacketLength(var size: longint): boolean;
begin
  result := false;
  if not self.packetReady then exit;
  size := self.tempLength;
  result := true;
end;

{ --------------------------------------------------------------------------
  Send a packet of data down the pipe.
  <data> is the packet data, of length <size>.
  Packet data must be at most IPCPIPE_MAX_PACKET_SIZE bytes long.
  TRUE is returned on success, and FALSE is returned on failure.
  -------------------------------------------------------------------------- }
function tipcPipeEndpoint.SendPacket(size: longint; const data): boolean;
var
  bytes: pByteArray;
begin
  result := false;
  if (size > IPCPIPE_MAX_PACKET_SIZE) then exit;

  bytes := pByteArray(@data);
  move(size, self.workBuffer^[0], sizeof(longint));
  if size > 0 then begin
    move(bytes^[0], self.workBuffer^[sizeof(longint)], size);
  end;
  self.writePipe.Write(self.workBuffer^[0], size + sizeof(longint));
  result := true;
end;

{ --------------------------------------------------------------------------
  Return the parent endpoint.
  Returns NIL if the endpoint has not been created.
  -------------------------------------------------------------------------- }
function tipcPipe.GetParentEndpoint: tipcPipeEndpoint;
begin
  result := self.parentEndpoint;
end;

{ --------------------------------------------------------------------------
  Return the child endpoint.
  Returns NIL if the endpoint has not been created.
  -------------------------------------------------------------------------- }
function tipcPipe.GetChildEndpoint: tipcPipeEndpoint;
begin
  result := self.childEndpoint;
end;

{ --------------------------------------------------------------------------
  Create a pair of pipe endpoints.
  Returns TRUE on success, or FALSE on failure.
  This is a seperate function because it is bad design to throw exceptions
  inside the constructor (which would have been the alternative way of
  handling a failure). Failure should only happen if the OS has run out of
  resources (file handles?).
  -------------------------------------------------------------------------- }
function tipcPipe.CreateEndpoints: boolean;
var
  parentPipeRead, childPipeRead: TInputPipeStream;
  parentPipeWrite, childPipeWrite: TOutputPipeStream;
begin
  result := false;

  { Can't create endpoints if we already did earlier }
  if assigned(self.parentEndpoint) or assigned(self.childEndpoint) then exit;

  { Get some plumbing for those endpoints. We create a pair of pipes, because
    each pipe only allows data to be sent in one direction }
  try
    parentPipeRead := nil;
    parentPipeWrite := nil;
    childPipeRead := nil;
    childPipeWrite := nil;
    CreatePipeStreams(parentPipeRead, childPipeWrite);
    CreatePipeStreams(childPipeRead, parentPipeWrite);
  except
    on e: exception do begin
      if assigned(parentPipeRead) then parentPipeRead.Destroy;
      if assigned(parentPipeWrite) then parentPipeRead.Destroy;
      if assigned(childPipeRead) then childPipeRead.Destroy;
      if assigned(childPipeWrite) then childPipeWrite.Destroy;
      exit;
    end;
  end;

  { Build endpoints for the pipes }
  self.parentEndPoint := tipcPipeEndpoint.Create(parentPipeRead, parentPipeWrite);
  self.childEndPoint := tipcPipeEndpoint.Create(childPipeRead, childPipeWrite);

  result := true;
end;

{ --------------------------------------------------------------------------
  tipcPipe constructor
  -------------------------------------------------------------------------- }
constructor tipcPipe.Create;
begin
  inherited Create;
  
  self.parentEndpoint := nil;
  self.childEndpoint := nil;
end;

{ --------------------------------------------------------------------------
  tipcPipe destructor
  CAUTION: This also destroys the pipe endpoint object pair
  -------------------------------------------------------------------------- }
destructor tipcPipe.Destroy;
begin
  if assigned(self.parentEndpoint) then begin
    self.parentEndpoint.Destroy;
    self.parentEndpoint := nil;
  end;
  if assigned(self.childEndpoint) then begin
    self.childEndpoint.Destroy;
    self.childEndpoint := nil;
  end;

  inherited Destroy;
end;

{ --------------------------------------------------------------------------
  tipcPipe constructor
  The user should never create these objects.
  -------------------------------------------------------------------------- }
constructor tipcPipeEndpoint.Create(rPipe: TInputPipeStream; wPipe: TOutputPipeStream);
const
  funcname = 'tipcPipeEndpoint.Create: ';
begin
  inherited Create;

  if (not assigned(rPipe)) or (not assigned(wPipe)) then begin
    raise exception.create(funcname + 'Pipes not assigned');
    exit;
  end;

  self.readPipe := rPipe;
  self.writePipe := wPipe;

  try
    getmem(self.readBuffer, IPCPIPE_MAX_MESSAGE_SIZE);
    getmem(self.workBuffer, IPCPIPE_MAX_MESSAGE_SIZE);
    getmem(self.tempBuffer, IPCPIPE_MAX_MESSAGE_SIZE);
  except
    on e: exception do begin
      raise exception.create(funcname + 'Out of memory allocating buffers');
    end;
  end;

  { Prepare the packet parser }
  readPos := 0;
  gotLength := false;
  packetLength := 0;
  packetReady := false;
end;

{ --------------------------------------------------------------------------
  tipcPipe destructor
  The user should never destroy these objects.
  -------------------------------------------------------------------------- }
destructor tipcPipeEndpoint.Destroy;
begin
  if assigned(self.readPipe) then self.readPipe.Destroy;
  if assigned(self.writePipe) then self.writePipe.Destroy;
  if assigned(self.readBuffer) then freemem(self.readBuffer);
  if assigned(self.workBuffer) then freemem(self.workBuffer);
  if assigned(self.tempBuffer) then freemem(self.tempBuffer);

  inherited Destroy;
end;

end.
