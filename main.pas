unit main;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, Buttons,
  Process, LCLIntf,ExtCtrls, Menus, Clipbrd,
  laz.VirtualTrees,
  utils, formoptions, eagleipc,
  duplexipc,
  TimeCheck,
  WatchThread, EagleDB;

type

  { TForm1 }
  TForm1 = class(TForm)
    btnEagle: TBitBtn;
    edtFilter: TEdit;
    fileTree: TLazVirtualStringTree;
    Label1: TLabel;
    MainMenu1: TMainMenu;
    Memo1: TMemo;
    fileTreeMenu: TPopupMenu;
    menuFile: TMenuItem;
    menuHelp: TMenuItem;
    MenuItem1: TMenuItem;
    Separator1: TMenuItem;
    traySearch: TMenuItem;
    trayQuit: TMenuItem;
    mnuOpenFile: TMenuItem;
    menuFileOpenFolder: TMenuItem;
    menuFileOpen: TMenuItem;
    MenuItem3: TMenuItem;
    mnuCopy: TMenuItem;
    mnuCopyName: TMenuItem;
    mnuCopyPathAndName: TMenuItem;
    mnuCopyPath: TMenuItem;
    menuTools: TMenuItem;
    menuOptions: TMenuItem;
    mnuOpenFolder: TMenuItem;
    TrayMenu: TPopupMenu;
    timerFilterDebounce: TTimer;
    TrayIcon: TTrayIcon;

    procedure btnEagleClick(Sender: TObject);
    procedure edtFilterChange(Sender: TObject);
    procedure fileTreeMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormWindowStateChange(Sender: TObject);
    procedure traySearchClick(Sender: TObject);
    procedure trayQuitClick(Sender: TObject);
    procedure mnuCopyPathAndNameClick(Sender: TObject);
    procedure mnuCopyPathClick(Sender: TObject);
    procedure mnuOpenFileClick(Sender: TObject);
    procedure timerFilterDebounceTimer(Sender: TObject);
    procedure timerIPCTimer(Sender: TObject);

    // FileTree context menu
    procedure mnuOpenFolderClick(Sender: TObject);
    procedure menuOptionsClick(Sender: TObject);
    procedure mnuCopyNameClick(Sender: TObject);

    procedure FormClick(Sender: TObject);
    procedure FormCreate;
    procedure FormDestroy;
  private
    FWatchThread: TWatchThread;
    FEagleDB: TEagleDB;
    FIPCServer: TDuplexIPC;
    FIPCTimer: TTimer;

    FFileRecords: TEagleFileRecords;
    FSortColumn: TColumnIndex;
    FSortDirection: TSortDirection;

    function LoadFileRecordFromTree(out fileRecord: TEagleFileRecord): Boolean;

    procedure HandleLog(const AMessage: string);
    procedure HandleCreate(const APath: string);
    procedure HandleDelete(const APath: string);
    procedure HandleRename(const AOldPath, ANewPath: string);
    procedure HandleInitialScan(const AFiles: array of TSearchRec);
    procedure HandleScanProgress(const ACount: integer);

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
    procedure SetupIPCServer;
    procedure StopIPCServer;
    procedure HandleIPCMessage(Sender: TObject; const AMessage: string);
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

  SetupIPCServer;

  if not btnEagle.Enabled then
    Exit;

  SetupDB;
  SetupWatchThread;

  benchStamp.InsertTime('Starting from DB');
  SetupFileTree;
  RefreshFileTree;
  benchStamp.InsertTime('Finished from DB');
end;

procedure TForm1.FormDestroy;
begin
  StopIPCServer;
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
  FWatchThread.SetOnScanProgress(@HandleScanProgress);
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

{$REGION Startup IPC}
procedure TForm1.SetupIPCServer;
begin
  FIPCServer := TDuplexIPC.Create(nil);
  FIPCServer.Configure(EAGLE_IPC_LOCAL_SERVER_ID, EAGLE_IPC_REMOTE_CLIENT_ID);
  FIPCServer.OnMessage := @HandleIPCMessage;
  FIPCServer.Start;

  FIPCTimer := TTimer.Create(Self);
  FIPCTimer.Interval := 250;
  FIPCTimer.OnTimer := @timerIPCTimer;
  FIPCTimer.Enabled := True;
end;

procedure TForm1.StopIPCServer;
begin
  if Assigned(FIPCTimer) then begin
    FIPCTimer.Enabled := False;
    FreeAndNil(FIPCTimer);
  end;

  if Assigned(FIPCServer) then begin
    if FIPCServer.Active then
      FIPCServer.Stop;

    FreeAndNil(FIPCServer);
  end;
