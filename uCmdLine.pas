unit uCmdLine;

// Command-line switches that print something and exit without starting the
// GUI:
//
//   --version            "filey <version>", then copyright and licence lines
//   --license/--licence  the full text of license.txt (from the embedded
//                        FILEY-SRC.ZIP, so it always matches this build)
//   --help, -h (and /? on Windows)  the list of these switches
//
// Anything else on the command line is left alone and the GUI starts as
// usual: widgetsets take their own options (Qt's -platform, -style, GTK's
// --display, ...), so an unknown switch is not treated as an error.
//
// The first line of --version output is relied on by bundleme.sh, which
// reads the second word of it as the version used in the AppImage name.
// Keep it exactly "filey <major.minor.release.build>".
//
// Windows: filey.exe is a GUI-subsystem program, so it has no console of
// its own. Output goes, in order of preference, to:
//   1. a redirected stdout (filey.exe --version > v.txt, or a pipe), as
//      UTF-8 bytes;
//   2. the console of the program that started it (cmd.exe, PowerShell),
//      attached with AttachConsole and written with WriteConsoleW, so
//      non-ASCII characters (the (C) sign in the copyright) display
//      correctly whatever the console codepage;
//   3. a message box, when there is neither (started from a shortcut or
//      the Run dialog).
// cmd.exe does not wait for GUI programs, so its prompt is printed before
// filey's output; press Enter to get a fresh prompt, or use
// "start /wait filey --version".

{$mode objfpc}{$H+}

interface

// True when a switch above was found and handled: the caller should exit
// without starting the GUI. ExitCode is set (0 on success, 1 if the
// requested text could not be produced).
function HandleCommandLine: Boolean;

// The version string, e.g. '3.1.0.798', from the executable's version
// resource; '' if the resource cannot be read.
function GetAppVersion: String;

implementation

uses
  {$IFDEF WINDOWS}
  Windows,
  {$ENDIF}
  Classes, SysUtils, uManagedUtils;

const
  APP_NAME = 'filey';
  ZIP_RESOURCE_NAME = 'FILEY-SRC.ZIP';
  LICENSE_FILE_NAME = 'license.txt';
  // Used only if the version resource has no LegalCopyright string.
  FALLBACK_COPYRIGHT = 'Copyright (C) Mark A Paley Software';
  LICENSE_SUMMARY =
    'License GPLv2+: GNU GPL version 2 or later ' +
    '<https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>';
  NO_WARRANTY =
    'This is free software: you are free to change and redistribute it.' +
    LineEnding + 'There is NO WARRANTY, to the extent permitted by law.';
  UTF8_BOM = #$EF#$BB#$BF;

type
  TCmdAction = (caNone, caVersion, caLicense, caHelp);

{$IFDEF WINDOWS}
const
  ATTACH_PARENT_PROCESS = DWORD(-1);

