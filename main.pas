unit main;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, Buttons,
  laz.VirtualTrees,
  TimeCheck,
  WatchThread, EagleDB;

type

  { TForm1 }
  TForm1 = class(TForm)
    btnEagle: TBitBtn;
    cbPath: TCheckBox;
    edtFilter: TEdit;
    edtPathToEagle: TEdit;
    fileTree: TLazVirtualStringTree;
    Label1: TLabel;
    Memo1: TMemo;

    procedure btnEagleClick(Sender: TObject);
    procedure edtFilterChange(Sender: TObject);

    procedure FormCreate;
    procedure FormDestroy;
  private
    FWatchThread: TWatchThread;
    FEagleDB: TEagleDB;

    FFileRecords: TEagleFileRecords;
    FSortColumn: TColumnIndex;
    FSortDirection: TSortDirection;

    procedure HandleLog(const AMessage: string);
    procedure HandleCreate(const APath: string);
    procedure HandleDelete(const APath: string);
    procedure HandleRename(const AOldPath, ANewPath: string);
    procedure HandleInitialScan(const AFiles: array of TSearchRec);

    procedure SetupWatchThread;
    procedure SetupDB;
    procedure RefreshFileTree;
    procedure SetupFileTree;
    procedure SortFileRecords;
    function CompareFileRecords(const A, B: TEagleFileRecord; const AColumn: TColumnIndex): integer;
    procedure PopulateFileTree;
    procedure FileTreeHeaderClick(Sender: TVTHeader; HitInfo: TVTHeaderHitInfo);
    procedure FileTreeGetText(Sender: TBaseVirtualTree; Node: PVirtualNode; Column: TColumnIndex; TextType: TVSTTextType; var CellText: string);

    procedure StopWatching;
  public

  end;

var
  Form1: TForm1;

implementation

{$R *.lfm}

{ TForm1 }

procedure TForm1.FormCreate;
begin
  FSortColumn := NoColumn;
  FSortDirection := sdAscending;

  SetupDB;
  SetupFileTree;
  SetupWatchThread;

  RefreshFileTree;
end;

procedure TForm1.FormDestroy;
begin
  StopWatching;

  if Assigned(FEagleDB) then
    FEagleDB.Free;
end;

procedure TForm1.SetupWatchThread;
begin
  FWatchThread := TWatchThread.Create;
  FWatchThread.SetOnLog(@HandleLog);
  FWatchThread.SetOnCreate(@HandleCreate);
  FWatchThread.SetOnDelete(@HandleDelete);
  FWatchThread.SetOnRename(@HandleRename);
  FWatchThread.SetOnInitialScan(@HandleInitialScan);
end;

procedure TForm1.StopWatching;
begin
  if Assigned(FWatchThread) then begin
    FWatchThread.Terminate;
    FWatchThread.WaitFor;
    FWatchThread.Free;
    FWatchThread := nil;
  end;

  btnEagle.Enabled := True;
end;

procedure TForm1.SetupDB;
begin
  FEagleDB := TEagleDB.Create;
  FEagleDB.Open;
end;

// Actions
procedure TForm1.btnEagleClick(Sender: TObject);
begin
  if not Assigned(FWatchThread) then
    SetupWatchThread;

  btnEagle.Enabled := False;
  if FWatchThread.Suspended then begin
    FWatchThread.AddWatchPath(edtPathToEagle.Text);
    FWatchThread.Start;
  end;
end;

procedure TForm1.edtFilterChange(Sender: TObject);
begin
  RefreshFileTree;
end;

// FileTree
procedure TForm1.RefreshFileTree;
var
  filterText: string;
begin
  filterText := Trim(edtFilter.Text);
  FFileRecords := FEagleDB.GetFiles(filterText, cbPath.Checked);
  SortFileRecords;
  PopulateFileTree;

  Memo1.Lines.Add('New records added: ' + IntToStr(Length(FFileRecords)));
end;

procedure TForm1.SetupFileTree;
var
  Column: TVirtualTreeColumn;
begin
  fileTree.Header.Columns.Clear;

  Column := fileTree.Header.Columns.Add;
  Column.Text := 'Name';
  Column.Width := 150;

  Column := fileTree.Header.Columns.Add;
  Column.Text := 'Path';
  Column.Width := 300;

  Column := fileTree.Header.Columns.Add;
  Column.Text := 'Size';
  Column.Width := 80;

  Column := fileTree.Header.Columns.Add;
  Column.Text := 'Date modified';
  Column.Width := 120;

  fileTree.Header.MainColumn := 0;
  fileTree.TreeOptions.SelectionOptions := fileTree.TreeOptions.SelectionOptions + [toFullRowSelect];
  fileTree.OnHeaderClick := @FileTreeHeaderClick;
  fileTree.OnGetText := @FileTreeGetText;
end;

