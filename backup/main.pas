unit main;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls,
  laz.VirtualTrees, WatchThread, EagleDB;

  type

  { TForm1 }

  TForm1 = class(TForm)
    btnEagle: TButton;
    cbPath: TCheckBox;
    edtFilter: TEdit;
    edtPathToEagle: TEdit;
    fileTree: TLazVirtualStringTree;
    Label1: TLabel;
    Memo1: TMemo;

    procedure btnEagleClick;
    procedure edtFilterChange(Sender: TObject);

    procedure FormCreate;
    procedure FormDestroy;
  private
    FWatchThread: TWatchThread;
    FEagleDB: TEagleDB;

    FFileRecords: TEagleFileRecords;

    procedure HandleLog(const AMessage: string);
    procedure HandleInitialScan(const AFiles: array of TSearchRec);
    procedure SetupWatchThread;
    procedure SetupDB;
    procedure RefreshFileTree;
    procedure SetupFileTree;
    procedure PopulateFileTree;
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
procedure TForm1.btnEagleClick;
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
  PopulateFileTree;
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
  fileTree.OnGetText := @FileTreeGetText;
end;

procedure TForm1.FileTreeGetText(Sender: TBaseVirtualTree; Node: PVirtualNode; Column: TColumnIndex; TextType: TVSTTextType; var CellText: string);
var
  NodeIndex: Integer;
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
var
  NodeIndex: Integer;
begin
  fileTree.Clear;

  for NodeIndex := 0 to High(FFileRecords) do
    fileTree.AddChild(nil);

  fileTree.Refresh;
end;


// TWatchThread delegate methods
procedure TForm1.HandleInitialScan(const AFiles: array of TSearchRec);
begin
  FEagleDB.SyncFiles(AFiles);
  RefreshFileTree;
  Memo1.Lines.Add('[DB_POPULATED] ' + IntToStr(Length(AFiles)) + ' files');
end;

procedure TForm1.HandleLog(const AMessage: string);
begin
  Memo1.Lines.Add(AMessage);
end;

end.

