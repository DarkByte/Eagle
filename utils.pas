unit utils;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils;

type
  TEagleOptions = record
    paths: TStringList;
    watchRecursively: Boolean;
  end;

function CurrentTime: String;
function GetEagleDataDir: string;
function GetEagleConfigDir: string;

procedure LoadConfig;
procedure SaveConfig;

function EndsWith(const Value, Suffix: string): boolean;
function IsIgnoredTempFileName(const FileName: string): boolean;

function EncodePathForFileURL(const APath: string): string;
function SumArray(list: array of integer): integer;

var
  eagleOptions: TEagleOptions;

implementation

uses
  IniFiles;

var
  configPath, configDir: String;
  lastPathCount: Integer;

function CurrentTime: String;
begin
  Result := FormatDateTime('dd.mm hh:nn:ss.zzz', Now);
end;

function GetEagleDataDir: string;
var
  xdgDataHome: string;
  homeDir: string;
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
  xdgConfigHome: string;
  homeDir: string;
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
  configDir := IncludeTrailingPathDelimiter(GetEagleConfigDir);
  configPath := configDir + 'eagle.ini';
  if not FileExists(configPath) then
    Exit;

  ini := TIniFile.Create(configPath);
  try
    eagleOptions.watchRecursively := ini.ReadBool('Paths', 'WatchRecursively', True);

    if not Assigned(eagleOptions.paths) then
      eagleOptions.paths := TStringList.Create
    else
      eagleOptions.paths.Clear;

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

  configPath := configDir + 'eagle.ini';

  ini := TIniFile.Create(configPath);
  try
    ini.WriteBool('Paths', 'WatchRecursively', eagleOptions.watchRecursively);
    ini.WriteInteger('Paths', 'Count', eagleOptions.paths.Count);

    for i := 0 to eagleOptions.paths.Count - 1 do
      ini.WriteString('Paths', 'Path' + IntToStr(i + 1), eagleOptions.paths[i]);

    if eagleOptions.paths.Count < lastPathCount then
      for i := eagleOptions.paths.Count to lastPathCount do
        ini.DeleteKey('Paths', 'Path' + IntToStr(i + 1));
  finally
    ini.Free;
  end;
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