function TForm1.CompareFileRecords(const A, B: TEagleFileRecord; const AColumn: TColumnIndex): integer;
begin
  case AColumn of
    0: Result := CompareText(A.Name, B.Name);
    1: Result := CompareText(A.Path, B.Path);
    2: begin
      if A.Size < B.Size then
        Result := -1
      else
        if A.Size > B.Size then
          Result := 1
        else
          Result := 0;
    end;
    3: begin
      if A.Time < B.Time then
        Result := -1
      else
        if A.Time > B.Time then
          Result := 1
        else
          Result := 0;
    end;
    else
      Result := 0;
  end;

  // Keep ordering deterministic when primary values are equal.
  if Result = 0 then begin
    Result := CompareText(A.Path, B.Path);
    if Result = 0 then
      Result := CompareText(A.Name, B.Name);
  end;

  if FSortDirection = sdDescending then
    Result := -Result;
end;

procedure TForm1.SortFileRecords;

  procedure QuickSort(L, R: integer);
  var
    I, J: integer;
    Pivot, Temp: TEagleFileRecord;
  begin
    I := L;
    J := R;
    Pivot := FFileRecords[(L + R) div 2];

    repeat
      while CompareFileRecords(FFileRecords[I], Pivot, FSortColumn) < 0 do
        Inc(I);
      while CompareFileRecords(FFileRecords[J], Pivot, FSortColumn) > 0 do
        Dec(J);

      if I <= J then begin
        Temp := FFileRecords[I];
        FFileRecords[I] := FFileRecords[J];
        FFileRecords[J] := Temp;
        Inc(I);
        Dec(J);
      end;
    until I > J;

    if L < J then
      QuickSort(L, J);
    if I < R then
      QuickSort(I, R);
  end;

begin
  if FSortColumn = NoColumn then
    Exit;

  if Length(FFileRecords) < 2 then
    Exit;

  QuickSort(0, High(FFileRecords));
end;

procedure TForm1.FileTreeHeaderClick(Sender: TVTHeader; HitInfo: TVTHeaderHitInfo);
begin
  if HitInfo.Column = NoColumn then
    Exit;

  if FSortColumn = HitInfo.Column then begin
    if FSortDirection = sdAscending then
      FSortDirection := sdDescending
    else
      FSortDirection := sdAscending;
  end else begin
    FSortColumn := HitInfo.Column;
    FSortDirection := sdAscending;
  end;

  fileTree.Header.SortColumn := FSortColumn;
  fileTree.Header.SortDirection := FSortDirection;

  SortFileRecords;
  PopulateFileTree;
end;

procedure TForm1.FileTreeGetText(Sender: TBaseVirtualTree; Node: PVirtualNode; Column: TColumnIndex; TextType: TVSTTextType; var CellText: string);
var
  NodeIndex: integer;
begin
  CellText := '';

  if Node = nil then
    Exit;

  NodeIndex := Sender.AbsoluteIndex(Node);
  if (NodeIndex < 0) or (NodeIndex >= Length(FFileRecords)) then
    Exit;

  case Column of
    0: CellText := FFileRecords[NodeIndex].Name;
    1: CellText := FFileRecords[NodeIndex].Path;
    2: CellText := IntToStr(FFileRecords[NodeIndex].Size);
    3: CellText := FormatDateTime('dd.mm.yyyy hh:nn', FileDateToDateTime(FFileRecords[NodeIndex].Time))
  end;
end;

procedure TForm1.PopulateFileTree;
begin
  fileTree.Clear;
  fileTree.RootNodeCount := Length(FFileRecords);
  fileTree.Refresh;
end;

// TWatchThread delegate methods
procedure TForm1.HandleInitialScan(const AFiles: array of TSearchRec);
begin
  FEagleDB.SyncFiles(AFiles);
  RefreshFileTree;
  Memo1.Lines.Add('[DB_POPULATED] ' + IntToStr(Length(AFiles)) + ' files');
end;

procedure TForm1.HandleCreate(const APath: string);
var
  sr: TSearchRec;
begin
  if FindFirst(APath, faAnyFile, sr) <> 0 then
    Exit;

  try
    if (sr.Attr and faDirectory) <> 0 then
      Exit;

    FEagleDB.AddFile(sr.Name, ExtractFileDir(APath), sr.Size, sr.Time);
  finally
    FindClose(sr);
  end;

  RefreshFileTree;
end;

procedure TForm1.HandleRename(const AOldPath, ANewPath: string);
begin
  FEagleDB.RenamePath(AOldPath, ANewPath);
  RefreshFileTree;
end;

procedure TForm1.HandleDelete(const APath: string);
begin
  FEagleDB.DeletePath(APath);
  RefreshFileTree;
end;

procedure TForm1.HandleLog(const AMessage: string);
begin
  Memo1.Lines.Add(AMessage);
end;

end.
