unit watchthread;

{$mode ObjFPC}{$H+}

interface

uses
  utils,
  Classes, SysUtils, SyncObjs, BaseUnix, Generics.Collections,
  EagleDB, scanthread;

const
  IN_MODIFY     = $00000002;
  IN_ATTRIB     = $00000004;
  IN_ISDIR      = $40000000;
  IN_MOVED_FROM = $00000040;
  IN_MOVED_TO   = $00000080;
  IN_CREATE     = $00000100;
  IN_DELETE     = $00000200;

  DIR_WATCH_MASK = IN_CREATE or IN_MODIFY or IN_DELETE or IN_MOVED_FROM or IN_MOVED_TO or IN_ATTRIB;

  INITIAL_SCAN_BATCH_SIZE = 4096;

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
  TWatchInitialScanHandler = procedure(const AFiles: TEagleImportFileRecords; const ACount: integer; const AIsFinal: boolean) of object;
  TWatchScanProgressHandler = procedure(const ACount: integer) of object;
  TWatchDoneHandler = procedure of object;

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

    FCmdLock: TCriticalSection;
    FPendingScanPaths: TStringList;
    FPendingWatchFromDB: boolean;

    FScanThread: TScanThread;
    FPendingScannedFolders: TStringList;
    FPendingScannedFiles: TEagleImportFileRecords;
    FPendingScannedFileCount: integer;
    FScanThreadDone: boolean;

    FFoundFiles: TEagleImportFileRecords;
    FFoundFilesCount: integer;
    FFoundFilesTotalCount: integer;
    FPendingInitialScanFiles: TEagleImportFileRecords;
    FPendingInitialScanCount: integer;
    FPendingInitialScanIsFinal: boolean;
    FWatchedFolders: specialize TDictionary<cint, string>;
    FWatchedFolderPaths: specialize TDictionary<string, cint>;
    FPendingMoves: specialize TDictionary<cuint32, TPendingMove>;

    FOnCreate: TWatchEventHandler;
    FOnModify: TWatchEventHandler;
    FOnDelete: TWatchEventHandler;
    FOnRename: TWatchRenameEventHandler;
    FOnAttributeChange: TWatchEventHandler;
    FOnLog: TWatchLogHandler;
    FOnInitialScan: TWatchInitialScanHandler;
    FOnScanProgress: TWatchScanProgressHandler;
    FOnDone: TWatchDoneHandler;

    FPendingLogMessage: string;
    FPendingScanProgressCount: integer;
    FLastProgressTime: QWord;
    FPendingCreatePath: string;
    FPendingDeletePath: string;
    FPendingRenameOldPath: string;
    FPendingRenameNewPath: string;

    function NormalizePathKey(const APath: string): string;
    function AddWatchDir(const dirPath: string): boolean;

    function GetWatchPath(wd: cint): string;
    function BuildChildPath(const parentPath, Name: string): string;

    procedure AddPendingMove(ACookie: cuint32; const APath: string; const AIsDir: boolean);
    function ExtractPendingMove(ACookie: cuint32; out AMove: TPendingMove): boolean;
    procedure FlushExpiredPendingMoves;

    procedure RenameWatchPathPrefix(const AOldPrefix, ANewPrefix: string);

    function ProcessFolderNotifyEvents: boolean;
    procedure ProcessPendingCommands;
    procedure StartScan(const APaths: TStringList);
    procedure HandleScanFoldersBatch(const AFolders: TScanFolderBatch; const ACount: integer);
    procedure HandleScanFilesBatch(const AFiles: TEagleImportFileRecords; const ACount: integer);
    procedure HandleScanDone;
    procedure DrainActiveScan;
    procedure FinalizeScan;
    procedure ExecuteWatchDB;
    procedure DispatchLog;
    procedure DispatchCreate;
    procedure DispatchDelete;
    procedure DispatchRename;
    procedure DispatchInitialScan;
    procedure DispatchScanProgress;
    procedure DispatchDone;
    procedure QueueDone;
    procedure QueueScanProgressIfDue;
    procedure QueueLog(const AMessage: string);
    procedure QueueCreate(const APath: string);
    procedure QueueDelete(const APath: string);
    procedure QueueRename(const AOldPath, ANewPath: string);
    procedure QueueInitialScan(const AFiles: TEagleImportFileRecords; const ACount: integer; const AIsFinal: boolean);
    procedure AppendFoundFile(const AFile: TEagleImportFileRecord);
    procedure FlushInitialScanBatch;

    function GetEventFileName(event: pinotify_event): string;

    function CanMapHighLevelEvent(event: pinotify_event; fullPath: string): boolean;
    procedure ProcessFolderEvents(event: pinotify_event; fullPath: string);
    procedure ProcessFileEvents(event: pinotify_event; fullPath: string);

    procedure InitEventStreamHandle;
    procedure CloseWatchHandles;
    function LoadWatchesFromDB: integer;
    procedure MoveToNext(var offset: cint; event: pinotify_event);
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;

    procedure ScanFolders(const APaths: array of string); overload;
    procedure ScanFolders(const APaths: TStringList); overload;
    procedure WatchFromDB;

    procedure SetOnCreate(const AHandler: TWatchEventHandler);
    procedure SetOnModify(const AHandler: TWatchEventHandler);
    procedure SetOnDelete(const AHandler: TWatchEventHandler);
    procedure SetOnRename(const AHandler: TWatchRenameEventHandler);
    procedure SetOnAttributeChange(const AHandler: TWatchEventHandler);

    procedure SetOnLog(const AHandler: TWatchLogHandler);
    procedure SetOnInitialScan(const AHandler: TWatchInitialScanHandler);
    procedure SetOnScanProgress(const AHandler: TWatchScanProgressHandler);
    procedure SetOnDone(const AHandler: TWatchDoneHandler);
  end;

