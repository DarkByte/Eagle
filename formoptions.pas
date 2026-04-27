unit formOptions;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, ExtCtrls, StdCtrls,
  ComCtrls, utils;

type
  { TOptionsForm }
  TOptionsForm = class(TForm)
    btnSave: TButton;
    btnPathAdd: TButton;
    btnPathOptions: TButton;
    btnPathRemove: TButton;

    cbCtrlClick: TComboBox;
    cbAltClick: TComboBox;
    cbCloseTray: TCheckBox;
    cbShiftClick: TComboBox;
    cbDoubleClick: TComboBox;
    cbMiddleClick: TComboBox;

    cbRecursive: TCheckBox;
    cbPrettySize: TCheckBox;
    cbStartMinimized: TCheckBox;
    cbRunStartup: TCheckBox;
    cbShowOnlyDate: TCheckBox;
    cbSearchPath: TCheckBox;
    cbMinimizeTray: TCheckBox;
    cbAllowIPC: TCheckBox;

    Label1: TLabel;
    Label2: TLabel;
    Label3: TLabel;
    Label4: TLabel;
    Label5: TLabel;
    Label6: TLabel;
    pathListBox: TListBox;
    pages: TPageControl;
    tabLocations: TTabSheet;
    tabSearchResults: TTabSheet;
    tabSearch: TTabSheet;
    tabAdvanced: TTabSheet;
    procedure btnPathAddClick(Sender: TObject);
    procedure btnPathRemoveClick(Sender: TObject);
    procedure cbRecursiveChange(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure pathListBoxSelectionChange(Sender: TObject; User: boolean);
    procedure FormShow(Sender: TObject);
    procedure btnSaveClick(Sender: TObject);
  private
    watchRecursively: boolean;

    procedure EnableButtons(enable: boolean);
  public
    shouldRefreshFileTree: boolean;
    shouldRestartIPCServer: boolean;

  end;

var
  frmOptions: TOptionsForm;

implementation

{$R *.lfm}

{ TOptionsForm }

procedure TOptionsForm.pathListBoxSelectionChange(Sender: TObject; User: boolean);
begin
  EnableButtons(True);
end;

procedure TOptionsForm.EnableButtons(enable: boolean);
begin
  //btnPathOptions.Enabled := enable;
  btnPathRemove.Enabled := enable;
end;

procedure TOptionsForm.FormShow(Sender: TObject);
begin
  shouldRefreshFileTree := False;
  pathListBox.Items.Clear;
  LoadConfig;

  cbRecursive.Checked := eagleOptions.watchRecursively;

  cbSearchPath.Checked   := eagleOptions.searchPath;
  cbPrettySize.Checked   := eagleOptions.prettySize;
  cbShowOnlyDate.Checked := eagleOptions.showOnlyDate;

  cbCtrlClick.ItemIndex   := Ord(eagleOptions.ctrlClickAction);
  cbAltClick.ItemIndex    := Ord(eagleOptions.altClickAction);
  cbShiftClick.ItemIndex  := Ord(eagleOptions.shiftClickAction);
  cbDoubleClick.ItemIndex := Ord(eagleOptions.doubleClickAction);
  cbMiddleClick.ItemIndex := Ord(eagleOptions.middleClickAction);

  pathListBox.Items := eagleOptions.paths;

  cbMinimizeTray.Checked := eagleOptions.minimizeToTray;
  cbCloseTray.Checked := eagleOptions.closeToTray;
  cbStartMinimized.Checked := eagleOptions.startMinimized;
  cbRunStartup.Checked     := eagleOptions.runOnStartup;
  cbAllowIPC.Checked       := eagleOptions.allowIPC;
end;

procedure TOptionsForm.btnSaveClick(Sender: TObject);
begin
  shouldRefreshFileTree := (eagleOptions.searchPath <> cbSearchPath.Checked) or (eagleOptions.prettySize <> cbPrettySize.Checked) or
    (eagleOptions.showOnlyDate <> cbShowOnlyDate.Checked);

  shouldRestartIPCServer := (eagleOptions.allowIPC <> cbAllowIPC.Checked);

  eagleOptions.watchRecursively := cbRecursive.Checked;

  eagleOptions.searchPath   := cbSearchPath.Checked;
  eagleOptions.prettySize   := cbPrettySize.Checked;
  eagleOptions.showOnlyDate := cbShowOnlyDate.Checked;

  eagleOptions.ctrlClickAction   := TItemAction(cbCtrlClick.ItemIndex);
  eagleOptions.altClickAction    := TItemAction(cbAltClick.ItemIndex);
  eagleOptions.shiftClickAction  := TItemAction(cbShiftClick.ItemIndex);
  eagleOptions.doubleClickAction := TItemAction(cbDoubleClick.ItemIndex);
  eagleOptions.middleClickAction := TItemAction(cbMiddleClick.ItemIndex);

  eagleOptions.paths.Text := pathListBox.Items.Text;

  eagleOptions.minimizeToTray := cbMinimizeTray.Checked;
  eagleOptions.closeToTray := cbCloseTray.Checked;
  eagleOptions.startMinimized := cbStartMinimized.Checked;
  eagleOptions.runOnStartup   := cbRunStartup.Checked;
  eagleOptions.allowIPC       := cbAllowIPC.Checked;

  SaveConfig;
  Close;
end;

// ACTIONS
procedure TOptionsForm.cbRecursiveChange(Sender: TObject);
begin
  watchRecursively := cbRecursive.Checked;
end;

procedure TOptionsForm.FormCreate(Sender: TObject);
begin
  pages.ActivePageIndex := 0;
end;

procedure TOptionsForm.btnPathRemoveClick(Sender: TObject);
begin
  pathListBox.Items.Delete(pathListBox.ItemIndex);
end;

procedure TOptionsForm.btnPathAddClick(Sender: TObject);
var
  selectedPath: string;
begin
  if SelectDirectory('Select folder to watch', '', selectedPath) then
    pathListBox.Items.Add(selectedPath);
end;

end.
