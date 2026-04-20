unit watchthread;

{$mode ObjFPC}{$H+}

interface

uses
  utils,
  Classes, SysUtils, BaseUnix, Generics.Collections;

const
  IN_MODIFY     = $00000002;
  IN_ATTRIB     = $00000004;
  IN_ISDIR      = $40000000;
  IN_MOVED_FROM = $00000040;
  IN_MOVED_TO   = $00000080;
  IN_CREATE     = $00000100;
  IN_DELETE     = $00000200;

  DIR_WATCH_MASK = IN_CREATE or IN_MODIFY or IN_DELETE or IN_MOVED_FROM or IN_MOVED_TO or IN_ATTRIB;

  SHOULD_CONTINUE = 1;
  SHOULD_BREAK    = 2;
  SHOULD_PROCESS  = 3;

  PENDING_MOVE_TIMEOUT_MS = 500;

type
  TPendingMove = record
    Path: string;
    IsDir: boolean;
    CreatedAt: QWord;
  end;

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
    Name: array[0..0] of char;
  end;

  { TWatchThread }
  TWatchThread = class(TThread)
  private
    eventStreamHandle: cint;

    FPaths: array of string;
    FFoundFiles: array of TSearchRec;
    FPendingInitialScanFiles: array of TSearchRec;
    FWatchedFolders: specialize TDictionary<cint, string>;
    FPendingMoves: specialize TDictionary<cuint32, TPendingMove>;

    FOnCreate: TWatchEventHandler;
    FOnModify: TWatchEventHandler;
    FOnDelete: TWatchEventHandler;
    FOnRename: TWatchRenameEventHandler;
    FOnAttributeChange: TWatchEventHandler;
    FOnLog: TWatchLogHandler;
    FOnInitialScan: TWatchInitialScanHandler;

    FPendingLogMessage: string;
    FPendingCreatePath: string;
    FPendingDeletePath: string;
    FPendingRenameOldPath: string;
    FPendingRenameNewPath: string;

    function AddWatchDir(const dirPath: string): boolean;
    procedure AddWatchRecursive(fd: cint; const rootPath: string);

    function GetWatchPath(wd: cint): string;
    function BuildChildPath(const parentPath, Name: string): string;

    procedure AddPendingMove(ACookie: cuint32; const APath: string; const AIsDir: boolean);
    function ExtractPendingMove(ACookie: cuint32; out AMove: TPendingMove): boolean;
    procedure FlushExpiredPendingMoves;

    procedure RenameWatchPathPrefix(const AOldPrefix, ANewPrefix: string);

    procedure ProcessEvents;
    procedure DispatchLog;
    procedure DispatchCreate;
    procedure DispatchDelete;
    procedure DispatchRename;
    procedure DispatchInitialScan;
    procedure QueueLog(const AMessage: string);
    procedure QueueCreate(const APath: string);
    procedure QueueDelete(const APath: string);
    procedure QueueRename(const AOldPath, ANewPath: string);
    procedure QueueInitialScan(const AFiles: array of TSearchRec);

    function GetEventFileName(event: pinotify_event): string;

    function ShouldProcess(bytesRead: cint): cint;

    function CanMapHighLevelEvent(event: pinotify_event; fullPath: string): boolean;
    procedure ProcessFolderEvents(event: pinotify_event; fullPath: string);
    procedure ProcessFileEvents(event: pinotify_event; fullPath: string);

    procedure InitEventStreamHandle;
    procedure CloseWatchHandles;
    function WatchAndScan: boolean;
    procedure MoveToNext(var offset: cint; event: pinotify_event);
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
function inotify_add_watch(fd: cint; pathname: pchar; mask: cuint32): cint; cdecl; external 'libc' name 'inotify_add_watch';
function inotify_rm_watch(fd: cint; wd: cint): cint; cdecl; external 'libc' name 'inotify_rm_watch';

{ TWatchThread }

constructor TWatchThread.Create;
begin
  FWatchedFolders := specialize TDictionary<cint, string>.Create;
  FPendingMoves := specialize TDictionary<cuint32, TPendingMove>.Create;

  inherited Create(True);
end;

destructor TWatchThread.Destroy;
begin
  FWatchedFolders.Free;
  FPendingMoves.Free;

  inherited Destroy;
end;

procedure TWatchThread.AddWatchPath(const APath: string);
var
  pathCount: integer;
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

procedure TWatchThread.DispatchLog;
begin
  if Assigned(FOnLog) then
    FOnLog(FPendingLogMessage);