implementation

function inotify_init: cint; cdecl; external 'libc' name 'inotify_init';
function inotify_add_watch(fd: cint; pathname: pchar; mask: cuint32): cint; cdecl; external 'libc' name 'inotify_add_watch';
function inotify_rm_watch(fd: cint; wd: cint): cint; cdecl; external 'libc' name 'inotify_rm_watch';

{ TWatchThread }

constructor TWatchThread.Create;
begin
  FCmdLock := TCriticalSection.Create;
  FPendingScanPaths := TStringList.Create;
  FPendingWatchFromDB := False;
  FPendingScannedFolders := TStringList.Create;
  FPendingScannedFileCount := 0;
  FScanThreadDone := False;
  FScanThread := nil;
  FWatchedFolders := specialize TDictionary<cint, string>.Create;
  FWatchedFolderPaths := specialize TDictionary<string, cint>.Create;
  FPendingMoves := specialize TDictionary<cuint32, TPendingMove>.Create;

  inherited Create(True);
end;

destructor TWatchThread.Destroy;
begin
  FPendingScanPaths.Free;
  FPendingScannedFolders.Free;
  SetLength(FPendingScannedFiles, 0);
  if Assigned(FScanThread) then begin
    FScanThread.Terminate;
    FScanThread.WaitFor;
    FreeAndNil(FScanThread);
  end;
  FCmdLock.Free;
  FWatchedFolderPaths.Free;
  FWatchedFolders.Free;
  FPendingMoves.Free;

  inherited Destroy;
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

procedure TWatchThread.SetOnScanProgress(const AHandler: TWatchScanProgressHandler);
begin
  FOnScanProgress := AHandler;
end;

procedure TWatchThread.SetOnDone(const AHandler: TWatchDoneHandler);
begin
  FOnDone := AHandler;
end;

procedure TWatchThread.ScanFolders(const APaths: array of string);
var
  i: integer;
begin
  FCmdLock.Enter;
  try
    for i := Low(APaths) to High(APaths) do
      FPendingScanPaths.Add(ExcludeTrailingPathDelimiter(APaths[i]));
  finally
    FCmdLock.Leave;
  end;
end;

procedure TWatchThread.ScanFolders(const APaths: TStringList);
var
  i: integer;
begin
  FCmdLock.Enter;
  try
    for i := 0 to APaths.Count - 1 do
      FPendingScanPaths.Add(ExcludeTrailingPathDelimiter(APaths[i]));
  finally
    FCmdLock.Leave;
  end;
