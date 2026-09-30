{ Filey - uTerminal.pas

Copyright (C) 2026 Mark A Paley

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program; if not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>.

Report bugs and questions at <https://gitlab.com/MarkAPaley/filey/-/issues>.
}

{ ==============================================================================
   uTerminal

   Opens a terminal window with a command typed in at the prompt, ready for
   the user to press Enter - used by About > Info for the "Install with:
   sudo ..." rows. Nothing is run without the user pressing Enter, and the
   command can be edited or cancelled (Ctrl+C) first.

   Linux has no single way to open "the" terminal, so FindTerminal looks for
   one in this order:
     1. $TERMINAL, if the user has set it;
     2. the desktop's own terminal (XDG_CURRENT_DESKTOP: KDE -> konsole,
        GNOME -> ptyxis/kgx/gnome-terminal, XFCE -> xfce4-terminal, ...);
     3. xdg-terminal-exec (the emerging freedesktop standard), then Debian's
        x-terminal-emulator;
     4. a fixed list of common terminals.
   Each terminal takes "run this program" differently (-e, -x, --, a single
   string, or nothing at all), which TTerminalArgStyle records.

   Terminals cannot pre-fill their own prompt, so the terminal runs bash,
   and bash's "read -e -i TEXT" puts the command on an editable readline
   line. When the user has finished, the script writes the command's exit
   code to a marker file. That is how TTerminalLaunch.Poll knows the
   install is over: gnome-terminal, ptyxis and xfce4-terminal hand the
   window to an already-running server and exit at once, so waiting for
   the launched process to end says nothing about the window.

   AppImage: a program started from inside an AppImage inherits APPDIR,
   APPIMAGE, OWD and any search paths the AppImage runtime pointed into
   its temporary /tmp/.mount_xxxx folder (LD_LIBRARY_PATH, XDG_DATA_DIRS,
   GTK_PATH, ...). A terminal - and pacman or apt inside it - could then
   load filey's bundled libraries instead of the system's.
   BuildCleanEnvironment removes all of that before the terminal starts.

   Linux/Unix only; on Windows TerminalSupported is False and nothing else
   here does anything useful (there, filey's tools are bundled).
============================================================================== }

unit uTerminal;

{$mode objfpc}{$H+}

interface

uses
  Classes, Process, SysUtils;

type
  // How a terminal is told which program to run.
  TTerminalArgStyle = (
    tasRest,          // term PROGRAM ARGS...          (kitty, foot, xdg-terminal-exec)
    tasDashE,         // term -e PROGRAM ARGS...       (konsole, xterm, alacritty, ...)
    tasDashX,         // term -x PROGRAM ARGS...       (xfce4-terminal, mate-terminal, terminator)
    tasDashDash,      // term -- PROGRAM ARGS...       (gnome-terminal, kgx, ptyxis)
    tasWezterm,       // wezterm start -- PROGRAM ARGS...
    tasDashEString);  // term -e "PROGRAM ARGS..."     (one shell-quoted string: tilix, qterminal, lxterminal)

  TTerminalInfo = record
    Exe: String;        // full path
    Name: String;       // file name, for messages
    Style: TTerminalArgStyle;
  end;

  TTerminalLaunchState = (
    tlsWaiting,    // the terminal is open; the user hasn't finished yet
    tlsDone,       // the script finished; ExitCode is the command's
    tlsFailed);    // the terminal could not start, or closed with an error
                   // before the script ever ran

  { TTerminalLaunch
    One terminal window opened by Start. Keep the object until Poll says
    tlsDone or tlsFailed (or the caller gives up waiting): it reaps the
    terminal process so it doesn't linger as a zombie, and Destroy deletes
    the marker file. Destroy never closes the terminal window. }
  TTerminalLaunch = class
  private
    FCommand: String;
    FMarkerFile: String;
    FProcess: TProcess;
    FStartTick: QWord;
    FTerminal: TTerminalInfo;
    function ReadMarker(out AExitCode: Integer): Boolean;

  public
    // Milliseconds since Start.
    function ElapsedMs: QWord;
    // Non-blocking. AExitCode is set only for tlsDone: 0 when the command
    // succeeded, its exit code otherwise, 130 when the user pressed Ctrl+C
    // and 129 when the window was closed before the command finished.
    function Poll(out AExitCode: Integer): TTerminalLaunchState;
    // Opens a terminal with ACommand waiting at the prompt. AAppDir is the
    // AppImage's $APPDIR to scrub from the environment ('' when filey is
    // not running from an AppImage). False, with AError saying why, if no
    // terminal or no bash could be found, or the terminal would not start.
    function Start(const ACommand, AAppDir: String; out AError: String): Boolean;
    destructor Destroy; override;
    property Command: String read FCommand;
    property Terminal: TTerminalInfo read FTerminal;
  end;

