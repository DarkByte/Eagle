program eagle;

{$mode objfpc}{$H+}

uses
  cthreads,
  Interfaces, // this includes the LCL widgetset
  Forms,
  Dialogs,
  SysUtils,
  TimeCheck,
  main,
  EagleDB,
  utils,
  formOptions, eagleipc { you can add units after this };

  {$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Scaled := True;

  {$PUSH}
  {$WARN 5044 OFF}
  Application.MainFormOnTaskbar := True;
  Application.ShowMainForm := not eagleOptions.startMinimized;
  {$POP}

  Application.Initialize;

  if isAnotherInstanceRunning then
    Halt;

  Application.CreateForm(TForm1, Form1);
  Application.Run;
end.
