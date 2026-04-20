program eagle;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  {$IFDEF HASAMIGA}
  athreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, Dialogs, SysUtils, BaseUnix,
  TimeCheck,
  main, EagleDB
  { you can add units after this };

{$R *.res}

const
  F_WRLCK = 1;
  F_UNLCK = 2;

var
  InstanceLockHandle: cint = -1;
  InstanceLock: FLock;

function AcquireSingleInstanceLock: Boolean;
var
  lockFilePath: string;
begin
  lockFilePath := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'eagle.lock';
  InstanceLockHandle := fpOpen(PChar(lockFilePath), O_CREAT or O_RDWR, &666);
  if InstanceLockHandle = -1 then
    Exit(False);

  FillChar(InstanceLock, SizeOf(InstanceLock), 0);
  InstanceLock.l_type := F_WRLCK;
  InstanceLock.l_whence := SEEK_SET;
  InstanceLock.l_start := 0;
  InstanceLock.l_len := 0;

  Result := FpFcntl(InstanceLockHandle, F_SETLK, InstanceLock) <> -1;
  if not Result then begin
    fpClose(InstanceLockHandle);
    InstanceLockHandle := -1;
  end;
end;

procedure ReleaseSingleInstanceLock;
begin
  if InstanceLockHandle = -1 then
    Exit;

  InstanceLock.l_type := F_UNLCK;
  FpFcntl(InstanceLockHandle, F_SETLK, InstanceLock);
  fpClose(InstanceLockHandle);
  InstanceLockHandle := -1;
end;

begin
  RequireDerivedFormResource:=True;
  Application.Scaled:=True;
  {$PUSH}{$WARN 5044 OFF}
  Application.MainFormOnTaskbar:=True;
  {$POP}
  Application.Initialize;

  if not AcquireSingleInstanceLock then begin
    MessageDlg('Eagle is already watching.', mtInformation, [mbOK], 0);
    Halt;
  end;

  Application.CreateForm(TForm1, Form1);
  try
    Application.Run;
  finally
    ReleaseSingleInstanceLock;
  end;
end.

