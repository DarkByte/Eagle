unit main;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, Buttons,
  Process, LCLIntf, ExtCtrls, Menus, Clipbrd,
  laz.VirtualTrees,
  utils, formoptions, eagleipc, BaseUnix,
  TimeCheck,
  WatchThread, EagleDB;

type

  { TMainForm }
  TMainForm = class(TForm)
    btnEagle: TBitBtn;
    btnJustWatch: TButton;
    edtFilter: TEdit;
    fileTree: TLazVirtualStringTree;
    Label1: TLabel;
    MainMenu1: TMainMenu;
    Memo1: TMemo;
    fileTreeMenu: TPopupMenu;
    menuFile: TMenuItem;
    menuHelp: TMenuItem;
    menuAbout: TMenuItem;
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
    procedure btnJustWatchClick(Sender: TObject);
    procedure edtFilterChange(Sender: TObject);
    procedure FormKeyPress(Sender: TObject; var Key: char);
    procedure timerFilterDebounceTimer(Sender: TObject);
    procedure timerIPCTimer(Sender: TObject);

    // Main menu
    procedure menuAboutClick(Sender: TObject);
    procedure menuOptionsClick(Sender: TObject);

    // Tray actions
    procedure traySearchClick(Sender: TObject);
    procedure trayQuitClick(Sender: TObject);

    // FileTree actions
    procedure fileTreeMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: integer);
    procedure mnuCopyNameClick(Sender: TObject);
    procedure mnuCopyPathClick(Sender: TObject);
    procedure mnuCopyPathAndNameClick(Sender: TObject);
    procedure mnuOpenFolderClick(Sender: TObject);
    procedure mnuOpenFileClick(Sender: TObject);

    // Form
    procedure FormCreate;
    procedure FormClick(Sender: TObject);
    procedure FormWindowStateChange(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: boolean);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure FormDestroy;
  private
    FWatchThread: TWatchThread;
    FEagleDB: TEagleDB;
    FIPCTimer: TTimer;

    FFileRecords: TEagleFileRecords;
    FSortColumn: TColumnIndex;
    FSortDirection: TSortDirection;
    FInitialScanImportActive: boolean;
    FInitialScanImportedCount: integer;

    {$IFDEF EAGLE_MEM_PROFILE}
    FInitialScanBeforeSync: THeapStatus;
    {$ENDIF}

    Row1RGB, Row2RGB: TColor;

    //SkipQuery: Boolean;

    procedure RestoreSearchForm;

    function LoadFileRecordFromTree(out fileRecord: TEagleFileRecord): boolean;

    procedure HandleLog(const AMessage: string);
    procedure HandleCreate(const APath: string);
    procedure HandleDelete(const APath: string);
    procedure HandleRename(const AOldPath, ANewPath: string);
    procedure HandleInitialScan(const AFiles: TEagleImportFileRecords; const ACount: integer; const AIsFinal: boolean);
    procedure HandleScanProgress(const ACount: integer);
    procedure HandleWatchDone;

    procedure SetupWatchThread;
    procedure SetupDB;

    procedure RefreshFileTree;
    procedure SetupFileTree;
    procedure PopulateFileTree;

    procedure FileTreeHeaderClick(Sender: TVTHeader; HitInfo: TVTHeaderHitInfo);
    procedure FileTreeGetText(Sender: TBaseVirtualTree; Node: PVirtualNode; Column: TColumnIndex; TextType: TVSTTextType; var CellText: string);
    procedure FileTreeBeforeCellPaint(Sender: TBaseVirtualTree; TargetCanvas: TCanvas; Node: PVirtualNode;
      Column: TColumnIndex; CellPaintMode: TVTCellPaintMode; CellRect: TRect; var ContentRect: TRect);

    procedure SavePositions;

    procedure StopWatching;
    procedure SetupIPCServer;
    procedure StopIPCServer;
    procedure HandleIPCMessage(Sender: TObject; const AMessage: string);
    procedure ApplyAfterOpenAction;
  public

  end;