end;

procedure TForm1.timerIPCTimer(Sender: TObject);
begin
  if not Assigned(FIPCServer) then
    Exit;

  Memo1.Lines.Add('Polling IPC');
  FIPCServer.Poll;
end;

procedure TForm1.HandleIPCMessage(Sender: TObject; const AMessage: string);
begin
  if AMessage = 'show' then begin
    if WindowState = wsMinimized then
      WindowState := wsNormal;

    Visible := True;
    BringToFront;
    SetFocus;
  end;
end;
{$ENDREGION}

// Actions
procedure TForm1.btnEagleClick(Sender: TObject);
var
  i: integer;
begin
  benchStamp.InsertTime('Starting watchThread');
  if not Assigned(FWatchThread) then
    SetupWatchThread;

  btnEagle.Enabled := False;
  if FWatchThread.Suspended then begin
    for i := 0 to eagleOptions.paths.Count - 1 do
      FWatchThread.AddWatchPath(eagleOptions.paths[i]);

    FWatchThread.Start;
  end;
end;

procedure TForm1.edtFilterChange(Sender: TObject);
begin
  timerFilterDebounce.Enabled := False;
  timerFilterDebounce.Enabled := True;
end;

procedure TForm1.timerFilterDebounceTimer(Sender: TObject);
begin
  timerFilterDebounce.Enabled := False;
  RefreshFileTree;
end;

procedure TForm1.menuOptionsClick(Sender: TObject);
var
  options: TOptionsForm;
begin
  options := TOptionsForm.Create(self);
  try
    options.ShowModal;
  finally
    if options.shouldRefreshFileTree then
      RefreshFileTree;

    options.Free;
  end;
end;

procedure TForm1.fileTreeMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  clickedNode: PVirtualNode;
  fileRecord: TEagleFileRecord;
  itemAction: TItemAction;
begin
  itemAction := iaIgnore;

  if (Button = mbLeft) and (ssDouble in Shift) then
    itemAction := eagleOptions.doubleClickAction
  else if Button = mbMiddle then
    itemAction := eagleOptions.middleClickAction
  else if (Button = mbLeft) and (ssCtrl in Shift) then
    itemAction := eagleOptions.ctrlClickAction
  else if (Button = mbLeft) and (ssAlt in Shift) then
    itemAction := eagleOptions.altClickAction
  else if (Button = mbLeft) and (ssShift in Shift) then
    itemAction := eagleOptions.shiftClickAction;

  if itemAction = iaIgnore then
    Exit;

  clickedNode := fileTree.GetNodeAt(X, Y);
  if clickedNode = nil then
    Exit;

  fileTree.ClearSelection;
  fileTree.FocusedNode := clickedNode;
  fileTree.Selected[clickedNode] := True;

  if not LoadFileRecordFromTree(fileRecord) then
    Exit;

  case itemAction of
    iaOpenFile: mnuOpenFileClick(Sender);
    iaOpenFolder: mnuOpenFolderClick(Sender);
    iaCopyName: mnuCopyNameClick(Sender);
    iaCopyPath: mnuCopyPathClick(Sender);
    iaCopyPathName: mnuCopyPathAndNameClick(Sender);
  end;
end;

procedure TForm1.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if eagleOptions.closeToTray then begin;
    CanClose := False;
    Visible := False;
  end;
end;

procedure TForm1.FormWindowStateChange(Sender: TObject);
begin
  if (WindowState = wsMinimized) and eagleOptions.minimizeToTray then begin
    WindowState := wsNormal;
    Hide;
  end;
end;

procedure TForm1.traySearchClick(Sender: TObject);
begin
  Self.Visible := True;
end;

procedure TForm1.trayQuitClick(Sender: TObject);
begin
  Application.Terminate;
end;

// TEST
procedure TForm1.FormClick(Sender: TObject);
begin
  Memo1.Lines.Add(benchStamp.GetAllTimestamps);
end;

{$REGION 'FileTree context menu'}
function TForm1.LoadFileRecordFromTree(out fileRecord: TEagleFileRecord): Boolean;
var
  selectedNode: PVirtualNode;
  nodeIndex: integer;
begin
  Result := False;
  selectedNode := fileTree.GetFirstSelected;
  if selectedNode = nil then
    selectedNode := fileTree.FocusedNode;

  if selectedNode = nil then
    Exit;

  nodeIndex := fileTree.AbsoluteIndex(selectedNode);

  if (nodeIndex < 0) or (nodeIndex >= Length(FFileRecords)) then
    Exit;

  fileRecord := FFileRecords[nodeIndex];
  Result := True;
end;

