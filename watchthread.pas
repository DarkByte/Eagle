unit watchthread;

{$mode ObjFPC}{$H+}

interface

uses
  utils,
  Classes, SysUtils, BaseUnix, Generics.Collections;

const
  IN_MODIFY      = $00000002;
  IN_ATTRIB      = $00000004;
  IN_ISDIR       = $40000000;
  IN_MOVED_FROM  = $00000040;
  IN_MOVED_TO    = $00000080;
  IN_CREATE      = $00000100;
  IN_DELETE      = $00000200;

  DIR_WATCH_MASK = IN_CREATE or IN_MODIFY or IN_DELETE or IN_MOVED_FROM or IN_MOVED_TO or IN_ATTRIB;

  SHOULD_CONTINUE = 1;
  SHOULD_BREAK = 2;
  SHOULD_PROCESS = 3;

type
  TWatchEventKind = (wekCreate, wekModify, wekDelete, wekRename, wekAttributeChange);
  TWatchEventHandler = procedure(const APath: string) of object;
  TWatchRenameEventHandler = procedure(const AOldPath, ANewPath: string) of object;
  TWatchLogHandler = procedure(const AMessage: string) of object;
  TWatchInitialScanHandler = procedure(const AFiles: array of TSearchRec) of object;

  pinotify_event = ^inotify_event;
  inotify_event = record
    wd: cint;
    mask: cuint32;
    cookie: cuint32;
    len: cuint32;
    name: array[0..0] of char;
  end;

  { TWatchThread }
  TWatchThread = class(TThread)
  private
    eventStreamHandle: cint;

    FPaths: array of string;
    FFoundFiles: array of TSearchRec;
    FPendingInitialScanFiles: array of TSearchRec;
    FWatchedFolders: specialize TDictionary<cint, string>;
    FPendingDirMoves: specialize TDictionary<cuint32, string>;

    FOnCreate: TWatchEventHandler;
    FOnModify: TWatchEventHandler;
    FOnDelete: TWatchEventHandler;
    FOnRename: TWatchRenameEventHandler;
    FOnAttributeChange: TWatchEventHandler;
    FOnLog: TWatchLogHandler;
    FOnInitialScan: TWatchInitialScanHandler;

    FPendingLogMessage: string;

    function AddWatchDir(const dirPath: string): Boolean;
    procedure AddWatchRecursive(fd: cint; const rootPath: string);

    function GetWatchPath(wd: cint): string;
    function BuildChildPath(const parentPath, name: string): string;

    procedure AddPendingDirMove(ACookie: cuint32; const APath: string);
    function ExtractPendingDirMove(ACookie: cuint32; out APath: string): Boolean;

    procedure RenameWatchPathPrefix(const AOldPrefix, ANewPrefix: string);

    procedure ProcessEvents;
    procedure DispatchLog;
    procedure DispatchInitialScan;
    procedure QueueLog(const AMessage: string);
    procedure QueueInitialScan(const AFiles: array of TSearchRec);

    function GetEventFileName(event: pinotify_event): string;

    function ShouldProcess(bytesRead: cint): cint;
    procedure ProcessFolderEvents(event: pinotify_event; fullPath: string);
    procedure ProcessFileEvents(event: pinotify_event; fullPath: string);
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;

    procedure AddWatchPath(const APath: string);

    procedure SetOnCreate(const AHandler: TWatchEventHandler);
    procedure SetOnModify(const AHandler: TWatchEventHandler);
    procedure SetOnDelete(const AHandler: TWatchEventHandler);
    procedure SetOnRename(const AHandler: TWatchRenameEventHandler);
    procedure SetOnAttributeChange(const AHandler: TWatchEventHandler);

    procedure SetOnLog(const AHandler: TWatchLogHandler);
    procedure SetOnInitialScan(const AHandler: TWatchInitialScanHandler);
  end;

implementation

function inotify_init: cint; cdecl; external 'libc' name 'inotify_init';
function inotify_add_watch(fd: cint; pathname: PChar; mask: cuint32): cint; cdecl; external 'libc' name 'inotify_add_watch';
function inotify_rm_watch(fd: cint; wd: cint): cint; cdecl; external 'libc' name 'inotify_rm_watch';

{ TWatchThread }

constructor TWatchThread.Create;
begin
  FWatchedFolders := specialize TDictionary<cint, string>.Create;
  FPendingDirMoves := specialize TDictionary<cuint32, string>.Create;

  inherited Create(True);
end;

destructor TWatchThread.Destroy;
begin
  FWatchedFolders.Free;
  FPendingDirMoves.Free;

  inherited Destroy;
end;

procedure TWatchThread.AddWatchPath(const APath: string);
var
  pathCount: Integer;
begin
  pathCount := Length(FPaths);
  SetLength(FPaths, pathCount + 1);
  FPaths[pathCount] := ExcludeTrailingPathDelimiter(APath);