end;

procedure TWatchThread.DispatchCreate;
begin
  if Assigned(FOnCreate) then
    FOnCreate(FPendingCreatePath);
end;

procedure TWatchThread.DispatchDelete;
begin
  if Assigned(FOnDelete) then
    FOnDelete(FPendingDeletePath);
end;

procedure TWatchThread.DispatchRename;
begin
  if Assigned(FOnRename) then
    FOnRename(FPendingRenameOldPath, FPendingRenameNewPath);
end;

procedure TWatchThread.QueueLog(const AMessage: string);
begin
  FPendingLogMessage := AMessage;
  Synchronize(@DispatchLog);
end;

procedure TWatchThread.QueueCreate(const APath: string);
begin
  FPendingCreatePath := APath;
  Synchronize(@DispatchCreate);
end;

procedure TWatchThread.QueueDelete(const APath: string);
begin
  FPendingDeletePath := APath;
  Synchronize(@DispatchDelete);
end;

procedure TWatchThread.QueueRename(const AOldPath, ANewPath: string);
begin
  FPendingRenameOldPath := AOldPath;
  FPendingRenameNewPath := ANewPath;
  Synchronize(@DispatchRename);
end;

procedure TWatchThread.DispatchInitialScan;
begin
  if Assigned(FOnInitialScan) then
    FOnInitialScan(FPendingInitialScanFiles);
end;

function TWatchThread.AddWatchDir(const dirPath: string): boolean;
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
  fileCount: integer;
  childPath: string;
begin
  AddWatchDir(rootPath);

  if FindFirst(IncludeTrailingPathDelimiter(rootPath) + '*', faAnyFile, sr) = 0 then
  try
    repeat
      if (sr.Name = '.') or (sr.Name = '..') then
        Continue;

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
    rawNameLen := StrLen(PChar(@event^.Name[0]));
    SetLength(Result, rawNameLen);

    if rawNameLen > 0 then
      Move(event^.Name[0], Result[1], rawNameLen);
  end;
end;

function TWatchThread.GetWatchPath(wd: cint): string;
begin
  Result := '';
  FWatchedFolders.TryGetValue(wd, Result);
end;

function TWatchThread.BuildChildPath(const parentPath, Name: string): string;
begin
  if parentPath = '' then
    Exit(Name);

  if Name = '' then
    Exit(parentPath);

  Result := IncludeTrailingPathDelimiter(parentPath) + Name;
end;

procedure TWatchThread.AddPendingMove(ACookie: cuint32; const APath: string; const AIsDir: boolean);
var
  pendingMove: TPendingMove;
begin
  if ACookie = 0 then
    Exit;

  pendingMove.Path := APath;
  pendingMove.IsDir := AIsDir;
  pendingMove.CreatedAt := GetTickCount64;
  FPendingMoves.AddOrSetValue(ACookie, pendingMove);
end;

function TWatchThread.ExtractPendingMove(ACookie: cuint32; out AMove: TPendingMove): boolean;
begin
  AMove.Path := '';
  AMove.IsDir := False;
  AMove.CreatedAt := 0;
  if ACookie = 0 then
    Exit;

  Result := FPendingMoves.TryGetValue(ACookie, AMove);
  if Result then
    FPendingMoves.Remove(ACookie);
end;

procedure TWatchThread.FlushExpiredPendingMoves;
var
  cookie: cuint32;
  pendingMove: TPendingMove;
  expiredCookies: array of cuint32;
  expiredCount: integer;
  i: integer;
begin
  expiredCount := 0;

  for cookie in FPendingMoves.Keys do begin
    pendingMove := FPendingMoves[cookie];
    if (GetTickCount64 - pendingMove.CreatedAt) >= PENDING_MOVE_TIMEOUT_MS then begin
      SetLength(expiredCookies, expiredCount + 1);
      expiredCookies[expiredCount] := cookie;
      Inc(expiredCount);
    end;
  end;

  // treat MOVED_OUT as DELETED after the timeout
  for i := 0 to expiredCount - 1 do begin
    cookie := expiredCookies[i];
    if FPendingMoves.TryGetValue(cookie, pendingMove) then begin
      FPendingMoves.Remove(cookie);
      QueueLog('[MOVED_OUT] ' + pendingMove.Path);
      QueueDelete(pendingMove.Path);
    end;
  end;
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

procedure TWatchThread.QueueInitialScan(const AFiles: array of TSearchRec);
var
  i: integer;
