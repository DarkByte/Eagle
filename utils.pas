unit utils;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils;

function CurrentTime: String;
function EndsWith(const Value, Suffix: string): boolean;
function IsIgnoredTempFileName(const FileName: string): boolean;

function EncodePathForFileURL(const APath: string): string;
function SumArray(list: array of integer): integer;

implementation

function CurrentTime: String;
begin
  Result := FormatDateTime('dd.mm hh:nn:ss.zzz', Now);
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

end.