end;

procedure TWatchThread.SetOnCreate(const AHandler: TWatchEventHandler);
begin
  FOnCreate := AHandler;
end;

procedure TWatchThread.SetOnModify(const AHandler: TWatchEventHandler);
begin
  FOnModify := AHandler;
end;

procedure TWatchThread.SetOnDelete(const AHandler: TWatchEventHandler);
begin
  FOnDelete := AHandler;
end;

procedure TWatchThread.SetOnRename(const AHandler: TWatchRenameEventHandler);
begin
  FOnRename := AHandler;
end;

procedure TWatchThread.SetOnAttributeChange(const AHandler: TWatchEventHandler);
begin
  FOnAttributeChange := AHandler;
end;

procedure TWatchThread.SetOnLog(const AHandler: TWatchLogHandler);
begin
  FOnLog := AHandler;
end;

procedure TWatchThread.SetOnInitialScan(const AHandler: TWatchInitialScanHandler);
begin
  FOnInitialScan := AHandler;
end;

function TWatchThread.AddWatchDir(const dirPath: string): Boolean;
var
  wd: cint;
  existingPath: string;
begin
  Result := False;

  for existingPath in FWatchedFolders.Values do
    if SameText(existingPath, dirPath) then begin
      Result := True;
      Exit;
    end;

  wd := inotify_add_watch(eventStreamHandle, PChar(dirPath), DIR_WATCH_MASK);
  if wd < 0 then
    Exit;

  FWatchedFolders.AddOrSetValue(wd, dirPath);
  Result := True;
end;

procedure TWatchThread.AddWatchRecursive(fd: cint; const rootPath: string);
var
  sr: TSearchRec;
  fileEntry: TSearchRec;
  fileCount: Integer;
  childPath: string;
begin
  AddWatchDir(rootPath);

  if FindFirst(IncludeTrailingPathDelimiter(rootPath) + '*', faAnyFile, sr) = 0 then
  try
    repeat
      if (sr.Name = '.') or (sr.Name = '..')
        then Continue;

      childPath := IncludeTrailingPathDelimiter(rootPath) + sr.Name;
      if (sr.Attr and faDirectory) <> 0 then begin
        AddWatchRecursive(fd, childPath);
        Continue;
      end;

      fileEntry := sr;
      fileEntry.Name := childPath;
      fileCount := Length(FFoundFiles);
      SetLength(FFoundFiles, fileCount + 1);
      FFoundFiles[fileCount] := fileEntry;
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
end;

function TWatchThread.GetEventFileName(event: pinotify_event): string;
var
  rawNameLen: SizeUInt;
begin
  Result := '';

  if event^.len > 0 then begin
    rawNameLen := StrLen(PChar(@event^.name[0]));
    SetLength(Result, rawNameLen);

    if rawNameLen > 0 then
      Move(event^.name[0], Result[1], rawNameLen);
  end;
end;

function TWatchThread.GetWatchPath(wd: cint): string;
begin
  Result := '';
  FWatchedFolders.TryGetValue(wd, Result);
end;

function TWatchThread.BuildChildPath(const parentPath, name: string): string;
begin
  if parentPath = ''
    then Exit(name);

  if name = ''
    then Exit(parentPath);

  Result := IncludeTrailingPathDelimiter(parentPath) + name;
end;

procedure TWatchThread.AddPendingDirMove(ACookie: cuint32; const APath: string);
begin
  if ACookie = 0
    then Exit;

  FPendingDirMoves.AddOrSetValue(ACookie, APath);
end;

function TWatchThread.ExtractPendingDirMove(ACookie: cuint32; out APath: string): Boolean;
begin
  APath := '';
  if ACookie = 0 then
    Exit;

  Result := FPendingDirMoves.TryGetValue(ACookie, APath);
  if Result then
    FPendingDirMoves.Remove(ACookie);
end;

procedure TWatchThread.RenameWatchPathPrefix(const AOldPrefix, ANewPrefix: string);
var
  watchHandle: cint;
  oldPath, newPath: string;
begin
  for watchHandle in FWatchedFolders.Keys do begin
    oldPath := FWatchedFolders[watchHandle];
    if Pos(AOldPrefix, oldPath) = 1 then begin
      newPath := StringReplace(oldPath, AOldPrefix, ANewPrefix, []);
      FWatchedFolders[watchHandle] := newPath;
    end;
  end;
end;

procedure TWatchThread.DispatchLog;
begin
  if Assigned(FOnLog) then
    FOnLog(FPendingLogMessage);
end;

procedure TWatchThread.QueueLog(const AMessage: string);
begin
  FPendingLogMessage := AMessage;
  Synchronize(@DispatchLog);
end;

procedure TWatchThread.DispatchInitialScan;
begin
  if Assigned(FOnInitialScan) then
    FOnInitialScan(FPendingInitialScanFiles);