var
  MainForm: TMainForm;

implementation

{$R *.lfm}

{$IFDEF EAGLE_MEM_PROFILE}
function ReadProcStatusValue(const AKey: string): string;
var
  statusLines: TStringList;
  i: integer;
  prefix: string;
begin
  Result := 'n/a';
  if not FileExists('/proc/self/status') then
    Exit;

  prefix := AKey + ':';
  statusLines := TStringList.Create;
  try
    statusLines.LoadFromFile('/proc/self/status');
    for i := 0 to statusLines.Count - 1 do begin
      if Pos(prefix, statusLines[i]) = 1 then begin
        Result := Trim(Copy(statusLines[i], Length(prefix) + 1, MaxInt));
        Exit;
      end;
    end;
  finally
    statusLines.Free;
  end;
end;

procedure LogProcessMemorySnapshot(AMemo: TMemo; const ATag: string);
begin
  if not Assigned(AMemo) then
    Exit;

  AMemo.Lines.Add(Format(
    '[PROC] %s VmRSS=%s VmHWM=%s VmData=%s RssAnon=%s RssFile=%s RssShmem=%s',
    [ATag,
     ReadProcStatusValue('VmRSS'),
     ReadProcStatusValue('VmHWM'),
     ReadProcStatusValue('VmData'),
     ReadProcStatusValue('RssAnon'),
     ReadProcStatusValue('RssFile'),
     ReadProcStatusValue('RssShmem')]
    ));
end;
{$ENDIF}

{ TMainForm }

procedure TMainForm.FormCreate;
begin
  FSortColumn := NoColumn;
  FSortDirection := sdAscending;
  FInitialScanImportActive := False;
  FInitialScanImportedCount := 0;

  SetupIPCServer;

  if not btnEagle.Enabled then
    Exit;

  SetupDB;
  SetupWatchThread;

  Width := eagleOptions.appWidth;
  Height := eagleOptions.appHeight;

  benchStamp.InsertTime('Starting from DB');
  SetupFileTree;
  RefreshFileTree;
  benchStamp.InsertTime('Finished from DB');
end;

procedure TMainForm.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  SavePositions;
  SaveConfig;
end;

procedure TMainForm.FormDestroy;
begin
  StopIPCServer;
  StopWatching;

  if Assigned(FEagleDB) then
    FEagleDB.Free;
end;

procedure TMainForm.SetupWatchThread;
begin
  FWatchThread := TWatchThread.Create;
  FWatchThread.SetOnLog(@HandleLog);
  FWatchThread.SetOnCreate(@HandleCreate);
  FWatchThread.SetOnDelete(@HandleDelete);
  FWatchThread.SetOnRename(@HandleRename);
  FWatchThread.SetOnInitialScan(@HandleInitialScan);
  FWatchThread.SetOnScanProgress(@HandleScanProgress);
  FWatchThread.SetOnDone(@HandleWatchDone);
end;

procedure TMainForm.StopWatching;
begin
  if Assigned(FWatchThread) then begin
    FWatchThread.Terminate;
    FWatchThread.WaitFor;
    FWatchThread.Free;
    FWatchThread := nil;
  end;

  btnEagle.Enabled := True;
end;

procedure TMainForm.SetupDB;
begin
  FEagleDB := TEagleDB.Create;
  FEagleDB.Open;
end;

procedure TMainForm.SavePositions;
begin
  if fileTree.Header.Columns.Count < 4 then
    Exit;

  with eagleOptions do begin
    colName := fileTree.Header.Columns[0].Width;
    colPath := fileTree.Header.Columns[1].Width;
    colSize := fileTree.Header.Columns[2].Width;
    colDate := fileTree.Header.Columns[3].Width;
    appWidth := Width;
    appHeight := Height;
  end;
end;

