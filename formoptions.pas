unit formOptions;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, ExtCtrls, StdCtrls,
  ComCtrls, FileCtrl, IniFiles, utils, Types;

type

  { TOptionsForm }

  TOptionsForm = class(TForm)
    btnSave: TButton;
    btnPathAdd: TButton;
    btnPathOptions: TButton;
    btnPathRemove: TButton;
    cbRecursive: TCheckBox;
    Label1: TLabel;
    pathListBox: TListBox;
    pages: TPageControl;
    tabLocations: TTabSheet;
    tabPreferences: TTabSheet;
    tabSearch: TTabSheet;
    procedure btnPathAddClick(Sender: TObject);
    procedure btnPathRemoveClick(Sender: TObject);
    procedure cbRecursiveChange(Sender: TObject);
    procedure pathListBoxSelectionChange(Sender: TObject; User: boolean);
    procedure FormShow(Sender: TObject);
    procedure btnSaveClick(Sender: TObject);
  private
    watchRecursively: Boolean;

    procedure EnableButtons(enable: boolean);
  public

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
  pathListBox.Items.Clear;
  LoadConfig;

  cbRecursive.Checked := eagleOptions.watchRecursively;
  pathListBox.Items := eagleOptions.paths;
end;

procedure TOptionsForm.btnSaveClick(Sender: TObject);
begin
  eagleOptions.watchRecursively := cbRecursive.Checked;
  eagleOptions.paths.Text := pathListBox.Items.Text;

  SaveConfig;
  Close;
end;

// ACTIONS
procedure TOptionsForm.cbRecursiveChange(Sender: TObject);
begin
  watchRecursively := cbRecursive.Checked;
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