procedure TForm1.mnuOpenFolderClick(Sender: TObject);
var
  folderPath, folderUrl: string;
  opened: boolean;

  fileRecord: TEagleFileRecord;
begin
  if not LoadFileRecordFromTree(fileRecord) then
    Exit;

  folderPath := fileRecord.Path;
  if (folderPath = '') or not DirectoryExists(folderPath) then
    Exit;

  folderUrl := 'file://' + EncodePathForFileURL(folderPath);

  opened := OpenURL(folderUrl);
  if not opened then
    opened := OpenDocument(folderPath);
end;

procedure TForm1.mnuCopyNameClick(Sender: TObject);
var
  fileRecord: TEagleFileRecord;
begin
  if not LoadFileRecordFromTree(fileRecord) then
    Exit;

  Clipboard.AsText := fileRecord.Name;
end;

procedure TForm1.mnuCopyPathAndNameClick(Sender: TObject);
var
  fileRecord: TEagleFileRecord;
begin
  if not LoadFileRecordFromTree(fileRecord) then
    Exit;

  Clipboard.AsText := IncludeTrailingPathDelimiter(fileRecord.Path) + fileRecord.Name;
end;

procedure TForm1.mnuCopyPathClick(Sender: TObject);
var
  fileRecord: TEagleFileRecord;
begin
  if not LoadFileRecordFromTree(fileRecord) then
    Exit;

  Clipboard.AsText := IncludeTrailingPathDelimiter(fileRecord.Path)
end;

procedure TForm1.mnuOpenFileClick(Sender: TObject);
var
  fileRecord: TEagleFileRecord;
  filePath: string;
  opened: boolean;
begin
  if not LoadFileRecordFromTree(fileRecord) then
    Exit;

  filePath := IncludeTrailingPathDelimiter(fileRecord.Path) + fileRecord.Name;
  if (filePath = '') or not FileExists(filePath) then
    Exit;

  opened := OpenDocument(filePath);
  if not opened then
    OpenURL('file://' + EncodePathForFileURL(filePath));
end;
{$ENDREGION}

{$REGION 'FileTree'}
procedure TForm1.RefreshFileTree;
var
  filterText: string;
begin
  filterText := Trim(edtFilter.Text);
  FFileRecords := FEagleDB.GetFiles(filterText, eagleOptions.searchPath);
  SortFileRecords;
  PopulateFileTree;

  Memo1.Lines.Add('New records added: ' + IntToStr(Length(FFileRecords)));
end;

procedure TForm1.SetupFileTree;
const
  widths: array of integer = (250, 80, 120);
var
  Column: TVirtualTreeColumn;
begin
  fileTree.Header.Columns.Clear;

  Column := fileTree.Header.Columns.Add;
  Column.Text := 'Name';
  Column.Width := fileTree.ClientWidth - SumArray(widths) - 16;

  Column := fileTree.Header.Columns.Add;
  Column.Text := 'Path';
  Column.Width := widths[0];

  Column := fileTree.Header.Columns.Add;
  Column.Text := 'Size';
  Column.Width := widths[1];

  Column := fileTree.Header.Columns.Add;
  Column.Text := 'Date';
  Column.Width := widths[2];

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

  // Keep ordering when primary values are equal.
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
    2:
      if eagleOptions.prettySize then
        CellText := PrettySize(FFileRecords[NodeIndex].Size)
      else
        CellText := IntToStr(FFileRecords[NodeIndex].Size);
    3:
      if eagleOptions.showOnlyDate then
        CellText := FormatDateTime('dd.mm.yyyy', FileDateToDateTime(FFileRecords[NodeIndex].Time))
      else
        CellText := FormatDateTime('dd.mm.yyyy hh:nn', FileDateToDateTime(FFileRecords[NodeIndex].Time));
  end;
end;

procedure TForm1.PopulateFileTree;
begin
  fileTree.Clear;
  fileTree.RootNodeCount := Length(FFileRecords);
  fileTree.Refresh;
end;
{$ENDREGION}

{$REGION TWatchThread delegate methods}
procedure TForm1.HandleInitialScan(const AFiles: array of TSearchRec);
begin
  benchStamp.InsertTime('Finished watchThread');

  Memo1.Lines.Add('Found ' + IntToStr(Length(AFiles)) + ' files!');

  benchStamp.InsertTime('Updating DB');
  FEagleDB.SyncFiles(AFiles);
  benchStamp.InsertTime('Updated DB');

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

procedure TForm1.HandleScanProgress(const ACount: integer);
begin
  Memo1.Lines.Add('[SCAN] ' + IntToStr(ACount) + ' files found so far...');
end;
{$ENDREGION}

end.
