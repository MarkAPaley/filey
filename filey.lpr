program filey;

{$mode objfpc}
{$runtimechecks off} // or {$CR-}
{$H+}

uses
  //cmem, // c memory manager, supposed to cleam memory better
  // cthreads gives a Unix program its threads. The Browser tab downloads on
  // background threads (uBrowser.pas), so this is no longer left to the
  // UseCThreads define, which no build mode set. Without it, uBrowser falls
  // back to downloading on the main thread, and the window freezes while a
  // page loads.
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils, Forms, Interfaces, uCmdLine, uMain, uUtils;

  {$R *.res}

  {$IFDEF WINDOWS}
  // Declared directly against uxtheme.dll rather than relying on an FPC-
  // shipped uxtheme unit (not confirmed to exist for this target) - same
  // external-DLL-function pattern uOSDetector.pas already uses for
  // ntdll.dll's wine_get_version/RtlGetVersion. See the call site below
  // for why this is being tried.
  procedure SetThemeAppProperties(dwFlags: DWORD); stdcall;
    external 'uxtheme.dll' name 'SetThemeAppProperties';
  {$ENDIF}

  procedure MainProc;
  begin
    {$if declared(useHeapTrace)}
    //setHeapTraceOutput('heap.trc');
    {$endIf}
    RequireDerivedFormResource := True;
    DebugLog('Before Application.Initialize');
    Application.Initialize;
    {$IFDEF WINDOWS}
    // Wine-only tab-control crash workaround. Every Windows Debug launch
    // under Wine (never on real Windows 8.1, tested both via the Lazarus
    // IDE and standalone - see CHANGES.txt) hits an EAccessViolation inside
    // Wine's own uxtheme.dll while creating pcMain's first tab control
    // handle (dlls/uxtheme/msstyles.c/system.c -> dlls/comctl32/tab.c). Two
    // build-setting theories (UseXPManifest, TrashVariables) were already
    // ruled out - this is a genuine Wine bug, not an app bug.
    // SetThemeAppProperties(0) tells uxtheme not to theme anything in this
    // process, which routes ALL subsequent control creation through the
    // plain, unthemed comctl32 path instead of the themed one that crashes
    // - called here, before Application.CreateForm, so no window handle
    // (themed or not) exists yet anywhere in the process.

    // ONLY under Wine (GetWineVersion is '' anywhere else). This used to run
    // on real Windows too, where it broke the Open button: without
    // STAP_ALLOW_CONTROLS, Windows refuses to create the Vista-style file
    // dialog at all (CoCreateInstance(CLSID_FileOpenDialog) fails with
    // 0x80040111), and the LCL then just returns False from Execute -
    // nothing shown, nothing reported. It also switched visual styles off
    // for every control on real Windows.
    if GetWineVersion <> '' then
    begin
      DebugLog('Before SetThemeAppProperties(0) (Wine)');
      try
        SetThemeAppProperties(0);
      except
        on E: Exception do
          LogError('SetThemeAppProperties(0) failed', E);
      end;
    end;
    {$ENDIF}
    DebugLog('Before Application.CreateForm(TForm1, Form1)');
    Application.CreateForm(TForm1, Form1);
    DebugLog('Before Application.Run');
    Application.Run;
  end;

begin
  // --version, --license/--licence, --help (and /? on Windows): print,
  // then exit without opening the window (see uCmdLine). ExitCode is
  // already set: 0, or 1 if the text could not be produced.
  if HandleCommandLine then Exit;
  DebugLog('Before MainProc');
  MainProc;
end.
