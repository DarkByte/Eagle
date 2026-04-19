unit EagleDB;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, SQLite3Conn, SQLDB;

type
  TEagleFileRecord = record
    Name: string;
    Path: string;
    Size: int64;
    ModifiedTimestamp: LongInt;
  end;

  TEagleFileRecords = array of TEagleFileRecord;

  TEagleDB = class
  private
    FDBPath: string;
    FConnection: TSQLite3Connection;
    FTransaction: TSQLTransaction;
    procedure EnsureSchema;
    procedure BulkImportFiles(const AFiles: array of TSearchRec);
    procedure BulkDeleteOrphanedFiles(const AFiles: array of TSearchRec);
  public
    constructor Create(const ADBPath: string = 'eagle.sqlite');
    destructor Destroy; override;

    procedure Open;
    procedure Close;
    function IsOpen: Boolean;
    function GetFiles(const AFilterText: string; const ASearchInPath: Boolean): TEagleFileRecords;

    procedure AddFile(name, path: string; size: int64; timestamp: longint);
    procedure SyncFiles(const AFiles: array of TSearchRec);
  end;

implementation

constructor TEagleDB.Create(const ADBPath: string);
begin
  inherited Create;
  FDBPath := ADBPath;

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
    'CREATE TABLE IF NOT EXISTS files (' +
    'id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
    'path TEXT NOT NULL, ' +
    'name TEXT NOT NULL, ' +
    'size INTEGER, ' +
    'timestamp INTEGER, ' +
    'UNIQUE(name, path)' +
    ');'
  );
  FTransaction.Commit;
end;

procedure TEagleDB.Open;
begin
  if FConnection.Connected
    then Exit;

  FConnection.Open;
  FTransaction.StartTransaction;
  EnsureSchema;
end;

procedure TEagleDB.Close;
begin
  if not FConnection.Connected
    then Exit;

  if FTransaction.Active then
    FTransaction.Commit;

  FConnection.Close;
end;

function TEagleDB.IsOpen: Boolean;
begin
  Result := FConnection.Connected;
end;

function TEagleDB.GetFiles(const AFilterText: string; const ASearchInPath: Boolean): TEagleFileRecords;
var
  query: TSQLQuery;
  filterText: string;
  itemCount: Integer;
begin
  SetLength(Result, 0);

  if not FConnection.Connected
    then Open;

  if not FTransaction.Active
    then FTransaction.StartTransaction;

  query := TSQLQuery.Create(nil);
  try
    query.DataBase := FConnection;
    query.Transaction := FTransaction;

    filterText := Trim(AFilterText);
    if filterText = '' then begin
      query.SQL.Text :=
        'SELECT substr(name, 1) as name, substr(path, 1) as path, size, timestamp ' +
        'FROM files ORDER BY path, name';
    end else if ASearchInPath then begin
      query.SQL.Text :=
        'SELECT substr(name, 1) as name, substr(path, 1) as path, size, timestamp ' +
        'FROM files ' +
        'WHERE (name LIKE :filter OR path LIKE :filter) ' +
        'ORDER BY path, name';
      query.ParamByName('filter').AsString := '%' + filterText + '%';
    end else begin
      query.SQL.Text :=
        'SELECT substr(name, 1) as name, substr(path, 1) as path, size, timestamp ' +
        'FROM files ' +
        'WHERE name LIKE :filter ' +
        'ORDER BY path, name';
      query.ParamByName('filter').AsString := '%' + filterText + '%';
    end;

    query.Open;
    while not query.Eof do begin
      itemCount := Length(Result);
      SetLength(Result, itemCount + 1);

      Result[itemCount].Name := query.FieldByName('name').AsString;
      Result[itemCount].Path := query.FieldByName('path').AsString;
      Result[itemCount].Size := query.FieldByName('size').AsLargeInt;
      Result[itemCount].ModifiedTimestamp := query.FieldByName('timestamp').AsInteger;

      query.Next;
    end;

    query.Close;
  finally
    query.Free;
  end;
end;

procedure TEagleDB.AddFile(name, path: string; size: int64; timestamp: longint);
var
  query: TSQLQuery;
begin
  if not FConnection.Connected
    then Open;

  if not FTransaction.Active
    then FTransaction.StartTransaction;

  query := TSQLQuery.Create(nil);
  try
    query.DataBase := FConnection;
    query.Transaction := FTransaction;
    query.SQL.Text := 'INSERT OR REPLACE INTO files (name, path, size, timestamp) VALUES (:name, :path, :size, :timestamp)';
    query.ParamByName('name').AsString := name;
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

procedure TEagleDB.BulkImportFiles(const AFiles: array of TSearchRec);
var
  query: TSQLQuery;
  i: Integer;
  fullPath: string;
  fileName: string;
  filePath: string;
begin
  query := TSQLQuery.Create(nil);
  try
    query.DataBase := FConnection;
    query.Transaction := FTransaction;
    query.SQL.Text := 'INSERT OR REPLACE INTO files (name, path, size, timestamp) VALUES (:name, :path, :size, :timestamp)';

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
    query.Free;
  end;
end;

procedure TEagleDB.BulkDeleteOrphanedFiles(const AFiles: array of TSearchRec);
var
  query, deleteQuery: TSQLQuery;
  dbName, dbPath: string;
  fullPath, fileName, filePath: string;
  i: Integer;
  found: Boolean;
begin
  query := TSQLQuery.Create(nil);
  deleteQuery := TSQLQuery.Create(nil);
  try
    query.DataBase := FConnection;
    query.Transaction := FTransaction;
    query.SQL.Text := 'SELECT name, path FROM files';
    query.Open;

    while not query.Eof do begin
      dbName := query.FieldByName('name').AsString;
      dbPath := query.FieldByName('path').AsString;
      found := False;

      for i := Low(AFiles) to High(AFiles) do begin
        fullPath := AFiles[i].Name;
        if Pos(PathDelim, fullPath) > 0 then begin
          fileName := ExtractFileName(fullPath);
          filePath := ExtractFileDir(fullPath);
        end else begin
          fileName := fullPath;
          filePath := '';
        end;

        if (dbName = fileName) and (dbPath = filePath) then begin
          found := True;
          Break;
        end;
      end;

      if not found then begin
        deleteQuery.DataBase := FConnection;
        deleteQuery.Transaction := FTransaction;
        deleteQuery.SQL.Text := 'DELETE FROM files WHERE name = :name AND path = :path';
        deleteQuery.ParamByName('name').AsString := dbName;
        deleteQuery.ParamByName('path').AsString := dbPath;
        deleteQuery.ExecSQL;
      end;

      query.Next;
    end;

    query.Close;
  finally
    query.Free;
    deleteQuery.Free;
  end;
end;

procedure TEagleDB.SyncFiles(const AFiles: array of TSearchRec);
begin
  if not FConnection.Connected
    then Open;

  if not FTransaction.Active
    then FTransaction.StartTransaction;

  try
    BulkImportFiles(AFiles);
    BulkDeleteOrphanedFiles(AFiles);

    FTransaction.Commit;
    FTransaction.StartTransaction;
  except
    if FTransaction.Active
      then FTransaction.Rollback;
    raise;
  end;
end;

end.

