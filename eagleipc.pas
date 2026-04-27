unit eagleipc;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, utils, simpleipc, duplexipc;

const
  EAGLE_IPC_LOCAL_SERVER_ID = 'eagle_local';
  EAGLE_IPC_REMOTE_CLIENT_ID = 'eagle_remote';

function isAnotherInstanceRunning: boolean;

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

end.