// Declared here rather than taken from the Windows unit, whose FPC 3.2
// declaration of AttachConsole is not guaranteed - the same pattern
// filey.lpr uses for SetThemeAppProperties.
function CmdLineAttachConsole(dwProcessId: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'AttachConsole';
{$ENDIF}

// --- Text ---------------------------------------------------------------

function GetAppVersion: String;
var
  VerInfo: TSmartVersionInfo;
begin
  Result := '';
  if not VerInfo.LoadLocalFileInfo then Exit;
  // TSmartVersionInfo.VersionString returns '0.0.0.0' when nothing was
  // loaded; LoadLocalFileInfo succeeded here, so an empty string means the
  // resource exists but has no FileVersion/ProductVersion.
  Result := Trim(VerInfo.VersionString);
end;

function LicenseText(out AText: String): Boolean; forward;

// The "Copyright ..." line of the embedded license.txt. Not the version
// resource's LegalCopyright: its "©" comes back through fcl-res's
// UTF-16 -> String conversion, which mangles it unless a widestring
// manager happens to be installed. license.txt is the same text the
// About -> License tab shows, so the two cannot disagree.
function GetCopyright: String;
var
  Lic: String;
  Lines: TSmartStrings;
  i: Integer;
begin
  Result := FALLBACK_COPYRIGHT;
  if not LicenseText(Lic) then Exit;
  Lines.Value.Text := Lic;
  for i := 0 to Lines.Value.Count - 1 do
    if Pos('copyright', LowerCase(TrimLeft(Lines.Value[i]))) = 1 then
      Exit(Trim(Lines.Value[i]));
end;

function VersionText(out AText: String): Boolean;
var
  Ver: String;
  SB: TStringBuilder;
begin
  Ver := GetAppVersion;
  Result := Ver <> '';
  // An unreadable version gives a first line whose second word is not a
  // version number, so bundleme.sh stops with a clear message instead of
  // naming the AppImage after a made-up one.
  if not Result then Ver := '(version unknown)';
  SB := TStringBuilder.Create;
  try
    SB.Append(APP_NAME).Append(' ').Append(Ver).Append(LineEnding);
    SB.Append(GetCopyright).Append(LineEnding);
    SB.Append(LICENSE_SUMMARY).Append(LineEnding);
    SB.Append(NO_WARRANTY).Append(LineEnding);
    AText := SB.ToString;
  finally
    SB.Free;
  end;
end;

// license.txt as stored in the embedded FILEY-SRC.ZIP: the same copy the
// About -> License tab shows (TForm1.tsLicenseShow), read straight from
// the executable so nothing has to be extracted to disk first.
function LicenseText(out AText: String): Boolean;
var
  Res: TSmartResourceStream;
  Unz: TSmartUnzipper;
  MS: TSmartMemoryStream;
  SrcStream: TMemoryStream;
  Raw: RawByteString;
  Lines: TSmartStrings;
begin
  AText := '';
  Result := False;
  try
    Res.Setup(HInstance, ZIP_RESOURCE_NAME, RT_RCDATA);
    // QuickExtractToStream hands over a new stream (or nil, if the zip has
    // no such entry); "MS.Value :=" takes ownership of it, as in
    // TForm1.LoadBundledDoc.
    SrcStream := Unz.QuickExtractToStream(Res.Value, ZIP_RESOURCE_NAME,
      LICENSE_FILE_NAME);
    if not Assigned(SrcStream) then Exit;
    MS.Value := SrcStream;
    Raw := '';
    SetLength(Raw, MS.Value.Size);
    if Length(Raw) > 0 then
    begin
      MS.Value.Position := 0;
      MS.Value.ReadBuffer(Raw[1], Length(Raw));
    end;
    if Copy(Raw, 1, Length(UTF8_BOM)) = UTF8_BOM then
      Delete(Raw, 1, Length(UTF8_BOM));
    // license.txt is UTF-8. Tag the bytes as such (no conversion) so the
    // TStrings assignment below keeps them unchanged on every platform.
    SetCodePage(Raw, CP_UTF8, False);
    // Through TStrings so CRLF or LF in the file both come out as this
    // platform's line ending.
    Lines.Value.Text := Raw;
    AText := Lines.Value.Text;
    Result := AText <> '';
  except
    // A missing resource or a damaged zip: report "could not be read".
    AText := '';
    Result := False;
  end;
end;

function HelpText: String;
var
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    SB.Append('Usage: ').Append(APP_NAME).Append(' [option]')
      .Append(LineEnding).Append(LineEnding);
    SB.Append('With no option, the ').Append(APP_NAME)
      .Append(' window opens.').Append(LineEnding).Append(LineEnding);
    SB.Append('Options:').Append(LineEnding);
    SB.Append('  --version   show the version and licence summary, then exit')
      .Append(LineEnding);
    SB.Append('  --license   show the full licence text, then exit')
      .Append(LineEnding);
    SB.Append('  --help      show this help, then exit').Append(LineEnding);
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

// --- Output -------------------------------------------------------------

{$IFDEF WINDOWS}
// Writes UTF-8 AText to H: as UTF-16 when H is a console (WriteConsoleW
// ignores the console codepage), otherwise as the UTF-8 bytes themselves
// (a file or a pipe).
function WriteToHandle(H: THandle; const AText: String): Boolean;
var
  Mode, Written: DWORD;
  W: UnicodeString;
  P: PWideChar;
  Remaining, Chunk: DWORD;
begin
  Result := False;
  if (H = 0) or (H = INVALID_HANDLE_VALUE) then Exit;
  if GetConsoleMode(H, Mode) then
  begin
    W := UTF8Decode(AText);
    P := PWideChar(W);
    Remaining := Length(W);
    // WriteConsoleW can refuse very large buffers; licence text is small,
    // but write in chunks anyway.
    while Remaining > 0 do
    begin
      Chunk := Remaining;
      if Chunk > 8192 then Chunk := 8192;
      Written := 0;
      if not WriteConsoleW(H, P, Chunk, Written, nil) or (Written = 0) then
        Exit;
      Inc(P, Written);
      Dec(Remaining, Written);
    end;
    Result := True;
  end
  else
  begin
    Written := 0;
    Result := (AText = '') or
      (WriteFile(H, AText[1], Length(AText), Written, nil) and
      (Written = DWORD(Length(AText))));
  end;
end;

function WriteOut(const AText: String; AIsError: Boolean): Boolean;
const
  STD_HANDLE: array[Boolean] of DWORD = (STD_OUTPUT_HANDLE, STD_ERROR_HANDLE);
var
  H: THandle;
  Caption: UnicodeString;
  Flags: UINT;
begin
  // 1. Redirected stdout/stderr: a GUI program still inherits those.
  H := GetStdHandle(STD_HANDLE[AIsError]);
  if WriteToHandle(H, AText) then Exit(True);
  // 2. The console of whatever started us.
  if CmdLineAttachConsole(ATTACH_PARENT_PROCESS) then
  begin
    H := CreateFileW('CONOUT$', GENERIC_READ or GENERIC_WRITE,
      FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
    if H <> INVALID_HANDLE_VALUE then
      try
        // A leading line break: cmd.exe has already printed its prompt.
        if WriteToHandle(H, LineEnding + AText) then Exit(True);
      finally
        CloseHandle(H);
      end;
  end;
  // 3. No console at all.
  Caption := UnicodeString(APP_NAME);
  if AIsError then Flags := MB_OK or MB_ICONERROR
  else Flags := MB_OK or MB_ICONINFORMATION;
  Result := MessageBoxW(0, PWideChar(UTF8Decode(AText)),
    PWideChar(Caption), Flags) <> 0;
end;
{$ELSE}
function WriteOut(const AText: String; AIsError: Boolean): Boolean;
begin
  Result := True;
  try
    if AIsError then
    begin
      Write(StdErr, AText);
      Flush(StdErr);
    end
    else
    begin
      Write(Output, AText);
      Flush(Output);
    end;
  except
    // stdout closed early (e.g. "filey --license | head -n 3"): nothing
    // more can be written, and that is not this program's failure.
    on E: EInOutError do Result := False;
  end;
end;
{$ENDIF}

// --- Parsing ------------------------------------------------------------

function ParseAction: TCmdAction;
var
  i: Integer;
  Arg: String;
begin
  Result := caNone;
  for i := 1 to ParamCount do
  begin
    // Option names are ASCII, so LowerCase (ASCII-only) is exact here and
    // leaves any non-ASCII bytes of other arguments untouched.
    Arg := LowerCase(ParamStr(i));
    if (Arg = '--version') then Exit(caVersion)
    else if (Arg = '--license') or (Arg = '--licence') then Exit(caLicense)
    else if (Arg = '--help') or (Arg = '-h')
      {$IFDEF WINDOWS} or (Arg = '/?'){$ENDIF} then Exit(caHelp);
  end;
end;

function HandleCommandLine: Boolean;
var
  Text: String;
begin
  Result := True;
  ExitCode := 0;
  case ParseAction of
    caNone:
      Result := False;
    caVersion:
      begin
        if not VersionText(Text) then ExitCode := 1;
        WriteOut(Text, False);
      end;
    caLicense:
      if LicenseText(Text) then WriteOut(Text, False)
      else
      begin
        ExitCode := 1;
        WriteOut(APP_NAME + ': the licence text could not be read from ' +
          'this executable.' + LineEnding + LICENSE_SUMMARY + LineEnding, True);
      end;
    caHelp:
      WriteOut(HelpText, False);
  end;
end;

end.
