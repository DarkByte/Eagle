unit scanthread;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, EagleDB;

const
  INITIAL_SCAN_BATCH_SIZE = 4096;
  SCAN_FOLDER_BATCH_SIZE = 1024;

type
  TScanFolderBatch = array of string;
  TScanFoldersBatchHandler = procedure(const AFolders: TScanFolderBatch; const ACount: integer) of object;
  TScanFilesBatchHandler = procedure(const AFiles: TEagleImportFileRecords; const ACount: integer) of object;
  TScanDoneHandler = procedure of object;

  TScanThread = class(TThread)
  private
    FPaths: TStringList;

    FLocalFolders: array of string;
    FLocalFolderCount: integer;
    FLocalFiles: TEagleImportFileRecords;
    FLocalFileCount: integer;

    FOnFoldersBatch: TScanFoldersBatchHandler;
    FOnFilesBatch: TScanFilesBatchHandler;
    FOnDone: TScanDoneHandler;

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

    procedure SetOnFoldersBatch(const AHandler: TScanFoldersBatchHandler);
    procedure SetOnFilesBatch(const AHandler: TScanFilesBatchHandler);
    procedure SetOnDone(const AHandler: TScanDoneHandler);
  end;

implementation

constructor TScanThread.Create(const APaths: TStringList);
begin
  FPaths := TStringList.Create;
  FPaths.Assign(APaths);

  FLocalFolderCount := 0;
  FLocalFileCount := 0;

  inherited Create(True);
end;

destructor TScanThread.Destroy;
begin
  SetLength(FLocalFolders, 0);
  SetLength(FLocalFiles, 0);
  FPaths.Free;

  inherited Destroy;
end;

procedure TScanThread.FlushLocalFolders;
var
  i: integer;
  packet: TScanFolderBatch;
begin
  if FLocalFolderCount = 0 then
    Exit;

  if Assigned(FOnFoldersBatch) then begin
    SetLength(packet, FLocalFolderCount);
    for i := 0 to FLocalFolderCount - 1 do
      packet[i] := FLocalFolders[i];
    FOnFoldersBatch(packet, FLocalFolderCount);
  end;

  FLocalFolderCount := 0;
end;

procedure TScanThread.FlushLocalFiles;
var
  i: integer;
  packet: TEagleImportFileRecords;
begin
  if FLocalFileCount = 0 then
    Exit;

  if Assigned(FOnFilesBatch) then begin
    SetLength(packet, FLocalFileCount);
    for i := 0 to FLocalFileCount - 1 do
      packet[i] := FLocalFiles[i];
    FOnFilesBatch(packet, FLocalFileCount);
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

  if Assigned(FOnDone) then
    FOnDone;
end;

procedure TScanThread.SetOnFoldersBatch(const AHandler: TScanFoldersBatchHandler);
begin
  FOnFoldersBatch := AHandler;
end;

procedure TScanThread.SetOnFilesBatch(const AHandler: TScanFilesBatchHandler);
begin
  FOnFilesBatch := AHandler;
end;

procedure TScanThread.SetOnDone(const AHandler: TScanDoneHandler);
begin
  FOnDone := AHandler;
end;

end.