{$REGION Startup IPC}
procedure TMainForm.SetupIPCServer;
begin
  if eagleOptions.allowIPC then begin
    StartEagleDuplexIPCServer;
    SetEagleDuplexIPCMessageHandler(@HandleIPCMessage);
  end else begin
    StartEagleSimpleIPCServer;
    SetEagleSimpleIPCMessageHandler(@HandleIPCMessage);
  end;

  FIPCTimer := TTimer.Create(Self);
  FIPCTimer.Interval := 250;
  FIPCTimer.OnTimer := @timerIPCTimer;
  FIPCTimer.Enabled := True;
end;

procedure TMainForm.StopIPCServer;
begin
  if Assigned(FIPCTimer) then begin
    FIPCTimer.Enabled := False;
    FreeAndNil(FIPCTimer);
  end;

  StopEagleDuplexIPCServer;
  StopEagleSimpleIPCServer;
end;

procedure TMainForm.timerIPCTimer(Sender: TObject);
begin
  if eagleOptions.allowIPC then
    PollEagleDuplexIPC
  else
    PollEagleSimpleIPC;
end;

procedure TMainForm.HandleIPCMessage(Sender: TObject; const AMessage: string);
begin
  if AMessage = 'show' then begin
    if WindowState = wsMinimized then
      WindowState := wsNormal;

    RestoreSearchForm;
    BringToFront;
    SetFocus;

    Memo1.Lines.Add('ping from another instance');
  end;
end;
{$ENDREGION}

// Actions
procedure TMainForm.btnEagleClick(Sender: TObject);
begin
  benchStamp.InsertTime('Starting watchThread');
  Memo1.Lines.Add(benchStamp.StampNow('starting search...'));
  if not Assigned(FWatchThread) then
    SetupWatchThread;

  btnEagle.Enabled := False;
  if FWatchThread.Suspended then
    FWatchThread.Start;

  FWatchThread.ScanFolders(eagleOptions.paths);
end;

procedure TMainForm.btnJustWatchClick(Sender: TObject);
begin
  btnEagle.Enabled := False;
  if not Assigned(FWatchThread) then
    SetupWatchThread;

  if FWatchThread.Suspended then
    FWatchThread.Start;

  FWatchThread.WatchFromDB;
end;

procedure TMainForm.edtFilterChange(Sender: TObject);
begin
  if not Visible then
    Exit;

  timerFilterDebounce.Enabled := False;
  timerFilterDebounce.Enabled := True;
end;

procedure TMainForm.FormKeyPress(Sender: TObject; var Key: char);
begin
  case key of
    #27: if eagleOptions.escToMinimize then
      Application.Minimize;
  end;
end;

procedure TMainForm.timerFilterDebounceTimer(Sender: TObject);
begin
  timerFilterDebounce.Enabled := False;
  RefreshFileTree;
end;

procedure TMainForm.menuOptionsClick(Sender: TObject);
var
  options: TOptionsForm;
begin
  options := TOptionsForm.Create(self);
  try
    options.ShowModal;
  finally
    if options.shouldRefreshFileTree then
      RefreshFileTree;

    if options.shouldRestartIPCServer then begin
      StopIPCServer;
      SetupIPCServer;
    end;

    options.Free;
  end;
end;

procedure TMainForm.FormCloseQuery(Sender: TObject; var CanClose: boolean);
begin
  if eagleOptions.closeToTray then begin
    CanClose := False;
    Visible := False;
  end;
end;

procedure TMainForm.FormWindowStateChange(Sender: TObject);
begin
  if (WindowState = wsMinimized) and eagleOptions.minimizeToTray then begin
    WindowState := wsNormal;
    Hide;
  end;
end;

procedure TMainForm.traySearchClick(Sender: TObject);
begin
  RestoreSearchForm;
end;

procedure TMainForm.trayQuitClick(Sender: TObject);
begin
  Application.Terminate;
end;

procedure TMainForm.RestoreSearchForm;
begin
  edtFilter.Text := ''; // must be first
  Visible := True;
  edtFilter.SetFocus;
end;

