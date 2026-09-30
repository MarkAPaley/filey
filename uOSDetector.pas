unit uOSDetector;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes
  {$IFDEF WINDOWS}
  , Windows, Registry, JwaWinNT {for TOSVersionInfoEx}
  {$ENDIF}
  {$IFDEF UNIX}
  , BaseUnix
  {$ENDIF};

type
  {$IFDEF WINDOWS}
  // 1. Define the Record
  //TOSVERSIONINFOEXW = record // already exists in JwaWinNT unit, same layout
  //  dwOSVersionInfoSize: DWORD;
  //  dwMajorVersion: DWORD;
  //  dwMinorVersion: DWORD;
  //  dwBuildNumber: DWORD;
  //  dwPlatformId: DWORD;
  //  szCSDVersion: array[0..127] of WideChar;
  //  wServicePackMajor: WORD;
  //  wServicePackMinor: WORD;
  //  wSuiteMask: WORD;
  //  wProductType: Byte;
  //  wReserved: Byte;
  //end;

  // 2. Define the Function Type SECOND
  TRtlGetVersion = function(var info: TOSVERSIONINFOEXW): LongInt; stdcall;
  TWineVerFunc = function: PChar; cdecl;
  // void wine_get_host_version(const char **sysname, const char **release)
  TWineHostVerProc = procedure(var sysname, release: PAnsiChar); cdecl;
  {$ENDIF}

  // Which package manager this Linux distribution uses, so filey can tell
  // the user the exact command that installs something it needs, instead
  // of a Debian-only "apt-get install" that is wrong on openSUSE, Fedora or
  // Arch. lpfUnknown on Windows, and on a distro none of the checks below
  // recognise.
  TLinuxPkgFamily = (lpfUnknown, lpfApt, lpfZypper, lpfDnf, lpfPacman);

  // Things filey uses but does not ship for Linux (see license.txt).
  TInstallable = (instOpenSSL, instFFprobe, instMKVToolNix);

  TOSReport = record
    // MarketingName plus DisplayVersion, without repeating the version when
    // MarketingName already contains it ("openSUSE Leap 15.6", not
    // "openSUSE Leap 15.6 15.6"). This is what should be shown to a user.
    DisplayName: String;
    DisplayVersion: String;
    DistroID: String;      // os-release ID, e.g. 'opensuse-leap', 'ubuntu'
    DistroIDLike: String;  // os-release ID_LIKE, e.g. 'suse opensuse'
    IsLinux: Boolean;
    IsWindows: Boolean;
    IsWine: Boolean;
    KernelVersion: String;
    MarketingName: String;
    PkgFamily: TLinuxPkgFamily;
    // Under Wine: the system Wine itself runs on, e.g. 'Linux 6.12.4-1-MANJARO'
    // or 'Darwin 23.6.0'. '' elsewhere, or if this Wine doesn't say.
    WineHost: String;
    WineVersion: String;
  end;

const
  // How InstallHint starts when it has an exact command; ExtractInstallCommand
  // looks for it.
  INSTALL_HINT_PREFIX = 'Install with: ';

function GetPreciseOSInfo: TOSReport;

// One line saying what filey is running on, for About > Info's "Platform"
// row and the like:
//   'Manjaro Linux (kernel 6.12.4-1-MANJARO)'
//   'Linux: Ubuntu 24.04.1 LTS (kernel 6.8.0-45-generic)'
//   'Windows 11 Pro 24H2 (build 10.0.26100)'
//   'Wine 9.19 on Linux 6.12.4-1-MANJARO (reports Windows 10 Pro)'
function PlatformSummary(const AReport: TOSReport): String;

// The real path of the .AppImage file this process was started from, or ''
// when it is not running from an AppImage (always '' on Windows).
// AExeName is the running executable (Application.ExeName). The AppImage
// runtime sets $APPIMAGE and $APPDIR for the program it starts, but child
// processes inherit them too - so the executable must actually live inside
// $APPDIR (the temporary /tmp/.mount_xxxx folder) to count.
function GetAppImagePath(const AExeName: String): String;

// The terminal command that installs AWhat on a distro of family AFamily,
// e.g. 'sudo zypper install ffmpeg-tools'. '' for lpfUnknown.
function InstallCommand(AFamily: TLinuxPkgFamily; AWhat: TInstallable): String;

