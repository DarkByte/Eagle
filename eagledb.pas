unit EagleDB;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils,
  SQLite3Conn, SQLDB, sqlite3dyn;

const
  DB_FILENAME = 'eagle.sqlite';

type
  TEagleFileRecord = record
    Name: string;
    Path: string;
    Size: int64;
    Time: longint;
  end;

  TEagleFileRecords = array of TEagleFileRecord;

  TEagleDB = class
  private
    FDBPath: string;
    FConnection: TSQLite3Connection;
    FTransaction: TSQLTransaction;
    procedure EnsureSchema;
    procedure BulkImportFiles(const AFiles: array of TSearchRec);
  public
    constructor Create(const ADBPath: string = DB_FILENAME);
    destructor Destroy; override;

    procedure Open;
    procedure Close;
    function IsOpen: boolean;
    function GetFiles(const AFilterText: string; searchPath: boolean; limit: Integer = 0): TEagleFileRecords;

    procedure AddFile(Name, path: string; size: int64; timestamp: longint);
    procedure DeleteFile(const fullPath: string);
    procedure DeletePath(const fullPath: string);
    procedure RenamePath(const oldPath, newPath: string);

    procedure SyncFiles(const AFiles: array of TSearchRec);
  end;

implementation

uses utils, TimeCheck;

function GetDefaultDBPath: string;
begin
  Result := IncludeTrailingPathDelimiter(GetEagleDataDir) + DB_FILENAME;
end;

constructor TEagleDB.Create(const ADBPath: string);
var
  targetDir: string;
begin
  inherited Create;
  if ADBPath = DB_FILENAME then
    FDBPath := GetDefaultDBPath
  else
    FDBPath := ADBPath;

  targetDir := ExtractFileDir(FDBPath);
  if (targetDir <> '') and (not DirectoryExists(targetDir)) then
    ForceDirectories(targetDir);

  FConnection := TSQLite3Connection.Create(nil);
  FTransaction := TSQLTransaction.Create(nil);

  FConnection.DatabaseName := FDBPath;
  FConnection.Transaction := FTransaction;
  FTransaction.DataBase := FConnection;
end;

destructor TEagleDB.Destroy;
begin
  Close;
  FTransaction.Free;
  FConnection.Free;
  inherited Destroy;
end;

procedure TEagleDB.EnsureSchema;
begin
  FConnection.ExecuteDirect(
    'CREATE TABLE IF NOT EXISTS files (' + 'id INTEGER PRIMARY KEY AUTOINCREMENT, ' + 'path TEXT NOT NULL, ' +
    'name TEXT NOT NULL, ' + 'size INTEGER, ' + 'timestamp INTEGER, ' + 'UNIQUE(name, path)' + ');'
    );
  FTransaction.Commit;
end;

procedure TEagleDB.Open;
begin
  if FConnection.Connected then
    Exit;

  FConnection.Open;

  // Set pragmas directly via SQLite handle - bypasses SQLDB transaction state
  sqlite3_exec(FConnection.Handle, 'PRAGMA journal_mode = WAL', nil, nil, nil);
  sqlite3_exec(FConnection.Handle, 'PRAGMA synchronous = NORMAL', nil, nil, nil);

  FTransaction.StartTransaction;
  EnsureSchema;
end;

procedure TEagleDB.Close;
begin
  if not FConnection.Connected then
    Exit;

  if FTransaction.Active then
    FTransaction.Commit;

  FConnection.Close;
end;

function TEagleDB.IsOpen: boolean;
begin
  Result := FConnection.Connected;
end;

function TEagleDB.GetFiles(const AFilterText: string; searchPath: boolean; limit: Integer = 0): TEagleFileRecords;
var
  query: TSQLQuery;
  filterText, limitText, queryStr: string;
  itemCount: integer;
begin
  SetLength(Result, 0);

  if not FConnection.Connected then
    Open;

  if not FTransaction.Active then
    FTransaction.StartTransaction;

  if limit > 0 then
    limitText := ' LIMIT ' + IntToStr(limit)
  else
    limitText := '';

  queryStr := 'SELECT substr(name, 1) as name, substr(path, 1) as path, size, timestamp FROM files %s ORDER BY path, name' + limitText;

  query := TSQLQuery.Create(nil);
  try
    query.DataBase := FConnection;
    query.Transaction := FTransaction;

    filterText := Trim(AFilterText);
    if filterText = '' then
      query.SQL.Text := Format(queryStr, [''])
    else if searchPath then begin
      query.SQL.Text := Format(queryStr, ['WHERE (name LIKE :filter OR path LIKE :filter)']);
      query.ParamByName('filter').AsString := '%' + filterText + '%';
    end
    else begin
      query.SQL.Text := Format(queryStr, ['WHERE (name LIKE :filter)']);
      query.ParamByName('filter').AsString := '%' + filterText + '%';
    end;

    query.Open;
    query.Last;
    itemCount := query.RecordCount;
    SetLength(Result, itemCount);
    query.First;

    itemCount := 0;
    while not query.EOF do begin
      Result[itemCount].Name := query.FieldByName('name').AsString;
      Result[itemCount].Path := query.FieldByName('path').AsString;
      Result[itemCount].Size := query.FieldByName('size').AsLargeInt;
      Result[itemCount].Time := query.FieldByName('timestamp').AsInteger;

      Inc(itemCount);
      query.Next;
    end;

    query.Close;
  finally
    query.Free;
  end;