// TEST
procedure TMainForm.FormClick(Sender: TObject);
begin
  Memo1.Lines.Add(benchStamp.GetAllTimestamps);
end;

{$REGION 'FileTree context menu'}
function TMainForm.LoadFileRecordFromTree(out fileRecord: TEagleFileRecord): boolean;
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

procedure TMainForm.mnuCopyNameClick(Sender: TObject);
var
  fileRecord: TEagleFileRecord;
begin
  if not LoadFileRecordFromTree(fileRecord) then
    Exit;

  Clipboard.AsText := fileRecord.Name;
end;

procedure TMainForm.mnuCopyPathAndNameClick(Sender: TObject);
var
  fileRecord: TEagleFileRecord;
begin
  if not LoadFileRecordFromTree(fileRecord) then
    Exit;

  Clipboard.AsText := IncludeTrailingPathDelimiter(fileRecord.Path) + fileRecord.Name;
end;

procedure TMainForm.mnuCopyPathClick(Sender: TObject);
var
  fileRecord: TEagleFileRecord;
begin
  if not LoadFileRecordFromTree(fileRecord) then
    Exit;

  Clipboard.AsText := IncludeTrailingPathDelimiter(fileRecord.Path);
end;

procedure TMainForm.mnuOpenFolderClick(Sender: TObject);
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

  if opened then
    ApplyAfterOpenAction;
end;

procedure TMainForm.mnuOpenFileClick(Sender: TObject);
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

  if opened then
    ApplyAfterOpenAction;
end;

procedure TMainForm.ApplyAfterOpenAction;
begin
  if eagleOptions.afterOpenAction = oaMinimize then
    WindowState := wsMinimized;
end;

procedure TMainForm.menuAboutClick(Sender: TObject);
begin
  OpenURL('https://github.com/DarkByte/Eagle/blob/main/README.md');
end;

procedure TMainForm.fileTreeMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: integer);
var
  clickedNode: PVirtualNode;
  fileRecord: TEagleFileRecord;
  itemAction: TItemAction;
begin
  itemAction := iaIgnore;

  if (Button = mbLeft) and (ssDouble in Shift) then
    itemAction := eagleOptions.doubleClickAction
  else
    if Button = mbMiddle then
      itemAction := eagleOptions.middleClickAction
    else
      if (Button = mbLeft) and (ssCtrl in Shift) then
        itemAction := eagleOptions.ctrlClickAction
      else
        if (Button = mbLeft) and (ssAlt in Shift) then
          itemAction := eagleOptions.altClickAction
        else
          if (Button = mbLeft) and (ssShift in Shift) then
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

{$ENDREGION}

{$REGION 'FileTree'}
procedure TMainForm.RefreshFileTree;
var
  filterText: string;
  r, g, b: byte;
  limit: integer;
begin
  Row1RGB := fileTree.colors.borderColor;
  if eagleOptions.alternatingColors then begin
    ColorToRGB(Row1RGB, r, g, b);
    Row2RGB := RGB(r - 10, g - 10, b - 10);
  end else
    Row2RGB := Row1RGB;

  limit := 0;
  if eagleOptions.limitResults then
    limit := eagleOptions.limitCount;

  filterText := Trim(edtFilter.Text);
  FFileRecords := FEagleDB.GetFiles(filterText, eagleOptions.searchPath, limit);
  if FSortColumn <> NoColumn then
    SortFileRecords(FFileRecords, integer(FSortColumn), FSortDirection = sdDescending);
  PopulateFileTree;

  Memo1.Lines.Add('New records added: ' + IntToStr(Length(FFileRecords)));
end;

procedure TMainForm.SetupFileTree;
var
  Column: TVirtualTreeColumn;