end;

procedure TWatchThread.WatchFromDB;
begin
  FCmdLock.Enter;
  try
    FPendingWatchFromDB := True;
  finally
    FCmdLock.Leave;
  end;
end;

procedure TWatchThread.ProcessPendingCommands;
var
  pathsToScan: TStringList;
  doWatchDB: boolean;
begin
  pathsToScan := nil;
  doWatchDB := False;

  FCmdLock.Enter;
  try
    if FPendingScanPaths.Count > 0 then begin
      pathsToScan := TStringList.Create;
      pathsToScan.Assign(FPendingScanPaths);
      FPendingScanPaths.Clear;
    end;
    if FPendingWatchFromDB then begin
      doWatchDB := True;
      FPendingWatchFromDB := False;
    end;
  finally
    FCmdLock.Leave;
  end;

  if doWatchDB then
    ExecuteWatchDB;

  if Assigned(pathsToScan) then
  try
    StartScan(pathsToScan);
  finally
    pathsToScan.Free;
  end;
end;

procedure TWatchThread.StartScan(const APaths: TStringList);
begin
  if Assigned(FScanThread) then begin
    FScanThread.Terminate;
    FScanThread.WaitFor;
    FreeAndNil(FScanThread);
  end;

  FFoundFilesCount := 0;
  FFoundFilesTotalCount := 0;
  SetLength(FFoundFiles, INITIAL_SCAN_BATCH_SIZE);
  FLastProgressTime := GetTickCount64;
  SetLength(FPendingScannedFiles, 0);
  FPendingScannedFileCount := 0;
  FPendingScannedFolders.Clear;
  FScanThreadDone := False;

  FScanThread := TScanThread.Create(APaths);
  FScanThread.SetOnFoldersBatch(@HandleScanFoldersBatch);
  FScanThread.SetOnFilesBatch(@HandleScanFilesBatch);
  FScanThread.SetOnDone(@HandleScanDone);
  FScanThread.Start;
end;

procedure TWatchThread.HandleScanFoldersBatch(const AFolders: TScanFolderBatch; const ACount: integer);
var
  i: integer;
begin
  if ACount <= 0 then
    Exit;

  FCmdLock.Enter;
  try
    for i := 0 to ACount - 1 do
      FPendingScannedFolders.Add(AFolders[i]);
  finally
    FCmdLock.Leave;
  end;
end;

procedure TWatchThread.HandleScanFilesBatch(const AFiles: TEagleImportFileRecords; const ACount: integer);
var
  i, baseIndex: integer;
begin
  if ACount <= 0 then
    Exit;

  FCmdLock.Enter;
  try
    baseIndex := FPendingScannedFileCount;
    SetLength(FPendingScannedFiles, baseIndex + ACount);
    for i := 0 to ACount - 1 do
      FPendingScannedFiles[baseIndex + i] := AFiles[i];
    Inc(FPendingScannedFileCount, ACount);
  finally
    FCmdLock.Leave;
  end;
end;

procedure TWatchThread.HandleScanDone;
begin
  FCmdLock.Enter;
  try
    FScanThreadDone := True;
  finally
    FCmdLock.Leave;
  end;
end;

procedure TWatchThread.DrainActiveScan;
var
  i: integer;
  localFolders: TStringList;
  localFiles: TEagleImportFileRecords;
  localFileCount: integer;
  localDone: boolean;
begin
  if not Assigned(FScanThread) then
    Exit;

  localFolders := TStringList.Create;
  localFileCount := 0;
  SetLength(localFiles, 0);
  localDone := False;
  try
    FCmdLock.Enter;
    try
      localFolders.Assign(FPendingScannedFolders);
      FPendingScannedFolders.Clear;

      localFileCount := FPendingScannedFileCount;
      if localFileCount > 0 then begin
        SetLength(localFiles, localFileCount);
        for i := 0 to localFileCount - 1 do
          localFiles[i] := FPendingScannedFiles[i];
        SetLength(FPendingScannedFiles, 0);
        FPendingScannedFileCount := 0;
      end;

      localDone := FScanThreadDone;
    finally
      FCmdLock.Leave;
    end;

    if eagleOptions.watchChanges then begin
      for i := 0 to localFolders.Count - 1 do
        AddWatchDir(localFolders[i]);
    end;

    for i := 0 to localFileCount - 1 do begin
      AppendFoundFile(localFiles[i]);
      QueueScanProgressIfDue;
    end;

    if localDone and (localFolders.Count = 0) and (localFileCount = 0) then
      FinalizeScan;
  finally
    localFolders.Free;
    SetLength(localFiles, 0);
  end;
