unit duplexipc;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, simpleipc;

type
  TDuplexIPCMessageEvent = procedure(Sender: TObject; const AMessage: string) of object;
  TDuplexIPCErrorEvent = procedure(Sender: TObject; const AMessage: string;
    const AException: Exception) of object;

  { TDuplexIPC }
  TDuplexIPC = class(TComponent)
  private
    FClient: TSimpleIPCClient;
    FServer: TSimpleIPCServer;
    FLocalServerID: string;
    FRemoteServerID: string;
    FActive: boolean;

    FOnMessage: TDuplexIPCMessageEvent;
    FOnError: TDuplexIPCErrorEvent;

    procedure RaiseError(const AMessage: string; const AException: Exception);
    function EnsureClientConnected: boolean;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    procedure Configure(const ALocalServerID, ARemoteServerID: string);
    procedure Start;
    procedure Stop;

    function Poll: integer;
    function SendString(const AMessage: string): boolean;

    function RemoteServerRunning: boolean;

    property Active: boolean read FActive;
    property LocalServerID: string read FLocalServerID;
    property RemoteServerID: string read FRemoteServerID;

    property OnMessage: TDuplexIPCMessageEvent read FOnMessage write FOnMessage;
    property OnError: TDuplexIPCErrorEvent read FOnError write FOnError;
  end;

implementation

{ TDuplexIPC }

constructor TDuplexIPC.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);

  FServer := TSimpleIPCServer.Create(nil);
  FClient := TSimpleIPCClient.Create(nil);

  FActive := False;
end;

destructor TDuplexIPC.Destroy;
begin
  Stop;

  FClient.Free;
  FServer.Free;

  inherited Destroy;
end;

procedure TDuplexIPC.Configure(const ALocalServerID, ARemoteServerID: string);
begin
  if FActive then
    raise Exception.Create('Cannot reconfigure duplex IPC while active');

  if Trim(ALocalServerID) = '' then
    raise Exception.Create('LocalServerID must not be empty');

  if Trim(ARemoteServerID) = '' then
    raise Exception.Create('RemoteServerID must not be empty');

  FLocalServerID := ALocalServerID;
  FRemoteServerID := ARemoteServerID;
end;

procedure TDuplexIPC.Start;
begin
  if FActive then
    Exit;

  if Trim(FLocalServerID) = '' then
    raise Exception.Create('Call Configure before Start (LocalServerID is empty)');

  if Trim(FRemoteServerID) = '' then
    raise Exception.Create('Call Configure before Start (RemoteServerID is empty)');

  FServer.ServerID := FLocalServerID;
  FServer.Global := True;
  FServer.StartServer;

  FClient.ServerID := FRemoteServerID;
  EnsureClientConnected;

  FActive := True;
end;

procedure TDuplexIPC.Stop;
begin
  if not FActive then
    Exit;

  if FClient.Active then begin
    try
      FClient.Disconnect;
    except
      on E: Exception do
        RaiseError('Disconnect failed', E);
    end;
  end;

  if FServer.Active then begin
    try
      FServer.StopServer;
    except
      on E: Exception do
        RaiseError('StopServer failed', E);
    end;
  end;

  FActive := False;
end;

function TDuplexIPC.Poll: integer;
var
  received: integer;
begin
  Result := 0;
  if not FActive then
    Exit;

  received := 0;

  while FServer.PeekMessage(0, True) do begin
    try
      Inc(received);

      if Assigned(FOnMessage) then
        FOnMessage(Self, FServer.StringMessage);
    except
      on E: Exception do
        RaiseError('Failed to read incoming message', E);
    end;
  end;

  Result := received;
end;

function TDuplexIPC.SendString(const AMessage: string): boolean;
begin
  Result := False;

  if not FActive then
    raise Exception.Create('Duplex IPC is not active');

  if not EnsureClientConnected then
    Exit;

  try
    FClient.SendStringMessage(AMessage);
    Result := True;
  except
    on E: Exception do
      RaiseError('Failed to send message', E);
  end;
end;

function TDuplexIPC.RemoteServerRunning: boolean;
begin
  Result := False;

  if Trim(FRemoteServerID) = '' then
    Exit;

  FClient.ServerID := FRemoteServerID;

  try
    Result := FClient.ServerRunning;
  except
    on E: Exception do
      RaiseError('Failed to check remote server state', E);
  end;
end;

procedure TDuplexIPC.RaiseError(const AMessage: string; const AException: Exception);
begin
  if Assigned(FOnError) then
    FOnError(Self, AMessage, AException);
end;

function TDuplexIPC.EnsureClientConnected: boolean;
begin
  Result := False;

  if Trim(FRemoteServerID) = '' then
    Exit;

  FClient.ServerID := FRemoteServerID;

  if not FClient.ServerRunning then
    Exit;

  if not FClient.Active then begin
    try
      FClient.Connect;
    except
      on E: Exception do begin
        RaiseError('Connect failed', E);
        Exit;
      end;
    end;
  end;

  Result := True;
end;

end.
