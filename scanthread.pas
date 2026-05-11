unit scanthread;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, EagleDB;

const
  INITIAL_SCAN_BATCH_SIZE = 4096;
  SCAN_FOLDER_BATCH_SIZE = 1024;

type
  TScanThread = class(TThread)
  private
    FPaths: TStringList;
    FQueueLock: TCriticalSection;
    FFinished: boolean;

    FLocalFolders: array of string;
    FLocalFolderCount: integer;
    FLocalFiles: TEagleImportFileRecords;
    FLocalFileCount: integer;

    FPendingFolders: array of string;
    FPendingFolderStart: integer;
    FPendingFolderCount: integer;

    FPendingFiles: TEagleImportFileRecords;
    FPendingFileStart: integer;
    FPendingFileCount: integer;

    procedure EnsurePendingFolderCapacity(const AAdditional: integer);
    procedure EnsurePendingFileCapacity(const AAdditional: integer);
    procedure CompactPendingFoldersIfNeeded;
    procedure CompactPendingFilesIfNeeded;
    procedure FlushLocalFolders;
    procedure FlushLocalFiles;
    procedure AddFolder(const APath: string);
    procedure AddFile(const AFullPath: string; const ASize: int64; const ATime: longint);
    procedure ScanPathRecursive(const APath: string);
  protected
    procedure Execute; override;
  public
    constructor Create(const APaths: TStringList);
    destructor Destroy; override;

    function DequeueFoldersBatch(const AMaxCount: integer; ABatch: TStringList): integer;
    function DequeueFilesBatch(const AMaxCount: integer; out ABatch: TEagleImportFileRecords; out ACount: integer): boolean;
    function HasPendingData: boolean;
    function IsFinished: boolean;
  end;

implementation

constructor TScanThread.Create(const APaths: TStringList);
begin
  FPaths := TStringList.Create;
  FPaths.Assign(APaths);
  FQueueLock := TCriticalSection.Create;
  FFinished := False;

  FLocalFolderCount := 0;
  FLocalFileCount := 0;
  FPendingFolderStart := 0;
  FPendingFolderCount := 0;
  FPendingFileStart := 0;
  FPendingFileCount := 0;

  inherited Create(True);
end;

destructor TScanThread.Destroy;
begin
  SetLength(FLocalFolders, 0);
  SetLength(FLocalFiles, 0);
  SetLength(FPendingFolders, 0);
  SetLength(FPendingFiles, 0);

  FQueueLock.Free;
  FPaths.Free;

  inherited Destroy;
end;

procedure TScanThread.EnsurePendingFolderCapacity(const AAdditional: integer);
var
  needed, newLen: integer;
begin
  needed := FPendingFolderStart + FPendingFolderCount + AAdditional;
  if needed <= Length(FPendingFolders) then
    Exit;

  CompactPendingFoldersIfNeeded;
  needed := FPendingFolderStart + FPendingFolderCount + AAdditional;
  if needed <= Length(FPendingFolders) then
    Exit;

  newLen := Length(FPendingFolders);
  if newLen = 0 then
    newLen := AAdditional;

  while newLen < needed do
    newLen := newLen * 2;

  SetLength(FPendingFolders, newLen);
end;

procedure TScanThread.EnsurePendingFileCapacity(const AAdditional: integer);
var
  needed, newLen: integer;
begin
  needed := FPendingFileStart + FPendingFileCount + AAdditional;
  if needed <= Length(FPendingFiles) then
    Exit;

  CompactPendingFilesIfNeeded;
  needed := FPendingFileStart + FPendingFileCount + AAdditional;
  if needed <= Length(FPendingFiles) then
    Exit;

  newLen := Length(FPendingFiles);
  if newLen = 0 then
    newLen := AAdditional;

  while newLen < needed do
    newLen := newLen * 2;

  SetLength(FPendingFiles, newLen);
end;

procedure TScanThread.CompactPendingFoldersIfNeeded;
var
  i: integer;
begin
  if (FPendingFolderStart = 0) or (FPendingFolderCount = 0) then begin
    if FPendingFolderCount = 0 then
      FPendingFolderStart := 0;
    Exit;
  end;

  for i := 0 to FPendingFolderCount - 1 do
    FPendingFolders[i] := FPendingFolders[FPendingFolderStart + i];

  FPendingFolderStart := 0;
end;

procedure TScanThread.CompactPendingFilesIfNeeded;
var
  i: integer;
begin
  if (FPendingFileStart = 0) or (FPendingFileCount = 0) then begin
    if FPendingFileCount = 0 then
      FPendingFileStart := 0;
    Exit;
  end;

  for i := 0 to FPendingFileCount - 1 do
    FPendingFiles[i] := FPendingFiles[FPendingFileStart + i];

  FPendingFileStart := 0;
end;

procedure TScanThread.FlushLocalFolders;
var
  i, targetIndex: integer;
begin
  if FLocalFolderCount = 0 then
    Exit;

  FQueueLock.Enter;
  try
    EnsurePendingFolderCapacity(FLocalFolderCount);
    targetIndex := FPendingFolderStart + FPendingFolderCount;
    for i := 0 to FLocalFolderCount - 1 do
      FPendingFolders[targetIndex + i] := FLocalFolders[i];
    Inc(FPendingFolderCount, FLocalFolderCount);
  finally
    FQueueLock.Leave;
  end;

  FLocalFolderCount := 0;
