unit utils;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, EagleDB;

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
function FullCurrentTime: string;
function GetEagleDataDir: string;
function GetEagleConfigDir: string;

procedure LoadConfig;
procedure SaveConfig;
procedure ApplyRunOnStartup;

function PrettySize(size: int64): string;

function EndsWith(const Value, Suffix: string): boolean;
function IsIgnoredTempFileName(const FileName: string): boolean;

function EncodePathForFileURL(const APath: string): string;
function SumArray(list: array of integer): integer;

// Sort FileTree data
function CompareFileRecords(const A, B: TEagleFileRecord; const AColumn: integer; const ADescending: boolean): integer; inline;
procedure SortFileRecords(var AFileRecords: TEagleFileRecords; const AColumn: integer; const ADescending: boolean);

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
  Result := FormatDateTime('hh:nn:ss.zzz', Now);
end;

function FullCurrentTime: string;
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
    eagleOptions.searchPath   := ini.ReadBool('Search', 'SearchPath', True);
    eagleOptions.prettySize   := ini.ReadBool('Search', 'PrettySize', True);
    eagleOptions.showOnlyDate := ini.ReadBool('Search', 'ShowOnlyDate', False);

    eagleOptions.ctrlClickAction   := IntegerToItemAction(ini.ReadInteger('Search', 'CtrlClickAction', Ord(iaIgnore)), iaIgnore);
    eagleOptions.altClickAction    := IntegerToItemAction(ini.ReadInteger('Search', 'AltClickAction', Ord(iaIgnore)), iaIgnore);
    eagleOptions.shiftClickAction  := IntegerToItemAction(ini.ReadInteger('Search', 'ShiftClickAction', Ord(iaIgnore)), iaIgnore);
    eagleOptions.doubleClickAction := IntegerToItemAction(ini.ReadInteger('Search', 'DoubleClickAction', Ord(iaIgnore)), iaIgnore);
    eagleOptions.middleClickAction := IntegerToItemAction(ini.ReadInteger('Search', 'MiddleClickAction', Ord(iaIgnore)), iaIgnore);

    eagleOptions.watchRecursively := ini.ReadBool('Paths', 'WatchRecursively', True);
    Count := ini.ReadInteger('Paths', 'Count', 0);
    lastPathCount := Count;
    for i := 1 to Count do begin
      path := ini.ReadString('Paths', 'Path' + IntToStr(i), '');
      if path <> '' then
        eagleOptions.paths.Add(path);
    end;

    eagleOptions.minimizeToTray := ini.ReadBool('Advanced', 'MinimizeToTray', False);
    eagleOptions.closeToTray := ini.ReadBool('Advanced', 'CloseToTray', False);
    eagleOptions.startMinimized := ini.ReadBool('Advanced', 'StartMinimized', False);
    eagleOptions.runOnStartup := ini.ReadBool('Advanced', 'RunOnStartup', False);
    eagleOptions.allowIPC := ini.ReadBool('Advanced', 'AllowIPC', False);

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
    ini.WriteBool('Search', 'PrettySize', eagleOptions.prettySize);
    ini.WriteBool('Search', 'ShowOnlyDate', eagleOptions.showOnlyDate);

    ini.WriteInteger('Search', 'CtrlClickAction', Ord(eagleOptions.ctrlClickAction));
    ini.WriteInteger('Search', 'AltClickAction', Ord(eagleOptions.altClickAction));
    ini.WriteInteger('Search', 'ShiftClickAction', Ord(eagleOptions.shiftClickAction));
    ini.WriteInteger('Search', 'DoubleClickAction', Ord(eagleOptions.doubleClickAction));
    ini.WriteInteger('Search', 'MiddleClickAction', Ord(eagleOptions.middleClickAction));

    ini.WriteBool('Paths', 'WatchRecursively', eagleOptions.watchRecursively);
    ini.WriteInteger('Paths', 'Count', eagleOptions.paths.Count);
    for i := 0 to eagleOptions.paths.Count - 1 do
      ini.WriteString('Paths', 'Path' + IntToStr(i + 1), eagleOptions.paths[i]);

    if eagleOptions.paths.Count < lastPathCount then
      for i := eagleOptions.paths.Count to lastPathCount do
        ini.DeleteKey('Paths', 'Path' + IntToStr(i + 1));

    ini.WriteBool('Advanced', 'MinimizeToTray', eagleOptions.minimizeToTray);
    ini.WriteBool('Advanced', 'CloseToTray', eagleOptions.closeToTray);
    ini.WriteBool('Advanced', 'StartMinimized', eagleOptions.startMinimized);
    ini.WriteBool('Advanced', 'RunOnStartup', eagleOptions.runOnStartup);
    ini.WriteBool('Advanced', 'AllowIPC', eagleOptions.allowIPC);
  finally
    ini.Free;
  end;
end;

procedure ApplyRunOnStartup;
const
  DESKTOP_FILENAME = 'eagle.desktop';
var
  autostartDir: string;
  desktopPath: string;
  f: TextFile;
begin
  autostartDir := IncludeTrailingPathDelimiter(GetEnvironmentVariable('HOME')) + '.config' + PathDelim + 'autostart';
  desktopPath  := IncludeTrailingPathDelimiter(autostartDir) + DESKTOP_FILENAME;

  if eagleOptions.runOnStartup then begin
    if not DirectoryExists(autostartDir) then
      ForceDirectories(autostartDir);

    AssignFile(f, desktopPath);
    Rewrite(f);
    try
      WriteLn(f, '[Desktop Entry]');
      WriteLn(f, 'Type=Application');
      WriteLn(f, 'Name=Eagle');
      WriteLn(f, 'Exec=' + ParamStr(0));
      WriteLn(f, 'Hidden=false');
      WriteLn(f, 'X-GNOME-Autostart-enabled=true');
      WriteLn(f, 'X-GNOME-Autostart-Delay=15');
    finally
      CloseFile(f);
    end;
  end else begin
    if FileExists(desktopPath) then
      DeleteFile(desktopPath);
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

// Sort FileTree data
function CompareFileRecords(const A, B: TEagleFileRecord; const AColumn: integer; const ADescending: boolean): integer;
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

  if Result = 0 then begin
    Result := CompareText(A.Path, B.Path);
    if Result = 0 then
      Result := CompareText(A.Name, B.Name);
  end;

  if ADescending then
    Result := -Result;
end;

procedure SortFileRecords(var AFileRecords: TEagleFileRecords; const AColumn: integer; const ADescending: boolean);

  procedure QuickSort(L, R: integer);
  var
    I, J: integer;
    Pivot, Temp: TEagleFileRecord;
  begin
    I     := L;
    J     := R;
    Pivot := AFileRecords[(L + R) div 2];

    repeat
      while CompareFileRecords(AFileRecords[I], Pivot, AColumn, ADescending) < 0 do
        Inc(I);
      while CompareFileRecords(AFileRecords[J], Pivot, AColumn, ADescending) > 0 do
        Dec(J);

      if I <= J then begin
        Temp := AFileRecords[I];
        AFileRecords[I] := AFileRecords[J];
        AFileRecords[J] := Temp;
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
  if Length(AFileRecords) < 2 then
    Exit;

  QuickSort(0, High(AFileRecords));
end;

begin
  LoadConfig;
end.