begin
  fileTree.Header.Columns.Clear;

  Column := fileTree.Header.Columns.Add;
  Column.Text := 'Name';
  Column.Width := eagleOptions.colName;

  Column := fileTree.Header.Columns.Add;
  Column.Text := 'Path';
  Column.Width := eagleOptions.colPath;

  Column := fileTree.Header.Columns.Add;
  Column.Text := 'Size';
  Column.Width := eagleOptions.colSize;

  Column := fileTree.Header.Columns.Add;
  Column.Text := 'Date';
  Column.Width := eagleOptions.colDate;

  fileTree.Header.MainColumn := 0;
  fileTree.TreeOptions.SelectionOptions := fileTree.TreeOptions.SelectionOptions + [toFullRowSelect];
  fileTree.OnHeaderClick := @FileTreeHeaderClick;
  fileTree.OnGetText := @FileTreeGetText;
  fileTree.OnBeforeCellPaint := @FileTreeBeforeCellPaint;
end;

procedure TMainForm.FileTreeHeaderClick(Sender: TVTHeader; HitInfo: TVTHeaderHitInfo);
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

  SortFileRecords(FFileRecords, integer(FSortColumn), FSortDirection = sdDescending);
  PopulateFileTree;
end;

procedure TMainForm.FileTreeGetText(Sender: TBaseVirtualTree; Node: PVirtualNode; Column: TColumnIndex; TextType: TVSTTextType;
  var CellText: string);
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
    2: if eagleOptions.prettySize then
        CellText := PrettySize(FFileRecords[NodeIndex].Size)
      else
        CellText := IntToStr(FFileRecords[NodeIndex].Size);
    3: if eagleOptions.showOnlyDate then
        CellText := FormatDateTime('dd.mm.yyyy', FileDateToDateTime(FFileRecords[NodeIndex].Time))
      else
        CellText := FormatDateTime('dd.mm.yyyy hh:nn', FileDateToDateTime(FFileRecords[NodeIndex].Time));
  end;
end;

procedure TMainForm.FileTreeBeforeCellPaint(Sender: TBaseVirtualTree; TargetCanvas: TCanvas; Node: PVirtualNode;
  Column: TColumnIndex; CellPaintMode: TVTCellPaintMode; CellRect: TRect; var ContentRect: TRect);
var
  NodeIndex: integer;
  RowColor: TColor;
begin
  NodeIndex := Sender.AbsoluteIndex(Node);

  if (NodeIndex mod 2) = 0 then
    RowColor := Row1RGB
  else
    RowColor := Row2RGB;

  TargetCanvas.Brush.Color := RowColor;
  TargetCanvas.FillRect(CellRect);
  ContentRect := CellRect;
end;

procedure TMainForm.PopulateFileTree;
begin
  fileTree.Clear;
  fileTree.RootNodeCount := Length(FFileRecords);
  fileTree.Refresh;
end;
{$ENDREGION}