// True on platforms where a terminal can be opened at all (Linux/Unix).
function TerminalSupported: Boolean;

// The terminal Start would use. False if none was found.
function FindTerminal(out AInfo: TTerminalInfo): Boolean;

// s as one word for bash: wrapped in single quotes, with any single quote
// inside written as '\''. Safe for every byte, UTF-8 included.
function ShellQuote(const s: String): String;

// The current environment, with everything the AppImage runtime added for
// AAppDir taken out (see the unit banner). With AAppDir = '' it is just a
// copy of the environment.
procedure BuildCleanEnvironment(const AAppDir: String; AEnv: TStrings);

implementation

uses
  FileUtil, LazFileUtils, uUtils;

type
  TKnownTerminal = record
    Name: String;
    Style: TTerminalArgStyle;
  end;

const
  BASH_NAME = 'bash';

  // Variables the AppImage runtime (type 2) and AppRun scripts set for the
  // program inside it. They mean nothing to anything else.
  APPIMAGE_ONLY_VARS: array[0..4] of String =
    ('APPDIR', 'APPIMAGE', 'ARGV0', 'OWD', 'APPRUN_DIR');

  // Common terminals, best-behaved first. The desktop's own terminal and
  // $TERMINAL are tried before any of these (see FindTerminal).
  KNOWN_TERMINALS: array[0..19] of TKnownTerminal = (
    (Name: 'konsole';          Style: tasDashE),
    (Name: 'gnome-terminal';   Style: tasDashDash),
    (Name: 'ptyxis';           Style: tasDashDash),
    (Name: 'kgx';              Style: tasDashDash),
    (Name: 'xfce4-terminal';   Style: tasDashX),
    (Name: 'mate-terminal';    Style: tasDashX),
    (Name: 'terminator';       Style: tasDashX),
    (Name: 'tilix';            Style: tasDashEString),
    (Name: 'alacritty';        Style: tasDashE),
    (Name: 'kitty';            Style: tasRest),
    (Name: 'foot';             Style: tasRest),
    (Name: 'wezterm';          Style: tasWezterm),
    (Name: 'qterminal';        Style: tasDashEString),
    (Name: 'lxterminal';       Style: tasDashEString),
    (Name: 'deepin-terminal';  Style: tasDashE),
    (Name: 'terminology';      Style: tasDashEString),
    (Name: 'urxvt';            Style: tasDashE),
    (Name: 'rxvt';             Style: tasDashE),
    (Name: 'st';               Style: tasDashE),
    (Name: 'xterm';            Style: tasDashE));