// A full sentence telling the user how to install AWhat on this distro:
// the exact command when the family is known, otherwise the package name to
// look for in their package manager.
function InstallHint(AFamily: TLinuxPkgFamily; AWhat: TInstallable): String;

// The command inside a text InstallHint produced, wherever it sits in AText
// ('NOT LOADED - downloads will fail. Install with: sudo apt install
// openssl'), or '' if there is none. Anything after two spaces and a '('
// - a note added after the command, such as '  (double-click to copy)' -
// is not part of it.
function ExtractInstallCommand(const AText: String): String;

// --- Where an AppImage lives ------------------------------------------------
// An AppImage is a single file that runs wherever it is, so it is usually
// first run from wherever the browser saved it. These support offering,
// once, to move it somewhere it will stay (TForm1.AskToMoveAppImage).

// ~/Applications: where AppImageLauncher puts AppImages, and the de facto
// place for them.
function AppImageHomeDir: String;

// True if APath (the .AppImage file) is somewhere files tend not to stay:
// the XDG download folder (~/Downloads unless user-dirs.dirs says
// otherwise), /tmp, /var/tmp, $TMPDIR, or removable media (/media,
// /run/media, /mnt). Always False on Windows.
function IsTransientAppImageLocation(const APath: String): Boolean;

// The name of an AppImage manager (AppImageLauncher, Gear Lever) if one is
// installed, else ''. Such a manager decides where AppImages go, so filey
// shouldn't offer to move itself.
function AppImageManagerName: String;

// Moves ASource into ADestDir (created if needed), keeping its name and
// making sure it stays executable. A rename when both are on the same
// filesystem; otherwise a copy to a temporary name next to the destination,
// a rename over it, and then removal of the original. Safe while the
// AppImage is running: the running copy keeps the file it opened. ADest is
// the new path. False, with AError saying why, if it could not be moved
// (the original is then left as it was).
function MoveAppImage(const ASource, ADestDir: String;
  out ADest, AError: String): Boolean;

implementation

uses
  {$IFDEF UNIX}FileUtil,{$ENDIF}
  uUtils;

{$IFDEF LINUX}
function GetOSReleaseValue(const Key: String): String;
var
  List: TStringList;
  i: Integer;
  Line, SearchKey: String;