{$REGION TWatchThread delegate methods}
procedure TMainForm.HandleInitialScan(const AFiles: TEagleImportFileRecords; const ACount: integer; const AIsFinal: boolean);
{$IFDEF EAGLE_MEM_PROFILE}
var
  afterSync, afterRefresh: THeapStatus;
{$ENDIF}
begin
  try
    if (ACount > 0) and (not FInitialScanImportActive) then begin
      FInitialScanImportActive := True;
      FInitialScanImportedCount := 0;

      {$IFDEF EAGLE_MEM_PROFILE}
      FInitialScanBeforeSync := GetHeapStatus;
      Memo1.Lines.Add(Format('[MEM] before SyncFiles allocated=%d free=%d addr=%d',
        [FInitialScanBeforeSync.TotalAllocated, FInitialScanBeforeSync.TotalFree, FInitialScanBeforeSync.TotalAddrSpace]));
      LogProcessMemorySnapshot(Memo1, 'before SyncFiles');
      {$ENDIF}

      Memo1.Lines.Add(benchStamp.StampNow('Saving to DB...'));
      benchStamp.InsertTime('Updating DB');
      FEagleDB.BeginSyncFiles;
    end;

    if ACount > 0 then begin
      FEagleDB.ImportFilesBatch(AFiles, ACount);
      Inc(FInitialScanImportedCount, ACount);
      Exit;
    end;

    if not AIsFinal then
      Exit;

    if not FInitialScanImportActive then begin
      FInitialScanImportActive := True;
      FInitialScanImportedCount := 0;

      {$IFDEF EAGLE_MEM_PROFILE}
      FInitialScanBeforeSync := GetHeapStatus;
      Memo1.Lines.Add(Format('[MEM] before SyncFiles allocated=%d free=%d addr=%d',
        [FInitialScanBeforeSync.TotalAllocated, FInitialScanBeforeSync.TotalFree, FInitialScanBeforeSync.TotalAddrSpace]));
      LogProcessMemorySnapshot(Memo1, 'before SyncFiles');
      {$ENDIF}

      Memo1.Lines.Add(benchStamp.StampNow('Saving to DB...'));
      benchStamp.InsertTime('Updating DB');
      FEagleDB.BeginSyncFiles;
    end;

    FEagleDB.EndSyncFiles;
    FInitialScanImportActive := False;
  except
    if FInitialScanImportActive then begin
      FEagleDB.CancelSyncFiles;
      FInitialScanImportActive := False;
      FInitialScanImportedCount := 0;
    end;

    raise;
  end;

  Memo1.Lines.Add(benchStamp.StampNow('Finished search...'));
  benchStamp.InsertTime('Finished watchThread');
  Memo1.Lines.Add('Found ' + IntToStr(FInitialScanImportedCount) + ' files!');

  benchStamp.InsertTime('Updated DB');
  Memo1.Lines.Add(benchStamp.StampNow('Saved to DB!'));

  {$IFDEF EAGLE_MEM_PROFILE}
  afterSync := GetHeapStatus;
  Memo1.Lines.Add(Format('[MEM] after SyncFiles allocated=%d free=%d addr=%d delta_alloc=%d',
    [afterSync.TotalAllocated, afterSync.TotalFree, afterSync.TotalAddrSpace,
     Int64(afterSync.TotalAllocated) - Int64(FInitialScanBeforeSync.TotalAllocated)]));
  LogProcessMemorySnapshot(Memo1, 'after SyncFiles');
  {$ENDIF}

  RefreshFileTree;

  {$IFDEF EAGLE_MEM_PROFILE}
  afterRefresh := GetHeapStatus;
  Memo1.Lines.Add(Format('[MEM] after RefreshFileTree allocated=%d free=%d addr=%d delta_from_sync=%d delta_total=%d',
    [afterRefresh.TotalAllocated, afterRefresh.TotalFree, afterRefresh.TotalAddrSpace,
     Int64(afterRefresh.TotalAllocated) - Int64(afterSync.TotalAllocated),
     Int64(afterRefresh.TotalAllocated) - Int64(FInitialScanBeforeSync.TotalAllocated)]));
  LogProcessMemorySnapshot(Memo1, 'after RefreshFileTree');
  {$ENDIF}

  Memo1.Lines.Add('[DB_POPULATED] ' + IntToStr(FInitialScanImportedCount) + ' files');
  FInitialScanImportedCount := 0;
end;

procedure TMainForm.HandleCreate(const APath: string);
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

procedure TMainForm.HandleRename(const AOldPath, ANewPath: string);
begin
  FEagleDB.RenamePath(AOldPath, ANewPath);
  RefreshFileTree;
end;

procedure TMainForm.HandleDelete(const APath: string);
begin
  FEagleDB.DeletePath(APath);
  RefreshFileTree;
end;

procedure TMainForm.HandleLog(const AMessage: string);
begin
  Memo1.Lines.Add(AMessage);
end;

procedure TMainForm.HandleScanProgress(const ACount: integer);
begin
  Memo1.Lines.Add('[SCAN] ' + IntToStr(ACount) + ' files found so far...');
end;

procedure TMainForm.HandleWatchDone;
begin
  btnEagle.Enabled := True;
end;
{$ENDREGION}

end.