end;

procedure TEagleDB.AddFile(Name, path: string; size: int64; timestamp: longint);
var
  query: TSQLQuery;
begin
  if not FConnection.Connected then
    Open;

  if not FTransaction.Active then
    FTransaction.StartTransaction;

  query := TSQLQuery.Create(nil);
  try
    query.DataBase := FConnection;
    query.Transaction := FTransaction;
    query.SQL.Text := 'INSERT OR REPLACE INTO files (name, path, size, timestamp) VALUES (:name, :path, :size, :timestamp)';
    query.ParamByName('name').AsString := Name;
    query.ParamByName('path').AsString := path;
    query.ParamByName('size').AsLargeInt := size;
    query.ParamByName('timestamp').AsInteger := timestamp;
    query.ExecSQL;

    FTransaction.Commit;
    FTransaction.StartTransaction;
  finally
    query.Free;
  end;
end;

procedure TEagleDB.DeleteFile(const fullPath: string);
var
  query: TSQLQuery;
  fileName: string;
  filePath: string;
begin
  if not FConnection.Connected then
    Open;

  if not FTransaction.Active then
    FTransaction.StartTransaction;

  if Pos(PathDelim, fullPath) > 0 then begin
    fileName := ExtractFileName(fullPath);
    filePath := ExtractFileDir(fullPath);
  end else begin
    fileName := fullPath;
    filePath := '';
  end;

  query := TSQLQuery.Create(nil);
  try
    query.DataBase := FConnection;
    query.Transaction := FTransaction;
    query.SQL.Text := 'DELETE FROM files WHERE name = :name AND path = :path';
    query.ParamByName('name').AsString := fileName;
    query.ParamByName('path').AsString := filePath;
    query.ExecSQL;

    FTransaction.Commit;
    FTransaction.StartTransaction;
  finally
    query.Free;
  end;
end;

procedure TEagleDB.DeletePath(const fullPath: string);
var
  query: TSQLQuery;
  fileName: string;
  filePath: string;
  matchCount: integer;
  folderPrefix: string;
begin
  if fullPath = '' then
    Exit;

  if not FConnection.Connected then
    Open;

  if not FTransaction.Active then
    FTransaction.StartTransaction;

  if Pos(PathDelim, fullPath) > 0 then begin
    fileName := ExtractFileName(fullPath);
    filePath := ExtractFileDir(fullPath);
  end else begin
    fileName := fullPath;
    filePath := '';
  end;

  query := TSQLQuery.Create(nil);
  try
    query.DataBase := FConnection;
    query.Transaction := FTransaction;

    query.SQL.Text := 'SELECT COUNT(1) AS match_count FROM files WHERE name = :name AND path = :path';
    query.ParamByName('name').AsString := fileName;
    query.ParamByName('path').AsString := filePath;
    query.Open;
    matchCount := query.FieldByName('match_count').AsInteger;
    query.Close;

    if matchCount > 0 then begin
      query.SQL.Text := 'DELETE FROM files WHERE name = :name AND path = :path';
      query.ParamByName('name').AsString := fileName;
      query.ParamByName('path').AsString := filePath;
      query.ExecSQL;
    end else begin
      folderPrefix := IncludeTrailingPathDelimiter(fullPath);
      query.SQL.Text := 'DELETE FROM files WHERE path = :folderPath OR path LIKE :folderPrefix';
      query.ParamByName('folderPath').AsString := fullPath;
      query.ParamByName('folderPrefix').AsString := folderPrefix + '%';
      query.ExecSQL;
    end;

    FTransaction.Commit;
    FTransaction.StartTransaction;
  finally
    query.Free;
  end;
end;

procedure TEagleDB.RenamePath(const oldPath, newPath: string);
var
  query: TSQLQuery;
  oldName, oldDir: string;
  newName, newDir: string;
  matchCount: integer;
  oldPrefix, newPrefix: string;
