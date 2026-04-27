unit utils;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils;

type
  TItemAction = (
    iaIgnore = 0,
    iaOpenFile = 1,
    iaOpenFolder = 2,
    iaCopyName = 3,
    iaCopyPath = 4,
    iaCopyPathName = 5
    );

  TEagleOptions = record
    paths: TStringList;
    watchRecursively: boolean;
    searchPath: boolean;
    prettySize: boolean;
    showOnlyDate: boolean;
    minimizeToTray: boolean;
    closeToTray: boolean;
    startMinimized: boolean;
    runOnStartup: boolean;
    allowIPC: boolean;
    ctrlClickAction: TItemAction;
    altClickAction: TItemAction;
    shiftClickAction: TItemAction;
    doubleClickAction: TItemAction;
    middleClickAction: TItemAction;
  end;

function CurrentTime: string;
function GetEagleDataDir: string;
function GetEagleConfigDir: string;

procedure LoadConfig;
procedure SaveConfig;

function PrettySize(size: int64): string;

function EndsWith(const Value, Suffix: string): boolean;
function IsIgnoredTempFileName(const FileName: string): boolean;

function EncodePathForFileURL(const APath: string): string;
function SumArray(list: array of integer): integer;

var
  eagleOptions: TEagleOptions;

implementation

uses
  IniFiles;

const
  INI_FILENAME = 'eagle.ini';

var
  configPath, configDir: string;
  lastPathCount: integer;

function IntegerToItemAction(const Value: integer; const defaultValue: TItemAction): TItemAction;
begin
  if (Value >= Ord(Low(TItemAction))) and (Value <= Ord(High(TItemAction))) then
    Result := TItemAction(Value)
  else
    Result := defaultValue;
end;

function CurrentTime: string;
begin
  Result := FormatDateTime('dd.mm hh:nn:ss.zzz', Now);
end;

function GetEagleDataDir: string;
var
  xdgDataHome, homeDir: string;
begin
  xdgDataHome := Trim(GetEnvironmentVariable('XDG_DATA_HOME'));
  if xdgDataHome <> '' then begin
    Result := IncludeTrailingPathDelimiter(xdgDataHome) + 'Eagle';
    Exit;
  end;

  homeDir := Trim(GetEnvironmentVariable('HOME'));
  if homeDir <> '' then begin
    Result := IncludeTrailingPathDelimiter(homeDir) + '.local' + PathDelim + 'share' + PathDelim + 'Eagle';
    Exit;
  end;

  Result := '.local' + PathDelim + 'share' + PathDelim + 'Eagle';
end;

function GetEagleConfigDir: string;
var
  xdgConfigHome, homeDir: string;
begin
  xdgConfigHome := Trim(GetEnvironmentVariable('XDG_CONFIG_HOME'));
  if xdgConfigHome <> '' then begin
    Result := IncludeTrailingPathDelimiter(xdgConfigHome) + 'Eagle';
    Exit;
  end;

  homeDir := Trim(GetEnvironmentVariable('HOME'));
  if homeDir <> '' then begin
    Result := IncludeTrailingPathDelimiter(homeDir) + '.config' + PathDelim + 'Eagle';
    Exit;
  end;

  Result := '.config' + PathDelim + 'Eagle';
end;

// INI file
procedure LoadConfig;
var
  ini: TIniFile;
  path: string;
  i, Count: integer;
begin
  eagleOptions.searchPath := True;
  eagleOptions.prettySize := True;
  eagleOptions.showOnlyDate := False;
  eagleOptions.minimizeToTray := False;
  eagleOptions.closeToTray := False;
  eagleOptions.startMinimized := False;
  eagleOptions.runOnStartup := False;
  eagleOptions.allowIPC := False;
  eagleOptions.ctrlClickAction := iaIgnore;
  eagleOptions.altClickAction := iaIgnore;
  eagleOptions.shiftClickAction := iaIgnore;
  eagleOptions.doubleClickAction := iaIgnore;
  eagleOptions.middleClickAction := iaIgnore;

  if not Assigned(eagleOptions.paths) then
    eagleOptions.paths := TStringList.Create
  else
    eagleOptions.paths.Clear;

  configDir  := IncludeTrailingPathDelimiter(GetEagleConfigDir);
  configPath := configDir + INI_FILENAME;
  if not FileExists(configPath) then
    Exit;

  ini := TIniFile.Create(configPath);
  try
    eagleOptions.searchPath      := ini.ReadBool('Search', 'SearchPath', True);
    eagleOptions.watchRecursively := ini.ReadBool('Paths', 'WatchRecursively', True);
    eagleOptions.prettySize      := ini.ReadBool('Preferences', 'PrettySize', True);
    eagleOptions.showOnlyDate    := ini.ReadBool('Preferences', 'ShowOnlyDate', False);
    eagleOptions.minimizeToTray  := ini.ReadBool('Preferences', 'MinimizeToTray', False);
    eagleOptions.closeToTray     := ini.ReadBool('Preferences', 'CloseToTray', False);
    eagleOptions.ctrlClickAction := IntegerToItemAction(ini.ReadInteger('Preferences', 'CtrlClickAction', Ord(iaIgnore)), iaIgnore);
    eagleOptions.altClickAction  := IntegerToItemAction(ini.ReadInteger('Preferences', 'AltClickAction', Ord(iaIgnore)), iaIgnore);
    eagleOptions.shiftClickAction := IntegerToItemAction(ini.ReadInteger('Preferences', 'ShiftClickAction', Ord(iaIgnore)), iaIgnore);
    eagleOptions.doubleClickAction := IntegerToItemAction(ini.ReadInteger('Preferences', 'DoubleClickAction', Ord(iaIgnore)), iaIgnore);
    eagleOptions.middleClickAction := IntegerToItemAction(ini.ReadInteger('Preferences', 'MiddleClickAction', Ord(iaIgnore)), iaIgnore);

    eagleOptions.startMinimized := ini.ReadBool('Preferences', 'StartMinimized', False);
    eagleOptions.runOnStartup := ini.ReadBool('Preferences', 'RunOnStartup', False);
    eagleOptions.allowIPC := ini.ReadBool('Preferences', 'AllowIPC', False);

    Count := ini.ReadInteger('Paths', 'Count', 0);
    lastPathCount := Count;
    for i := 1 to Count do begin
      path := ini.ReadString('Paths', 'Path' + IntToStr(i), '');
      if path <> '' then
        eagleOptions.paths.Add(path);
    end;
  finally
    ini.Free;
  end;