end;

procedure TWatchThread.FinalizeScan;
var
  i: integer;
  localFolders: TStringList;
  localFiles: TEagleImportFileRecords;
  localFileCount: integer;
begin
  if not Assigned(FScanThread) then
    Exit;

  FScanThread.WaitFor;

  localFolders := TStringList.Create;
  localFileCount := 0;
  SetLength(localFiles, 0);
  try
    FCmdLock.Enter;
    try
      localFolders.Assign(FPendingScannedFolders);
      FPendingScannedFolders.Clear;

      localFileCount := FPendingScannedFileCount;
      if localFileCount > 0 then begin
        SetLength(localFiles, localFileCount);
        for i := 0 to localFileCount - 1 do
          localFiles[i] := FPendingScannedFiles[i];
      end;
      SetLength(FPendingScannedFiles, 0);
      FPendingScannedFileCount := 0;
      FScanThreadDone := False;
    finally
      FCmdLock.Leave;
    end;

    if eagleOptions.watchChanges then begin
      for i := 0 to localFolders.Count - 1 do
        AddWatchDir(localFolders[i]);
    end;

    for i := 0 to localFileCount - 1 do begin
      AppendFoundFile(localFiles[i]);
      QueueScanProgressIfDue;
    end;
  finally
    localFolders.Free;
    SetLength(localFiles, 0);
  end;

  FlushInitialScanBatch;
  QueueInitialScan(FFoundFiles, 0, True);

  SetLength(FFoundFiles, 0);
  FFoundFilesCount := 0;
  FFoundFilesTotalCount := 0;

  FreeAndNil(FScanThread);
  QueueDone;
end;

procedure TWatchThread.ExecuteWatchDB;
begin
  QueueLog('[WATCH] Loading watch folders from DB...');
  LoadWatchesFromDB;
  QueueDone;
end;

procedure TWatchThread.DispatchDone;
begin
  if Assigned(FOnDone) then
    FOnDone;
end;

procedure TWatchThread.QueueDone;
begin
  Synchronize(@DispatchDone);
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
    FOnInitialScan(FPendingInitialScanFiles, FPendingInitialScanCount, FPendingInitialScanIsFinal);
end;

procedure TWatchThread.DispatchScanProgress;
begin
  if Assigned(FOnScanProgress) then
    FOnScanProgress(FPendingScanProgressCount);
end;

procedure TWatchThread.QueueScanProgressIfDue;
begin
  if (FFoundFilesTotalCount and $7FFF = 0) then begin
    FLastProgressTime := GetTickCount64;
    FPendingScanProgressCount := FFoundFilesTotalCount;
    Synchronize(@DispatchScanProgress);
  end;
end;

procedure TWatchThread.AppendFoundFile(const AFile: TEagleImportFileRecord);
begin
  if Length(FFoundFiles) = 0 then
    SetLength(FFoundFiles, INITIAL_SCAN_BATCH_SIZE);

  if FFoundFilesCount >= Length(FFoundFiles) then
    FlushInitialScanBatch;

  FFoundFiles[FFoundFilesCount] := AFile;
  Inc(FFoundFilesCount);
  Inc(FFoundFilesTotalCount);
end;

procedure TWatchThread.FlushInitialScanBatch;
begin
  if FFoundFilesCount = 0 then
    Exit;

  QueueInitialScan(FFoundFiles, FFoundFilesCount, False);
  FFoundFilesCount := 0;
end;

function TWatchThread.NormalizePathKey(const APath: string): string;
begin
  Result := ExcludeTrailingPathDelimiter(APath);
end;

function TWatchThread.AddWatchDir(const dirPath: string): boolean;
var
  wd: cint;
  existingWD: cint;
  existingPath: string;
  normalizedPath: string;