// The bash script the terminal runs. AMarker is where the exit code goes.
// It is kept in the variable m, so the trap below (itself single-quoted)
// never has to quote the path a second time.
function BuildScript(const ACommand, AMarker: String): String;
var
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create(512);
  try
    SB.Append('m=').Append(ShellQuote(AMarker)).Append(#10);
    // Closing the window (SIGHUP) or a kill (SIGTERM) still leaves a
    // marker, so filey isn't left waiting for a window that is gone.
    SB.Append('trap ''printf %s 129 > "$m"; exit 129'' HUP TERM').Append(#10);
    // Ctrl+C at the prompt cancels: marker 130, and the window closes.
    // (With a trap that doesn't exit, bash's readline just carries on
    // reading, so Ctrl+C would appear to do nothing.)
    SB.Append('trap ''printf %s 130 > "$m"; exit 130'' INT').Append(#10);
    SB.Append('printf ''%s\n%s\n\n'' ')
      .Append(ShellQuote('filey: press Enter to run this command.'))
      .Append(' ')
      .Append(ShellQuote('You can edit it first, or press Ctrl+C to cancel.'))
      .Append(#10);
    SB.Append('rc=130').Append(#10);
    SB.Append('if IFS= read -r -e -i ').Append(ShellQuote(ACommand))
      .Append(' -p ''$ '' c; then').Append(#10);
    // Ctrl+C while the command runs stops the command, not this script,
    // so its result is still shown and recorded.
    SB.Append('  trap ''rc=130'' INT').Append(#10);
    SB.Append('  rc=0').Append(#10);
    SB.Append('  if [ -n "$c" ]; then eval "$c"; rc=$?; fi').Append(#10);
    SB.Append('fi').Append(#10);
    SB.Append('printf %s "$rc" > "$m"').Append(#10);
    SB.Append('if [ "$rc" = 0 ]; then').Append(#10);
    SB.Append('  printf ''\n%s\n'' ')
      .Append(ShellQuote('Done. filey will check for the program again.'))
      .Append(#10);
    SB.Append('else').Append(#10);
    SB.Append('  printf ''\n%s %s\n'' ')
      .Append(ShellQuote('The command ended with exit code'))
      .Append(' "$rc."').Append(#10);
    SB.Append('fi').Append(#10);
    SB.Append('printf ''%s'' ')
      .Append(ShellQuote('Press Enter to close this window.')).Append(#10);
    SB.Append('IFS= read -r _').Append(#10);
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

// Fills AParams with what AInfo's terminal needs to run ABash with AScript.
procedure BuildTerminalParams(const AInfo: TTerminalInfo;
  const ABash, AScript: String; AParams: TStrings);
begin
  AParams.Clear;
  case AInfo.Style of
    tasRest: ;
    tasDashE: AParams.Add('-e');
    tasDashX: AParams.Add('-x');
    tasDashDash: AParams.Add('--');
    tasWezterm:
      begin
        AParams.Add('start');
        AParams.Add('--');
      end;
    tasDashEString:
      begin
        AParams.Add('-e');
        // These split the string themselves, with shell quoting rules.
        AParams.Add(ShellQuote(ABash) + ' -c ' + ShellQuote(AScript));
        Exit;
      end;
  end;
  AParams.Add(ABash);
  AParams.Add('-c');
  AParams.Add(AScript);
end;

// The terminals that belong to the running desktop, best first. Matched
// against XDG_CURRENT_DESKTOP, which may list several names ("ubuntu:GNOME",
// "X-Cinnamon"), case-insensitively.
procedure DesktopTerminals(AList: TStrings);
var
  sDesktop: String;

  function Has(const AName: String): Boolean;
  begin
    Result := Pos(AName, sDesktop) > 0;
  end;

begin
  // ASCII-only names, so LowerCase is exact; a non-ASCII byte in the value
  // is left alone and simply never matches.
  sDesktop := LowerCase(GetEnvironmentVariable('XDG_CURRENT_DESKTOP') + ':' +
    GetEnvironmentVariable('DESKTOP_SESSION'));
  if Has('kde') or Has('plasma') then AList.Add('konsole');
  if Has('gnome') or Has('unity') or Has('pop') then
  begin
    AList.Add('ptyxis');
    AList.Add('kgx');
    AList.Add('gnome-terminal');
  end;
  if Has('cinnamon') then AList.Add('gnome-terminal');
  if Has('budgie') then
  begin
    AList.Add('tilix');
    AList.Add('gnome-terminal');
  end;
  if Has('xfce') then AList.Add('xfce4-terminal');
  if Has('mate') then AList.Add('mate-terminal');
  if Has('lxqt') then AList.Add('qterminal');
  if Has('lxde') then AList.Add('lxterminal');
  if Has('deepin') then AList.Add('deepin-terminal');
  if Has('enlightenment') then AList.Add('terminology');
end;

// Full path of AName on PATH, or ''. A name containing '/' is checked as
// it stands.
function ExeOnPath(const AName: String): String;
begin
  Result := '';
  if AName = '' then Exit;
  if Pos('/', AName) > 0 then
  begin
    if FileIsExecutable(AName) then Result := AName;
    Exit;
  end;
  Result := FindDefaultExecutablePath(AName);
end;

// True if AName is one of KNOWN_TERMINALS.
function IsKnownTerminal(const AName: String): Boolean;
var
  i: Integer;
begin
  for i := Low(KNOWN_TERMINALS) to High(KNOWN_TERMINALS) do
    if KNOWN_TERMINALS[i].Name = AName then Exit(True);
  Result := False;
end;

function ShellQuote(const s: String): String;
var
  c: Char;
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create(Length(s) + 8);
  try
    SB.Append('''');
    // Byte-wise is UTF-8 safe: the quote is ASCII, and no byte of a
    // multi-byte UTF-8 sequence can equal it.
    for c in s do
      if c = '''' then SB.Append('''\''''')
      else
        SB.Append(c);
    SB.Append('''');
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

// AValue with every ':'-separated entry inside AAppDir removed. '' if that
// leaves nothing.
function StripAppDirEntries(const AValue, AAppDir: String): String;
var
  Parts: TStringArray;
  sPart: String;
  SB: TStringBuilder;
begin
  Parts := AValue.Split([':']);
  SB := TStringBuilder.Create(Length(AValue));
  try
    for sPart in Parts do
    begin
      // Byte prefix match is right: Linux paths are case-sensitive, and a
      // UTF-8 prefix is a byte prefix.
      if (sPart = '') or (Copy(sPart, 1, Length(AAppDir)) = AAppDir) or
        (sPart + '/' = AAppDir) then Continue;
      if SB.Length > 0 then SB.Append(':');
      SB.Append(sPart);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

procedure BuildCleanEnvironment(const AAppDir: String; AEnv: TStrings);
var
  i, p: Integer;
  sAppDir, sEntry, sName, sOriginal, sValue: String;

  function IsAppImageOnly(const AName: String): Boolean;
  var
    sVar: String;
  begin
    for sVar in APPIMAGE_ONLY_VARS do
      if AName = sVar then Exit(True);
    // APPIMAGE_ORIGINAL_*, APPIMAGE_UUID, APPIMAGE_SILENT_INSTALL, ...
    Result := Pos('APPIMAGE_', AName) = 1;
  end;

begin
  AEnv.Clear;
  sAppDir := '';
  if AAppDir <> '' then
    sAppDir := IncludeTrailingPathDelimiter(ExpandFileName(AAppDir));
  for i := 1 to GetEnvironmentVariableCount do
  begin
    sEntry := GetEnvironmentString(i);
    p := Pos('=', sEntry);
    // Entries such as "=C:=C:\" (Windows) or no '=' at all are kept as they
    // are; there is nothing of the AppImage's in them.
    if (sAppDir = '') or (p <= 1) then
    begin
      AEnv.Add(sEntry);
      Continue;
    end;
    sName := Copy(sEntry, 1, p - 1);
    sValue := Copy(sEntry, p + 1, MaxInt);
    if IsAppImageOnly(sName) then Continue;
    // Some AppRun scripts save what a variable held before they changed
    // it. When they did, that original is the right value to hand on.
    sOriginal := GetEnvironmentVariable('APPIMAGE_ORIGINAL_' + sName);
    if sOriginal <> '' then
      sValue := sOriginal
    else if Pos(ExcludeTrailingPathDelimiter(sAppDir), sValue) > 0 then
      sValue := StripAppDirEntries(sValue, sAppDir);
    if sValue = '' then Continue;
    AEnv.Add(sName + '=' + sValue);
  end;
end;

// The argument style for a terminal known by its file name; tasDashE (the
// x-terminal-emulator convention most terminals follow) for any other.
function StyleForName(const AName: String): TTerminalArgStyle;
var
  i: Integer;
begin
  for i := Low(KNOWN_TERMINALS) to High(KNOWN_TERMINALS) do
    if KNOWN_TERMINALS[i].Name = AName then Exit(KNOWN_TERMINALS[i].Style);
  if AName = 'xdg-terminal-exec' then Exit(tasRest);
  Result := tasDashE;
end;

function TerminalSupported: Boolean;
begin
  {$IFDEF UNIX}
  Result := True;
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

function TryTerminal(const AName: String; out AInfo: TTerminalInfo): Boolean;
var
  sPath, sReal, sRealName: String;
begin
  AInfo := Default(TTerminalInfo);
  sPath := ExeOnPath(AName);
  Result := sPath <> '';
  if not Result then Exit;
  AInfo.Exe := sPath;
  AInfo.Name := ExtractFileName(sPath);
  // x-terminal-emulator (and often $TERMINAL) is a symlink - on Debian a
  // chain of them through /etc/alternatives. When it ends at a terminal
  // this unit knows, use that terminal's own way of being told what to
  // run: Debian's gnome-terminal.wrapper, for one, reads "-e" differently
  // from the x-terminal-emulator convention.
  sReal := ReadAllLinks(sPath, False);
  if sReal <> '' then
  begin
    sRealName := ExtractFileName(sReal);
    if Copy(sRealName, Length(sRealName) - 7, 8) = '.wrapper' then
      SetLength(sRealName, Length(sRealName) - 8);
    if (sRealName <> AInfo.Name) and IsKnownTerminal(sRealName) and
      (ExeOnPath(sRealName) <> '') then
    begin
      AInfo.Exe := ExeOnPath(sRealName);
      AInfo.Name := sRealName;
    end;
  end;
  AInfo.Style := StyleForName(AInfo.Name);
end;

function FindTerminal(out AInfo: TTerminalInfo): Boolean;
var
  Candidates: TStringList;
  i: Integer;
  sUser: String;
begin
  AInfo := Default(TTerminalInfo);
  Result := False;
  if not TerminalSupported then Exit;
  Candidates := TStringList.Create;
  try
    // $TERMINAL may carry options ("kitty --single-instance"); only its
    // first word is a program name.
    sUser := Trim(GetEnvironmentVariable('TERMINAL'));
    if Pos(' ', sUser) > 0 then SetLength(sUser, Pos(' ', sUser) - 1);
    if sUser <> '' then Candidates.Add(sUser);
    DesktopTerminals(Candidates);
    Candidates.Add('xdg-terminal-exec');
    Candidates.Add('x-terminal-emulator');
    for i := Low(KNOWN_TERMINALS) to High(KNOWN_TERMINALS) do
      Candidates.Add(KNOWN_TERMINALS[i].Name);
    for i := 0 to Candidates.Count - 1 do
      if TryTerminal(Candidates[i], AInfo) then Exit(True);
  finally
    Candidates.Free;
  end;
end;

{ TTerminalLaunch }

function TTerminalLaunch.ElapsedMs: QWord;
begin
  if FStartTick = 0 then Exit(0);
  Result := GetTickCount64 - FStartTick;
end;

function TTerminalLaunch.Poll(out AExitCode: Integer): TTerminalLaunchState;
var
  bRunning: Boolean;
begin
  AExitCode := -1;
  if FProcess = nil then Exit(tlsFailed);
  if ReadMarker(AExitCode) then
  begin
    // Reap the terminal if it has gone, so it isn't left a zombie.
    FProcess.Running;
    Exit(tlsDone);
  end;
  // Running also reaps the process once it has exited.
  bRunning := FProcess.Running;
  // A terminal that hands the window to a server (gnome-terminal, ptyxis,
  // xfce4-terminal) exits straight away with 0 - that is normal. Exiting
  // with an error before the script wrote anything means it never ran.
  if (not bRunning) and (FProcess.ExitStatus <> 0) and
    not ReadMarker(AExitCode) then
  begin
    AExitCode := FProcess.ExitStatus;
    Exit(tlsFailed);
  end;
  Result := tlsWaiting;
end;

function TTerminalLaunch.ReadMarker(out AExitCode: Integer): Boolean;
var
  SL: TStringList;
begin
  AExitCode := -1;
  Result := (FMarkerFile <> '') and FileExists(FMarkerFile);
  if not Result then Exit;
  SL := TStringList.Create;
  try
    try
      SL.LoadFromFile(FMarkerFile);
      // bash may still be writing it; an empty file is read again next time.
      if (SL.Count = 0) or (Trim(SL[0]) = '') then Exit(False);
      AExitCode := StrToIntDef(Trim(SL[0]), -1);
    except
      Result := False;
    end;
  finally
    SL.Free;
  end;
end;

function TTerminalLaunch.Start(const ACommand, AAppDir: String;
  out AError: String): Boolean;
var
  sBash: String;
begin
  Result := False;
  AError := '';
  FCommand := ACommand;
  if not TerminalSupported then
  begin
    AError := 'Opening a terminal is only done on Linux.';
    Exit;
  end;
  if Trim(ACommand) = '' then
  begin
    AError := 'There is no command to run.';
    Exit;
  end;
  if not FindTerminal(FTerminal) then
  begin
    AError := 'No terminal program was found.';
    Exit;
  end;
  sBash := ExeOnPath(BASH_NAME);
  if sBash = '' then
  begin
    AError := 'bash was not found, so the command cannot be typed in for you.';
    Exit;
  end;
  // Unique per launch: the process ID tells two running copies of filey
  // apart, and the tick count two launches from the same copy.
  FMarkerFile := CombinePath(GetTempDir(False),
    sb(['filey-install-', IntToStr(GetProcessID), '-',
    IntToStr(GetTickCount64), '.rc']));
  DeleteFile(FMarkerFile);
  FProcess := TProcess.Create(nil);
  try
    FProcess.Executable := FTerminal.Exe;
    BuildTerminalParams(FTerminal, sBash, BuildScript(ACommand, FMarkerFile),
      FProcess.Parameters);
    BuildCleanEnvironment(AAppDir, FProcess.Environment);
    // filey's own open files (the .DBF tables among them) are none of the
    // terminal's business.
    FProcess.InheritHandles := False;
    FProcess.Options := [];
    FProcess.Execute;
    FStartTick := GetTickCount64;
    DebugLog(sb(['uTerminal: opened ', FTerminal.Name, ' for "', ACommand,
      '"; marker ', FMarkerFile]));
    Result := True;
  except
    on E: Exception do
    begin
      AError := sb(['Could not start ', FTerminal.Name, ': ', E.Message]);
      LogError('uTerminal.Start: ' + AError);
      FreeAndNil(FProcess);
    end;
  end;
end;

destructor TTerminalLaunch.Destroy;
begin
  if Assigned(FProcess) then
  begin
    // One last chance to reap it. Freeing a TProcess never kills the
    // program it started, so a terminal still open stays open.
    FProcess.Running;
    FreeAndNil(FProcess);
  end;
  if FMarkerFile <> '' then DeleteFile(FMarkerFile);
  inherited Destroy;
end;

end.