end;

procedure TScanThread.FlushLocalFiles;
var
  i, targetIndex: integer;
begin
  if FLocalFileCount = 0 then
    Exit;

  FQueueLock.Enter;
  try
    EnsurePendingFileCapacity(FLocalFileCount);
    targetIndex := FPendingFileStart + FPendingFileCount;
    for i := 0 to FLocalFileCount - 1 do
      FPendingFiles[targetIndex + i] := FLocalFiles[i];
    Inc(FPendingFileCount, FLocalFileCount);
  finally
    FQueueLock.Leave;
  end;

  FLocalFileCount := 0;
end;

procedure TScanThread.AddFolder(const APath: string);
begin
  if FLocalFolderCount >= Length(FLocalFolders) then
    SetLength(FLocalFolders, FLocalFolderCount + SCAN_FOLDER_BATCH_SIZE);

  FLocalFolders[FLocalFolderCount] := APath;
  Inc(FLocalFolderCount);

  if FLocalFolderCount >= SCAN_FOLDER_BATCH_SIZE then
    FlushLocalFolders;
end;

procedure TScanThread.AddFile(const AFullPath: string; const ASize: int64; const ATime: longint);
begin
  if FLocalFileCount >= Length(FLocalFiles) then
    SetLength(FLocalFiles, FLocalFileCount + INITIAL_SCAN_BATCH_SIZE);

  FLocalFiles[FLocalFileCount].FullPath := AFullPath;
  FLocalFiles[FLocalFileCount].Size := ASize;
  FLocalFiles[FLocalFileCount].Time := ATime;
  Inc(FLocalFileCount);

  if FLocalFileCount >= INITIAL_SCAN_BATCH_SIZE then
    FlushLocalFiles;
end;

procedure TScanThread.ScanPathRecursive(const APath: string);
var
  sr: TSearchRec;
  childPath, pathWithDelim: string;
begin
  if Terminated then
    Exit;

  AddFolder(ExcludeTrailingPathDelimiter(APath));
  pathWithDelim := IncludeTrailingPathDelimiter(APath);

  if FindFirst(pathWithDelim + '*', faAnyFile, sr) = 0 then
  try
    repeat
      if (sr.Name = '.') or (sr.Name = '..') then
        Continue;

      childPath := pathWithDelim + sr.Name;
      if (sr.Attr and faDirectory) <> 0 then begin
        ScanPathRecursive(childPath);
        Continue;
      end;

      AddFile(childPath, sr.Size, sr.Time);
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
end;

procedure TScanThread.Execute;
var
  i: integer;
begin
  SetLength(FLocalFolders, SCAN_FOLDER_BATCH_SIZE);
  SetLength(FLocalFiles, INITIAL_SCAN_BATCH_SIZE);

  for i := 0 to FPaths.Count - 1 do begin
    if Terminated then
      Break;

    ScanPathRecursive(FPaths[i]);
  end;

  FlushLocalFolders;
  FlushLocalFiles;

  FQueueLock.Enter;
  try
    FFinished := True;
  finally
    FQueueLock.Leave;
  end;
end;

function TScanThread.DequeueFoldersBatch(const AMaxCount: integer; ABatch: TStringList): integer;
var
  i, takeCount: integer;
begin
  ABatch.Clear;

  if AMaxCount <= 0 then
    Exit(0);

  FQueueLock.Enter;
  try
    if FPendingFolderCount = 0 then
      Exit(0);

    takeCount := AMaxCount;
    if takeCount > FPendingFolderCount then
      takeCount := FPendingFolderCount;

    for i := 0 to takeCount - 1 do
      ABatch.Add(FPendingFolders[FPendingFolderStart + i]);

    Inc(FPendingFolderStart, takeCount);
    Dec(FPendingFolderCount, takeCount);
    if FPendingFolderCount = 0 then
      FPendingFolderStart := 0;
    Result := takeCount;
  finally
    FQueueLock.Leave;
  end;
end;

function TScanThread.DequeueFilesBatch(const AMaxCount: integer; out ABatch: TEagleImportFileRecords; out ACount: integer): boolean;
var
  i, takeCount: integer;
begin
  ACount := 0;
  SetLength(ABatch, 0);

  if AMaxCount <= 0 then
    Exit(False);

  FQueueLock.Enter;
  try
    if FPendingFileCount = 0 then
      Exit(False);

    takeCount := AMaxCount;
    if takeCount > FPendingFileCount then
      takeCount := FPendingFileCount;

    SetLength(ABatch, takeCount);
    for i := 0 to takeCount - 1 do
      ABatch[i] := FPendingFiles[FPendingFileStart + i];

    Inc(FPendingFileStart, takeCount);
    Dec(FPendingFileCount, takeCount);
    if FPendingFileCount = 0 then
      FPendingFileStart := 0;

    ACount := takeCount;
    Result := True;
  finally
    FQueueLock.Leave;
  end;
end;

function TScanThread.HasPendingData: boolean;
begin
  FQueueLock.Enter;
  try
    Result := (FPendingFolderCount > 0) or (FPendingFileCount > 0);
  finally
    FQueueLock.Leave;
  end;
end;

function TScanThread.IsFinished: boolean;
begin
  FQueueLock.Enter;
  try
    Result := FFinished;
  finally
    FQueueLock.Leave;
  end;
end;

end.