begin
  Result := '';
  if not FileExists('/etc/os-release') then Exit;

  List := TStringList.Create;
  try
    List.LoadFromFile('/etc/os-release');
    SearchKey := Key + '=';
    for i := 0 to List.Count - 1 do
    begin
      Line := List[i];
      if Pos(SearchKey, Line) = 1 then
      begin
        Result := Copy(Line, Length(SearchKey) + 1, MaxInt);
        Result := StringReplace(Result, '"', '', [rfReplaceAll]);
        Result := StringReplace(Result, '''', '', [rfReplaceAll]);
        Break;
      end;
    end;
  finally
    List.Free;
  end;
end;

// Matches one os-release ID/ID_LIKE word (already lowercase) to a family.
function FamilyFromWord(const AWord: String): TLinuxPkgFamily;
begin
  Result := lpfUnknown;
  if AWord = '' then Exit;
  // ID is e.g. 'opensuse-leap', 'opensuse-tumbleweed', 'sles', 'sled'.
  if (Pos('opensuse', AWord) = 1) or (AWord = 'suse') or
    (Pos('sle', AWord) = 1) then Exit(lpfZypper);
  case AWord of
    'debian', 'ubuntu', 'linuxmint', 'zorin', 'pop', 'elementary',
    'neon', 'kali', 'raspbian', 'mx':
      Result := lpfApt;
    'fedora', 'rhel', 'centos', 'rocky', 'almalinux', 'nobara',
    'ultramarine':
      Result := lpfDnf;
    'arch', 'manjaro', 'endeavouros', 'garuda', 'artix', 'cachyos':
      Result := lpfPacman;
  end;
end;

// ID is checked before ID_LIKE: a distro's own ID is the more specific of
// the two (Zorin: ID=zorin, ID_LIKE="ubuntu debian"). If neither is
// recognised, whichever package manager is actually installed decides.
function DetectPkgFamily(const AID, AIDLike: String): TLinuxPkgFamily;
var
  Words: TStringArray;
  w: String;
begin
  Result := FamilyFromWord(LowerCase(Trim(AID)));
  if Result <> lpfUnknown then Exit;
  Words := LowerCase(AIDLike).Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
  for w in Words do
  begin
    Result := FamilyFromWord(w);
    if Result <> lpfUnknown then Exit;
  end;
  if FileExists('/usr/bin/zypper') then Result := lpfZypper
  else if FileExists('/usr/bin/apt-get') then Result := lpfApt
  else if FileExists('/usr/bin/dnf') then Result := lpfDnf
  else if FileExists('/usr/bin/pacman') then Result := lpfPacman;
end;
{$ENDIF}

function MakeDisplayName(const AMarketingName, AVersion: String): String;
begin
  Result := AMarketingName;
  if (AVersion <> '') and (Pos(AVersion, AMarketingName) = 0) then
    Result := Result + ' ' + AVersion;
end;

function GetPreciseOSInfo: TOSReport;
var
  {$IFDEF WINDOWS}
  hNT: THandle;
  RtlGetVersion: TRtlGetVersion;
  WineHostProc: TWineHostVerProc;
  WineVerFunc: TWineVerFunc;
  pSysName, pRelease: PAnsiChar;
  ver: TOSVERSIONINFOEXW;
  reg: TRegistry;
  {$ENDIF}
  {$IFDEF LINUX}
  UName: UTSName;
  {$ENDIF}
begin
  Result.MarketingName := 'Unknown OS';
  Result.KernelVersion := '0.0.0';
  Result.IsWindows := False;
  Result.IsLinux := False;
  Result.IsWine := False;
  Result.WineVersion := '';
  Result.WineHost := '';
  Result.DisplayVersion := '';
  Result.DisplayName := '';
  Result.DistroID := '';
  Result.DistroIDLike := '';
  Result.PkgFamily := lpfUnknown;

  {$IFDEF WINDOWS}
  ver := Default(TOSVERSIONINFOEXW);
  Result.IsWindows := True;

  hNT := GetModuleHandle('ntdll.dll');
  if hNT <> 0 then
  begin
    // Cast Pointer to the specific function type
    WineVerFunc := TWineVerFunc(GetProcAddress(hNT, 'wine_get_version'));
    if Assigned(WineVerFunc) then
    begin
      Result.IsWine := True;
      Result.WineVersion := WineVerFunc();
      WineHostProc := TWineHostVerProc(GetProcAddress(hNT,
        'wine_get_host_version'));
      if Assigned(WineHostProc) then
      begin
        pSysName := nil;
        pRelease := nil;
        WineHostProc(pSysName, pRelease);
        if Assigned(pSysName) then
        begin
          Result.WineHost := StrPas(pSysName);
          if Assigned(pRelease) then
            Result.WineHost := Trim(Result.WineHost + ' ' + StrPas(pRelease));
        end;
      end;
    end;

    RtlGetVersion := TRtlGetVersion(GetProcAddress(hNT, 'RtlGetVersion'));
    if Assigned(RtlGetVersion) then
    begin
      FillChar(ver, SizeOf(ver), 0);
      ver.dwOSVersionInfoSize := SizeOf(ver);
      if RtlGetVersion(ver) = 0 then Result.KernelVersion :=
          Format('%d.%d.%d', [ver.dwMajorVersion, ver.dwMinorVersion,
          ver.dwBuildNumber]);
    end;
  end;

  reg := TRegistry.Create(KEY_READ);
  try
    reg.RootKey := HKEY_LOCAL_MACHINE;
    if reg.OpenKeyReadOnly('SOFTWARE\Microsoft\Windows NT\CurrentVersion') then
    begin
      Result.MarketingName := reg.ReadString('ProductName');
      Result.DisplayVersion := reg.ReadString('DisplayVersion');

      // Fix for Windows 11 reporting as Windows 10 in registry
      if (ver.dwMajorVersion = 10) and (ver.dwBuildNumber >= 22000) and
        (Pos('Windows 10', Result.MarketingName) > 0) then
        Result.MarketingName := StringReplace(Result.MarketingName,
          'Windows 10', 'Windows 11', []);
    end;
  finally
    reg.Free;
  end;
  {$ENDIF}

  {$IFDEF LINUX}
  Result.IsLinux := True;
  UName := Default(UTSName);
  if fpUname(UName) = 0 then Result.KernelVersion := StrPas(UName.Release);

  Result.MarketingName := GetOSReleaseValue('PRETTY_NAME');
  Result.DisplayVersion := GetOSReleaseValue('VERSION_ID');
  Result.DistroID := GetOSReleaseValue('ID');
  Result.DistroIDLike := GetOSReleaseValue('ID_LIKE');
  Result.PkgFamily := DetectPkgFamily(Result.DistroID, Result.DistroIDLike);

  if Result.MarketingName = '' then Result.MarketingName := 'Generic Linux';
  {$ENDIF}

  Result.DisplayName := MakeDisplayName(Result.MarketingName,
    Result.DisplayVersion);
end;

function GetAppImagePath(const AExeName: String): String;
{$IFDEF LINUX}
var
  sAppDir, sAppImage, sExe: String;
begin
  Result := '';
  sAppImage := GetEnvironmentVariable('APPIMAGE');
  sAppDir := GetEnvironmentVariable('APPDIR');
  if (sAppImage = '') or (sAppDir = '') then Exit;
  sAppDir := IncludeTrailingPathDelimiter(ExpandFileName(sAppDir));
  sExe := ExpandFileName(AExeName);
  // Byte comparison is right here: Linux paths are case-sensitive, and a
  // UTF-8 prefix match is a byte prefix match.
  if Copy(sExe, 1, Length(sAppDir)) <> sAppDir then Exit;
  if not FileExists(sAppImage) then Exit;
  Result := ExpandFileName(sAppImage);
end;
{$ELSE}
begin
  Result := '';
end;
{$ENDIF}

function PlatformSummary(const AReport: TOSReport): String;
begin
  if AReport.IsWine then
  begin
    Result := 'Wine';
    if AReport.WineVersion <> '' then
      Result := Result + ' ' + AReport.WineVersion;
    if AReport.WineHost <> '' then
      Result := Result + ' on ' + AReport.WineHost;
    Result := Result + ' (reports ' + AReport.DisplayName + ')';
  end
  else if AReport.IsWindows then
  begin
    Result := AReport.DisplayName;
    // '0.0.0' is GetPreciseOSInfo's "RtlGetVersion didn't answer".
    if (AReport.KernelVersion <> '') and (AReport.KernelVersion <> '0.0.0') then
      Result := Result + ' (build ' + AReport.KernelVersion + ')';
  end
  else if AReport.IsLinux then
  begin
    // "Manjaro Linux" already says it; "Ubuntu 24.04.1 LTS" doesn't.
    // ASCII-only LowerCase is exact for finding 'linux' in UTF-8 text.
    if Pos('linux', LowerCase(AReport.DisplayName)) > 0 then
      Result := AReport.DisplayName
    else
      Result := 'Linux: ' + AReport.DisplayName;
    if (AReport.KernelVersion <> '') and (AReport.KernelVersion <> '0.0.0') then
      Result := Result + ' (kernel ' + AReport.KernelVersion + ')';
  end
  else
    Result := AReport.DisplayName;
end;

function InstallCommand(AFamily: TLinuxPkgFamily; AWhat: TInstallable): String;
begin
  Result := '';
  // ffprobe on openSUSE: ffmpeg-4 (Leap) and ffmpeg-7 (Tumbleweed) both
  // provide the capability "ffmpeg-tools", so zypper picks the right one.
  // (zypper can't install by file path - it doesn't download the file
  // lists - so '/usr/bin/ffprobe' would fail there.)
  // ffprobe on Fedora: ffmpeg-free is the one in Fedora's own repositories;
  // someone with RPM Fusion's ffmpeg already has ffprobe and never sees this.
  case AFamily of
    lpfApt:
      case AWhat of
        instOpenSSL: Result := 'sudo apt install openssl';
        instFFprobe: Result := 'sudo apt install ffmpeg';
        instMKVToolNix: Result := 'sudo apt install mkvtoolnix';
      end;
    lpfZypper:
      case AWhat of
        instOpenSSL: Result := 'sudo zypper install openssl';
        instFFprobe: Result := 'sudo zypper install ffmpeg-tools';
        instMKVToolNix: Result := 'sudo zypper install mkvtoolnix';
      end;
    lpfDnf:
      case AWhat of
        instOpenSSL: Result := 'sudo dnf install openssl';
        instFFprobe: Result := 'sudo dnf install ffmpeg-free';
        instMKVToolNix: Result := 'sudo dnf install mkvtoolnix';
      end;
    lpfPacman:
      case AWhat of
        instOpenSSL: Result := 'sudo pacman -S openssl';
        instFFprobe: Result := 'sudo pacman -S ffmpeg';
        instMKVToolNix: Result := 'sudo pacman -S mkvtoolnix-cli';
      end;
    lpfUnknown: ;
  end;
end;

function InstallHint(AFamily: TLinuxPkgFamily; AWhat: TInstallable): String;
const
  PackageNames: array[TInstallable] of String =
    ('openssl', 'ffmpeg', 'mkvtoolnix');
var
  sCmd: String;
begin
  sCmd := InstallCommand(AFamily, AWhat);
  if sCmd <> '' then
    Result := INSTALL_HINT_PREFIX + sCmd
  else
    Result := 'Install the "' + PackageNames[AWhat] +
      '" package with your package manager';
end;

function ExtractInstallCommand(const AText: String): String;
var
  p: Integer;
begin
  Result := '';
  // All ASCII markers, so byte positions are exact in UTF-8 text.
  p := Pos(INSTALL_HINT_PREFIX, AText);
  if p = 0 then Exit;
  Result := Copy(AText, p + Length(INSTALL_HINT_PREFIX), MaxInt);
  p := Pos('  (', Result);
  if p > 0 then SetLength(Result, p - 1);
  Result := Trim(Result);
end;

function AppImageHomeDir: String;
begin
  Result := CombinePath(GetUserDir, 'Applications');
end;

{$IFDEF UNIX}
// The XDG download folder: XDG_DOWNLOAD_DIR from ~/.config/user-dirs.dirs
// (written by xdg-user-dirs, translated on non-English systems:
// ~/Téléchargements, ~/Загрузки, ...), else ~/Downloads.
function XdgDownloadDir: String;
var
  i: Integer;
  sConfig, sHome, sLine, sValue: String;
  SL: TStringList;
begin
  sHome := ExcludeTrailingPathDelimiter(GetUserDir);
  Result := CombinePath(sHome, 'Downloads');
  sConfig := GetEnvironmentVariable('XDG_CONFIG_HOME');
  if sConfig = '' then sConfig := CombinePath(sHome, '.config');
  sConfig := CombinePath(sConfig, 'user-dirs.dirs');
  if not FileExists(sConfig) then Exit;
  SL := TStringList.Create;
  try
    try
      SL.LoadFromFile(sConfig);
    except
      Exit;
    end;
    for i := 0 to SL.Count - 1 do
    begin
      sLine := Trim(SL[i]);
      if Pos('XDG_DOWNLOAD_DIR=', sLine) <> 1 then Continue;
      // XDG_DOWNLOAD_DIR="$HOME/Downloads" - always quoted, $HOME-relative
      // or absolute, per the xdg-user-dirs format.
      sValue := Copy(sLine, Length('XDG_DOWNLOAD_DIR=') + 1, MaxInt);
      sValue := StringReplace(sValue, '"', '', [rfReplaceAll]);
      sValue := StringReplace(sValue, '$HOME', sHome, []);
      // "$HOME/" alone means the home folder itself: downloads go
      // straight there, and the home folder is not "transient".
      if (sValue <> '') and (sValue[1] = '/') and
        (ExcludeTrailingPathDelimiter(sValue) <> sHome) then
        Result := ExcludeTrailingPathDelimiter(sValue);
      Break;
    end;
  finally
    SL.Free;
  end;
end;

// True if APath is ADir itself or inside it. Byte comparison: Linux paths
// are case-sensitive, and a UTF-8 prefix is a byte prefix.
function IsInDir(const APath, ADir: String): Boolean;
var
  sDir: String;
begin
  Result := False;
  if ADir = '' then Exit;
  sDir := IncludeTrailingPathDelimiter(ADir);
  Result := (Copy(APath, 1, Length(sDir)) = sDir) or
    (APath = ExcludeTrailingPathDelimiter(ADir));
end;
{$ENDIF}

function IsTransientAppImageLocation(const APath: String): Boolean;
{$IFDEF UNIX}
var
  sDir: String;
begin
  sDir := ExtractFileDir(ExpandFileName(APath));
  Result := IsInDir(sDir, XdgDownloadDir) or IsInDir(sDir, '/tmp') or
    IsInDir(sDir, '/var/tmp') or
    IsInDir(sDir, GetEnvironmentVariable('TMPDIR')) or
    IsInDir(sDir, '/media') or IsInDir(sDir, '/run/media') or
    IsInDir(sDir, '/mnt');
end;
{$ELSE}
begin
  Result := False;
end;
{$ENDIF}

function AppImageManagerName: String;
{$IFDEF UNIX}
const
  FLATPAK_GEARLEVER = 'flatpak/app/it.mijorus.gearlever';
begin
  Result := '';
  if (FindDefaultExecutablePath('AppImageLauncher') <> '') or
    (FindDefaultExecutablePath('appimagelauncherd') <> '') or
    (FindDefaultExecutablePath('ail-cli') <> '') then
    Exit('AppImageLauncher');
  if (FindDefaultExecutablePath('gearlever') <> '') or
    DirectoryExists(CombinePath('/var/lib', FLATPAK_GEARLEVER)) or
    DirectoryExists(CombinePath(CombinePath(GetUserDir, '.local/share'),
    FLATPAK_GEARLEVER)) then
    Exit('Gear Lever');
end;
{$ELSE}
begin
  Result := '';
end;
{$ENDIF}

function MoveAppImage(const ASource, ADestDir: String;
  out ADest, AError: String): Boolean;
{$IFDEF UNIX}
var
  Info: Stat;
  sTemp: String;
begin
  Result := False;
  AError := '';
  ADest := CombinePath(ADestDir, ExtractFileName(ASource));
  if ExpandFileName(ASource) = ExpandFileName(ADest) then
  begin
    AError := 'It is already there.';
    Exit;
  end;
  if not FileExists(ASource) then
  begin
    AError := 'The file is no longer at "' + ASource + '".';
    Exit;
  end;
  if not ForceDirectories(ADestDir) then
  begin
    AError := 'Could not create "' + ADestDir + '".';
    Exit;
  end;
  // Same filesystem: one atomic rename(), which also replaces a copy of
  // the same name already there (the same version, given the name).
  if fpRename(ASource, ADest) = 0 then
  begin
    Result := True;
    DebugLog(sb(['MoveAppImage: renamed "', ASource, '" to "', ADest, '"']));
  end
  else if fpGetErrno <> ESysEXDEV then
  begin
    AError := sb(['Could not move it: ', SysErrorMessage(fpGetErrno), '.']);
    Exit;
  end
  else
  begin
    // Different filesystems: copy beside the destination first, so a
    // half-copied file never sits under the real name.
    sTemp := ADest + '.part';
    if not FileUtil.CopyFile(ASource, sTemp, [cffOverwriteFile]) then
    begin
      DeleteFile(sTemp);
      AError := 'Could not copy it to "' + ADestDir + '".';
      Exit;
    end;
    if fpRename(sTemp, ADest) <> 0 then
    begin
      AError := sb(['Could not move it into place: ',
        SysErrorMessage(fpGetErrno), '.']);
      DeleteFile(sTemp);
      Exit;
    end;
    // The copy is complete and in place; only now is the original removed.
    if not DeleteFile(ASource) then
      DebugLog('MoveAppImage: copied, but could not remove "' + ASource + '"');
    Result := True;
    DebugLog(sb(['MoveAppImage: copied "', ASource, '" to "', ADest, '"']));
  end;
  // A copy may not keep the executable bits; a rename does, but setting
  // them again costs nothing.
  Info := Default(Stat);
  if fpStat(ADest, Info) = 0 then
    fpChmod(ADest, (Info.st_mode and &7777) or &0111);
end;
{$ELSE}
begin
  ADest := '';
  AError := 'Only AppImages on Linux are moved.';
  Result := False;
end;
{$ENDIF}

initialization
  DebugLog('uOSDetector initialization');

end.