begin
  Result := False;

  normalizedPath := NormalizePathKey(dirPath);
  if normalizedPath = '' then
    Exit;

  if FWatchedFolderPaths.TryGetValue(normalizedPath, existingWD) then begin
    Result := True;
    Exit;
  end;

  wd := inotify_add_watch(eventStreamHandle, PChar(dirPath), DIR_WATCH_MASK);
  if wd < 0 then
    Exit;

  if FWatchedFolders.TryGetValue(wd, existingPath) then
    FWatchedFolderPaths.Remove(NormalizePathKey(existingPath));

  FWatchedFolders.AddOrSetValue(wd, dirPath);
  FWatchedFolderPaths.AddOrSetValue(normalizedPath, wd);
  Result := True;
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

  FWatchedFolderPaths.Clear;
  for watchHandle in FWatchedFolders.Keys do
    FWatchedFolderPaths.AddOrSetValue(NormalizePathKey(FWatchedFolders[watchHandle]), watchHandle);
end;

procedure TWatchThread.QueueInitialScan(const AFiles: TEagleImportFileRecords; const ACount: integer; const AIsFinal: boolean);
begin
  FPendingInitialScanFiles := AFiles;
  FPendingInitialScanCount := ACount;
  FPendingInitialScanIsFinal := AIsFinal;

  Synchronize(@DispatchInitialScan);

  SetLength(FPendingInitialScanFiles, 0);
  FPendingInitialScanCount := 0;
  FPendingInitialScanIsFinal := False;
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

function TWatchThread.ProcessFolderNotifyEvents: boolean;
var
  buffer: array[0..8191] of char;
  bytesRead, offset: cint;
  event: pinotify_event;
  eventName, parentPath, fullPath: string;
begin
  Result := False;

  if eventStreamHandle < 0 then
    Exit;

  bytesRead := fpread(eventStreamHandle, @buffer[0], SizeOf(buffer));
  if bytesRead <= 0 then
    Exit;

  Result := True;
  offset := 0;
  while offset < bytesRead do begin
    if Terminated then
      Break;

    event := pinotify_event(@buffer[offset]);
    eventName := GetEventFileName(event);

    if not IsIgnoredTempFileName(eventName) then begin
      parentPath := GetWatchPath(event^.wd);
      fullPath := BuildChildPath(parentPath, eventName);

      if not CanMapHighLevelEvent(event, fullPath) then begin
        ProcessFolderEvents(event, fullPath);
        ProcessFileEvents(event, fullPath);
      end;
    end;

    MoveToNext(offset, event);
  end;
end;

procedure TWatchThread.Execute;
begin
  InitEventStreamHandle;
  if eventStreamHandle < 0 then begin
    QueueLog('[ERROR] Failed to initialize inotify');
    Exit;
  end;

  try
    while not Terminated do begin
      ProcessPendingCommands;
      DrainActiveScan;
      if not ProcessFolderNotifyEvents then begin
        if not Assigned(FScanThread) then
          TThread.Sleep(200)
        else
          TThread.Sleep(20);
      end;

      FlushExpiredPendingMoves;
    end;

    if Assigned(FScanThread) then begin
      FScanThread.Terminate;
      FScanThread.WaitFor;
      FreeAndNil(FScanThread);
    end;
  finally
    CloseWatchHandles;
  end;
end;

// HELPERS
{$REGION HELPERS}
function TWatchThread.LoadWatchesFromDB: integer;
var
  db: TEagleDB;
  folders: TStringList;
  i: integer;
begin
  Result := 0;
  db := TEagleDB.Create;
  try
    db.Open;
    QueueLog('[WATCH] Getting DB folders');
    folders := db.GetUniqueFolders;
    QueueLog('[WATCH] Getting DB folders - done');
    try
      for i := 0 to folders.Count - 1 do begin
        if Terminated then
          Break;

        if AddWatchDir(folders[i]) then
          Inc(Result);
      end;
    finally
      folders.Free;
    end;
  finally
    db.Free;
  end;

  QueueLog('[WATCH] Added ' + IntToStr(Result) + ' folders from DB');
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
{$ENDREGION}

end.
