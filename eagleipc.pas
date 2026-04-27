unit eagleipc;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, utils, simpleipc, duplexipc;

function isAnotherInstanceRunning: boolean;

// DuplexIPC approach (receive-and-send server)
procedure StartEagleDuplexIPCServer;
procedure StopEagleDuplexIPCServer;
procedure PollEagleDuplexIPC;
procedure SetEagleDuplexIPCMessageHandler(const AHandler: TIPCMessageEvent);

// SimpleIPC-only fallback approach (receive-only server)
procedure StartEagleSimpleIPCServer;
procedure StopEagleSimpleIPCServer;
procedure PollEagleSimpleIPC;
procedure SetEagleSimpleIPCMessageHandler(const AHandler: TIPCMessageEvent);

const
  EAGLE_IPC_LOCAL_SERVER_ID  = 'eagle_local';
  EAGLE_IPC_REMOTE_CLIENT_ID = 'eagle_remote';

var
  EagleSimpleIPCMessageHandler: TIPCMessageEvent;

  EagleSimpleIPCServer: TSimpleIPCServer;
  EagleDuplexIPCServer: TDuplexIPC;

implementation

function isAnotherInstanceRunning: boolean;
var
  client: TSimpleIPCClient;
begin
  client := TSimpleIPCClient.Create(nil);
  try
    client.ServerID := EAGLE_IPC_LOCAL_SERVER_ID;
    Result := client.ServerRunning;
    if Result then begin
      client.Connect;
      client.SendStringMessage('show');
    end;
  finally
    client.Free;
  end;
end;

procedure StartEagleDuplexIPCServer;
begin
  if Assigned(EagleDuplexIPCServer) then
    Exit;

  EagleDuplexIPCServer := TDuplexIPC.Create(nil);
  EagleDuplexIPCServer.Configure(EAGLE_IPC_LOCAL_SERVER_ID, EAGLE_IPC_REMOTE_CLIENT_ID);
  EagleDuplexIPCServer.Start;
end;

procedure StopEagleDuplexIPCServer;
begin
  if not Assigned(EagleDuplexIPCServer) then
    Exit;

  if EagleDuplexIPCServer.Active then
    EagleDuplexIPCServer.Stop;

  FreeAndNil(EagleDuplexIPCServer);
end;

procedure PollEagleDuplexIPC;
begin
  if Assigned(EagleDuplexIPCServer) then
    EagleDuplexIPCServer.Poll;
end;

procedure SetEagleDuplexIPCMessageHandler(const AHandler: TIPCMessageEvent);
begin
  if Assigned(EagleDuplexIPCServer) then
    EagleDuplexIPCServer.OnMessage := AHandler;
end;

procedure StartEagleSimpleIPCServer;
begin
  if Assigned(EagleSimpleIPCServer) then
    Exit;

  EagleSimpleIPCServer := TSimpleIPCServer.Create(nil);
  EagleSimpleIPCServer.ServerID := EAGLE_IPC_LOCAL_SERVER_ID;
  EagleSimpleIPCServer.Global := True;
  EagleSimpleIPCServer.StartServer;
end;

procedure StopEagleSimpleIPCServer;
begin
  if not Assigned(EagleSimpleIPCServer) then
    Exit;

  if EagleSimpleIPCServer.Active then
    EagleSimpleIPCServer.StopServer;

  FreeAndNil(EagleSimpleIPCServer);
end;

procedure PollEagleSimpleIPC;
begin
  if not Assigned(EagleSimpleIPCServer) then
    Exit;

  while EagleSimpleIPCServer.PeekMessage(0, True) do begin
    if Assigned(EagleSimpleIPCMessageHandler) then
      EagleSimpleIPCMessageHandler(EagleSimpleIPCServer, EagleSimpleIPCServer.StringMessage);
  end;
end;

procedure SetEagleSimpleIPCMessageHandler(const AHandler: TIPCMessageEvent);
begin
  EagleSimpleIPCMessageHandler := AHandler;
end;

initialization
  EagleDuplexIPCServer := nil;
  EagleSimpleIPCServer := nil;
  EagleSimpleIPCMessageHandler := nil;

finalization
  StopEagleDuplexIPCServer;
  StopEagleSimpleIPCServer;

end.
