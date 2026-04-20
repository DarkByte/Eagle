unit utils;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils;

function EndsWith(const Value, Suffix: string): boolean;
function IsIgnoredTempFileName(const FileName: string): boolean;

implementation

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

end.