begin
  if (oldPath = '') or (newPath = '') then
    Exit;

  if not FConnection.Connected then
    Open;

  if not FTransaction.Active then
    FTransaction.StartTransaction;

  if Pos(PathDelim, oldPath) > 0 then begin
    oldName := ExtractFileName(oldPath);
    oldDir := ExtractFileDir(oldPath);
  end else begin
    oldName := oldPath;
    oldDir := '';
  end;

  if Pos(PathDelim, newPath) > 0 then begin
    newName := ExtractFileName(newPath);
    newDir := ExtractFileDir(newPath);
  end else begin
    newName := newPath;
    newDir := '';
  end;

  query := TSQLQuery.Create(nil);
  try
    query.DataBase := FConnection;
    query.Transaction := FTransaction;

    query.SQL.Text := 'SELECT COUNT(1) AS match_count FROM files WHERE name = :name AND path = :path';
    query.ParamByName('name').AsString := oldName;
    query.ParamByName('path').AsString := oldDir;
    query.Open;
    matchCount := query.FieldByName('match_count').AsInteger;
    query.Close;

    if matchCount > 0 then begin
      query.SQL.Text := 'UPDATE files SET name = :newName, path = :newPath WHERE name = :oldName AND path = :oldPath';
      query.ParamByName('newName').AsString := newName;
      query.ParamByName('newPath').AsString := newDir;
      query.ParamByName('oldName').AsString := oldName;
      query.ParamByName('oldPath').AsString := oldDir;
      query.ExecSQL;
    end else begin
      oldPrefix := IncludeTrailingPathDelimiter(oldPath);
      newPrefix := IncludeTrailingPathDelimiter(newPath);

      query.SQL.Text :=
        'UPDATE files ' + 'SET path = CASE ' + 'WHEN path = :oldFolder THEN :newFolder ' +
        'ELSE REPLACE(path, :oldPrefix, :newPrefix) ' + 'END ' + 'WHERE path = :oldFolder OR path LIKE :oldPrefixLike';
      query.ParamByName('oldFolder').AsString := oldPath;
      query.ParamByName('newFolder').AsString := newPath;
      query.ParamByName('oldPrefix').AsString := oldPrefix;
      query.ParamByName('newPrefix').AsString := newPrefix;
      query.ParamByName('oldPrefixLike').AsString := oldPrefix + '%';
      query.ExecSQL;
    end;

    FTransaction.Commit;
    FTransaction.StartTransaction;
  finally
    query.Free;
  end;
end;

procedure TEagleDB.BulkImportFiles(const AFiles: array of TSearchRec);
var
  query: TSQLQuery;
  i: integer;
  fullPath: string;
  fileName: string;
  filePath: string;
begin
  query := TSQLQuery.Create(nil);
  try
    query.DataBase := FConnection;
    query.Transaction := FTransaction;
    query.SQL.Text := 'INSERT INTO files (name, path, size, timestamp) VALUES (:name, :path, :size, :timestamp)';
    query.Prepare;

    try
      for i := Low(AFiles) to High(AFiles) do begin
        fullPath := AFiles[i].Name;
        if Pos(PathDelim, fullPath) > 0 then begin
          fileName := ExtractFileName(fullPath);
          filePath := ExtractFileDir(fullPath);
        end else begin
          fileName := fullPath;
          filePath := '';
        end;

        query.ParamByName('name').AsString := fileName;
        query.ParamByName('path').AsString := filePath;
        query.ParamByName('size').AsLargeInt := AFiles[i].Size;
        query.ParamByName('timestamp').AsInteger := AFiles[i].Time;
        query.ExecSQL;
      end;
    finally
      query.UnPrepare;
    end;
  finally
    query.Free;
  end;
end;

// full nuclear
procedure TEagleDB.SyncFiles(const AFiles: array of TSearchRec);
var
  query: TSQLQuery;
begin
  if not FConnection.Connected then
    Open;

  if not FTransaction.Active then
    FTransaction.StartTransaction;

  try
    // Delete all files from the table
    query := TSQLQuery.Create(nil);
    try
      query.DataBase := FConnection;
      query.Transaction := FTransaction;
      query.SQL.Text := 'DELETE FROM files';
      query.ExecSQL;
    finally
      query.Free;
    end;

    // Populate with new data
    BulkImportFiles(AFiles);
    FTransaction.Commit;
    FConnection.ExecuteDirect('PRAGMA wal_checkpoint(TRUNCATE)');
    if not FTransaction.Active then
      FTransaction.StartTransaction;
  except
    if FTransaction.Active then
      FTransaction.Rollback;
    raise;
  end;
end;

end.