begin
  SetLength(FPendingInitialScanFiles, Length(AFiles));
  for i := Low(AFiles) to High(AFiles) do
    FPendingInitialScanFiles[i] := AFiles[i];

  Synchronize(@DispatchInitialScan);
end;

function TWatchThread.CanMapHighLevelEvent(event: pinotify_event; fullPath: string): boolean;
var
  oldMove: TPendingMove;
begin
  Result := False;

  if ((event^.mask and IN_MOVED_FROM) <> 0) and (fullPath <> '') then begin
    AddPendingMove(event^.cookie, fullPath, (event^.mask and IN_ISDIR) <> 0);
    QueueLog('[MOVED_FROM] ' + fullPath);

    Result := True;
  end;

  if ((event^.mask and IN_MOVED_TO) <> 0) and (fullPath <> '') then begin
    if ExtractPendingMove(event^.cookie, oldMove) then begin
      if oldMove.IsDir then
        RenameWatchPathPrefix(oldMove.Path, fullPath);

      QueueLog('[RENAMED] ' + oldMove.Path + ' -> ' + fullPath);
      QueueRename(oldMove.Path, fullPath);
    end else begin
      QueueLog('[MOVED_TO] ' + fullPath);
      if (event^.mask and IN_ISDIR) <> 0 then
        AddWatchDir(fullPath)
      else
        QueueCreate(fullPath);
    end;

    Result := True;
  end;
end;

procedure TWatchThread.ProcessFolderEvents(event: pinotify_event; fullPath: string);
begin
  if ((event^.mask and IN_ISDIR) = 0) then
    Exit;

  if ((event^.mask and IN_CREATE) <> 0) and (fullPath <> '') then
    AddWatchDir(fullPath);
end;

procedure TWatchThread.ProcessFileEvents(event: pinotify_event; fullPath: string);
begin
  if (event^.mask and IN_CREATE) <> 0 then begin
    QueueLog('[CREATED] ' + fullPath);
    if (event^.mask and IN_ISDIR) = 0 then
      QueueCreate(fullPath);
  end else
    if (event^.mask and IN_MODIFY) <> 0 then
      QueueLog('[MODIFIED] ' + fullPath)
    else
      if (event^.mask and IN_DELETE) <> 0 then begin
        QueueLog('[DELETED] ' + fullPath);
        QueueDelete(fullPath);
      end else
        if (event^.mask and IN_ATTRIB) <> 0 then
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
    FlushExpiredPendingMoves;

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
        MoveToNext(offset, event);
        Continue;
      end;

      parentPath := GetWatchPath(event^.wd);
      fullPath := BuildChildPath(parentPath, eventName);

      if CanMapHighLevelEvent(event, fullPath) then begin
        MoveToNext(offset, event);
        Continue;
      end;

      ProcessFolderEvents(event, fullPath);
      ProcessFileEvents(event, fullPath);

      offset := offset + 16 + event^.len;
    end;
  end;
end;

procedure TWatchThread.Execute;
begin
  eventStreamHandle := -1;
  try
    InitEventStreamHandle;

    if not WatchAndScan then
      Exit;

    ProcessEvents;
  finally
    CloseWatchHandles;
  end;
end;

// HELPERS
function TWatchThread.WatchAndScan: boolean;
var
  i: integer;
begin
  Result := True;

  SetLength(FFoundFiles, 0);
  FWatchedFolders.Clear;
  FPendingMoves.Clear;

  for i := Low(FPaths) to High(FPaths) do
    AddWatchRecursive(eventStreamHandle, FPaths[i]);
  QueueInitialScan(FFoundFiles);

  Result := FWatchedFolders.Count > 0;
end;

procedure TWatchThread.InitEventStreamHandle;
begin
  eventStreamHandle := inotify_init();
  if eventStreamHandle < 0 then
    Exit;

  fpfcntl(eventStreamHandle, F_SetFL, fpfcntl(eventStreamHandle, F_GetFL, 0) or O_NONBLOCK);
end;

procedure TWatchThread.CloseWatchHandles;
var
  watchHandle: cint;
begin
  if eventStreamHandle >= 0 then begin
    for watchHandle in FWatchedFolders.Keys do
      inotify_rm_watch(eventStreamHandle, watchHandle);
    fpclose(eventStreamHandle);
  end;
end;

procedure TWatchThread.MoveToNext(var offset: cint; event: pinotify_event);
begin
  offset := offset + 16 + event^.len;
end;

end.