end;

procedure TWatchThread.QueueInitialScan(const AFiles: array of TSearchRec);
var
  i: Integer;
begin
  SetLength(FPendingInitialScanFiles, Length(AFiles));
  for i := Low(AFiles) to High(AFiles) do
    FPendingInitialScanFiles[i] := AFiles[i];

  Synchronize(@DispatchInitialScan);
end;

procedure TWatchThread.ProcessFolderEvents(event: pinotify_event; fullPath: string);
var
  oldDirPath: string;
begin
  if ((event^.mask and IN_ISDIR) = 0)
    then Exit;

  if ((event^.mask and IN_MOVED_FROM) <> 0) and (fullPath <> '')
    then AddPendingDirMove(event^.cookie, fullPath);

  if ((event^.mask and IN_MOVED_TO) <> 0) and ExtractPendingDirMove(event^.cookie, oldDirPath)
    then RenameWatchPathPrefix(oldDirPath, fullPath);

  if (((event^.mask and IN_CREATE) <> 0) or ((event^.mask and IN_MOVED_TO) <> 0)) and (fullPath <> '')
    then AddWatchDir(fullPath);
end;

procedure TWatchThread.ProcessFileEvents(event: pinotify_event; fullPath: string);
begin
  if (event^.mask and IN_CREATE) <> 0 then
    QueueLog('[CREATED] ' + fullPath)
  else if (event^.mask and IN_MODIFY) <> 0 then
    QueueLog('[MODIFIED] ' + fullPath)
  else if (event^.mask and IN_DELETE) <> 0 then
    QueueLog('[DELETED] ' + fullPath)
  else if (event^.mask and IN_MOVED_FROM) <> 0 then
    QueueLog('[MOVED_FROM] ' + fullPath)
  else if (event^.mask and IN_MOVED_TO) <> 0 then
    QueueLog('[MOVED_TO] ' + fullPath)
  else if (event^.mask and IN_ATTRIB) <> 0 then
    QueueLog('[ATTRIB] ' + fullPath)
  else
    QueueLog('[EVENT] ' + fullPath);
end;

function TWatchThread.ShouldProcess(bytesRead: cint): cint;
begin
  if bytesRead < 0 then begin
    if (fpgeterrno = ESysEINTR) or (fpgeterrno = ESysEAGAIN) then begin
      TThread.Sleep(25);
      Exit(SHOULD_CONTINUE);
    end;

    Exit(SHOULD_BREAK);
  end;

  if bytesRead = 0 then begin
    TThread.Sleep(25);
    Exit(SHOULD_CONTINUE);
  end;

  Result := SHOULD_PROCESS;
end;

procedure TWatchThread.ProcessEvents;
var
  buffer: array[0..8191] of char;
  bytesRead, offset: cint;
  event: pinotify_event;
  eventName, parentPath, fullPath: string;
begin
  while not Terminated do begin
    // check the stream buffer
    bytesRead := fpread(eventStreamHandle, @buffer[0], SizeOf(buffer));
    case ShouldProcess(bytesRead) of
      SHOULD_CONTINUE: Continue;
      SHOULD_BREAK: Break;
    end;

    // read the buffer, one notification at a time
    offset := 0;
    while offset < bytesRead do begin
      if Terminated then
        Break;

      event := pinotify_event(@buffer[offset]);
      eventName := GetEventFileName(event);

      if IsIgnoredTempFileName(eventName) then begin
        offset := offset + 16 + event^.len;
        Continue;
      end;

      parentPath := GetWatchPath(event^.wd);
      fullPath := BuildChildPath(parentPath, eventName);

      ProcessFolderEvents(event, fullPath);
      ProcessFileEvents(event, fullPath);

      offset := offset + 16 + event^.len;
    end;
  end;
end;

procedure TWatchThread.Execute;
var
  i: Integer;
  watchHandle: cint;
begin
  eventStreamHandle := -1;
  try
    SetLength(FFoundFiles, 0);
    FWatchedFolders.Clear;
    FPendingDirMoves.Clear;

    eventStreamHandle := inotify_init();
    if eventStreamHandle < 0
      then Exit;

    fpfcntl(eventStreamHandle, F_SetFL, fpfcntl(eventStreamHandle, F_GetFL, 0) or O_NONBLOCK);

    for i := Low(FPaths) to High(FPaths) do
      AddWatchRecursive(eventStreamHandle, FPaths[i]);

    QueueInitialScan(FFoundFiles);

    if FWatchedFolders.Count = 0
      then Exit;

    ProcessEvents;
  finally
    if eventStreamHandle >= 0 then begin
      for watchHandle in FWatchedFolders.Keys do
        inotify_rm_watch(eventStreamHandle, watchHandle);
      fpclose(eventStreamHandle);
    end;
  end;
end;

end.