end;

procedure SaveConfig;
var
  ini: TIniFile;
  i: integer;
begin
  configDir := IncludeTrailingPathDelimiter(GetEagleConfigDir);
  if (configDir <> '') and (not DirectoryExists(configDir)) then
    ForceDirectories(configDir);

  configPath := configDir + INI_FILENAME;

  ini := TIniFile.Create(configPath);
  try
    ini.WriteBool('Search', 'SearchPath', eagleOptions.searchPath);

    ini.WriteBool('Paths', 'WatchRecursively', eagleOptions.watchRecursively);
    ini.WriteInteger('Paths', 'Count', eagleOptions.paths.Count);
    ini.WriteBool('Preferences', 'PrettySize', eagleOptions.prettySize);
    ini.WriteBool('Preferences', 'ShowOnlyDate', eagleOptions.showOnlyDate);
    ini.WriteBool('Preferences', 'MinimizeToTray', eagleOptions.minimizeToTray);
    ini.WriteBool('Preferences', 'CloseToTray', eagleOptions.closeToTray);
    ini.WriteBool('Preferences', 'StartMinimized', eagleOptions.startMinimized);
    ini.WriteBool('Preferences', 'RunOnStartup', eagleOptions.runOnStartup);
    ini.WriteBool('Preferences', 'AllowIPC', eagleOptions.allowIPC);
    ini.WriteInteger('Preferences', 'CtrlClickAction', Ord(eagleOptions.ctrlClickAction));
    ini.WriteInteger('Preferences', 'AltClickAction', Ord(eagleOptions.altClickAction));
    ini.WriteInteger('Preferences', 'ShiftClickAction', Ord(eagleOptions.shiftClickAction));
    ini.WriteInteger('Preferences', 'DoubleClickAction', Ord(eagleOptions.doubleClickAction));
    ini.WriteInteger('Preferences', 'MiddleClickAction', Ord(eagleOptions.middleClickAction));

    for i := 0 to eagleOptions.paths.Count - 1 do
      ini.WriteString('Paths', 'Path' + IntToStr(i + 1), eagleOptions.paths[i]);

    if eagleOptions.paths.Count < lastPathCount then
      for i := eagleOptions.paths.Count to lastPathCount do
        ini.DeleteKey('Paths', 'Path' + IntToStr(i + 1));
  finally
    ini.Free;
  end;
end;

function PrettySize(size: int64): string;
const
  sizes: array of string = (' B', ' KB', ' MB', ' GB', ' TB');
var
  i: integer;
  tempSize: int64;
begin
  tempSize := size;
  for i := Low(sizes) to High(sizes) do
    if tempSize < 1024 then
      Break
    else
      tempSize := tempSize div 1024;

  Result := IntToStr(tempSize) + sizes[i];
end;

function EndsWith(const Value, Suffix: string): boolean;
begin
  Result := (Length(Value) >= Length(Suffix)) and (Copy(Value, Length(Value) - Length(Suffix) + 1, Length(Suffix)) = Suffix);
end;

function IsIgnoredTempFileName(const FileName: string): boolean;
var
  lowerName: string;
begin
  if (FileName = '') or (FileName = '(unknown)') then
    Exit(False);

  lowerName := LowerCase(FileName);

  Result :=
    (Pos('.goutputstream-', lowerName) = 1) or (Pos('.~lock.', lowerName) = 1) or (Pos('.fuse_hidden', lowerName) = 1) or
    EndsWith(lowerName, '~') or EndsWith(lowerName, '.swp') or EndsWith(lowerName, '.swo') or EndsWith(lowerName, '.swx') or
    EndsWith(lowerName, '.tmp') or EndsWith(lowerName, '.temp') or EndsWith(lowerName, '.part') or EndsWith(lowerName, '.crdownload');
end;

function EncodePathForFileURL(const APath: string): string;
begin
  Result := APath;
  Result := StringReplace(Result, '%', '%25', [rfReplaceAll]);
  Result := StringReplace(Result, '#', '%23', [rfReplaceAll]);
  Result := StringReplace(Result, '?', '%3F', [rfReplaceAll]);
  Result := StringReplace(Result, '''', '%27', [rfReplaceAll]);
  Result := StringReplace(Result, ' ', '%20', [rfReplaceAll]);
end;

function SumArray(list: array of integer): integer;
var
  i: integer;
begin
  Result := 0;
  for i := Low(list) to High(list) do
    Inc(Result, list[i]);
end;

begin
  LoadConfig;
end.
