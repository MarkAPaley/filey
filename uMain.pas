{ Filey

Copyright (C) 2026 Mark A Paley

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program; if not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>.

Report bugs and questions at <https://gitlab.com/MarkAPaley/filey/-/issues>.
}
//Lazarus version 2.3.0

unit uMain;

{$mode objfpc}
{$MODESWITCH ADVANCEDRECORDS}
{$COPERATORS ON}
{$LONGSTRINGS ON}
{$SMARTLINK ON}
{$INLINE ON}
{$hints on}
{$runtimechecks off}// or {$CR-}
{$J-}// Constants are truly read-only
interface

uses
  {$IFDEF WINDOWS}ActiveX, ComObj, ShlObj, Win32Proc, Windows,{$ENDIF}
  ActnList, Buttons, Classes, ComCtrls, Controls,
  CRT, db, DBCtrls, dbf, DBGrids, Dialogs, DOS, EditBtn, ExtCtrls,
  FGL, FileInfo, Forms, fpcunit, fphttpclient, Generics.Collections,
  Graphics, Grids, HtmlGlobals, IniFiles, IPHtml, iphtmlnodes,
  Iphttpbroker, IpFileBroker, {jsonparser,} LazLogger, Menus, opensslsockets,
  Process, RegExpr, StdCtrls, SynEdit, SynEditMouseCmds, SynEditTypes,
  SynHighlighterPas, {System.UITypes,} SysUtils, {testregistry,} Types,
  TypInfo, uBrowser, uDBF, uDBFManager, uEpisodeMatching, uManagedUtils,
  uOSDetector, uTerminal,
  uUtils, Zipper;

const
  Subtitle_Extensions: array[1..4] of String =
    ('.IDX', '.SUB', '.NFO', '.SRT');

  // Buffer sizes
  READ_BUFFER_SIZE = 2048;

  // Font constraints
  MIN_FONT_SIZE = 6;
  MAX_FONT_SIZE = 48;
  DEFAULT_FONT_SIZE = 10;

  // Common characters
  CR = char(13);
  LE = LineEnding;
  QuoteChr: char = '"';
  Space: char = ' ';
  DirSep: String = DirectorySeparator;

type

  // A map where Key = String and Value = Boolean
  TPathCacheMap = specialize TFPGMap<String, Boolean>;

  THackDBNavigator = class(TDBNavigator)
  end;

  THackDBDataLink = class(TDBNavDataLink)
  end;

  //Expose TDBGrid.DataLink private property
  TDBGridHack = class(TDBGrid)
  end;

  // ===== IMPROVED TYPE DEFINITIONS =====

  { Exception classes for better error handling }
  EFileyException = class(Exception);
  EFileyFileException = class(EFileyException);
  EFileyDatabaseException = class(EFileyException);
  EFileyNetworkException = class(EFileyException);

  { Procedure type for database operations }
  TDatabaseOperation = procedure of object;

  // TDbType, DBFs, and TDBRecord now live in uDBF, alongside the DBF
  // schema/status logic that uses them.

  // Structure to save complete UI state
  TDBGridState = record
    BookMark: TBookmark;
    GridHasFocus: Boolean;
    IsEditing: Boolean;
    SelectedColumn: Integer;
    WasEnabled: Boolean;
  end;

  // TEpisodePattern, TEpPatterns and TEpisodeMatch now live in
  // uEpisodeMatching, alongside the episode-matching logic that uses them.

  // What goes in place of the characters Windows forbids in file names
  // (: ? * / \ | < > "), in a new file name: look-alikes (꞉ ？ ∗ ∕ ∖ ǀ ‹ ›
  // and curly quotes; uManagedUtils.RESERVED_LOOKALIKES), or '_'. File
  // menu > New file names; ini: [Main] ReservedCharacters = lookalike |
  // underscore.
  TReservedCharStyle = (rcsLookalike, rcsUnderscore);
  // What separates the words and parts of a new file name. File menu > New
  // file names; ini: [Main] WordSeparator = space | dot.
  TWordSeparator = (wsSpace, wsDot);

  TGlobals = record
    // The real .AppImage file when running from one (see
    // uOSDetector.GetAppImagePath), else ''. ProgramPath is then only the
    // temporary /tmp/.mount_xxxx folder, gone as soon as filey exits.
    AppImagePath, OSDisplayName: String;
    // uOSDetector.PlatformSummary: the About > Info "Platform" line.
    PlatformText: String;
    PkgFamily: TLinuxPkgFamily;
    // IsAskMoveAppImage: False once the user chose "Don't ask again" in
    // AskToMoveAppImage (ini: [Main] AskMoveAppImage).
    // IsCreateMenuEntry: Linux application-menu entry, made alongside the
    // desktop launcher (ini: [Main] IsCreateMenuEntry).
    IsAppImage, IsAskMoveAppImage, IsCreateDesktopShortcut,
    IsCreateMenuEntry, IsFormSnapped,
    IsIniFileDeleted, IsInternetConnected, IsHideBadPath,
    IsHideRenamedCount, IsHideSelectAShow, IsHideZipCount,
    IsLinux, IsModalWait, IsProgressCanceled, IsWindows,
    IsWine, SearchDirectionForward, WasSelected: Boolean;

    buttonSelected, SourceFilesCount: Integer;

    // New file name style. The first value of each is the default, which
    // is also what Default(TGlobals) gives.
    ReservedCharStyle: TReservedCharStyle;
    WordSeparator: TWordSeparator;

    AllShowsTxt, DisplayVersion, EpGuidesURL, EpName, EpNum,
    ExactFind, FileNameFFProbe, FileNameMKVMerge,
    FileNameMKVPropEdit, FoundTitle, IniFileName, KernelVersion,
    LastTitleFound, LastURL, MarketingName,
    SelectedTitle, SourceZipFileName, Title, Today, URL,
    WineFFProbe, WineMKVMerge, WineMKVPropEdit, WineVersion, Year: String;

    CnfgFilePath, FilePathFFProbe, FilePathlibeay,
    FilePathMKVMerge, FilePathMKVPropEdit, FilePathssleay,
    FilePathSourceZip, OpPath, ProgramPath, SourcePath: TFilePath;
  end;

  TRenameOperationState = record
    buttonSelected: TModalResult;
    From, sTo, CurDB: String;
    FromPath, ToPath: TFilePath;
    IsCancel: Boolean;
    CopiedCount, SkipCount: Integer;
  end;

  { TForm1 }
  TForm1 = class(TForm)
    actToggleStatusBar: TAction;
    IpHtmlPanel1: TIpHtmlPanel;
    MenuItem10: TMenuItem;
    MenuItem11: TMenuItem;
    MenuItemEpsEdit: TMenuItem;
    MenuItemShowsEdit: TMenuItem;
    PanelAttributionContainer: TPanel;
    PanelPrivacyContainer: TPanel;
    PanelReadmeContainer: TPanel;
    ProgressBar: TProgressBar;
    ProgressBitBtn: TBitBtn;
    ProgressLabel: TLabel;
    ProgressPanelBottom: TPanel;
    ProgressPanelFull: TPanel;
    ProgressPanelHeader: TPanel;
    ProgressPanelMiddle: TPanel;
    ToolBarMemo1: TToolBar;
    tsProgress: TTabSheet;
    procedure actToggleStatusBarExecute(Sender: TObject);
    procedure DBGridEpsEditingDone(Sender: TObject);
    procedure DBGridEpsMouseWheel(Sender: TObject; Shift: TShiftState;
      WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
    procedure DBGridShowsEditingDone(Sender: TObject);
    procedure DBGridShowsEnter(Sender: TObject);
    procedure DBGridShowsMouseWheel(Sender: TObject;
      Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint;
      var Handled: Boolean);
    procedure DBNavigatorShowsClick(Sender: TObject;
      Button: TDBNavButtonType);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure MenuItem10Click(Sender: TObject);
    procedure MenuItem11Click(Sender: TObject);
    procedure MenuItemEpsEditClick(Sender: TObject);
    procedure MenuItemShowsEditClick(Sender: TObject);
    procedure PanelShowsTopResize(Sender: TObject);
    procedure ProgressBitBtnClick(Sender: TObject);
    procedure ShowsFilterEditMouseEnter(Sender: TObject);
    procedure tsPrivacyHide(Sender: TObject);
    procedure tsProgressHide(Sender: TObject);
    procedure tsProgressShow(Sender: TObject);

  private
    // Declare one for each tab to keep content persistent
    // TODO: EpNameRegEx/EpNumRegEx/SmartEpNameRegEx/SmartEpNumRegEx parse
    // episode names/numbers out of downloaded EpGuides HTML - a genuinely
    // different concern from the filename-based episode matching now living
    // in uEpisodeMatching.pas (TEpisodeMatcher), even though the naming
    // suggests kinship. Decide whether these belong alongside
    // TEpisodeMatcher in uEpisodeMatching.pas, or deserve their own unit
    // (e.g. uEpGuideScraping.pas) the next time TForm1 gets thinned out.
    EpNameRegEx: TRegExpr;
    EpNumRegEx: TRegExpr;
    // Browser tab. See SetupBrowser, BrowseToURL and uBrowser.
    // Set by NavigateBrowser to stop the page that is loading, so that
    // FPendingBrowserURL can load instead.
    FBrowserCancel: Boolean;
    // Set when the page BrowseToURL asked for turned out not to be one it
    // can show and went to the system's own program instead
    // (HandBrowserPageToSystem).
    FBrowserHandedOff: Boolean;
    // Addresses of pages shown in the Browser tab, oldest first, and which
    // one is showing. TIpHtmlPanel has GoBack/GoForward of its own, but its
    // GoBack always re-opens the last entry on its stack - the page already
    // showing - so a second Back never goes anywhere.
    FBrowserHistory: TSmartStrings;
    FBrowserHistoryIndex: Integer;
    // True while acBackExecute/acForwardExecute load a page, so
    // IpHtmlPanel1DocumentOpen doesn't treat it as a new page.
    FBrowserMovingInHistory: Boolean;
    FBrowserProvider: TFileyHttpDataProvider;
    // The g.URL tsBrowserShow last loaded - see there.
    FBrowserSourceURL: String;
    // Status line for the Browser tab, shown by ShowStatusBrowser.
    FBrowserStatus: String;
    FDbf: TDBFArray;
    FEpisodeMatcher: TEpisodeMatcher;
    // Files CheckResourceFiles actually extracted this run (for the log).
    FExtractedCount: Integer;
    // About > Info "Install with: ..." rows (see CopyInstallCommand and
    // RunInstallInTerminal). FInstallMenu is the right-click menu for
    // those rows, made on first use; FInstallMenuCommand is the command of
    // the row it was opened on.
    FInstallMenu: TPopupMenu;
    FInstallMenuCommand: String;
    // The terminal RunInstallInTerminal opened, and the timer that waits
    // for the user to finish in it. nil/disabled when none is open.
    FInstallTerminal: TTerminalLaunch;
    FInstallTimer: TTimer;
    // Re-entrancy guards for long-running operations that pump the message
    // queue (via TSmartBusyState/SetAllCursors/UI.Check) while they run.
    // Without them, an event handler firing during that pumping - e.g. the
    // user hitting the Rename button or dropping files a second time - can
    // re-enter the still-running operation. Kept as separate flags rather
    // than one shared flag so a rename in progress doesn't block an
    // unrelated file drop, and vice versa.
    // IpHtmlPanel1.OpenURL pumps messages while it loads a page.
    FIsBrowsing: Boolean;
    // While True, ExtractFromSourceZip/ExtractZipResourceIfStale report
    // each extraction on the Progress page. Set only by CheckResourceFiles.
    FIsCheckingResources: Boolean;
    FIsDestroyed: Boolean;
    FIsRenaming: Boolean;
    FIsScanning: Boolean;
    FIsShuttingDown: Boolean;
    // True from the constructor until DeferredStartup has finished; tables
    // aren't open before then.
    FIsStartingUp: Boolean;
    // Set when the user copied or ran an install command: until
    // FToolRecheckUntil (GetTickCount64), coming back to filey's window
    // looks for missing tools again (AppActivate), at most once every
    // TOOL_RECHECK_MIN_GAP_MS.
    FLastToolRecheck: QWord;
    // Address DeferredBrowse opens (link clicks, tsBrowserShow,
    // NavigateBrowser), and whether to reload it if it is already showing.
    FPendingBrowserForce: Boolean;
    FPendingBrowserURL: String;
    FPieces: TSmartStrings;
    FProgressUpdateCounter: Integer;
    // Readme tab. vwReadme also shows the other documents FILEY-SRC.ZIP
    // carries (README_DOCS) when a link in one points at another - see
    // ReadmeLinkClick. FReadmeHistory holds the documents visited, oldest
    // first, as "Name=Position"; the last one is the one showing, and
    // Back (FReadmeBack, made by SetupReadmeBack) returns to the one
    // before it, scrolled to where the reader left it.
    FReadmeBack: TBitBtn;
    FReadmeHistory: TSmartStrings;
    // The link ReadmeLinkClick queued for DeferredReadmeLink.
    FReadmePendingLink: String;
    // Debounces AutoAdjustColumns calls on DBGridShows: several event
    // handlers (tab Show, filter Change/KeyPress/KeyUp/EditingDone) can
    // each fire it in quick succession for a single user action, and on
    // a large table (thousands of rows) re-measuring every column that
    // many times in a row is wasted, noticeable work. See
    // SmartAutoAdjustColumns.
    FShowsColumnsThrottle: TThrottledUI;
    // True once SHOWS.DBF's SEARCHTHIS keys are known to be what the
    // current Key makes (SEARCH_KEY_VERSION). SaveConfiguration records it.
    FSearchKeysCurrent: Boolean;
    FSourceManager: TSourceViewManager;
    FStartupQueued: Boolean;
    // Set by StatusBarDrawPanel; DeferredStartup waits for it.
    FStatusBarPainted: Boolean;
    FTitleField: TField;
    FToolRecheckUntil: QWord;
    // File menu > New file names: look-alikes, underscores, spaces, dots -
    // indexed by NAME_STYLE_* (see SetupNameStyleMenu).
    FNameStyleItems: array[0..3] of TMenuItem;
    // What CreateWineLinuxLaunchers did this run, as "what=outcome" lines
    // (written, up to date, or why not), one About > Info row each. Empty
    // when it hasn't run (always, except under Wine).
    FWineLauncherStatus: TSmartStrings;
    g: TGlobals;   // OS and Environment flags
    // (The settings file is uManagedUtils.AppIni, shared with the rest of
    // the program - see its declaration.)
    LastKeyTyped: char;
    MyComponent: TComponent;
    MyObject: TObject;
    // Target control for OnZipEntryExtracted (set immediately before a
    // callback-mode ExtractFileFromZip call, valid only for the duration
    // of that call).
    SmartEpNameRegEx: TSmartRegEx;
    SmartEpNumRegEx: TSmartRegEx;
    UI: TThrottledUI;
    Video_File_Extensions: TSmartStrings;
    procedure acBackExecute(Sender: TObject);
    procedure acForwardExecute(Sender: TObject);
    function ActiveSourceSynEdit: TSynEdit;
    procedure AddFiles(const aFileStrings: TStrings);
    procedure AddRow(const Cat, Desc: String);
    function AddtsSourceCode(pc: TPageControl;
      const TabCaption: String): TTabSheet;
    procedure AdjustColumns(const Sender: TObject);
    procedure AfterEpsShow(Data: PtrInt);
    procedure AfterShowsShow(Data: PtrInt);
    // Application.OnActivate: looks for missing tools again after the user
    // has copied or run an install command (see FToolRecheckUntil).
    procedure AppActivate(Sender: TObject);
    // Guesses the release group from the ORIGINAL ("From") file name and,
    // if one is found, inserts "-Group" right before ABaseName's extension
    // (e.g. "Show.S01E01.720p.mkv" -> "Show.S01E01.720p-LOL.mkv"). Returns
    // ABaseName unchanged if no group can be guessed. See uReleaseGroup.
    function AppendReleaseGroup(const ABaseName: String): String;
    // AText with the characters Windows forbids replaced by their
    // look-alikes, when g.ReservedCharStyle says so; otherwise unchanged,
    // for FixWinFileName to make them '_'.
    function ApplyReservedCharStyle(const AText: String): String;
    procedure ApplySpringColumn(const Grid: TDBGrid;
      const AIndex: Integer = -1);
    procedure ApplyStandardColors(var ASynEdit: TSynEdit);
    procedure ApplySubtitleFlags(const AFilePath: String);
    // Offers, once, to move an AppImage run from Downloads, /tmp or
    // removable media to ~/Applications (see uOSDetector). Queued by
    // DeferredStartup so it comes after the window is up.
    procedure AskToMoveAppImage(Data: PtrInt);
    procedure AssignDBGridLogEvents;
    procedure AssignFoundEp;
    procedure AssignListFieldIfEmpty(const sFieldName, sValue: String);
    procedure AssignRootNameToAssociatedFiles;
    procedure AttributionLinkClick(Sender: TObject; const SRC: ThtString;
      var Handled: Boolean);
    // Shows AURL in the Browser tab. AForce reloads a page that is already
    // showing; without it, asking for the current page does nothing.
    function BrowseToURL(const AURL: String; AForce: Boolean = False): Boolean;
    procedure BuildAboutReport;
    function BundledDocForLink(const ALink: String;
      out AAnchor: String): String;
    procedure CheckLogCheckBoxes;
    procedure CheckResourceFiles;
    procedure CleanupSourceRAII;
    // Deletes files earlier versions of filey left by mistake in the folder
    // it was started from (see uUtils.IsStrayManifestFile and
    // uDBF.IsFileyTableLeftover). Each file is only removed after its
    // contents prove it is one of those.
    procedure CleanUpStrayFiles;
    procedure CloseGrid(var aGrid: TDBGrid);
    // The new name for LIST's current row, from its TITLE, EPNUM, EPNAME,
    // HEIGHT, CODEC, AUDIOCHAN, SUBTITLES and EXTENSION, styled as
    // g.ReservedCharStyle and g.WordSeparator say and made safe for Windows.
    // AFromFileName: TITLE/EPNAME came from parsing the old file name
    // (no episode match), so their dots separate words.
    function ComposeNewName(AFromFileName: Boolean): String;
    procedure ConfigureDBFDataSource(aDbType: TDbType;
      ADataSource: TDataSource);
    procedure ConfigureOpenSSLLibPaths;
    procedure ConfirmThenZapPackTable(var aDB: TDbf);
    // Puts ACommand on the clipboard and says so in the status bar.
    procedure CopyInstallCommand(const ACommand: String);
    procedure CreateDesktopShortcut;
    {$IFDEF UNIX}
    procedure CreateLinuxShortcut;
    {$ENDIF}
    {$IFDEF WINDOWS}
    procedure CreateWindowsShortcut;
    // Under Wine: Linux desktop launcher and application-menu entry that
    // start this filey.exe through Wine (Filey-Wine.desktop).
    procedure CreateWineLinuxLaunchers;
    {$ENDIF}
    // The command in the current About > Info row's "Install with: ..."
    // value, or ''.
    function CurrentAboutInstallCommand: String;
    procedure DBEpsStateChange(Sender: TObject);
    procedure DbfAccessChanged(Sender: TObject);
    procedure DBFRecordCountChanged(DataSet: TDataSet);
    procedure DBGridAboutDblClick(Sender: TObject);
    procedure DBShowsStateChange(Sender: TObject);
    procedure DealWithSpecialFiles;
    procedure DeferredBrowse(Data: PtrInt);
    procedure DeferredReadmeLink({%H-}Data: PtrInt);
    procedure DeferredStartup(Data: PtrInt);
    // AppActivate's recheck, queued so the window has finished activating.
    procedure DeferredToolRecheck(Data: PtrInt);
    function DiscoverExternalTool(
      const ALinuxExeName, AWindowsExeName, AVersionArg: String;
      out AWinePrefix, AResolvedFileName: String): TFilePath;
    function DownloadBrowserPage(const AURL: String): TBrowserDownload;
    procedure DownLoadEps;
    function DownloadShowsFile(const ShowsFile: String): Boolean;
    // Builds FInstallMenu (Copy / Open in Terminal / Check again) once.
    procedure EnsureInstallMenu;
    function EnsureMKVToolsAvailable(ANeedMKVMerge,
      ANeedMKVPropEdit: Boolean): Boolean;
    function EnsureToolAvailable(var AFilePath: TFilePath;
      var AWinePrefix: String;
      const ALinuxExeName, AWindowsExeName, AVersionArg: String): Boolean;
    function ExtractFromSourceZip(const AFileName: String;
      AOnlyIfMissing: Boolean = False): Boolean;
    procedure ExtractResourceToObject(const AFileName: TFilePath;
      AObject: TObject);
    function ExtractZipResourceIfStale(aResourceName: String): Boolean;
    procedure FilterEpsOnTitle(DataSet: TDataSet; var Accept: Boolean);
    procedure FilterLogOnUndo(DataSet: TDataSet; var Accept: Boolean);
    procedure FilterShowsOnDirInTitle(DataSet: TDataSet;
      var Accept: Boolean);
    procedure FilterShowsOnExactTitle(DataSet: TDataSet;
      var Accept: Boolean);
    procedure FilterShowsOnTitleDir(DataSet: TDataSet; var Accept: Boolean);
    procedure FinalizeShowsImport(aDB: TDbf; ProcessedCount: Integer;
      const StartTime: TDateTime);
    function FindExecutableFile(const FileName: String): String;
    function FindMyTitle(const sFind: String): String;
    function FindPathTo(const sFind: String): String;
    function FindTitleByDirectory: String;
    function FindTitleByEpisodeName: String;
    function FindTitleWithYear: String;
    function FindYear(const sInputname: String): String;
    function FindYearExec(const sInputname, sExpr: String): String;
    procedure FitStatusBarHeight;
    procedure ForceDBGridLogInCellEditing;
    function GetDbField(aDbType: TDbType; const aField: String): String;
    function GetEpName(const curFile: String): String;
    function GetEpsEpName: String;
    function GetEpsSortOrder: String;
    function GetEpsTitle: String;
    function GetGridForDataset(const aDB: TDbf): TDBGrid; overload;
    function GetListEpName: String;
    function GetListEpNum: String;
    function GetListExt: String;
    function GetListFrom: String;
    function GetListFromPath: String;
    function GetListTitle: String;
    function GetListTo: String;
    function GetListTreeLevel: String;
    procedure GetMKVAttributes(const curFile: String);
    function GetShowsDirectory: String;
    function GetShowsLookUpDate: String;
    function GetShowsSearchThis: String;
    function GetShowsTitle: String;
    function GetStreamFromZipResource(
      const AMemoryTarget: String): TMemoryStream;
    function GetSubtitleTrackInfo(const AFilePath: String;
      out AEnglishID: Integer): TSmartStrings;
    function GetUndo: Boolean;
    function HackFrom(const sFind: String;
      var s, sLeft, sRight: String): String;
    function HackTo(const sFind: String; var s, sLeft, sRight: String): String;
    procedure HandBrowserPageToSystem(const AURL: String);
    procedure IHtmlViewer1LinkClick(Sender: TObject;
      const SRC: ThtString; var Handled: Boolean);
    function ImportShowsRows(aDB: TDbf; const CSVLines: TSmartStrings;
      TotalLines: Integer; const StartTime: TDateTime): Integer;
    procedure InitializeDBFs;
    function InitializeShowsDownloadSSL: Boolean;
    procedure InitializeVariables;
    procedure InstallMenuCheckClick(Sender: TObject);
    procedure InstallMenuCopyClick(Sender: TObject);
    procedure InstallMenuTerminalClick(Sender: TObject);
    procedure InstallTimerTimer(Sender: TObject);
    procedure IpHtmlPanel1DocumentOpen(Sender: TObject);
    procedure IpHtmlPanel1HotClick(Sender: TObject);
    // True once aDbType's table exists and is open. Handlers that can fire
    // before DeferredStartup has opened the tables (resize, show) check it.
    function IsDbOpen(aDbType: TDbType): Boolean;
    procedure LazyLoadSourceCode;
    function LoadBrowserImages(const APageURL: String;
      ASources: TStrings): Integer;
    function LoadBundledDoc(var AViewer: TSmartHtmlViewer;
      const ADoc: String): Boolean;
    procedure LoadConfiguration(ini: TIniFile);
    function LoadResourceToString(const ResourceName: String): String;
    function LoadShowsCSV(const ShowsFile: String;
      const CSVLines: TSmartStrings): Integer;
    function LocateRecordInBackground(aDB: TDbf; const FieldName: String;
      const Value: variant; Options: TLocateOptions = []): Boolean;
    procedure LogIt(const Op: TRenameOperationState);
    procedure LogSyncShowsEntryState(aDB: TDbf; const ShowsFile: String);
    function MakeSourceSheets: Integer;
    procedure MessageList(const Title: String; const SL: TStringList);
    procedure MessageRenamedCount(var Op: TRenameOperationState);
    // Names of the external tools not found, comma-separated; '' if none.
    function MissingToolNames: String;
    procedure MouseWheelScaleToFont(Sender: TObject;
      Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint;
      var Handled: Boolean);
    procedure NameStyleMenuClick(Sender: TObject);
    procedure NavigateBrowser(const AURL: String; AForce: Boolean);
    function NormalizeTitleAndYear(const s: String): String;
    procedure OfferRenameDeepestDir;
    procedure OnZipEntryExtracted(AStream: TStream;
      const AArchiveFileName: String);
    procedure OpenBundledDocExternally(const ADoc, AFallbackURL: String);
    procedure ParseFilesList;
    procedure ParseHTMLToMemo;
    function ParseTitleNEpNum(const curFile: String): String;
    procedure PerformTitleLookup;
    procedure PostRecord(var aDB: TDbf);
    procedure PrepareShowsTableForImport(aDB: TDbf);
    function ProbeFile(const sFind: String): String;
    procedure ProcessEpisodeLookup;
    function QueryThenRename(const ATargetPiece: String;
      var Op: TRenameOperationState): Boolean;
    function QuickLocateInBackground(const aDB: TDbf;
      const FieldName: String; const Value: variant): Boolean;
    procedure ReadmeBackClick(Sender: TObject);
    procedure ReadmeLinkClick(Sender: TObject; const SRC: ThtString;
      var Handled: Boolean);
    // Once per SEARCH_KEY_VERSION: recomputes the SEARCHTHIS keys an older
    // Key made for SHOWS.DBF, writing only the rows that change.
    procedure RefreshShowsSearchKeys;
    // Runs ValidateAndDiscoverTools again, rebuilds About > Info if it is
    // showing, and says in the status bar what changed. AWhy starts the
    // message ('Checked again', 'Terminal closed', ...).
    procedure RecheckExternalTools(const AWhy: String);
    procedure RegenerateResourceFile(const ARCFile, AResFile: String);
    // Op is var: the CopiedCount/SkipCount this adds to are what
    // RenameThisList's MessageRenamedCount reports.
    function RenameListItem(const aDB: TDbf;
      var Op: TRenameOperationState): Boolean;
    procedure RenameThisList(aDB: TDbf);
    procedure ReportShowsImportProgress(
      CurrentLine, TotalLines, ProcessedCount: Integer;
      const StartTime: TDateTime);
    procedure RestoreDBGridState(aDB: TDbf; Grid: TDBGrid;
      const SavedState: TDBGridState);
    procedure RightMouseFonts(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure RunBrowserDownloads(ABatch: TBrowserDownloadBatch;
      AWorkers: Integer; ATimeLimitMs: QWord; const AStatus: String);
    // Opens a terminal with ACommand typed in, ready for Enter (Linux only;
    // see uTerminal). The command also goes on the clipboard first, so it
    // is at hand even when no terminal can be opened.
    procedure RunInstallInTerminal(const ACommand: String);
    function SafeGetDbField(aDbType: TDbType; const aField: String): String;
    procedure SafeSetDbField(const aDbType: TDbType;
      const aField, AValue: String);
    procedure SaveAboutRecNo;
    procedure SaveConfiguration(ini: TIniFile);
    function SaveDBGridState(aDB: TDbf; Grid: TDBGrid): TDBGridState;
    function SelectAShow: String;
    // SHOWS.DBF's SEARCHTHIS keys are current: records SEARCH_KEY_VERSION
    // in filey.ini now, or on exit if there is no ini yet.
    procedure SearchKeysAreCurrent;
    procedure SetBitBtnUndoEnabled;
    procedure SetBounds(aCtrl: TControl;
      ALeft, ATop, AWidth, AHeight: Integer); overload;
    procedure SetDbField(const aDbType: TDbType;
      const aField, aString: String);
    procedure SetFilterEpsOnTitle;
    procedure SetListDirectory(const aString: String);
    procedure SetListEpName(const aString: String);
    procedure SetListEpNum(const aString: String);
    procedure SetListExt(const aString: String);
    procedure SetListFrom(const aString: String);
    procedure SetListFromPath(const aString: String);
    procedure SetListNameNPath(const aString: String);
    procedure SetListTextWidth;
    procedure SetListTitle(const aString: String);
    procedure SetListTo(const aString: String);
    procedure SetListToPath(const aString: String);
    procedure SetListTreeLevel(const aString: String);
    procedure SetLogUndo(const aBoolean: Boolean);
    procedure SetTabSheetListButtons;
    procedure SetTabSheetMemoButtons;
    procedure SetTabSheetSourceCodeButtons(Sender: TObject);
    procedure SetupBrowser;
    procedure SetupDbAbout;
    procedure SetupDbEps;
    procedure SetupDbList;
    procedure SetupDbLog;
    procedure SetupDbShows;
    procedure SetupReadmeBack;
    procedure SetupUI;
    // The File menu's "New file names" submenu (FNameStyleItems), made once
    // by SetupUI.
    procedure SetupNameStyleMenu;
    function ShowBrowserPage(APage: TBrowserDownload): Boolean;
    function ShowDataSetStates(const DataSet: TDataSet): String;
    procedure ShowDBFStatus(aDB: TDbf);
    procedure ShowEpisodeParsingStats;
    procedure ShowExtractProgress(const AFileName: String);
    procedure ShowMessageList(var aList: TStringList);
    function ShowReadmeDoc(const ADoc: String; APosition: Integer;
      const AAnchor: String = ''): Boolean;
    procedure ShowStatusBrowser;
    procedure ShowStatusDBF(aDbType: TDbType);
    procedure ShowStatusSourceCode;
    procedure SmartAutoAdjustColumns(aGrid: TDBGrid;
      var AThrottle: TThrottledUI);
    procedure SwapFromTo(var Op: TRenameOperationState);
    function sYearAndEpNumOnlyNoEpName: String;
    procedure SyncShowsDatabase;
    procedure SynEditOnEnter(Sender: TObject);
    procedure SynEditStatusChange(Sender: TObject;
      Changes: TSynStatusChanges);
    procedure TabSheetAlignButtons;
    procedure ToggleLogUndoBoxes(Value: Boolean);
    procedure UpdateBrowserButtons;
    procedure UpdateReadmeBack;
    procedure UpdateStatusBar;
    // Run once per ini whose IniVersion is older than INI_VERSION: deletes
    // the keys that version retired, then records INI_VERSION.
    procedure UpgradeIniFile;
    procedure ValidateAndDiscoverTools;
    procedure ViewerHotClick(Sender: TObject; const SRC: ThtString;
      var Handled: Boolean);
    procedure WriteSourceCodeFont(ini: TIniFile; APage: TTabSheet;
      AEdit: TSynEdit);
    function ZapAndRebuildShows(out AFailure: String): Boolean;
    procedure ZipperProgress(Sender: TObject; const Pct: double);
    procedure ZipperStartFile(Sender: TObject; const AFileName: String);

  public
    vwAttribution, vwReadme, vwPrivacy: TSmartHtmlViewer;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

  published
    actClear: TAction;
    actCustom: TAction;
    actDeleteIniFile: TAction;
    actExit: TAction;
    actFilterEditCancel: TAction;
    actFind: TAction;
    actFormFonts: TAction;
    actHints: TAction;
    ActionList: TActionList;
    actLookupEps: TAction;
    actMeasure: TAction;
    actMemoToEps: TAction;
    actNew: TAction;
    actNext: TAction;
    actOpen: TAction;
    actOpenFolder: TAction;
    actPrior: TAction;
    actReadOnly: TAction;
    actRenameMatches: TAction;
    actSelect: TAction;
    actShowAllEpisodes: TAction;
    actSouceCodeFont: TAction;
    actStatusBarFont: TAction;
    actSysMenu: TAction;
    actTest: TAction;
    actUniqueToggle: TAction;
    actZap: TAction;
    actZipSources: TAction;
    BitBtn1: TBitBtn;
    BitBtnCancel: TBitBtn;
    BitBtnClear: TBitBtn;
    BitBtnCopyEps: TBitBtn;
    BitBtnExit: TBitBtn;
    BitBtnFindN: TBitBtn;
    BitBtnIcon: TBitBtn;
    BitBtnLookupEps: TBitBtn;
    BitBtnOpen: TBitBtn;
    BitBtnOpenReadme: TBitBtn;
    BitBtnRename: TBitBtn;
    BitBtnSelect: TBitBtn;
    BitBtnUndo: TBitBtn;
    btBack: TSpeedButton;
    btForward: TSpeedButton;
    btGo: TSpeedButton;
    DBGridAbout: TDBGrid;
    DBGridEps: TDBGrid;
    DBGridList: TDBGrid;
    DBGridLog: TDBGrid;
    DBGridShows: TDBGrid;
    DBNavigatorEps: TDBNavigator;
    DBNavigatorLog: TDBNavigator;
    DBNavigatorShows: TDBNavigator;
    edUrl: TEdit;
    FindDialog: TFindDialog;
    FontDialog: TFontDialog;
    ImageListFiley: TImageList;
    MainMenu: TMainMenu;
    Memo1: TMemo;
    MemoLicense: TMemo;
    MenuEps: TPopupMenu;
    MenuItem1: TMenuItem;
    MenuItem2: TMenuItem;
    MenuItem3: TMenuItem;
    MenuItem4: TMenuItem;
    MenuItem5: TMenuItem;
    MenuItem6: TMenuItem;
    MenuItem7: TMenuItem;
    MenuItem8: TMenuItem;
    MenuItem9: TMenuItem;
    MenuItemDeleteShow: TMenuItem;
    MenuItemExit: TMenuItem;
    MenuItemInsert: TMenuItem;
    MenuItemMeasure: TMenuItem;
    MenuItemOpen: TMenuItem;
    MenuItemOpenFolder: TMenuItem;
    MenuItemSeparator: TMenuItem;
    MenuItemSourceCodeFind: TMenuItem;
    MenuItemSourceCodeFont: TMenuItem;
    MenuItemToggle: TMenuItem;
    MenuItemUnique: TMenuItem;
    MenuItemZap: TMenuItem;
    MenuMaintenance: TMenuItem;
    MenuShowEnv: TMenuItem;
    MenuShows: TPopupMenu;
    MenuShowsToggleHidden: TMenuItem;
    MenuSourceCode: TPopupMenu;
    MenuZipSources: TMenuItem;
    N1: TMenuItem;
    OpenDialog: TOpenDialog;
    PanelAttribution: TPanel;
    PanelEpsBottom: TPanel;
    PanelEpsTop: TPanel;
    PanelFilesBottom: TPanel;
    PanelFilesGrid: TPanel;
    PanelFilesMain: TPanel;
    PanelLogTop: TPanel;
    PanelNav: TPanel;
    PanelSelect: TPanel;
    PanelShowsBottom: TPanel;
    PanelShowsCombo: TPanel;
    PanelShowsNav: TPanel;
    PanelShowsTop: TPanel;
    PanelTop: TPanel;
    pcAbout: TPageControl;
    pcMain: TPageControl;
    pcSourceCode: TPageControl;
    pnTop: TPanel;
    PopupMenuAbout: TPopupMenu;
    Separator1: TMenuItem;
    Separator2: TMenuItem;
    ShowDBFsStatus: TMenuItem;
    ShowsFilterEdit: TEditButton;
    StatusBar: TStatusBar;
    SynFreePascalSyn1: TSynFreePascalSyn;
    sysAbout: TAction;
    TaskDialog: TTaskDialog;
    ToolBarFiles: TToolBar;
    ToolBarMemo: TToolBar;
    tsAbout: TTabSheet;
    tsBrowser: TTabSheet;
    tsEps: TTabSheet;
    tsInfo: TTabSheet;
    tsLicense: TTabSheet;
    tsList: TTabSheet;
    tsLog: TTabSheet;
    tsMemo: TTabSheet;
    tsPrivacy: TTabSheet;
    tsReadme: TTabSheet;
    tsShows: TTabSheet;
    tsSourceCode: TTabSheet;
    procedure actClearExecute(Sender: TObject);
    procedure actDeleteIniFileExecute(Sender: TObject);
    procedure actExitExecute(Sender: TObject);
    procedure actFilterEditCancelExecute(Sender: TObject);
    procedure actFindExecute(Sender: TObject);
    procedure actFormFontsExecute(Sender: TObject);
    procedure actGoExecute(Sender: TObject);
    procedure actHintsExecute(Sender: TObject);
    procedure actLookupEpsExecute(Sender: TObject);
    procedure actMeasureExecute(Sender: TObject);
    procedure actMemoToEpsExecute(Sender: TObject);
    procedure actOpenExecute(Sender: TObject);
    procedure actOpenFolderExecute(Sender: TObject);
    procedure actReadOnlyExecute(Sender: TObject);
    procedure actRenameMatchesExecute(Sender: TObject);
    procedure actSelectExecute(Sender: TObject);
    procedure actShowAllEpisodesExecute(Sender: TObject);
    procedure actSouceCodeFontExecute(Sender: TObject);
    procedure actStatusBarFontExecute(Sender: TObject);
    procedure actUniqueToggleExecute(Sender: TObject);
    procedure actZapExecute(Sender: TObject);
    procedure actZipSourcesExecute(Sender: TObject);
    procedure BitBtn1Click(Sender: TObject);
    procedure BitBtnCancelClick(Sender: TObject);
    procedure BitBtnIconClick(Sender: TObject);
    procedure BitBtnLookupEpsMouseEnter(Sender: TObject);
    procedure BitBtnNextClick(Sender: TObject);
    procedure BitBtnOpenReadmeClick(Sender: TObject);
    procedure BitBtnPrevClick(Sender: TObject);
    procedure BitBtnUndoClick(Sender: TObject);
    procedure btGoClick(Sender: TObject);
    procedure DBGridAboutMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure DBGridDblClick(Sender: TObject);
    procedure DBGridEpsEnter(Sender: TObject);
    procedure DBGridEpsMouseEnter(Sender: TObject);
    procedure DBGridExit(Sender: TObject);
    procedure DBGridListAfterScroll(DataSet: TDataSet);
    procedure DBGridListBeforeScroll(DataSet: TDataSet);
    procedure DBGridListSelectEditor(Sender: TObject; Column: TColumn;
      var Editor: TWinControl);
    procedure DBGridListSetColumnWidths;
    procedure DBGridLogCellClick(Column: TColumn);
    procedure DBGridLogColEnter(Sender: TObject);
    procedure DBGridLogDblClick(Sender: TObject);
    procedure DBGridLogDrawColumnCell(Sender: TObject;
      const Rect: TRect; DataCol: Integer; Column: TColumn;
      State: TGridDrawState);
    procedure DBGridLogEnter(Sender: TObject);
    procedure DBGridLogKeyDown(Sender: TObject; var Key: word;
      Shift: TShiftState);
    procedure DBGridLogMouseEnter(Sender: TObject);
    procedure DBGridLogMouseLeave(Sender: TObject);
    procedure DBGridLogSelectEditor(Sender: TObject; Column: TColumn;
      var Editor: TWinControl);
    procedure DBGridMakeHint(const Sender: TObject; const X, Y: Integer);
    procedure DBGridMouseMove(Sender: TObject; Shift: TShiftState;
      X, Y: Integer);
    procedure DBGridShowsAfterScroll(DataSet: TDataSet);
    procedure DBGridShowsBeforeScroll(DataSet: TDataSet);
    procedure DBGridShowsMouseEnter(Sender: TObject);
    procedure DBGridTitleClick(Column: TColumn);
    procedure DBNavigatorEpsClick(Sender: TObject; Button: TDBNavButtonType);
    procedure DBNavigatorEpsResize(Sender: TObject);
    procedure DBNavigatorLogClick(Sender: TObject; Button: TDBNavButtonType);
    procedure DrawSimpleCheckBox(const Rect: TRect; Checked: Boolean;
      Selected: Boolean);
    procedure EditButtonClick(Sender: TObject);
    procedure EditChange(Sender: TObject);
    procedure EditKeyDown(Sender: TObject; var Key: word;
      Shift: TShiftState);
    procedure EditKeyUp(Sender: TObject; var Key: word; Shift: TShiftState);
    procedure EditMouseEnter(Sender: TObject);
    procedure edUrlEditingDone(Sender: TObject);
    procedure edUrlMouseEnter(Sender: TObject);
    procedure EpsAfterScroll(DataSet: TDataSet);
    procedure EpsBeforeScroll(DataSet: TDataSet);
    procedure FormActivate(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormDropFiles(Sender: TObject;
      const FileNames: array of String);
    procedure FormResize(Sender: TObject);
    procedure FormShowHint(Sender: TObject; HintInfo: PHintInfo);
    procedure LogAfterPost(DataSet: TDataSet);
    procedure LogAfterScroll(DataSet: TDataSet);
    procedure LogBeforeEdit(DataSet: TDataSet);
    procedure LogBeforeScroll(DataSet: TDataSet);
    procedure MenuItemDeleteShowClick(Sender: TObject);
    procedure MenuItemInsertClick(Sender: TObject);
    procedure MenuShowEnvClick(Sender: TObject);
    procedure MenuShowsToggleHiddenClick(Sender: TObject);
    procedure pcAboutChange(Sender: TObject);
    procedure pcMainChange(Sender: TObject);
    procedure pcMainChanging(Sender: TObject; var AllowChange: Boolean);
    procedure pcMainResize(Sender: TObject);
    procedure pcSourceCodeChange(Sender: TObject);
    procedure ShowDBFsStatusClick(Sender: TObject);
    procedure ShowsFilterEditButtonClick(Sender: TObject);
    procedure ShowsFilterEditChange(Sender: TObject);
    procedure ShowsFilterEditEditingDone(Sender: TObject);
    procedure ShowsFilterEditKeyPress(Sender: TObject; var Key: char);
    procedure ShowsFilterEditKeyUp(Sender: TObject; var Key: word;
      Shift: TShiftState);
    procedure ShowsFilterEditMouseLeave(Sender: TObject);
    procedure StatusBarDrawPanel(statBar: TStatusBar;
      Panel: TStatusPanel; const Rect: TRect);
    procedure StatusBarMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure SynEditKeyDown(Sender: TObject; var Key: word;
      Shift: TShiftState);
    procedure TestKeyDown(Sender: TObject; var Key: word;
      Shift: TShiftState);
    procedure ToolBarFilesResize(Sender: TObject);
    procedure tsAboutShow(Sender: TObject);
    procedure tsBrowserResize(Sender: TObject);
    procedure tsBrowserShow(Sender: TObject);
    procedure tsEpsResize(Sender: TObject);
    procedure tsEpsShow(Sender: TObject);
    procedure tsInfoHide(Sender: TObject);
    procedure tsInfoResize(Sender: TObject);
    procedure tsInfoShow(Sender: TObject);
    procedure tsLicenseHide(Sender: TObject);
    procedure tsLicenseShow(Sender: TObject);
    procedure tsListResize(Sender: TObject);
    procedure tsListShow(Sender: TObject);
    procedure tsLogResize(Sender: TObject);
    procedure tsLogShow(Sender: TObject);
    procedure tsMemoResize(Sender: TObject);
    procedure tsPrivacyShow(Sender: TObject);
    procedure tsReadmeHide(Sender: TObject);
    procedure tsReadmeShow(Sender: TObject);
    procedure tsShowsShow(Sender: TObject);
    procedure tsSourceCodeExit(Sender: TObject);
    procedure tsSourceCodeShow(Sender: TObject);
  end;

var
  Form1: TForm1;

implementation

{$R *.lfm}

uses
  Character, Clipbrd, DateUtils, DynLibs,
  FileUtil, fpDBExport, fpHTML, HtmlView,
  LazEditHighlighter, LazFileUtils, LazUTF8, LCLIntf,
  LCLProc, LCLType, LConvEncoding, LResources, Math,
  openssl, sockets, StrUtils, Themes, uReleaseGroup,
  Variants, fpjson, jsonparser, ZStream {for clmax};

{$IFDEF WINDOWS}
// Declared here rather than by using FPC's CommDlg unit, whose many
// Windows-API names (FindText, ChooseFont, ...) would shadow the LCL's
// in this unit. Why the last common dialog failed; 0 if it was cancelled.
function CommDlgExtendedError: DWORD; stdcall;
  external 'comdlg32.dll' name 'CommDlgExtendedError';
{$ENDIF}

const
  // Default fonts, best first. Only real, scalable font families: on
  // openSUSE, generic names like 'Times' (and sometimes 'Serif') can land
  // on the old X11 *bitmap* fonts (Adobe Times, Helvetica, Courier, ...)
  // that openSUSE installs by default, and a bitmap font only looks right
  // at the sizes it was drawn for - it looks ragged at 16 pt.
  // 'Serif' and 'Monospace' are fontconfig's aliases, kept only as a last
  // resort. Windows keeps Times New Roman first, as it always looked.
  DEFAULT_SERIF_FONTS: array[0..9] of String = (
    {$IFDEF WINDOWS}'Times New Roman', 'Droid Serif',
    {$ELSE}'Droid Serif', 'Times New Roman',{$ENDIF}
    'Noto Serif', 'DejaVu Serif', 'Liberation Serif', 'FreeSerif',
    'Georgia', 'Cambria', 'Palatino Linotype', 'Serif');
  DEFAULT_MONO_FONTS: array[0..8] of String = (
    'Consolas', 'DejaVu Sans Mono', 'Noto Sans Mono', 'Liberation Mono',
    'Source Code Pro', 'Droid Sans Mono', 'Courier New', 'FreeMono',
    'Monospace');
  DEFAULT_FORM_FONT_SIZE = 16;
  DEFAULT_STATUSBAR_FONT_SIZE = 13;
  // Written to the ini with the fonts. Before version 2, the constructor's
  // SetupUI overwrote the fonts LoadConfiguration had just read, so what an
  // older ini holds is only the old default written back on exit, never a
  // choice the user made - and on openSUSE that old default is the one
  // that looks bad. Font names from an older ini are therefore ignored.
  FONT_SETTINGS_VERSION = 2;
  // The layout of filey.ini, stored as [Main] IniVersion. Raise it whenever
  // keys are retired, and add them to UpgradeIniFile; an ini without the
  // key counts as version 1.
  INI_VERSION = 3;
  // How SHOWS.DBF's SEARCHTHIS keys were made, stored as [Main]
  // SearchKeyVersion (missing means 1). Raise it whenever Key changes what
  // it returns for text a title can hold; RefreshShowsSearchKeys then
  // recomputes the stored keys once.
  //   2: the look-alikes for the characters Windows forbids, curly double
  //      quotes and other programs' stand-ins break words; U+2018 vanishes,
  //      like ' and U+2019 already did.
  SEARCH_KEY_VERSION = 2;
  // FNameStyleItems indices (and the menu items' Tag).
  NAME_STYLE_RESERVED_LOOKALIKE = 0;
  NAME_STYLE_RESERVED_UNDERSCORE = 1;
  NAME_STYLE_SPACES = 2;
  NAME_STYLE_DOTS = 3;

// ASaved if that font is installed here, else the first installed entry of
// ADefaults, else AFallback. A font saved on another computer, or later
// uninstalled, would otherwise make the LCL quietly substitute something
// arbitrary.
function BestInstalledFont(const ASaved: String;
  const ADefaults: array of String; const AFallback: String): String;
var
  sName: String;
begin
  if (ASaved <> '') and (Screen.Fonts.IndexOf(ASaved) >= 0) then
    Exit(ASaved);
  for sName in ADefaults do
    if Screen.Fonts.IndexOf(sName) >= 0 then Exit(sName);
  Result := AFallback;
end;

// SHOWS.DBF's SEARCHTHIS for one row: the Key of the title and of the
// epguides directory, each followed by '|', with one more '|' in front.
// The import and RefreshShowsSearchKeys both build it here, so they can't
// drift apart.
function ShowsSearchKey(const ATitle, ADir: String): String;
begin
  Result := sb(['|', ATitle.Key, '|', ADir.Key, '|']);
end;

const
  // Where Filey's documents live online. README links there, so that it
  // reads right on GitLab too; inside Filey, BundledDocForLink turns those
  // links into the copies this build carries.
  FILEY_REPO_URL = 'https://gitlab.com/MarkAPaley/filey/';
  // The documents in FILEY-SRC.ZIP that the Readme tab shows, the first
  // being the one it opens on. Casing matters on Linux: these are the
  // names inside the zip.
  README_DOCS: array[0..1] of String =
    ('README.html', 'Privacy_Policy.html');
  // Documents in FILEY-SRC.ZIP that are far too big for THtmlViewer, so
  // links to them open the extracted copy in the default browser instead
  // (OpenBundledDocExternally). README2.html embeds ~60 MB of instructional
  // GIFs so that it stays portable; in THtmlViewer it took about a minute
  // to load, with the UI frozen, and peaked at ~770 MB.
  README_EXTERNAL_DOCS: array[0..0] of String = ('README2.html');

  // About > Info install commands (RunInstallInTerminal, AppActivate).
  // How often the open terminal is checked on, and for how long.
  INSTALL_POLL_MS = 1000;
  INSTALL_WAIT_MAX_MS = 2 * 60 * 60 * 1000;
  // After a command is copied or run, coming back to filey's window looks
  // for the missing programs again for this long ...
  TOOL_RECHECK_WINDOW_MS = 30 * 60 * 1000;
  // ... but no more often than this (each look runs every tool once).
  TOOL_RECHECK_MIN_GAP_MS = 10 * 1000;
  // FInstallMenu's items, in the order EnsureInstallMenu adds them.
  INSTALL_MENU_COPY = 0;
  INSTALL_MENU_TERMINAL = 1;

constructor TForm1.Create(AOwner: TComponent);
var
  DbIndex: TDbType;
  FileVerInfo: TSmartVersionInfo;
  i: Integer;
  Info: TOSReport;
  Grid: TDBGrid;
  LComp: TComponent;
  LCtrl: TControl;
  s: String;
begin
  FIsDestroyed := False;
  FIsShuttingDown := False;
  FSearchKeysCurrent := False;
  FIsStartingUp := True; // cleared by DeferredStartup
  try
    inherited Create(AOwner);
    // Must be an ASSIGNMENT. TThrottledUI.Create is a static class function
    // returning a record - calling it as a bare statement configured a
    // temporary and discarded it, so UI kept Initialize's 100ms default and
    // the 150 was never applied. (FormCreate does this correctly for
    // FShowsColumnsThrottle.)
    UI := TThrottledUI.Create(150);
    // Initialize Global variables very quickly.
    // Default(TGlobals) instead of FillChar(g, SizeOf(g), 0): FillChar is
    // safe here ONLY because NewInstance already zeroed g before this
    // constructor ran. FillChar-ing a record with ~40 reference-counted
    // (String/interface) fields does not finalize them first - it would
    // leak every one of them if this line is ever reached a second time
    // (e.g. a future re-init path). Default() finalizes-then-resets
    // correctly regardless of prior content.
    g := Default(TGlobals);
    // uUtils.pas computes and owns the canonical OpPath value in its own
    // unit initialization section (guaranteed to run before TForm1.Create
    // - see uUtils.pas), specifically so uUtils.pas never has to depend
    // on TGlobals/g. g.OpPath derives from that single source of truth
    // rather than independently recomputing the same expression, so the
    // two can no longer drift apart.
    g.OpPath := uUtils.OpPath;
    g.CnfgFilePath := uUtils.OpPath;
    //InitializeDebugLog;  //moved to uUtils.pas Initialization section
    InitializeVariables;
    g.SearchDirectionForward := True;
    // Complex type initializations using Default()
    MyComponent := Default(TComponent);
    MyObject := Default(TObject);
    // Initialize DBF records array using Default()
    for DbIndex :=
      Low(TDbType) to High(TDbType) do FDbf[DbIndex] := Default(TDBRecord);
    // Initialize form properties
    ShowInTaskBar := stAlways;
    Anchors := [];
    Align := alNone;
    BorderStyle := bsSizeable;
    BorderIcons := [biSystemMenu, biMinimize, biMaximize];
    DragMode := dmAutomatic;
    DragKind := dkDrag;
    Info := GetPreciseOSInfo;
    g.IsWindows := Info.IsWindows;
    g.IsLinux := Info.IsLinux;
    g.IsWine := Info.IsWine;
    g.WineVersion := Info.WineVersion;
    g.MarketingName := Info.MarketingName;
    g.DisplayVersion := Info.DisplayVersion;
    g.OSDisplayName := Info.DisplayName;
    g.KernelVersion := Info.KernelVersion;
    g.PlatformText := PlatformSummary(Info);
    g.PkgFamily := Info.PkgFamily;
    g.AppImagePath := GetAppImagePath(Application.ExeName);
    g.IsAppImage := g.AppImagePath <> '';
    // Fuller startup banner - the early one in uUtils.pas's initialization
    // section only had compile-time facts (Debug/Release, Windows/Linux
    // target) available; by here GetPreciseOSInfo has actually run, so
    // this one can additionally say precisely which OS/Wine build this
    // run is under and which app version is running - the two pieces of
    // information several rounds of this app's own Wine debugging were
    // lost re-establishing from log content alone (e.g. a "Windows"
    // target log with no further detail doesn't say whether it's real
    // Windows or Wine, or which of the two ~identical AppData path styles
    // means which). Logged to both debug.log and error.log for the same
    // reason as the early banner: error.log accumulates across many runs
    // and environments, so each run needs its own unambiguous marker.
    FileVerInfo.LoadLocalFileInfo;
    s := sb(['=== STARTUP (full): filey ', FileVerInfo.VersionString,
      ' - ', IfThen(g.IsWine,
      sb(['Wine ', g.WineVersion, ' on ', g.OSDisplayName]),
      IfThen(g.IsWindows, sb(['Real Windows: ', g.OSDisplayName]),
      IfThen(g.IsLinux, sb(['Linux: ', g.OSDisplayName,
      IfThen(g.IsAppImage, sb([' (AppImage: ', g.AppImagePath, ')']), '')]),
      'Unknown OS'))), ' ===']);
    DebugLog(s);
    //LogError(s);
    // "filey 3.1.0.800 (AppImage)": the version in the title bar makes a
    // screenshot self-identifying, and the AppImage note says which of the
    // Linux builds it was. VersionString is '0.0.0.0' only if the version
    // resource couldn't be read, in which case it's left out.
    s := FileVerInfo.VersionString;
    Caption := sb([Application.Title,
      IfThen((s <> '') and (s <> '0.0.0.0'), ' ' + s, ''),
      IfThen(g.IsAppImage, ' (AppImage)', ''),
      {$IFDEF DEBUG}' [DEBUG]',{$ENDIF} '']);
    g.ProgramPath := ExtractFilePath(Application.ExeName);
    // g.IsInternetConnected is now set in DeferredStartup: the probe can
    // block for seconds on a dead network, and nothing reads it earlier.
    pcAbout.ActivePageIndex := tsInfo.PageIndex;
    pcMain.ActivePageIndex := tsList.PageIndex;
    DefaultFormatSettings.ShortDateFormat := 'dd/mm/yy';
    g.SourcePath := ExpandPathName(
      CombinePath(CombinePath(ExtractFileDir(Application.ExeName),
      '..'), '..'));
    g.Today := FormatDateTime('YYYY/MM/DD', Today);
    // Must be set before CheckResourceFiles runs (DeferredStartup, after
    // the first paint), which extracts license.txt/README.html/etc (and,
    // on Windows, libeay32.dll/ssleay32.dll) via
    // TForm1.ExtractFromSourceZip, which reads g.FilePathSourceZip.Value
    // as the zip to pull them from. This used to be assigned ~60 lines
    // further down in this same constructor (right before
    // actHintsExecute), which meant every one of those extractions ran
    // against g.FilePathSourceZip.Value still holding Default(TGlobals)'s
    // empty string - "ExtractFromZipIfNotFound: failed to extract
    // ... from '' ..." for every single resource, every single run,
    // regardless of whether the zip itself, or the embedded resource used
    // to (re)create it, was ever valid. Only depends on Application.Title
    // (set in this unit's own initialization section, which runs before
    // TForm1.Create is ever reached) and g.OpPath (set above, at the top
    // of this constructor) - both already available here.
    g.SourceZipFileName := sb([Application.Title, '-src.zip']);
    g.FilePathSourceZip := CombinePath(g.OpPath.Value, g.SourceZipFileName);
    g.IniFileName := sb([g.CnfgFilePath.Value,
      efnOnly(Application.ExeName), '.ini']);
    Self.Position := TPosition(IfThen(FileExists(g.IniFileName),
      Ord(poDesigned), Ord(poScreenCenter)));
    AppIni.Setup(g.IniFileName);
    UpgradeIniFile;
    LoadConfiguration(AppIni.Value);
    actDeleteIniFile.Caption :=
      sb(['Delete ', g.IniFileName, ' configuration file']);

    SetupUI;
    // CreateDesktopShortcut moved to DeferredStartup: the Linux version
    // extracts filey64.png from filey-src.zip, and CheckResourceFiles (also
    // deferred now) is what puts that archive on disk.
    actZipSources.Visible := False;

    if (GetEnv('USER') = 'mark') or (GetEnv('USERNAME') = 'Win') then
      actZipSources.Visible := True;
    for i := 0 to Self.ComponentCount - 1 do
    begin
      LComp := Self.Components[i];
      if LComp is TControl then
      begin
        LCtrl := TControl(LComp);
        // 1. Global Event Handlers
        LCtrl.AddHandlerOnMouseWheel(@MouseWheelScaleToFont, True);
        LCtrl.AddHandlerOnKeyDown(@TestKeyDown);
        // 2. Double buffering, but only where the LCL does the painting.
        // Forcing it on a native comctl32 control redirects WM_PAINT into an
        // offscreen DC that Wine's BUTTON/ToolbarWindow32 procs don't honour,
        // which blanks the glyph and caption. TCustomBitBtn descends from
        // TCustomButton, so the button case is covered.
        if (LCtrl is TWinControl) and not
          IsNativeWin32Control(TWinControl(LCtrl)) then
          TWinControl(LCtrl).DoubleBuffered := True;
        // 3. Font logic (Skip SynEdit)
        if not (LCtrl is TSynEdit) then LCtrl.Font.Assign(Self.Canvas.Font);
        // 4. Specific Class Logic
        if LCtrl is TDBGrid then
        begin
          Grid := TDBGrid(LCtrl);
          Grid.OnDblClick := @DBGridDblClick;
          Grid.OnMouseMove := @DBGridMouseMove;
          Grid.OnTitleClick := @DBGridTitleClick;
          Grid.AutoSize := False; // Grids usually stay fixed
        end
        else if LCtrl is TSynEdit then
        begin
          TSynEdit(LCtrl).Lines.Clear;
        end
        else if (LCtrl is TBitBtn) or (LCtrl is TPanel) or
          (LCtrl is TToolBar) then
        begin
          LCtrl.AutoSize := True;
        end;
      end;
      // 5. Special Published Props (Safe check for non-controls too)
      if IsPublishedProp(LComp, 'ScreenSnap') then
        SetPropValue(LComp, 'ScreenSnap', False);
    end;
    g.EpGuidesURL := 'https://www.epguides.com/';
    g.URL := g.EpGuidesURL;
    g.AllShowsTxt := 'allshows.txt';
    // g.SourceZipFileName/g.FilePathSourceZip moved earlier in this
    // constructor, before LoadConfiguration - see the comment there for why.
    // Application.OnShowHint := @ApplicationShowHint;
    actHintsExecute(Self);
    PanelSelect.Visible := False;
    DBGridList.OnMouseDown := @RightMouseFonts;
    DBGridLog.OnMouseDown := @RightMouseFonts;
    DBGridLog.ScrollBars := ssBoth;
    DBGridLog.FixedCols := 1;
    // InitializeDBFs (grid/column setup: SetupDbShows/SetupDbEps/SetupDbList/
    // SetupDbLog) moved to FormCreate. It was running here, inside the
    // constructor, before `inherited Create`'s .lfm-streamed components were
    // guaranteed fully realized (handles allocated, default properties like
    // Font populated) - Linux tolerated this timing, Wine did not, producing
    // an AV inside TColumn/TFont construction (Grid.Columns.Add). FormCreate
    // fires only after Create's full inherited chain - including streaming -
    // has completed, which is the guarantee this code actually needs.
  except
    on E: Exception do
    begin
      LogError('Failed to create form', E);
      //CleanupResources;
      raise;
    end;
  end;
end;

procedure TForm1.acBackExecute(Sender: TObject);
begin
  if FIsBrowsing or (FBrowserHistoryIndex <= 0) then Exit;
  FBrowserMovingInHistory := True;
  try
    Dec(FBrowserHistoryIndex);
    if not BrowseToURL(FBrowserHistory.Value[FBrowserHistoryIndex], True) then
      Inc(FBrowserHistoryIndex); // didn't load: still on the same page
  finally
    FBrowserMovingInHistory := False;
  end;
  UpdateBrowserButtons;
end;

procedure TForm1.acForwardExecute(Sender: TObject);
begin
  if FIsBrowsing or (FBrowserHistoryIndex < 0) or
    (FBrowserHistoryIndex >= FBrowserHistory.Value.Count - 1) then Exit;
  FBrowserMovingInHistory := True;
  try
    Inc(FBrowserHistoryIndex);
    if not BrowseToURL(FBrowserHistory.Value[FBrowserHistoryIndex], True) then
      Dec(FBrowserHistoryIndex); // didn't load: still on the same page
  finally
    FBrowserMovingInHistory := False;
  end;
  UpdateBrowserButtons;
end;

procedure TForm1.actClearExecute(Sender: TObject);
begin
  DBGridList.Enabled := False;
  ZapPackTable(FDbf[dbList].aDB);
  FDbf[dbList].aRecCountDirty := True;
  ShowsFilterEdit.Text := '';
  SetTabSheetListButtons;
  DBGridList.Hint := 'Drop here files to be renamed';
  DBGridList.Enabled := True;
  g.FoundTitle := '';
  g.LastTitleFound := '';
  g.Title := '';
  g.EpNum := '';
  g.EpName := '';
  g.Year := '';
  g.SelectedTitle := '';
end;

procedure TForm1.actDeleteIniFileExecute(Sender: TObject);
begin
  // Through AppIni, so the settings it still holds in memory can't write
  // the file straight back: its own clean-up on exit used to do exactly
  // that, undoing this menu item every time. g.IsIniFileDeleted then stops
  // SaveConfiguration, so the next start uses the defaults.
  if AppIni.RemoveFile then g.IsIniFileDeleted := True
  else
    StatusBar.Panels[0].Text := 'Could not delete ' + g.IniFileName;
end;

procedure TForm1.actExitExecute(Sender: TObject);
begin
  if FIsShuttingDown then Exit;
  FIsShuttingDown := True;
  BitBtnCancelClick(Sender);
  SetAllCursors(crDefault);
  Close; // Don't use Form1.Close, use Close
  // Don't call Application.Terminate - let the form close naturally
end;

procedure TForm1.actFilterEditCancelExecute(Sender: TObject);
begin
  if not Assigned(FDbf[dbEps].aDB) then Exit;
  ShowsFilterEdit.Text := '';
  FDbf[dbEps].aFilterDescription := '';
  FDbf[dbEps].aFilterText := '';
  FDbf[dbEps].aDB.Filtered := False;
  FDbf[dbEps].aRecCountDirty := True;
  FDbf[dbShows].aFilterDescription := '';
  FDbf[dbShows].aFilterText := '';
  FDbf[dbShows].aDB.Filtered := False;
  FDbf[dbShows].aRecCountDirty := True;
  if DbfHasIndex(FDbf[dbShows].aDB, 'TITLE') then
    FDbf[dbShows].aDB.IndexName := 'TITLE';
  PanelSelect.Visible := False;
  g.IsModalWait := False;
  AdjustColumns(DBGridShows);
  //LastTitleFound := '';
end;

procedure TForm1.actFindExecute(Sender: TObject);
//var  FocusedComponent: Integer = 0;  i: Integer = 0;
begin
  if (TObject(Sender).ClassName = 'TTabSheet') and Showing and Visible then
    SafeSetFocus(Sender as TControl);
end;

procedure TForm1.actFormFontsExecute(Sender: TObject);
var
  LComp: TComponent;
begin
  FontDialog.Font.Assign(Self.Canvas.Font);
  // Using 'Self' is cleaner than 'Form1' inside its own method
  FontDialog.Title := 'Change Main Fonts';
  if FontDialog.Execute then
  begin
    // The Enumerator handles the list of components automatically
    for LComp in Self do
    begin
      // Combine logic: We want things that ARE controls but ARE NOT SynEdits
      if (LComp is TControl) and not (LComp is TSynEdit) then
        TControl(LComp).Font.Assign(FontDialog.Font);
    end;
    Self.Canvas.Font.Assign(FontDialog.Font);
  end;
end;

procedure TForm1.actGoExecute(Sender: TObject);
begin
  // Go! loads the address typed in the box - the old version loaded g.URL
  // and ignored the box - and reloads a page that is already showing.
  NavigateBrowser(edUrl.Text, True);
end;

procedure TForm1.actHintsExecute(Sender: TObject);
var
  LControl: TControl;
  LComp: TComponent;
begin
  // 1. Iterating through the visual child controls of the Toolbar
  for LControl in ToolBarFiles do LControl.AutoSize := True;
  // 2. Iterating through all components owned by the Form
  for LComp in Self do
  begin
    if IsPublishedProp(LComp, 'ShowHint') then
      SetPropValue(LComp, 'ShowHint', True);
    if IsPublishedProp(LComp, 'ParentShowHint') then
      SetPropValue(LComp, 'ParentShowHint', True);
  end;
end;

function TForm1.ActiveSourceSynEdit: TSynEdit;
var
  i: Integer;
  Page: TTabSheet;
begin
  Result := nil;
  if (pcSourceCode.PageCount = 0) or (pcSourceCode.ActivePage = nil) then Exit;
  Page := pcSourceCode.ActivePage;
  for i := 0 to Page.ComponentCount - 1 do
    if Page.Components[i] is TSynEdit then Exit(TSynEdit(Page.Components[i]));
end;

procedure TForm1.actLookupEpsExecute(Sender: TObject);
var
  ProcessedCount: Integer = 0;
  TotalCount: Integer = 0;
  db: TDbf;
begin
  if FIsShuttingDown then Exit;
  db := FDbf[dbList].aDB;
  // No DisableControls/EnableControls of our own here, on either table.
  // - EPS: this loop used to hold EPS's controls disabled for the whole
  //   batch, which included SelectAShow's wait loop, so DBGridEps stopped
  //   updating after a show was picked until every remaining file had
  //   been processed. Every step that actually walks or filters EPS
  //   (FindTitleByEpisodeName, AssignFoundEp, actMemoToEpsExecute,
  //   actSelectExecute's RefreshSelection) already holds its own
  //   TDataLayoutGuard on EPS for just that step, so the outer disable
  //   gained nothing.
  // - LIST: the old unbalanced db.EnableControls here was cancelling
  //   ParseFilesList's guard from the inside so the user could see rows
  //   fill in. ParseFilesList now releases that guard before calling us,
  //   so LIST is already live.
  TotalCount := db.RecordCount;
  db.First;
  while (not db.EOF) and (not FIsShuttingDown) do
  begin
    try
      UI.Check;
      // Check if we should continue
      if FIsShuttingDown then Break;
      // Skip if already looked up
      if GetListTo = '' then
      begin
        // Process this record
        ProcessEpisodeLookup;
        Inc(ProcessedCount);
        // Update progress
        if Assigned(StatusBar) then StatusBar.Panels[0].Text :=
            Format('Processing %d of %d episodes...',
            [ProcessedCount, TotalCount]);
      end;
      db.Next;
    except
      on E: Exception do
      begin
        LogError('Error processing episode lookup', E);
        // Continue with next record
        try
          db.Next;
        except
          Break; // If we can't move to next, stop processing
        end;
      end;
    end;
  end;
  SetTabSheetListButtons;
  if Assigned(StatusBar) then StatusBar.Panels[0].Text :=
      Format('Processed %d episodes successfully', [ProcessedCount]);
end;

procedure TForm1.actMeasureExecute(Sender: TObject);
var
  db: TDbf;
  Guard: TDataLayoutGuard;
  LField: TField;
  DForm: TSmartDialogForm;
  OutStrings: TSmartStrings;
  s: String;
  w: array of Integer;
begin
  db := FDbf[dbShows].aDB;
  Guard := TDataLayoutGuard.Create(db, DBGridShows, nil);
  g.IsProgressCanceled := False;
  SetLength(w, db.FieldCount);
  if Length(w) > 0 then FillChar(w[0], Length(w) * SizeOf(integer), 0);
  pcMain.ActivePage := tsProgress;
  ProgressBitBtn.Enabled := True; //set AFTER switching ActivePage
  ProgressBitBtn.Kind := bkCancel;
  ProgressBar.Max := db.PhysicalRecordCount;
  ProgressPanelHeader.Caption := 'Measure field widths';
  db.First;
  while (not db.EOF) and (not g.IsProgressCanceled) do
  begin
    for LField in db.Fields do
      w[LField.Index] := Max(w[LField.Index], Length(Trim(LField.AsString)));
    db.Next;
    ProgressBar.Position := db.RecNo;
    ProgressLabel.Caption :=
      Format('%d/%d', [db.PhysicalRecNo, db.PhysicalRecordCount]);
    UI.Check;
  end;
  OutStrings.Value.Add(#9 + 'Minimum required field widths:');
  OutStrings.Value.Add('');
  for LField in db.Fields do
  begin
    s := #9 + Format('%-11s', [LField.FieldName]) + '= ' + #9 +
      Format('%4d', [w[LField.Index]]) + ' chars';
    OutStrings.Value.Add(s);
  end;
  DForm.Setup('Longest widths of fields:', Self.Canvas.Font);
  for s in OutStrings.Value do DForm.Value.DialogMemo.Lines.Add(s);
  DForm.ShowModal;
end;

procedure TForm1.actMemoToEpsExecute(Sender: TObject);
var
  EpIsFound: Boolean;
  EPS, TEps: TDbf;
  EpsGuard, TempEpsGuard: TDataLayoutGuard;
  fDestTitle, fDestEpNum, fDestEpName, fDestSort: TField;
  fSrcTitle, fSrcEpNum, fSrcEpName: TField;
  MyVarArray: variant;
  OldIndex: String;
  RecCounter: Integer;
  WasReadOnly: Boolean;
begin
  if Memo1.GetTextLen <= 0 then Exit;
  if IsPhysicallyReadOnly(FDbf[dbEps].aDB) then
  begin
    StatusBar.Panels[0].Text :=
      sb([STATUS_READONLY_TAG, ' Episodes not copied: ',
      FDbf[dbEps].aDB.TableName, ' is read-only because ',
      DbfReadOnlyReason(FDbf[dbEps].aDB)]);
    Exit;
  end;
  TEps := FDbf[dbTempEps].aDB;
  EPS := FDbf[dbEps].aDB;
  TEps.Active := True;
  EPS.Active := True;
  EpsGuard := TDataLayoutGuard.Create(EPS);
  TempEpsGuard := TDataLayoutGuard.Create(TEps);
  fSrcTitle := TEps.FieldByName('TITLE');
  fSrcEpNum := TEps.FieldByName('EPNUM');
  fSrcEpName := TEps.FieldByName('EPNAME');
  fDestTitle := EPS.FieldByName('TITLE');
  fDestEpNum := EPS.FieldByName('EPNUM');
  fDestEpName := EPS.FieldByName('EPNAME');
  fDestSort := EPS.FieldByName('SORTORDER');
  OldIndex := EPS.IndexName;
  EPS.IndexName := 'SORTORDER';
  WasReadOnly := EPS.ReadOnly;
  EPS.ReadOnly := False;
  RecCounter := 0;
  try
    TEps.First;
    while not TEps.EOF do
    begin
      g.Title := fSrcTitle.AsString;
      if g.Title = '' then
      begin
        SetDbField(dbTempEps, 'TITLE', GetDbField(dbShows, 'TITLE'));
        g.Title := fSrcTitle.AsString;
      end;
      g.EpNum := fSrcEpNum.AsString;
      MyVarArray := VarArrayOf([g.Title, g.EpNum]);
      EpIsFound := EPS.Locate('TITLE;EPNUM', MyVarArray,
        [loCaseInsensitive]);
      if not EpIsFound then
      begin
        try
          g.Title := DecodeHTMLEntities(g.Title);
          g.EpNum := RemoveAllSpacesAndDots(DecodeHTMLEntities(g.EpNum));
          g.EpName := DecodeHTMLEntities(fSrcEpName.AsString);
          EPS.Append;
          fDestTitle.AsString := g.Title;
          fDestEpNum.AsString := g.EpNum;
          fDestEpName.AsString := g.EpName;
          fDestSort.AsString :=
            StripNonAlphaNum(g.Title + g.EpNum + g.EpName);
          EPS.Post;
        except
          on E: Exception do
          begin
            EPS.Cancel;
            LogError(sb(['actMemoToEpsExecute Error Appending: ',
              g.Title, Space, g.EpNum, Space, g.EpName, Space,
              ' to EPS.DBF']), E);
          end;
        end;
      end;
      TEps.Next;
      Inc(RecCounter);
    end;
  finally
    // 3. Manual state restoration (Index/ReadOnly aren't in our RAII yet)
    EPS.IndexName := OldIndex;
    EPS.ReadOnly := WasReadOnly;
    // Note: EnableControls is handled automatically by the Guards
  end;
end;

procedure TForm1.actOpenExecute(Sender: TObject);
{$IFDEF WINDOWS}
const
  // Nobody can see a dialog and cancel it this fast, so a False from
  // Execute this quick, with no CommDlgExtendedError, means the dialog
  // never appeared.
  QUICK_FAIL_MS = 400;
{$ENDIF}
var
  bOK: Boolean;
  Err: DWord;
  ElapsedMs: QWord;
  sDir, sPrevFileName: String;

  // One attempt at showing the dialog. Also reports how long it was up
  // and, on Windows, why the common dialog failed (0 = cancelled, or the
  // Vista-style dialog, which never sets it).
  function TryExecute(out AErr: DWord; out AElapsedMs: QWord): Boolean;
  var
    StartTick: QWord;
  begin
    Result := False;
    AErr := 0;
    StartTick := GetTickCount64;
    try
      Result := OpenDialog.Execute;
      {$IFDEF WINDOWS}
      // Read at once: any later API call may reset it.
      if not Result then AErr := CommDlgExtendedError;
      {$ENDIF}
    except
      on E: Exception do
      begin
        LogError('actOpenExecute: OpenDialog.Execute raised', E);
        StatusBar.Panels[0].Text := 'Could not show the Open dialog: ' +
          E.Message;
      end;
    end;
    AElapsedMs := GetTickCount64 - StartTick;
  end;

begin
  // Start from a folder that exists, with nothing in the file name box:
  // the classic Windows dialog refuses a starting FileName it considers
  // invalid (AddFiles leaves the full path of the last dropped file there;
  // DBGridAboutMouseDown can leave any About > Info value, PATH included).
  sPrevFileName := OpenDialog.FileName;
  sDir := '';
  if sPrevFileName <> '' then sDir := ExtractFileDir(sPrevFileName);
  if (sDir = '') or not DirectoryExists(sDir) then sDir := OpenDialog.InitialDir;
  if (sDir = '') or not DirectoryExists(sDir) then sDir := GetUserDir;
  OpenDialog.InitialDir := sDir;
  OpenDialog.FileName := '';
  bOK := TryExecute(Err, ElapsedMs);
  {$IFDEF WINDOWS}
  // Gone again before anyone could have used it: the dialog didn't open.
  // The Vista-style dialog (Vista and later) can't be created at all when
  // visual styles are switched off for the process (see filey.lpr), and
  // the LCL then simply returns False. Try the other style once; if that
  // one works, it stays for the rest of this run.
  if (not bOK) and (Err = 0) and (ElapsedMs < QUICK_FAIL_MS) then
  begin
    LogError(sb(['actOpenExecute: the Open dialog closed after ',
      IntToStr(ElapsedMs), ' ms without being shown (',
      IfThen(ofOldStyleDialog in OpenDialog.Options, 'classic', 'Vista'),
      ' style, ', g.OSDisplayName, ', ThemesEnabled=',
      IfThen(ThemeServices.ThemesEnabled), ') - trying the other style']));
    if ofOldStyleDialog in OpenDialog.Options then
      OpenDialog.Options := OpenDialog.Options - [ofOldStyleDialog]
    else
      OpenDialog.Options := OpenDialog.Options + [ofOldStyleDialog];
    bOK := TryExecute(Err, ElapsedMs);
    if (not bOK) and (Err = 0) and (ElapsedMs < QUICK_FAIL_MS) then
    begin
      LogError('actOpenExecute: the other dialog style did not open either');
      StatusBar.Panels[0].Text := 'The Open dialog could not be shown. ' +
        'Drag and drop files onto the list instead.';
    end;
  end;
  // Not 0: the classic dialog refused to open, and says why.
  if (not bOK) and (Err <> 0) then
  begin
    LogError(Format('actOpenExecute: the Open dialog failed, ' +
      'CommDlgExtendedError = $%.4x', [Err]));
    StatusBar.Panels[0].Text := Format('The Open dialog could not be ' +
      'shown (error $%.4x). Drag and drop files onto the list instead.',
      [Err]);
  end;
  {$ENDIF}
  if bOK then
  begin
    AddFiles(OpenDialog.Files);
    Exit;
  end;
  // Cancelled (or failed): put back what SaveConfiguration and
  // actOpenFolderExecute read.
  OpenDialog.FileName := sPrevFileName;
end;

procedure TForm1.actOpenFolderExecute(Sender: TObject);
var
  s: String;
begin
  s := OpenDialog.FileName;
  if (not DirectoryExists(s)) and
    (not UTF8ContainsText('.ini.txt', ExtractFileExt(s))) then
    s := ExtractFilePath(s);
  if DirectoryExists(s) or FileExists(s) then OpenDocument(s);
end;

procedure TForm1.actReadOnlyExecute(Sender: TObject);
var
  i: Integer;
  dbIdx: TDbType;
begin
  // 1. Silence all databases to prevent UI flickering during the toggle}
  for dbIdx := Low(TDbType) to High(TDbType) do
    if Assigned(FDbf[dbIdx].aDB) then FDbf[dbIdx].aDB.DisableControls;
  try
    // 2. Global reset
    for i := 0 to Self.ComponentCount - 1 do
      SetReadOnly(Self.Components[i], False);
    // 2b. ...except tables that are physically read-only: put those back
    // BEFORE the toggles below, so ToggleBoolean sees them as locked and
    // keeps both the grid and the table read-only.
    for dbIdx := Low(TDbType) to High(TDbType) do
      if IsPhysicallyReadOnly(FDbf[dbIdx].aDB) then
        FDbf[dbIdx].aDB.ReadOnly := True;
    // 3. Update Grid Options
    DBGridShows.Options :=
      DBGridShows.Options + [dgRowSelect, dgEditing, dgCellHints];
    // 4. Perform Toggles
    ToggleBoolean(DBGridShows);
    ToggleBoolean(DBGridEps);
    // Toggle the actual datasets
    ToggleBoolean(FDbf[dbEps].aDB);
    ToggleBoolean(FDbf[dbTempEps].aDB);
    ToggleBoolean(FDbf[dbList].aDB);
    ToggleBoolean(FDbf[dbShows].aDB);
  finally
    // 5. Re-enable and refresh UI in one shot
    for dbIdx := Low(TDbType) to High(TDbType) do
      if Assigned(FDbf[dbIdx].aDB) then FDbf[dbIdx].aDB.EnableControls;
    UpdateStatusBar;
  end;
end;

procedure TForm1.actRenameMatchesExecute(Sender: TObject);
begin
  RenameThisList(FDbf[dbList].aDB);
  actClearExecute(FDbf[dbList].aDB);
end;

procedure TForm1.actSelectExecute(Sender: TObject);

// The guard lives only as long as this nested routine, so it is
// released before the page switch and column sizing below.
  procedure RefreshSelection;
  var
    Guard: TDataLayoutGuard;
  begin
    Guard := TDataLayoutGuard.Create(FDbf[dbEps].aDB);
    if not g.IsInternetConnected then StatusBar.Panels[0].Text :=
        'EPISODES NOT UPDATED! -- NO INTERNET CONNECTION!'
    else if GetDbField(dbShows, 'LOOKUPDATE') <> g.Today then
    begin
      // Not loaded into the Browser tab here: that would download the page
      // a second time on every selection, and ParseHTMLToMemo doesn't use
      // it. tsBrowserShow shows g.URL when the tab is next opened.
      g.URL := sb([g.EpGuidesURL, GetShowsDirectory, '/']);
      ParseHTMLToMemo;
      actMemoToEpsExecute(Form1);
      SetDbField(dbShows, 'LOOKUPDATE', g.Today);
    end;
    g.FoundTitle := GetShowsTitle;
    g.LastTitleFound := g.FoundTitle;
    FDbf[dbShows].aFilterText := g.FoundTitle;
    SetListTitle(g.FoundTitle);
    SetFilterEpsOnTitle;
    g.WasSelected := True;
    g.SelectedTitle := g.FoundTitle;
    g.IsModalWait := False;
  end;

begin
  RefreshSelection;
  pcMain.ActivePage := tsEps;
  AdjustColumns(DBGridEps);
end;

procedure TForm1.actShowAllEpisodesExecute(Sender: TObject);
var
  Grid: TDBGrid;
  Guard: TDataLayoutGuard;
begin
  Grid := DBGridEps;
  //Guard := TDataLayoutGuard.Create(FDbf[dbEps].aDB, Grid);
  Guard := TDataLayoutGuard.Create(FDbf[dbEps].aDB, Grid, nil);
  FDbf[dbEps].aFilterText := '';
  FDbf[dbEps].aFilterDescription := '';
  FDbf[dbEps].aDB.Filtered := False;
  FDbf[dbEps].aRecCountDirty := True;
  ToggleBoolean(Grid.Columns[3], 'Visible');
  Grid.Columns[2].SizePriority :=
    IfThen(Grid.Columns[3].Visible, 0, 1);
  AdjustColumns(Grid);
  UpdateStatusBar;
end;

procedure TForm1.actSouceCodeFontExecute(Sender: TObject);
var
  LComp: TComponent;
  LPage: TTabSheet;
  LEdit: TSynEdit; // Local typecast alias for readability
begin
  if pcSourceCode.PageCount <= 0 then Exit;
  LPage := pcSourceCode.Pages[pcSourceCode.ActivePageIndex];
  for LComp in LPage do
  begin
    if LComp is TSynEdit then
    begin
      LEdit := TSynEdit(LComp);
      FontDialog.Font.Assign(LEdit.Font);
      if LEdit.Font.Size < 6 then FontDialog.Font.Size := 10;
      FontDialog.Title := 'Change Editor Font';
      FontDialog.Options :=
        [fdFixedPitchOnly, fdForceFontExist, fdLimitSize];
      if FontDialog.Execute then
      begin
        LEdit.Font.Assign(FontDialog.Font);
        // Saved now, not only at exit: leaving the Source Code tab frees
        // these pages (tsSourceCodeExit), so SaveConfiguration usually has
        // none left to save.
        if not g.IsIniFileDeleted then
          WriteSourceCodeFont(AppIni.Value, LPage, LEdit);
      end;
    end;
  end;
end;

procedure TForm1.actStatusBarFontExecute(Sender: TObject);
begin
  FontDialog.Title := 'Change StatusBar Font';
  FontDialog.Font.Assign(StatusBar.Canvas.Font);
  FontDialog.Options :=
    [fdFixedPitchOnly, fdForceFontExist, fdLimitSize];
  if FontDialog.Execute then StatusBar.Canvas.Font.Assign(FontDialog.Font);
  //FitStatusBarHeight;
end;

procedure TForm1.actToggleStatusBarExecute(Sender: TObject);
begin
  StatusBar.Align := alBottom;
  StatusBar.AutoSize:= True;
  StatusBar.BringToFront; // win32 sometimes hides it behind the alClient control
  pcMain.Align := alClient;
  if StatusBar.IsVisible then StatusBar.Hide
  else StatusBar.Show;
  StatusBar.Invalidate;
end;

procedure TForm1.actUniqueToggleExecute(Sender: TObject);
begin
  //with DbfShows.Indexes[0] do}{if ixUnique in Options
  //  then Options:= Options - [ixUnique]}{  else Options:= Options - [ixUnique];
  //DbfShows.Active:= false;}{//DbfShows.IndexName:= '';}{DbfShows.UpdateIndexDefs;
  ////DbfShows.RegenerateIndexes;}{//DbfShows.IndexName:= 'TITLEDIR';
  //DbfShows.Active:= true;
  NoOp;
end;

procedure TForm1.actZapExecute(Sender: TObject);
var
  sFailure: String;
begin
  if MessageDlgEx('Zap?' + LE +
    'Delete, Re-Download, and then re-create the Shows and Episodes databases?',
    mtConfirmation, [mbYes, mbCancel]) <> mrYes then Exit;
  if not ZapAndRebuildShows(sFailure) then
    ShowMessage(sb(['Zap could not proceed:', LE, LE, sFailure]),
      False, 'Zap Failed');
end;

procedure TForm1.actZipSourcesExecute(Sender: TObject);
const
  cSourceFiles: array[0..20] of String = (
    'uMain.pas', 'uMain.lfm', 'uManagedUtils.pas', 'uUtils.pas',
    'uDBF.pas', 'uDBFManager.pas', 'uEpisodeMatching.pas', 'uBrowser.pas',
    'uReleaseGroup.pas', 'uOSDetector.pas', 'uTerminal.pas', 'uCmdLine.pas',
    'filey.lpi',
    'filey.lpr', 'filey64.png', 'license.txt', 'Privacy_Policy.html',
    'README.html', 'README.md', 'README2.html', 'README2.md');
  cResourceFiles: array[0..4] of String = (
    'ffprobe.exe', 'libeay32.dll', 'mkvmerge.exe',
    'mkvpropedit.exe', 'ssleay32.dll');
  // The files in g.SourcePath that building Filey needs - what
  // SourceListChecked expects to find in cSourceFiles.
  cSourceMasks = '*.pas;*.pp;*.inc;*.lfm;*.lpr;*.lpi';
var
  Busy: TSmartBusyState;
  ExitCode: Integer;
  i: Integer;
  lg, Output, s, sFailure, SP, ParentDir, ResourceDir, TempShowsDBF,
  TempShowsDir: String;
  NewEntry: TFullZipFileEntry;
  z: TZipper;
  zList: TSmartStrings;
  zSmartZipper: TSmartZipper;

  // cSourceFiles is in the order the SourceCode tab shows the files, not
  // alphabetical, so a new unit is easy to leave out of it. True if both
  // lists still match what is on disk, or the user chose to zip anyway.
  // A listed file that isn't there stops the zip outright: ZipAllFiles
  // would fail part-way through.
  function SourceListChecked: Boolean;
  var
    Found, Missing, Unlisted: TSmartStrings;
    sFile, sName: String;

    function IsListed(const AFileName: String): Boolean;
    var
      sListed: String;
    begin
      Result := False;
      // CompareFilenames ignores case only where the file system does.
      for sListed in cSourceFiles do
        if CompareFilenames(sListed, AFileName) = 0 then Exit(True);
    end;

  begin
    for sName in cSourceFiles do
      if not FileExists(CombinePath(SP, sName)) then Missing.Value.Add(sName);
    for sName in cResourceFiles do
      if not FileExists(CombinePath(ResourceDir, sName)) then
        Missing.Value.Add(CombinePath('resources', sName));
    if Missing.Value.Count > 0 then
    begin
      MessageDlgEx(sb(['Nothing was zipped. These files are listed in ',
        'actZipSourcesExecute, but are not in "', SP, '":', LE, LE,
        TrimRight(Missing.Value.Text)]), mtError, [mbOK]);
      Exit(False);
    end;
    FindAllFiles(Found.Value, SP, cSourceMasks, False);
    for sFile in Found.Value do
    begin
      sName := ExtractFileName(sFile);
      if not IsListed(sName) then Unlisted.Value.Add(sName);
    end;
    Result := (Unlisted.Value.Count = 0) or
      (MessageDlgEx(sb(['These files in "', SP, '" are not in ',
      'actZipSourcesExecute''s cSourceFiles, so the zip would leave them ',
      'out:', LE, LE, TrimRight(Unlisted.Value.Text), LE, LE,
      'Zip anyway?']), mtWarning, [mbYes, mbCancel]) = mrYes);
  end;

begin
  SP := g.SourcePath;
  ParentDir := CombinePath(SP, '..');
  ResourceDir := CombinePath(SP, 'resources');
  // Before the zap below, so that a zip called off here leaves the
  // databases alone.
  if not SourceListChecked then Exit;
  // Always zipped freshly rebuilt - current allshows.txt, every LOOKUPDATE
  // blank - so no "Zap?" question here. If that didn't happen, stop rather
  // than zip the SHOWS.DBF already there.
  if not ZapAndRebuildShows(sFailure) then
  begin
    ShowMessage(sb(['Nothing was zipped: SHOWS.DBF could not be rebuilt.',
      LE, LE, sFailure]), False, 'ZipSourcesZapFailed');
    Exit;
  end;
  z := zSmartZipper.Value;
  TempShowsDir := sb([IncludeTrailingPathDelimiter(GetTempDir(False)),
    'filey-zipsrc-', IntToStr(GetTickCount64)]);
  TempShowsDBF := sb([IncludeTrailingPathDelimiter(TempShowsDir),
    'SHOWS.DBF']);
  Busy := TSmartBusyState.Start(Form1, nil, StatusBar, True);
  try
    pcMain.ActivePage := tsProgress;
    FProgressUpdateCounter := 0;
    pcMain.ActivePage := tsList;
    StatusBar.Visible := True;
    StatusBar.Panels[0].Text := 'Zipping Source Files...';
    z.OnProgress := @ZipperProgress;
    z.OnStartFile := @ZipperStartFile;
    z.FileName := CombinePath(SP, g.SourceZipFileName);
    for s in cSourceFiles do zList.Value.Add(CombinePath(SP, s));
    for s in cResourceFiles do zList.Value.Add(CombinePath(ResourceDir, s));
    if FDbf[dbShows].aDB.State in [dsEdit, dsInsert] then
      FDbf[dbShows].aDB.Post;
    if not CopyFileForceDir(CombinePath(g.OpPath, 'SHOWS.DBF'),
      TempShowsDBF) then
      raise Exception.Create(sb(['Could not snapshot "', g.OpPath.Value,
        'SHOWS.DBF" to "', TempShowsDBF, '" for zipping.']));
    zList.Value.Add(TempShowsDBF);
    pcMain.ActivePage := tsProgress;
    ProgressBar.Min := 0;
    ProgressBar.Max := 100;
    ProgressBar.Position := 0;
    z.Entries.Clear;
    for i := 0 to zList.Value.Count - 1 do
    begin
      s := zList.Value[i];
      lg := sb([lg, LE, s]);
      NewEntry := TFullZipFileEntry(z.Entries.AddFileEntry(s));
      NewEntry.ArchiveFileName := efn(s);
      NewEntry.CompressionLevel := clmax;
    end;
    z.ZipAllFiles;
    CopyFile(z.FileName, g.FilePathSourceZip);
  except
    on E: Exception do
    begin
      lg := sb([lg, LE, LE, 'Error: ', E.Message]);
      LogError('actZipSourcesExecute failed', E);
    end;
  end;
  DeleteIfExists(TempShowsDBF);
  if DirectoryExists(TempShowsDir) then RemoveDir(TempShowsDir);
  ShowMessage(sb([lg, LE, LE, ns(z.Entries.Count), ' files zipped to: ',
    z.FileName]), False, 'ZipSources');
  Output := RunEx('/usr/bin/windres',
    ['-i', CombinePath(SP, 'filey.rc'), '-o', CombinePath(SP, 'filey.res')],
    ExitCode, True);
  StatusBar.Panels[0].Text :=
    IfThen(ExitCode = 0, 'Source zipped and .res updated.',
    'Error: Resource compiler failed.');
  if (ExitCode <> 0) and Output.IsNotEmpty then
    LogError('actZipSourcesExecute: windres failed - ' + Output);
  //ExtractZipResourceIfStale(g.SourceZipFileName);
  pcMain.ActivePage := tsList;
end;

procedure TForm1.AddFiles(const aFileStrings: TStrings);
var
  //Don't put TDataLayoutGuard or TSmartBusyState here, both cause problems
  db: TDbf;
  Grid: TDBGrid;
  s: String;
begin
  // Guard against re-entrancy: UI.Check pumps the message queue while the
  // scan/import below is in progress, so a second drop while the first is
  // still importing can re-enter this method mid-scan. Just drop the
  // re-entrant call. FIsScanning is the actual gate; TSmartBusyState
  // (ADisableUI=True) additionally disables every control for the
  // duration, which blocks most GUI-triggered re-entry before it reaches
  // this check, and replaces the manual SetAllCursors(crHourGlass)/
  // SetAllCursors(crDefault) pair with an exception-safe restore.
  if FIsScanning then Exit;
  FIsScanning := True;
  try
    db := FDbf[dbList].aDB;
    Grid := DBGridList;
    pcMain.ActivePageIndex := tsList.PageIndex;
    db.First;
    Grid.DataSource := FDbf[dbList].ADataSource;
    Form1.BringToFront;
    // let's see what's being dropped
    for s in aFileStrings do
    begin
      UI.Check;
      db.Append;
      SetListFrom(s);
      OpenDialog.FileName := s; //set InitialDir via SaveConfiguration
      PostRecord(db);
    end;
    DealWithSpecialFiles;
    ParseFilesList;
  finally
    FIsScanning := False;
  end;
end;

procedure TForm1.AddRow(const Cat, Desc: String);
var
  db: TDbf;
  Guard: TDataLayoutGuard;
begin
  db := FDbf[dbAbout].aDB;
  if not Assigned(db) then Exit;
  Guard := TDataLayoutGuard.Create(db, DBGridAbout, nil);
  db.Append;
  db.FieldByName('INFO').AsString := Cat;
  db.FieldByName('VALUE').AsString := Desc;
  PostRecord(db);
end;

{ ---------------------------------------------------------------------------
  Leftovers in the folder filey was started from, and where the AppImage
  lives
  --------------------------------------------------------------------------- }

procedure TForm1.AskToMoveAppImage(Data: PtrInt);
var
  sDest, sDestDir, sError, sManager, sOld: String;
begin
  if FIsShuttingDown or not (g.IsLinux and g.IsAppImage and
    g.IsAskMoveAppImage) then Exit;
  if not IsTransientAppImageLocation(g.AppImagePath) then Exit;
  // A manager already decides where AppImages go; filey stays out of it.
  sManager := AppImageManagerName;
  if sManager <> '' then
  begin
    DebugLog('AskToMoveAppImage: ' + sManager + ' is installed - not asking');
    Exit;
  end;
  sDestDir := AppImageHomeDir;
  case QuestionDlg('Keep filey somewhere it will stay?',
      sb(['filey is running from', LE, '  ', g.AppImagePath, LE, LE,
      'Files there are often cleaned out. Move filey to', LE, '  ', sDestDir,
      LE, LE, 'filey keeps running, and its desktop launcher and menu ',
      'entry will start it from the new place.']),
      mtConfirmation, [mrYes, 'Move it', mrNo, 'Not now',
      mrIgnore, 'Don''t ask again'], 0) of
    mrYes: ;
    mrIgnore:
      begin
        g.IsAskMoveAppImage := False;
        // Now, not only at exit, so a crash doesn't bring the question back.
        if not g.IsIniFileDeleted then
          AppIni.Value.WriteBool('Main', 'AskMoveAppImage', False);
        Exit;
      end;
    else
      Exit;
  end;
  sOld := g.AppImagePath;
  if not MoveAppImage(sOld, sDestDir, sDest, sError) then
  begin
    LogError('AskToMoveAppImage: ' + sError);
    MessageDlgEx(sb(['filey could not be moved to ', sDestDir, '.', LE, LE,
      sError]), mtError, [mbOK]);
    Exit;
  end;
  g.AppImagePath := sDest;
  // The desktop launcher and menu entry still name the old place, which no
  // longer exists, so CreateLinuxShortcut rewrites both
  // (DesktopLauncherWorks).
  CreateDesktopShortcut;
  if (pcMain.ActivePage = tsAbout) and (pcAbout.ActivePage = tsInfo) then
  begin
    SaveAboutRecNo;
    SetupDbAbout;
    AdjustColumns(DBGridAbout);
  end;
  MessageDlgEx(sb(['filey is now in', LE, '  ', sDest, LE, LE,
    'Start it from there, from the application menu or from its desktop ',
    'launcher from now on. ',
    'This copy keeps running until you close it.']), mtInformation, [mbOK]);
end;

procedure TForm1.CleanUpStrayFiles;
var
  Dirs, Found: TStringList;
  sDir, sFile: String;

  procedure AddDir(const ADir: String);
  var
    sD: String;
  begin
    sD := ExcludeTrailingPathDelimiter(Trim(ADir));
    // OpPath is filey's own folder: nothing there is a stray.
    if (sD = '') or (sD = ExcludeTrailingPathDelimiter(g.OpPath.Value)) or
      not DirectoryExists(sD) then Exit;
    if Dirs.IndexOf(sD) < 0 then Dirs.Add(sD);
  end;

  // Collected first and deleted afterwards, so the directory listing is
  // never changing underneath FindNext.
  procedure ScanDir(const ADir: String);
  var
    SR: TSearchRec;
    sPath: String;
  begin
    if FindFirst(CombinePath(ADir, '*'), faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Attr and faDirectory) <> 0 then Continue;
        sPath := CombinePath(ADir, SR.Name);
        // Cheap name tests come first inside both checks, so a big folder
        // costs one string compare per file.
        if IsFileyTableLeftover(sPath) or IsStrayManifestFile(sPath) then
          Found.Add(sPath);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;

begin
  Dirs := TStringList.Create;
  Found := TStringList.Create;
  try
    // Where filey was started (a file manager's current folder, for an
    // AppImage opened from Downloads), what the AppImage runtime recorded
    // as that, and $HOME, where a desktop launcher usually starts it.
    AddDir(uUtils.LaunchDir);
    {$IFDEF UNIX}
    AddDir(GetEnvironmentVariable('OWD'));
    {$ENDIF}
    AddDir(GetUserDir);
    for sDir in Dirs do ScanDir(sDir);
    for sFile in Found do
      if DeleteFile(sFile) then
        DebugLog('CleanUpStrayFiles: removed ' + sFile)
      else
        DebugLog('CleanUpStrayFiles: could not remove ' + sFile);
  finally
    Found.Free;
    Dirs.Free;
  end;
end;

{ ---------------------------------------------------------------------------
  About > Info: "Install with: ..." rows

  On Linux, a tool filey could not find (ffprobe, mkvmerge, mkvpropedit) or
  a missing OpenSSL gets a row whose value is the exact command for this
  distro (uOSDetector.InstallHint). Double-clicking the row copies the
  command; right-clicking it offers Copy, Open in Terminal (uTerminal: the
  command typed in at a bash prompt, run only when the user presses Enter)
  and Check again. Either way, filey then looks for the programs again by
  itself: when the terminal reports that the command has finished
  (InstallTimerTimer), and when the user comes back to filey's window after
  installing from a terminal of their own (AppActivate).
  --------------------------------------------------------------------------- }

procedure TForm1.AppActivate(Sender: TObject);
var
  Now64: QWord;
begin
  if FIsShuttingDown or FIsStartingUp or (FToolRecheckUntil = 0) then Exit;
  Now64 := GetTickCount64;
  if Now64 > FToolRecheckUntil then
  begin
    FToolRecheckUntil := 0;
    Exit;
  end;
  // A terminal filey opened is watched by InstallTimerTimer instead, which
  // knows when the command has actually finished.
  if Assigned(FInstallTerminal) then Exit;
  if Now64 - FLastToolRecheck < TOOL_RECHECK_MIN_GAP_MS then Exit;
  // Set now, not when the queued call runs, so a burst of activations
  // queues only one.
  FLastToolRecheck := Now64;
  Application.QueueAsyncCall(@DeferredToolRecheck, 0);
end;

procedure TForm1.CopyInstallCommand(const ACommand: String);
begin
  if ACommand = '' then Exit;
  Clipboard.AsText := ACommand;
  FToolRecheckUntil := GetTickCount64 + TOOL_RECHECK_WINDOW_MS;
  StatusBar.Panels[0].Text := sb(['Copied: ', ACommand,
    '  - paste it into a terminal (Ctrl+Shift+V) and press Enter']);
end;

function TForm1.CurrentAboutInstallCommand: String;
var
  db: TDbf;
begin
  Result := '';
  db := FDbf[dbAbout].aDB;
  if not (Assigned(db) and db.Active) or db.IsEmpty then Exit;
  Result := ExtractInstallCommand(db.FieldByName('VALUE').AsString);
end;

procedure TForm1.DBGridAboutDblClick(Sender: TObject);
var
  sCommand: String;
begin
  DBGridDblClick(Sender);
  // The first click of the double-click has already made the row under
  // the mouse the current one.
  sCommand := CurrentAboutInstallCommand;
  if sCommand <> '' then CopyInstallCommand(sCommand);
end;

procedure TForm1.DeferredToolRecheck(Data: PtrInt);
begin
  if FIsShuttingDown or (MissingToolNames = '') then
  begin
    FToolRecheckUntil := 0;
    Exit;
  end;
  RecheckExternalTools('Checked again');
end;

procedure TForm1.EnsureInstallMenu;

  function AddItem(const ACaption: String; AOnClick: TNotifyEvent): TMenuItem;
  begin
    Result := TMenuItem.Create(FInstallMenu);
    Result.Caption := ACaption;
    Result.OnClick := AOnClick;
    FInstallMenu.Items.Add(Result);
  end;

begin
  if Assigned(FInstallMenu) then Exit;
  FInstallMenu := TPopupMenu.Create(Self);
  // Order must match INSTALL_MENU_COPY / INSTALL_MENU_TERMINAL.
  AddItem('Copy', @InstallMenuCopyClick);
  AddItem('Open in Terminal (press Enter there to run it)',
    @InstallMenuTerminalClick);
  AddItem('-', nil);
  AddItem('Check again for missing programs', @InstallMenuCheckClick);
end;

procedure TForm1.InstallMenuCheckClick(Sender: TObject);
begin
  RecheckExternalTools('Checked again');
end;

procedure TForm1.InstallMenuCopyClick(Sender: TObject);
begin
  CopyInstallCommand(FInstallMenuCommand);
end;

procedure TForm1.InstallMenuTerminalClick(Sender: TObject);
begin
  RunInstallInTerminal(FInstallMenuCommand);
end;

procedure TForm1.InstallTimerTimer(Sender: TObject);
var
  iExit: Integer;
  sName: String;
  State: TTerminalLaunchState;
begin
  if FIsShuttingDown or not Assigned(FInstallTerminal) then
  begin
    FInstallTimer.Enabled := False;
    Exit;
  end;
  State := FInstallTerminal.Poll(iExit);
  if (State = tlsWaiting) and
    (FInstallTerminal.ElapsedMs < INSTALL_WAIT_MAX_MS) then Exit;
  FInstallTimer.Enabled := False;
  sName := FInstallTerminal.Terminal.Name;
  FreeAndNil(FInstallTerminal);
  case State of
    tlsDone:
      case iExit of
        0: RecheckExternalTools('Install finished');
        129: RecheckExternalTools('Terminal closed');
        130: StatusBar.Panels[0].Text := 'Install cancelled.';
        else
          RecheckExternalTools(sb(['The install command ended with exit ',
            'code ', iExit]));
      end;
    tlsFailed:
      StatusBar.Panels[0].Text := sb([sName,
        ' could not open the command (exit code ', iExit,
        '). It is on the clipboard: paste it into a terminal and press ',
        'Enter.']);
    else
      // Still open after INSTALL_WAIT_MAX_MS: stop waiting, look once.
      RecheckExternalTools('Stopped waiting for the terminal');
  end;
end;

function TForm1.MissingToolNames: String;
var
  SB: TStringBuilder;

  procedure Check(const AName: String; const APath: TFilePath);
  begin
    if (APath.Value <> '') and APath.Exists then Exit;
    if SB.Length > 0 then SB.Append(', ');
    SB.Append(AName);
  end;

begin
  SB := TStringBuilder.Create;
  try
    Check('ffprobe', g.FilePathFFProbe);
    Check('mkvmerge', g.FilePathMKVMerge);
    Check('mkvpropedit', g.FilePathMKVPropEdit);
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

procedure TForm1.RecheckExternalTools(const AWhy: String);
var
  sAfter, sBefore, sMessage: String;
begin
  if FIsShuttingDown or FIsStartingUp then Exit;
  FLastToolRecheck := GetTickCount64;
  sBefore := MissingToolNames;
  SetAllCursors(crHourGlass);
  try
    ValidateAndDiscoverTools;
  finally
    SetAllCursors(crDefault);
  end;
  sAfter := MissingToolNames;
  if sAfter = '' then FToolRecheckUntil := 0;
  // Rebuild About > Info if it is what's on screen, so the rows change
  // from "[NOT FOUND]" to the version found, keeping the user's place.
  if (pcMain.ActivePage = tsAbout) and (pcAbout.ActivePage = tsInfo) then
  begin
    SaveAboutRecNo;
    SetupDbAbout;
    AdjustColumns(DBGridAbout);
  end;
  if sAfter = '' then
    sMessage := sb([AWhy, '. All external programs were found.'])
  else if sAfter <> sBefore then
    sMessage := sb([AWhy, '. Some were found; still missing: ', sAfter, '.'])
  else
    sMessage := sb([AWhy, '. Still not found: ', sAfter, '.']);
  DebugLog('RecheckExternalTools: ' + sMessage);
  StatusBar.Panels[0].Text := sMessage;
end;

procedure TForm1.RunInstallInTerminal(const ACommand: String);
var
  sAppDir, sError: String;
begin
  if ACommand = '' then Exit;
  // First, so the command is at hand even if no terminal opens.
  CopyInstallCommand(ACommand);
  // The terminal must not inherit what the AppImage runtime set up for
  // filey itself (see uTerminal.BuildCleanEnvironment).
  sAppDir := '';
  if g.IsAppImage then sAppDir := GetEnvironmentVariable('APPDIR');
  // A terminal opened earlier stays open; filey just stops waiting on it.
  FreeAndNil(FInstallTerminal);
  FInstallTerminal := TTerminalLaunch.Create;
  if not FInstallTerminal.Start(ACommand, sAppDir, sError) then
  begin
    FreeAndNil(FInstallTerminal);
    StatusBar.Panels[0].Text := sb([sError, ' The command is on the ',
      'clipboard: paste it into a terminal (Ctrl+Shift+V) and press Enter.']);
    Exit;
  end;
  if not Assigned(FInstallTimer) then
  begin
    FInstallTimer := TTimer.Create(Self);
    FInstallTimer.Enabled := False;
    FInstallTimer.Interval := INSTALL_POLL_MS;
    FInstallTimer.OnTimer := @InstallTimerTimer;
  end;
  FInstallTimer.Enabled := True;
  StatusBar.Panels[0].Text := sb(['Opened ', FInstallTerminal.Terminal.Name,
    ': press Enter there to run "', ACommand,
    '". filey looks for the programs again when it has finished.']);
end;

function TForm1.AddtsSourceCode(pc: TPageControl;
  const TabCaption: String): TTabSheet;
var
  bn, bp: TBitBtn;
  eb: TEditButton;
  Guard: TDataLayoutGuard;
  i: Integer;
  MS: TSmartMemoryStream;
  pn: TPanel;
  se: TSynEdit;
  SrcStream: TMemoryStream;
  UniqueSuffix: String;
begin
  Guard := TDataLayoutGuard.CreateLayOut(pc);
  // 1. Create the TabSheet
  i := g.SourceFilesCount - 1;
  // 0-based arrays
  FSourceManager.AddSourceView(pc, efn(TabCaption), TabCaption);
  Result := FSourceManager.GetTabSheet(i);
  Result.PageControl := pc;
  Result.Caption := efn(TabCaption);
  Result.ImageIndex := IfThen(UTF8ContainsText('.pas,.lpr',
    lowercase(ExtractFileExt(TabCaption))), 1, 0);
  // 2. Generate Suffix based on PageIndex (0-based) to match Event Handlers
  UniqueSuffix := i.toString;
  // 3. Create Panel
  pn := FSourceManager.GetPanel(i);
  pn.Align := alTop;
  pn.AutoSize := False;
  pn.Caption := '';
  pn.Height := 44;
  eb := FSourceManager.GetEditButton(i);
  eb.Name := 'EditButton' + UniqueSuffix;
  eb.Caption := '';
  eb.Align := alLeft;
  eb.AutoSelect := True;
  eb.AutoSize := True;
  eb.ButtonHint := 'Clear Find';
  eb.ButtonWidth := 38;
  eb.Button.Caption := '';
  //remove the '..'
  eb.Button.AutoSize := True;
  //eb.Button.Width:= 42;
  eb.DirectInput := True;
  eb.Enabled := True;
  eb.Height := 44;
  eb.Hint := 'Find Text';
  eb.ImageIndex := 3;
  eb.Images := ImageListFiley;
  eb.ImageWidth := 32;
  eb.NumGlyphs := 1;
  eb.Parent := pn;
  eb.PasswordChar := #0;
  eb.TabOrder := 1;
  eb.Width := tsAbout.ClientWidth div 2;
  // Assign Events last to avoid triggering them during setup
  eb.OnButtonClick := @EditButtonClick;
  eb.OnChange := @EditChange;
  eb.OnKeyDown := @EditKeyDown;
  eb.OnKeyUp := @EditKeyUp;
  eb.OnMouseEnter := @EditMouseEnter;
  // 5. Create BitBtnNext
  bn := FSourceManager.GetBitBtnNext(i);
  bn.Name := 'BitBtnNext' + UniqueSuffix;
  bn.Caption := '';
  bn.Align := alLeft;
  bn.AutoSize := True;
  bn.BorderSpacing.CellAlignHorizontal := ccaFill;
  bn.BorderSpacing.CellAlignVertical := ccaFill;
  bn.GlyphShowMode := gsmApplication;
  bn.Height := 50;
  bn.Hint := 'Find Next';
  bn.ImageIndex := 18;
  bn.Images := ImageListFiley;
  bn.ImageWidth := 32;
  bn.Kind := bkCustom;
  bn.Parent := pn;
  bn.Spacing := 4;
  bn.TabOrder := 0;
  bn.Width := 48;
  bn.OnClick := @BitBtnNextClick;
  // 6. Create BitBtnPrev
  bp := FSourceManager.GetBitBtnPrev(i);
  bp.Name := 'BitBtnPrev' + UniqueSuffix;
  bp.Caption := '';
  bp.Align := alLeft;
  bp.AutoSize := True;
  bp.BorderSpacing.CellAlignHorizontal := ccaFill;
  bp.BorderSpacing.CellAlignVertical := ccaFill;
  bp.GlyphShowMode := gsmAlways;
  bp.Height := 44;
  bp.Hint := 'Find Previous';
  bp.ImageIndex := 19;
  bp.Images := ImageListFiley;
  bp.ImageWidth := 32;
  bp.Kind := bkCustom;
  bp.NumGlyphs := 1;
  bp.Parent := pn;
  bp.Spacing := 4;
  bp.TabOrder := 2;
  bp.Width := 48;
  bp.OnClick := @BitBtnPrevClick;
  // 6. Create SynEdit
  se := FSourceManager.GetSynEdit(i);
  se.Name := 'SynEdit' + UniqueSuffix;
  se.Caption := '';
  se.Align := alClient;
  se.Font.Assign(StatusBar.Canvas.Font);
  se.Font.Style := [];
  se.Font.Pitch := Graphics.fpFixed;
  TSynEdit(se).Gutter.Color := $00F0F0F0;
  se.Gutter.LineNumberPart.Index := $00AF912B;
  se.Highlighter := SynFreePascalSyn1;
  se.Hint := 'Source Code';
  se.PopupMenu := MenuSourceCode;
  se.ReadOnly := True;
  se.MouseOptions := [emCtrlWheelZoom];
  se.OnEnter := @SynEditOnEnter;
  se.OnKeyDown := @SynEditKeyDown;
  se.OnStatusChange := @SynEditStatusChange;
  ApplyStandardColors(se);
  // Load content.
  // MS.Value on the LEFT of ':=' is SetValue; MS.Value inside Assigned() is
  // the LAZY getter, which creates a fresh empty TMemoryStream whenever
  // FStream is nil. So "if Assigned(MS.Value)" was unconditionally True and
  // a nil return from GetStreamFromZipResource silently loaded an empty
  // editor instead of being caught. Test the real return value.
  SrcStream := GetStreamFromZipResource(TabCaption);
  if Assigned(SrcStream) then
  begin
    MS.Value := SrcStream;   // record takes ownership from here on
    MS.Value.Position := 0;
    se.Lines.LoadFromStream(MS.Value);
  end
  else
    LogError('Could not read from source zip: ' + TabCaption);
  se.ReadOnly := True;
  if i = 0 then
    // Fix: Force Focus logic
  begin
    pc.ActivePageIndex := 0;
    Self.ActiveControl := se;
    SafeSetFocus(se);
  end;
  // se.EndUpdate removed: there is no matching se.BeginUpdate anywhere in
  // this routine. (The TDataLayoutGuard is on pc, a TPageControl, so it
  // takes the DisableAutoSizing/DisableAlign branch, not BeginUpdate.) An
  // unpaired EndUpdate drives TCustomSynEdit's paint-lock counter to -1,
  // after which the "if FPaintLock = 1" logic in every later Begin/End pair
  // is off by one and repaints get silently dropped. If batching was the
  // intent, add "se.BeginUpdate;" right after se is obtained instead.
end;

// NOTE: Deliberately kept in TForm1, not uUtils.pas. Despite the generic
// Sender: TObject parameter, this method's logic is hardwired to this
// form's specific grid (DBGridShows) and throttle field
// (FShowsColumnsThrottle) via SmartAutoAdjustColumns/ApplySpringColumn -
// it isn't a reusable utility, it's UI logic specific to this layout.
procedure TForm1.AdjustColumns(const Sender: TObject);
var
  Grid: TDBGrid;
  Guard: TDataLayoutGuard;
begin
  // 1. Safely resolve the Sender to a TDBGrid
  if Sender is TDBGrid then Grid := TDBGrid(Sender)
  else if Sender is TEditButton then
    // Adjust this line if the Grid is linked differently (e.g., via a property)
    Grid := TDBGrid(TEditButton(Sender).Parent)
  else
    Exit;
  // 2. Early exit checks before any work or RAII initialization happens
  if (Grid = nil) or not Grid.Showing or not Grid.Enabled or
    (Grid.Columns.Count = 0) then Exit;
  // 3. Initialize RAII Guard; it will automatically clean up when the procedure exits
  Guard := TDataLayoutGuard.CreateLayOut(Grid);
  // DBGridShows is large enough (thousands of rows) that repeated
  // AutoAdjustColumns calls within a single user action are worth
  // debouncing - see SmartAutoAdjustColumns. Other grids are small
  // enough that this hasn't been a problem, so they go through the
  // plain, unthrottled call.
  if Grid = DBGridShows then
    SmartAutoAdjustColumns(Grid, FShowsColumnsThrottle)
  else
    Grid.AutoAdjustColumns;
  ApplySpringColumn(Grid);
end;

procedure TForm1.AfterEpsShow(Data: PtrInt);
var
  db: TDbf;
  Grid: TDBGrid;
  Guard: TDataLayoutGuard;
begin
  if (GetEpsTitle = GetShowsTitle) then Exit;
  Grid := DBGridEps;
  db := FDbf[dbEps].aDB;
  Guard := TDataLayoutGuard.Create(db); // don't guard Grid here
  SetFilterEpsOnTitle;
  Grid.Options := Grid.Options + [dgRowSelect, dgCellHints, dgEditing];
  UI.Check;
  Grid.Columns[2].SizePriority := 1;
  Grid.Columns[3].Visible := False;
  Grid.AutoAdjustColumns;
  if (db.ExactRecordCount > 0) or (GetShowsLookUpDate = g.Today) then Exit;
  DownLoadEps; // re-adjusts DBGridEps' columns itself once done
end;

procedure TForm1.AfterShowsShow(Data: PtrInt);
begin
  // The control is now fully "alive" and ready for focus
  if ShowsFilterEdit.Text = '' then ShowsFilterEdit.Button.Click;
  SmartAutoAdjustColumns(DBGridShows, FShowsColumnsThrottle);
  if ShowsFilterEdit.CanFocus then SafeSetFocus(ShowsFilterEdit);
end;

function TForm1.AppendReleaseGroup(const ABaseName: String): String;
var
  sExt, sGroup, sStem: String;
begin
  Result := ABaseName;
  if ABaseName.IsEmpty then Exit;
  // Guessed from the ORIGINAL name (the "From" field), never from
  // ABaseName itself - the "To" name is our own freshly-built
  // Title.EpNum.EpName...-style name and has no release group of its own
  // to find.
  sGroup := GuessReleaseGroup(GetListFrom);
  if sGroup.IsEmpty then Exit;
  sExt := ExtractFileExt(ABaseName);
  sStem := Copy(ABaseName, 1, Length(ABaseName) - Length(sExt));
  Result := sb([sStem, '-', sGroup, sExt]);
end;

function TForm1.ApplyReservedCharStyle(const AText: String): String;
var
  bReplaced: Boolean;
  c: Char;
  i, j: Integer;
  SB: TStringBuilder;
begin
  // rcsUnderscore: FixWinFileName turns them into '_', as before.
  if g.ReservedCharStyle <> rcsLookalike then Exit(AText);
  // Byte by byte: every character replaced is ASCII, and an ASCII byte is
  // never part of a multi-byte UTF-8 character, so the rest pass through
  // untouched.
  SB := TStringBuilder.Create(Length(AText) + 16);
  try
    for i := 1 to Length(AText) do
    begin
      c := AText[i];
      if c = '"' then
      begin
        // Opening quote at the start or after a space or an opening
        // bracket; closing quote everywhere else.
        if (i = 1) or (AText[i - 1] in [' ', #9, '(', '[', '{']) then
          SB.Append(QUOTE_OPEN_LOOKALIKE)
        else
          SB.Append(QUOTE_CLOSE_LOOKALIKE);
        Continue;
      end;
      bReplaced := False;
      for j := Low(RESERVED_LOOKALIKES) to High(RESERVED_LOOKALIKES) do
        if RESERVED_LOOKALIKES[j].Reserved = c then
        begin
          SB.Append(RESERVED_LOOKALIKES[j].Lookalike);
          bReplaced := True;
          Break;
        end;
      if not bReplaced then SB.Append(c);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

procedure TForm1.ApplySpringColumn(const Grid: TDBGrid;
  const AIndex: Integer = -1);
var
  Item: TCollectionItem;
  // The loop variable must match the collection's base type
  Column: TColumn;
  Guard: TDataLayoutGuard;
  SpringColumn: TColumn;
  TotalWidth: Integer;
const
  SCROLLBAR_BUFFER = 25;
  MIN_SPRING_WIDTH = 80;
begin
  if not (Grid is TDBGrid) then Exit;
  if (Grid.Columns.Count = 0) or not Showing then Exit;
  Guard := TDataLayoutGuard.CreateLayOut(Grid);
  // 1. Identify the target Spring Column
  if (AIndex < 0) or (AIndex >= Grid.Columns.Count) then
    SpringColumn := Grid.Columns[Grid.Columns.Count - 1]
  else
    SpringColumn := Grid.Columns[AIndex];
  // If the spring column itself is hidden, there's nothing to spring!}
  if not SpringColumn.Visible then Exit;
  // 2. Calculate the width of all OTHER visible columns
  TotalWidth := 0;
  for Item in Grid.Columns do
  begin
    Column := TColumn(Item);
    // Only sum if the column is NOT our spring target AND is visible
    if (Column <> SpringColumn) and (Column.Visible) then
      TotalWidth := TotalWidth + Column.Width;
  end;
  // 3. Apply the spring with a fallback minimum
  // We use Grid.ClientWidth to be accurate to the component's internal space
  if Grid.ClientWidth > (TotalWidth + SCROLLBAR_BUFFER) then
    SpringColumn.Width := Grid.ClientWidth - TotalWidth - 5
  else
    SpringColumn.Width := MIN_SPRING_WIDTH;
end;

procedure TForm1.ApplyStandardColors(var ASynEdit: TSynEdit);
const
  clNotepadQQ = TColor($FAFAFA);
  clOrange = TColor($00A5FF);
  clWhiteSmoke = TColor($F5F5F5);
var
  FP: TSynFreePascalSyn;
  Guard: TDataLayoutGuard;
begin
  if not (ASynEdit.Highlighter is TSynFreePascalSyn) then Exit;
  FP := TSynFreePascalSyn(ASynEdit.Highlighter);
  Guard := TDataLayoutGuard.CreateLayOut(ASynEdit);
  ASynEdit.Color := clWhiteSmoke;  //or clNotepadQQ
  ASynEdit.ReadOnly := True;
  FP.Attribute[Ord(tkComment)].Foreground := clGreen;
  FP.Attribute[Ord(tkDirective)].Foreground := clMaroon;
  FP.Attribute[Ord(tkKey)].Foreground := clBlue;
  FP.Attribute[Ord(tkKey)].Style := [fsBold];
  FP.Attribute[Ord(tkNumber)].Foreground := clOrange;
  FP.Attribute[Ord(tkString)].Foreground := clGray;
  FP.Attribute[Ord(tkSymbol)].Foreground := clNavy;
end;

procedure TForm1.ApplySubtitleFlags(const AFilePath: String);
var
  oTrackIDs: TSmartStrings;
  sCommandLine: String;
  iEnglishTrackInt: Integer;
  i: Integer;
  sCurrentID: String;
  iCurrentIDInt: Integer;
begin
  // 1. Get the full subtitle track list and the first English track ID
  // (if any) from a single mkvmerge invocation.
  oTrackIDs := GetSubtitleTrackInfo(AFilePath, iEnglishTrackInt);
  if oTrackIDs.Value.Count = 0 then Exit;
  // 1a. mkvpropedit is used below to apply the flags GetSubtitleTrackInfo
  // (mkvmerge) just found - re-verify it's still there before building a
  // command line around it, same as mkvmerge just was.
  if not EnsureMKVToolsAvailable(False, True) then Exit;
  // 2. Build the command
  sCommandLine := sb([g.WineMKVPropEdit + g.FilePathMKVPropEdit.Value,
    ' ', AFilePath.Quote]);
  for i := 0 to oTrackIDs.Value.Count - 1 do
  begin
    sCurrentID := oTrackIDs.Value[i];
    iCurrentIDInt := StrToIntDef(sCurrentID, -1);
    // Increment ID for mkvpropedit (0-based to 1-based)
    sCommandLine := sCommandLine +
      sb([' --edit track:@', IntToStr(iCurrentIDInt + 1)]);
    // Logic: If this track is our target English track, enable it. Otherwise, disable.
    if (iEnglishTrackInt <> -1) and (iCurrentIDInt = iEnglishTrackInt) then
      sCommandLine := sCommandLine + ' --set flag-default=1 --set flag-forced=1'
    else
      sCommandLine := sCommandLine +
        ' --set flag-default=0 --set flag-forced=0';
  end;
  RunEx(sCommandLine, True);
end;

procedure TForm1.AssignDBGridLogEvents;
begin
  DBGridLog.OnCellClick := @DBGridLogCellClick;
  DBGridLog.OnColEnter := @DBGridLogColEnter;
  DBGridLog.OnMouseEnter := @DBGridLogMouseEnter;
  DBGridLog.OnMouseLeave := @DBGridLogMouseLeave;
  DBGridLog.OnKeyDown := @DBGridLogKeyDown;
  DBGridLog.OnEnter := @DBGridLogEnter;
  DBGridLog.OnDblClick := @DBGridLogDblClick;
  DBGridLog.OnDrawColumnCell := @DBGridLogDrawColumnCell;
  DBGridLog.OnMouseMove := @DBGridMouseMove;
  DBGridLog.OnMouseDown := @RightMouseFonts;
end;

procedure TForm1.AssignFoundEp;
var
  db: TDbf;
  EpIsFound: Boolean = False;
  Guard: TDataLayoutGuard;
  MyVarArray: variant;
  s1: String = '';
  s2: String = '';
  sFinalResult: String = '';
begin
  g.LastTitleFound := GetListTitle;
  ShowsFilterEdit.Text := g.FoundTitle;
  s1 := Trim(g.FoundTitle);
  s2 := GetListEpNum;
  MyVarArray := VarArrayOf([s1, s2]);
  // turn off Filtering to allow Locate to work correctly
  db := FDbf[dbEps].aDB;
  Guard := TDataLayoutGuard.Create(db);
  db.Filtered := False;
  DBFRecordCountChanged(db);
  // First attempt: use case-insensitive locate
  EpIsFound := db.Locate('TITLE;EPNUM', MyVarArray, [loCaseInsensitive]);
  // Only download episodes if not already found — avoids redundant
  // downloads and prevents the DB being left in an unexpected state
  DebugLog('AssignFoundEp, EpIsFound= ' + IfThen(EpIsFound));
  if not EpIsFound then
  begin
    DownLoadEps;
    // Retry after download, still case-insensitive for robustness
    EpIsFound := db.Locate('TITLE;EPNUM', MyVarArray, [loCaseInsensitive]);
  end;
  if EpIsFound then
  begin
    SetListTitle(GetEpsTitle);
    // As epguides spells it, spaces and all: ComposeNewName decides what
    // separates the words. (It used to be stored with spaces made dots,
    // which ComposeNewName could not tell from a real "Dr. Who" dot.)
    SetListEpName(GetEpsEpName);
    SetListDirectory(GetShowsDirectory);
  end;
  sFinalResult := ComposeNewName(not EpIsFound);
  DebugLog('AssignFoundEp, sFinalResult= ' + sFinalResult);
  // Note: do NOT set db.Exclusive := True here — it has no matching
  // restore and would lock the dataset for all subsequent lookups in
  // the same batch (causing S02E01, S03E01, etc. to be skipped).
  if GetListTreeLevel = '0' then
    SetListTo(AppendReleaseGroup(sFinalResult));
end;

procedure TForm1.AssignListFieldIfEmpty(const sFieldName, sValue: String);
begin
  if FDbf[dbList].aDB.FieldByName(sFieldName).AsString = '' then
    FDbf[dbList].aDB.FieldByName(sFieldName).AsString := sValue;
end;

procedure TForm1.AssignRootNameToAssociatedFiles;
var
  RootTo: String = '';
  db: TDbf;
begin
  db := FDbf[dbList].aDB;
  db.IndexName := 'SORTORDER';
  db.First;
  while not db.EOF do
  begin
    if GetListTreeLevel = '0' then RootTo := efnOnly(GetListTo);
    if GetListTreeLevel = '1' then
      SetListTo(FixWinFileName(RootTo + GetDbField(dbList, 'EXTENSION')));
    db.Next;
  end;
end;

procedure TForm1.AttributionLinkClick(Sender: TObject;
  const SRC: ThtString; var Handled: Boolean);
begin
  // Open the URL in the system default browser
  LCLIntf.OpenURL(ansistring(SRC));
  Handled := True;
end;

procedure TForm1.BitBtn1Click(Sender: TObject);
begin
  OpenURL('https://github.com/IndySockets/OpenSSL-Binaries');
end;

// Despite the name, this is not wired to any button's OnClick (the live
// Cancel button on the Select-a-Show panel uses Action = actFilterEditCancel,
// handled by actFilterEditCancelExecute). Its only caller is actExitExecute,
// which uses it purely to force-close the panel and clear its filters as
// one step of a full application shutdown; actExitExecute already sets
// FIsShuttingDown itself, so this must not set it too -- doing so here
// would make any future direct rebinding of this handler to a live button
// silently quit the whole application instead of just cancelling the panel.
procedure TForm1.BitBtnCancelClick(Sender: TObject);
begin
  ShowsFilterEdit.Text := '';
  FDbf[dbEps].aFilterText := '';
  FDbf[dbEps].aFilterDescription := '';
  FDbf[dbEps].aDB.Filtered := False;
  FDbf[dbEps].aRecCountDirty := True;
  FDbf[dbShows].aFilterText := '';
  FDbf[dbShows].aFilterDescription := '';
  FDbf[dbShows].aDB.Filtered := False;
  FDbf[dbShows].aRecCountDirty := True;
  PanelSelect.Visible := False;
  SetAllCursors(crDefault);
end;

procedure TForm1.BitBtnIconClick(Sender: TObject);
begin
  OpenURL('https://www.flaticon.com/free-icon/television_926087');
end;

procedure TForm1.BitBtnLookupEpsMouseEnter(Sender: TObject);
begin
  SetTabSheetListButtons;
end;

procedure TForm1.BitBtnNextClick(Sender: TObject);
var
  ASearch: String = '';
  p: Integer = 0;
  sSynEditName: String = '';
  EditBtn: TEditButton;
  SynEdit: TSynEdit;
begin
  if pcSourceCode.PageCount = 0 then Exit;
  p := pcSourceCode.ActivePageIndex;
  if p < 0 then Exit;
  EditBtn := pcSourceCode.Page[p].FindComponent(
    sb(['EditButton', p.toString])) as TEditButton;
  if EditBtn = nil then Exit;
  ASearch := EditBtn.Text;
  sSynEditName := sb(['SynEdit', p.toString]);
  SynEdit := pcSourceCode.Page[p].FindComponent(sSynEditName) as TSynEdit;
  if SynEdit = nil then Exit;
  g.SearchDirectionForward := True;
  SynEdit.SearchReplace(ASearch, '', []);
end;

procedure TForm1.BitBtnOpenReadmeClick(Sender: TObject);
begin
  // (Two constants: the compiler joins them, so no run-time concatenation.)
  OpenBundledDocExternally(README_EXTERNAL_DOCS[0],
    FILEY_REPO_URL + '-/blob/master/README2.md');
end;

procedure TForm1.BitBtnPrevClick(Sender: TObject);
var
  ASearch: String;
  p: Integer;
  sSynEditName: String;
  EditBtn: TEditButton;
  SynEdit: TSynEdit;
begin
  if pcSourceCode.PageCount = 0 then Exit;
  p := pcSourceCode.ActivePageIndex;
  if p < 0 then Exit;
  EditBtn := pcSourceCode.Page[p].FindComponent(
    sb(['EditButton', p.toString])) as TEditButton;
  if EditBtn = nil then Exit;
  ASearch := EditBtn.Text;
  sSynEditName := sb(['SynEdit', p.toString]);
  SynEdit := pcSourceCode.Page[p].FindComponent(sSynEditName) as TSynEdit;
  if SynEdit = nil then Exit;
  g.SearchDirectionForward := False;
  SynEdit.SearchReplace(ASearch, '', [ssoBackwards]);
end;

procedure TForm1.BitBtnUndoClick(Sender: TObject);
var
  db: TDbf;
begin
  db := FDbf[dbLog].aDB;
  db.ShowDeleted := True;
  db.OnFilterRecord := @FilterLogOnUndo;
  db.Filtered := True;
  DBFRecordCountChanged(db);
  db.First;
  RenameThisList(db);
  db.ShowDeleted := False;
  db.Filtered := False;
  DBFRecordCountChanged(db);
  db.First;
end;

function TForm1.BrowseToURL(const AURL: String; AForce: Boolean): Boolean;
var
  Page: TBrowserDownload;
  sURL: String;
begin
  Result := False;
  if FIsBrowsing or FIsShuttingDown then Exit;
  sURL := NormalizeWebAddress(AURL);
  if sURL.IsEmpty then
  begin
    if AURL.IsNotBlank then
    begin
      FBrowserStatus := sb(['Not a web address: "', Trim(AURL),
        '". Only http:// and https:// pages can be shown here.']);
      ShowStatusBrowser;
    end;
    Exit;
  end;
  if (not AForce) and (sURL = g.LastURL) then Exit(True);
  FIsBrowsing := True;
  FBrowserCancel := False;
  FBrowserHandedOff := False;
  edUrl.Text := sURL; // also clears edUrl.Modified - see edUrlEditingDone
  FBrowserStatus := sb(['Loading ', sURL, ' ...']);
  ShowStatusBrowser;
  // The window keeps responding while a page loads (RunBrowserDownloads),
  // hence the "busy in the background" cursor rather than the hourglass.
  SetAllCursors(crAppStart);
  Page := nil;
  try
    try
      // https:// needs libeay32.dll/ssleay32.dll on Windows - same one-retry
      // pattern as ParseHTMLToMemo and InitializeShowsDownloadSSL. Done
      // here, on the main thread, before any download thread uses OpenSSL.
      EnsureOpenSSLDllsPresent;
      try
        InitSSLInterface;
      except
        on E: Exception do
          if UTF8ContainsText(E.Message, 'Could not initialize OpenSSL') and
            EnsureOpenSSLDllsPresent then
            InitSSLInterface // retry once, now that the DLLs are in place
          else
            raise;
      end;
      Page := DownloadBrowserPage(sURL);
      // nil: stopped for another address, or the program is closing.
      if Assigned(Page) then Result := ShowBrowserPage(Page);
    except
      on E: Exception do
      begin
        // edUrl keeps the address, so a typo can be corrected.
        FBrowserStatus := sb(['Could not open ', sURL, ': ', E.Message]);
        LogError('BrowseToURL: could not open ' + sURL, E);
      end;
    end;
  finally
    Page.Free;
    FIsBrowsing := False;
    SetAllCursors(crDefault);
  end;
  if FIsShuttingDown then
  begin
    // Exit was clicked while the page loaded (RunBrowserDownloads keeps
    // messages flowing). The main loop can end up waiting for one more
    // event before it sees Application.Terminated - which, with the mouse
    // still, might not come. This wakes it (GTK2: a byte down the pipe its
    // poll watches), so the program closes at once.
    if Assigned(WakeMainThread) then WakeMainThread(Self);
    Exit;
  end;
  if FBrowserCancel then
  begin
    // NavigateBrowser stopped this page for another; that one opens now.
    FBrowserCancel := False;
    Application.QueueAsyncCall(@DeferredBrowse, Ord(FPendingBrowserForce));
    Exit;
  end;
  UpdateBrowserButtons;
  ShowStatusBrowser;
end;

procedure TForm1.btGoClick(Sender: TObject);
begin
  actGoExecute(Sender);
end;

//jcf:format=on
procedure TForm1.BuildAboutReport;
var
  FileVerInfo: TSmartVersionInfo;
  pHTML: TSmartHtmlViewer;
  s: String;
  vStrings: TStrings;
const
  sNF = ' [NOT FOUND]';
  // Follows an "Install with: ..." hint. ExtractInstallCommand stops at the
  // two spaces and '(' this starts with.
  INSTALL_TIP = '  (double-click to copy, right-click for more)';

  // InstallHint for AWhat on this distro, plus how to use the command when
  // there is an exact one.
  function InstallHintWithTip(AWhat: TInstallable): String;
  begin
    Result := InstallHint(g.PkgFamily, AWhat);
    if InstallCommand(g.PkgFamily, AWhat) <> '' then
      Result := Result + INSTALL_TIP;
  end;

  // AName is what the row is called when fn is '' (nothing was found, so
  // there is no file name to show) - otherwise the row was just " [NOT
  // FOUND]", with no way to tell what was missing.
  procedure AddRowIfExists(const fn: String; const AName: String = '');
  var
    sName: String;
  begin
    sName := efn(fn);
    if sName = '' then sName := AName;
    AddRow(sName + IfExists(fn, ' [exists]', sNF),
      IfThen(fn <> '', fn, '[no path]'));
  end;

  // First line the tool prints for AVersionArg. A bundled Windows .exe on
  // Linux runs through Wine (AWinePrefix <> ''), the same way filey runs
  // it everywhere else; launching the .exe directly just fails.
  function ToolVersion(const APath, AWinePrefix, AVersionArg: String): String;
  var
    iExit: Integer;
    SL: TSmartStrings;
  begin
    if Trim(AWinePrefix) = '' then Exit(GetToolVer(APath, AVersionArg));
    Result := ' [No Version Found]';
    SL.Value.Text := Trim(RunEx('wine', [APath, AVersionArg], iExit));
    if (iExit <> -1) and (SL.Value.Count > 0) then
      Result := SL.Value[0] + ' (via Wine)';
  end;

  // One row per external tool. Missing: the row still names the tool, and
  // the value says how to get it - on Linux the exact command for this
  // distro, since filey ships only the Windows builds of these tools.
  procedure AddToolRow(const AToolName: String; const APath: TFilePath;
    const AWinePrefix, AVersionArg: String; AWhat: TInstallable;
    AFirstDashField: Boolean);
  var
    sPath, sVer: String;
  begin
    sPath := APath.Value;
    if sPath = '' then
    begin
      if g.IsLinux then
        AddRow(AToolName + sNF, InstallHintWithTip(AWhat))
      else
        AddRow(AToolName + sNF,
          'The bundled copy could not be extracted or would not run');
      Exit;
    end;
    sVer := ToolVersion(sPath, AWinePrefix, AVersionArg);
    // "ffprobe version 6.1.1-3ubuntu5 Copyright..." -> "ffprobe version 6.1.1"
    if AFirstDashField then sVer := ExtractDelimited(1, sVer, ['-']);
    AddRow(efn(sPath) + IfExists(sPath, ' [exists]', sNF), sVer);
  end;

  // The OpenSSL library filey's HTTPS downloads use, as loaded right now.
  function OpenSSLStatus: String;
  begin
    Result := '';
    try
      {$IFDEF WINDOWS}
      // Not loaded here just to show it: on Windows, InitSSLInterface
      // seeds its random generator from a full screenshot (see the note
      // in uManagedUtils' initialization section). It loads by itself on
      // the first download.
      if not IsSSLloaded then
        Exit('Not loaded yet (it loads on the first download)');
      {$ENDIF}
      // OpenSSL 1.1 and 3.x. Loads the library first if it isn't yet.
      Result := OpenSSLGetVersion(0);
      {$PUSH}{$WARN SYMBOL_DEPRECATED OFF}
      // OpenSSL 1.0.x (the libeay32/ssleay32 DLLs bundled for Windows) has
      // no OpenSSL_version function, only SSLeay_version.
      if (Result = '') and IsSSLloaded then Result := SSLeayversion(0);
      {$POP}
    except
      on E: Exception do
        LogError('BuildAboutReport: OpenSSL version check failed', E);
    end;
    if Result <> '' then Exit;
    if IsSSLloaded then Exit('Loaded (version not reported)');
    if g.IsLinux then
      Result := 'NOT LOADED - downloads will fail. ' +
        InstallHintWithTip(instOpenSSL)
    else
      Result := 'NOT LOADED - downloads will fail';
  end;

  function Plural(ACount: Integer; const AWord: String): String;
  begin
    Result := IntToStr(ACount) + ' ' + AWord;
    if ACount <> 1 then Result := Result + 's';
  end;

  // How many records ADbType's table has, e.g. '12345 records'. Unfiltered,
  // this is the same count the status bar shows, so its cache
  // (aCachedRecCount/aRecCountDirty, see GetDBStatus) is shared rather
  // than walking the table again. A filtered table says so, since then
  // that count is only the rows the filter lets through.
  function RecordCountText(ADbType: TDbType): String;
  var
    db: TDbf;
  begin
    db := FDbf[ADbType].aDB;
    try
      if db.Filtered then
        Exit(sb([Plural(db.ExactRecordCount, 'record'),
          ' shown (filtered), ', db.PhysicalRecordCount, ' in the file']));
      if FDbf[ADbType].aRecCountDirty then
      begin
        FDbf[ADbType].aCachedRecCount := db.ExactRecordCount;
        FDbf[ADbType].aRecCountDirty := False;
      end;
      Result := Plural(FDbf[ADbType].aCachedRecCount, 'record');
    except
      on E: Exception do
      begin
        LogError('BuildAboutReport: could not count ' + db.TableName, E);
        Result := 'record count unavailable';
      end;
    end;
  end;

  // One row per table. A file-backed table's row keeps its full file path
  // as the value (so right-click > Open still works) and puts the count in
  // the name; a memory table has no file, so its count is the value.
  procedure AddTableRow(ADbType: TDbType);
  var
    db: TDbf;
    sFile: String;
  begin
    db := FDbf[ADbType].aDB;
    if not Assigned(db) then Exit;
    sFile := CombinePath(db.FilePathFull, db.TableName);
    if not db.Active then
    begin
      AddRow(db.TableName + ' [NOT OPEN]',
        IfThen(db.Storage = stoMemory, '(in memory)', sFile));
      Exit;
    end;
    if db.Storage = stoMemory then
      AddRow(db.TableName, RecordCountText(ADbType) + ' (in memory)')
    else
      AddRow(sb([db.TableName, ' (', RecordCountText(ADbType), ')',
        IfThen(IsPhysicallyReadOnly(db), ' [READ-ONLY]', ''),
        IfThen(IsWorkingCopy(db), ' [WORKING COPY]', '')]), sFile);
  end;

  // What CreateWineLinuxLaunchers did this run, one row per launcher.
  procedure AddWineLauncherRows;
  var
    i: Integer;
    SL: TStringList;
  begin
    SL := FWineLauncherStatus.Value;
    if SL.Count = 0 then
    begin
      AddRow('Wine launchers', 'not tried yet this run');
      Exit;
    end;
    for i := 0 to SL.Count - 1 do
      AddRow(SL.Names[i], SL.ValueFromIndex[i]);
  end;

  // allshows.txt is only needed to fill an empty SHOWS.DBF (SHOWS.DBF
  // normally arrives ready-made), so its absence is usually fine - the row
  // says which case this is rather than a bare "[NOT FOUND]".
  procedure AddAllShowsRow;
  const
    ZAP_ACTION = '"Zap Shows and Episodes, rebuild from new allshows.txt"';
  var
    dbS: TDbf;
    sFile: String;
  begin
    sFile := CombinePath(g.OpPath, g.AllShowsTxt);
    if FileExists(sFile) then
    begin
      AddRow(g.AllShowsTxt + ' [exists]', sFile);
      Exit;
    end;
    dbS := FDbf[dbShows].aDB;
    if Assigned(dbS) and dbS.Active and not dbS.IsEmpty then
      AddRow(g.AllShowsTxt + ' [not needed]', sb(['SHOWS.DBF already has ',
        'the shows list. It is downloaded again only by ', ZAP_ACTION]))
    else if g.IsInternetConnected then
      AddRow(g.AllShowsTxt + sNF, sb(['SHOWS.DBF is empty. Restart filey, ',
        'or use ', ZAP_ACTION, ', to download it from epguides.com']))
    else
      AddRow(g.AllShowsTxt + sNF, 'SHOWS.DBF is empty and filey is ' +
        'offline. Connect to the internet, then restart filey to ' +
        'download it from epguides.com');
  end;

begin
  //if not Assigned(FDbf[dbAbout].aDB) then Exit;
  // aSavedRecNo is deliberately NOT touched here. ABOUT.DBF is fully
  // Zapped and re-Appended below, every single call, so the only saved
  // position worth anything afterward is the one tsInfoHide captured
  // BEFORE the user left this tab - before this rebuild ever started.
  // Grabbing a fresh one here would just re-read that same still-current
  // cursor position at best, and silently discard the real "where the
  // user was" value at worst. Restoring is left entirely to the caller
  // (SetupDbAbout), once this rebuild has fully finished.
  DBGridAbout.DataSource := FDbf[dbAbout].ADataSource;
  StatusBar.Visible := False;
  ZapPackTable(FDbf[dbAbout].aDB);
  FDbf[dbAbout].aRecCountDirty := True;
  if FileVerInfo.LoadLocalFileInfo then
  begin
    vStrings := FileVerInfo.Value.VersionStrings;
    s := sb([efn(Application.ExeName), ' (version: ',
      vStrings.Values['FileVersion'],
      {$IFDEF WPO}' [WPO build]',{$ENDIF}
      {$IFDEF DEBUG}' [DEBUG build]',{$ENDIF} ')']);
    AddRow('FileName:', s);
    AddRow('File description:', vStrings.Values['FileDescription']);
    AddRow('CompanyName:', vStrings.Values['CompanyName']);
  end;
  AddRow('IsInternetConnected', IfThen(g.IsInternetConnected));
  // One positive statement instead of IsLinux/IsWindows/IsWine rows, two
  // of which were always False. Under Wine it names Wine, the host system
  // and what Windows version Wine reports - the case where IsWindows and
  // IsWine were both True and easy to misread.
  AddRow('Platform', g.PlatformText);
  if g.IsLinux then
    AddRow('AppImage', IfThen(g.IsAppImage, g.AppImagePath, 'No'));
  if g.IsWine then
    AddWineLauncherRows;
  AddRow('ThemesEnabled', IfThen(ThemeServices.ThemesEnabled));
  AddRow('CnfgFilePath', g.CnfgFilePath);
  AddRow('IniFile', AppIni.Value.FileName);
  AddRow('OpPath', g.OpPath);
  AddRow('ProgramPath', g.ProgramPath);
  AddAllShowsRow;
  AddTableRow(dbShows);
  AddTableRow(dbEps);
  AddTableRow(dbLog);
  AddTableRow(dbList);
  AddTableRow(dbTempEps);
  // ffprobe's option parser wants the single-dash -version (see ToolRunsOK).
  AddToolRow('ffprobe', g.FilePathFFProbe, g.WineFFProbe, '-version',
    instFFprobe, True);
  AddToolRow('mkvmerge', g.FilePathMKVMerge, g.WineMKVMerge, '--version',
    instMKVToolNix, False);
  AddToolRow('mkvpropedit', g.FilePathMKVPropEdit, g.WineMKVPropEdit,
    '--version', instMKVToolNix, False);
  AddRow('OpenSSL', OpenSSLStatus);
  if g.IsWindows then
  begin
    AddRowIfExists(g.FilePathlibeay, LIBEAY_NAME);
    AddRowIfExists(g.FilePathssleay, SSLEAY_NAME);
  end;
  AddRow('PATH', GetEnvironmentVariable('PATH'));
  s := IntToStr(GetHeapStatus.TotalAllocated div 1024) + ' KB';
  AddRow('Total Allocated Memory', s);
  StatusBar.Visible := True;
end;

// The README_DOCS or README_EXTERNAL_DOCS name of the document ALink points
// at, or '' if it isn't one of them. ALink may be relative
// ("README2.html"), a file:// URL, or an address in Filey's GitLab
// repository (FILEY_REPO_URL) - where GitLab shows the Markdown original,
// so "README2.md" there means README2.html here. Any other site's
// README.html is that site's business, so is left alone. AAnchor gets the
// "#name" part, if any, without the "#".
function TForm1.BundledDocForLink(const ALink: String;
  out AAnchor: String): String;
var
  iPos: Integer;
  sDoc, sLink, sName: String;
begin
  Result := '';
  AAnchor := '';
  sLink := Trim(ALink);
  iPos := Pos('#', sLink);
  if iPos > 0 then
  begin
    AAnchor := Copy(sLink, iPos + 1, MaxInt);
    SetLength(sLink, iPos - 1);
  end;
  iPos := Pos('?', sLink);
  if iPos > 0 then SetLength(sLink, iPos - 1);
  // A bare "#name" is a place in the page on show: THtmlViewer's own job.
  if sLink = '' then Exit;
  // A scheme ("https:", "mailto:") - but not a drive letter ("C:").
  iPos := Pos(':', sLink);
  if (iPos > 2) and not sLink.StartsWith('file:', True) and
    not sLink.StartsWith(FILEY_REPO_URL, True) then Exit;
  // The last path segment. '/' and '\' are single bytes that never occur
  // inside a UTF-8 multi-byte sequence, so a byte search is Unicode-safe.
  sName := Copy(sLink, LastDelimiter('/\', sLink) + 1, MaxInt);
  if UTF8CompareText(ExtractFileExt(sName), '.md') = 0 then
    sName := ChangeFileExt(sName, '.html');
  for sDoc in README_DOCS do
    if UTF8CompareText(sDoc, sName) = 0 then Exit(sDoc);
  for sDoc in README_EXTERNAL_DOCS do
    if UTF8CompareText(sDoc, sName) = 0 then Exit(sDoc);
end;

procedure TForm1.CheckLogCheckBoxes;
begin
  if not IsDbOpen(dbLog) then Exit; // see SetBitBtnUndoEnabled

  // One-liner for simple background checks}
  //BitBtnUndo.Enabled := QuickLocateInBackground(FDbf[dbLog].aDB, 'UNDO', True);
  BitBtnUndo.Enabled :=
    LocateRecordInBackground(FDbf[dbLog].aDB, 'UNDO', True, []);
end;

procedure TForm1.CheckResourceFiles;
//reminder: filename casing matters for Linux
const
  // Replaced whenever the copy on disk isn't this build's (an older
  // build's, or damaged) - see ExtractFromSourceZip.
  ResourceFiles: array[0..4] of String =
    ('license.txt', 'README.html', 'README2.html', 'Privacy_Policy.html',
    'filey64.png');
  // Extracted only when missing, never replaced: Filey writes to these
  // after extracting them. SHOWS.DBF is the user's shows database
  // (allshows.txt imports, shows added and deleted), while the copy in the
  // zip is a fresh seed that actZipSourcesExecute rebuilds (through
  // ZapAndRebuildShows) for every build - so it would never match a user's
  // working copy, and replacing that would throw the user's data away with
  // every new build.
  SeedFiles: array[0..0] of String = ('SHOWS.DBF');
var
  FileName: String;
  PrevPage: TTabSheet;
begin
  DebugLog('Enter CheckResourceFiles');
  PrevPage := pcMain.ActivePage;
  FExtractedCount := 0;
  // While this is True, every file actually extracted - filey-src.zip
  // itself, the DLLs, any bundled tool ValidateAndDiscoverTools pulls out
  // via DiscoverExternalTool, and the ResourceFiles/SeedFiles below - is
  // shown on the Progress page by ShowExtractProgress. Each one is
  // extracted when missing and, SeedFiles aside, replaced when the copy on
  // disk isn't this build's - so the first launch of a new build brings
  // every one of them up to date.
  FIsCheckingResources := True;
  try
    // First, as everything else is extracted from it: a filey-src.zip left
    // by an older build would hand out that build's files.
    ExtractZipResourceIfStale(g.SourceZipFileName);
    // libeay32.dll and ssleay32.dll are needed for Windows
    if g.IsWindows then
    begin
      g.FilePathlibeay := CombinePath(g.OpPath.Value, uUtils.LIBEAY_NAME);
      ExtractFromSourceZip(uUtils.LIBEAY_NAME);
      g.FilePathssleay := CombinePath(g.OpPath.Value, uUtils.SSLEAY_NAME);
      ExtractFromSourceZip(uUtils.SSLEAY_NAME);
      ConfigureOpenSSLLibPaths;
    end;
    DebugLog('CheckResourceFiles: before ValidateAndDiscoverTools');
    // Each tool's version check (through Wine, for the bundled Windows
    // builds on Linux) can take seconds and pumps no messages, so say what
    // is happening before it starts.
    StatusBar.Panels[0].Text :=
      'Checking ffprobe, mkvmerge and mkvpropedit...';
    if pcMain.ActivePage = tsProgress then
    begin
      ProgressBar.Position := 0;
      ProgressLabel.Caption := StatusBar.Panels[0].Text;
    end;
    Application.ProcessMessages;
    ValidateAndDiscoverTools;
    for FileName in ResourceFiles do
    begin
      if FIsShuttingDown then Break;
      if not ExtractFromSourceZip(FileName) then
        DebugLog('CheckResourceFiles: failed to extract ' + FileName);
    end;
    for FileName in SeedFiles do
    begin
      if FIsShuttingDown then Break;
      if not ExtractFromSourceZip(FileName, True) then
        DebugLog('CheckResourceFiles: failed to extract ' + FileName);
    end;
  finally
    FIsCheckingResources := False;
  end;
  if FExtractedCount > 0 then
    DebugLog(sb(['CheckResourceFiles: extracted ', FExtractedCount,
      ' file(s) to ', g.OpPath.Value]));
  // Same as actZipSourcesExecute: back to where the user was.
  if (pcMain.ActivePage = tsProgress) and (PrevPage <> tsProgress) then
    pcMain.ActivePage := PrevPage;
  DebugLog('Exit CheckResourceFiles');
end;

procedure TForm1.CleanupSourceRAII;
begin
  FSourceManager.Clear;
end;

procedure TForm1.CloseGrid(var aGrid: TDBGrid);
begin
  aGrid.DataSource := nil;
  SafeClearGridColumns(aGrid);
  FreeAndNil(aGrid);
end;

function TForm1.ComposeNewName(AFromFileName: Boolean): String;
const
  // LIST fields, in the order they appear in the new name.
  NAME_FIELDS: array[0..6] of String = ('TITLE', 'EPNUM', 'EPNAME',
    'HEIGHT', 'CODEC', 'AUDIOCHAN', 'SUBTITLES');
var
  db: TDbf;
  i: Integer;
  SB: TStringBuilder;
  sJoined, sPart, sSep: String;

  // A title or episode name parsed from a scene-style file name has its
  // words joined by dots ("Valles.Marineris", "Part.1"). For the spaces
  // style those dots become spaces - but not a dot between two digits
  // ("5.1"), and not in what looks like an abbreviation, where every piece
  // is a single character ("S.W.A.T."), nor in a name that already has
  // spaces. '.' is ASCII, so byte-wise is UTF-8 safe.
  function DotsToSpaces(const AText: String): String;
  var
    bLongPiece: Boolean;
    j, iPieceLen: Integer;
  begin
    Result := AText;
    if (Pos(' ', AText) > 0) or (Pos('.', AText) = 0) then Exit;
    bLongPiece := False;
    iPieceLen := 0;
    for j := 1 to Length(AText) do
      if AText[j] = '.' then iPieceLen := 0
      else
      begin
        Inc(iPieceLen);
        if iPieceLen >= 2 then bLongPiece := True;
      end;
    if not bLongPiece then Exit;
    for j := 1 to Length(Result) do
      if (Result[j] = '.') and not ((j > 1) and (j < Length(Result)) and
        (Result[j - 1] in ['0'..'9']) and (Result[j + 1] in ['0'..'9'])) then
        Result[j] := ' ';
  end;

  // Runs of ASep (' ' or '.') collapsed to one, and trimmed off both ends.
  function Tidy(const AText: String; ASep: Char): String;
  begin
    Result := AText;
    while Pos(ASep + ASep, Result) > 0 do
      Result := StringReplace(Result, ASep + ASep, ASep, [rfReplaceAll]);
    Result := TrimSet(Result, [ASep, ' ']);
  end;

begin
  db := FDbf[dbList].aDB;
  if g.WordSeparator = wsDot then sSep := '.'
  else
    sSep := ' ';
  SB := TStringBuilder.Create;
  try
    for i := 0 to High(NAME_FIELDS) do
    begin
      sPart := Trim(db.FieldByName(NAME_FIELDS[i]).AsString);
      if sPart = '' then Continue;
      if NAME_FIELDS[i] = 'HEIGHT' then sPart := sPart + 'p';
      sPart := ApplyReservedCharStyle(sPart);
      // With underscores, any '/' or '\' is still here, and FixWinFileName
      // would take everything before it for a folder ("Face/Off" ->
      // "Off"); so they become '_' now, as the other characters will.
      sPart := StringReplace(sPart, '/', '_', [rfReplaceAll]);
      sPart := StringReplace(sPart, '\', '_', [rfReplaceAll]);
      if g.WordSeparator = wsDot then
        sPart := Tidy(StringReplace(sPart, ' ', '.', [rfReplaceAll]), '.')
      else
      begin
        if AFromFileName and ((NAME_FIELDS[i] = 'TITLE') or
          (NAME_FIELDS[i] = 'EPNAME')) then sPart := DotsToSpaces(sPart);
        sPart := Tidy(sPart, ' ');
      end;
      if sPart = '' then Continue;
      if SB.Length > 0 then SB.Append(sSep);
      SB.Append(sPart);
    end;
    sJoined := SB.ToString;
  finally
    SB.Free;
  end;
  // EXTENSION already starts with its dot (".mkv").
  Result := FixWinFileName(sJoined + Trim(db.FieldByName('EXTENSION').AsString));
end;

// Binds the per-table event handlers that uDBFManager.CreateAndOpenDBFs has
// no business knowing about by name. "of object" because DBEpsStateChange/
// DBShowsStateChange are real instance methods.
procedure TForm1.ConfigureDBFDataSource(aDbType: TDbType;
  ADataSource: TDataSource);
begin
  case aDbType of
    dbEps: ADataSource.OnStateChange := @DBEpsStateChange;
    dbShows: ADataSource.OnStateChange := @DBShowsStateChange;
    else
      NoOp;
  end;
end;

procedure TForm1.ConfigureOpenSSLLibPaths;
// Pre-loads the DLL files Filey extracted into g.OpPath by their full,
// absolute path, before FPC's openssl unit ever tries to load OpenSSL
// itself. InitSSLInterface (called lazily, elsewhere, the first time SSL
// is actually needed) ultimately loads libeay32.dll/ssleay32.dll via a
// bare-filename LoadLibrary call. On native Windows the default search
// order (app directory, then system directories, then PATH) reliably
// finds the extracted DLLs that way. Under Wine, that same bare-name
// search can instead resolve to a Wine-builtin placeholder DLL of the
// same name before it ever considers g.OpPath, causing InitSSLInterface
// to fail with "Could not initialize OpenSSL library" even though a
// working copy exists on disk right next to the .exe.

// The fix doesn't touch any of openssl.pas's internal DLL-name variables
// or arrays directly, since their exact names, types, and array bounds
// have changed across FPC versions (see FPC bug #37137) and hard-coding
// today's shape would just as easily break on a different FPC release.
// Instead this relies on ordinary Windows/Wine loader behaviour: once a
// DLL has been loaded into the process by its absolute path, the loader
// registers it under its own base file name (e.g. "libeay32.dll") in the
// process's module table. Any later bare-name LoadLibrary('libeay32.dll')
// call - including the one buried inside InitSSLInterface - resolves to
// that already-loaded module instead of repeating a fresh on-disk/registry
// search, and simply increments its reference count. So as long as this
// runs before InitSSLInterface's own first call, it transparently wins
// the race without needing to know anything about openssl.pas's current
// internals.

// Order matters here: libeay32 (the crypto/util library) must be loaded
// before ssleay32 (the SSL library), since ssleay32.dll depends on
// symbols from libeay32.dll.
var
  aHandle: TLibHandle;
  LLastError: DWord;
begin
  DebugLog('Enter ConfigureOpenSSLLibPaths');
  if not g.IsWindows then
  begin
    DebugLog('ConfigureOpenSSLLibPaths: not Windows, exiting');
    Exit;
  end;
  DebugLog('ConfigureOpenSSLLibPaths: g.FilePathlibeay=' +
    g.FilePathlibeay.Value + ' exists=' +
    IfThen(FileExists(g.FilePathlibeay.Value)));
  if FileExists(g.FilePathlibeay.Value) then
  begin
    aHandle := DynLibs.LoadLibrary(g.FilePathlibeay.Value);
    if aHandle = DynLibs.NilHandle then
    begin
      // Capture immediately - nothing else runs between the failed
      // LoadLibrary and this read that could reset the process-wide
      // last-error value.
      LLastError := GetLastOSError;
      LogError('Could not pre-load ' + g.FilePathlibeay.Value);
      DebugLog('ConfigureOpenSSLLibPaths: LoadLibrary(libeay) failed. ' +
        'Reason: ' + SysErrorMessage(LLastError) + ' (Code ' +
        IntToStr(LLastError) + ')');
    end
    else
      DebugLog('ConfigureOpenSSLLibPaths: libeay32.dll loaded OK, handle=' +
        IntToStr(PtrUInt(aHandle)));
  end;
  DebugLog('ConfigureOpenSSLLibPaths: g.FilePathssleay=' +
    g.FilePathssleay.Value + ' exists=' +
    IfThen(FileExists(g.FilePathssleay.Value)));
  if FileExists(g.FilePathssleay.Value) then
  begin
    aHandle := DynLibs.LoadLibrary(g.FilePathssleay.Value);
    if aHandle = DynLibs.NilHandle then
    begin
      LLastError := GetLastOSError;
      LogError('Could not pre-load ' + g.FilePathssleay.Value);
      DebugLog('ConfigureOpenSSLLibPaths: LoadLibrary(ssleay) failed. ' +
        'Reason: ' + SysErrorMessage(LLastError) + ' (Code ' +
        ns(LLastError) + ')');
    end
    else
      DebugLog('ConfigureOpenSSLLibPaths: ssleay32.dll loaded OK, handle=' +
        IntToStr(PtrUInt(aHandle)));
  end;
  DebugLog('Exit ConfigureOpenSSLLibPaths');
end;

procedure TForm1.ConfirmThenZapPackTable(var aDB: TDbf);
var
  aDBGuard, dbShowsGuard: TDataLayoutGuard;
begin
  if (aDB.PhysicalRecordCount <= 0) then Exit; //nothing to Zap
  // Say so up front, instead of asking "are you CERTAIN?" and then failing.
  if IsPhysicallyReadOnly(aDB) then
  begin
    MessageDlgEx(sb(['Cannot Zap ', aDB.TableName, ': it is read-only ',
      'because ', DbfReadOnlyReason(aDB), '.']), mtInformation, [mbOK]);
    Exit;
  end;
  if MessageDlgEx(sb([
    'Are you CERTAIN that you want to Zap (completely delete) and refresh the ',
    aDB.TableName, ' database?']), mtConfirmation, [mbCancel, mbYes]) = mrYes then
  begin
    SetAllCursors(crHourGlass);
    aDBGuard := TDataLayoutGuard.Create(aDB);
    dbShowsGuard := TDataLayoutGuard.Create(FDbf[dbShows].aDB,
      DBGridShows, nil);
    aDB.Filtered := False;
    if aDB.Name = 'EPS' then
    begin
      // Zapping EPS.DBF should let the user re-lookup Episodes for EVERY
      // show today, not just ones EPS already had entries for - so blank
      // LookUpDate across the whole SHOWS.DBF, unconditionally. dbShowsGuard
      // above already has SHOWS' controls disabled, so no separate guard
      // or DisableControls call is needed here.
      with FDbf[dbShows].aDB do
      begin
        First;
        while not EOF do
        begin
          if FieldByName('LOOKUPDATE').AsString <> '' then
          begin
            Edit;
            // Clear is faster/safer than AsString:='' - see SwapFromTo.
            FieldByName('LOOKUPDATE').Clear;
            PostRecord(FDbf[dbShows].aDB);
          end;
          Next;
        end;
      end;
    end;
    // Zap is destructive/irreversible, so its two status lines go to
    // DebugLog (a plain, stateless procedure - see uDBFManager's banner
    // comment for why TDBFStatusEvent isn't "of object") rather than the
    // status bar, which the very next UI update would just overwrite.
    ZapPackTable(aDB, @DebugLog);
    DBFRecordCountChanged(aDB); // covers both dbEps and dbLog callers
    // FDbf[dbShows].aFilterText := '';}{FDbf[dbShows].aFilterDescription := '';
    FDbf[dbEps].aFilterText := '';
    FDbf[dbEps].aFilterDescription := '';
  end;
  SetAllCursors(crDefault);
end;

procedure TForm1.CreateDesktopShortcut;
begin
  {$IFDEF WINDOWS}
  // Wine first, and by itself: whether IsWindows is also True under Wine
  // is a matter of how uOSDetector reports it, and the launchers that
  // matter there are Linux ones either way.
  if g.IsWine then CreateWineLinuxLaunchers
  else if g.IsWindows then CreateWindowsShortcut;
  {$ENDIF}
  {$IFDEF UNIX}
  if g.IsLinux then CreateLinuxShortcut;
  {$ENDIF}
end;

// AArg written as one argument of a .desktop file's Exec= key, following
// the Desktop Entry Specification: quoted if it contains a reserved
// character (a space, most often), with ", `, $ and \ backslash-escaped
// inside the quotes. The key's value is then a string in its own right,
// where \ is itself escaped, and a literal % must be written %%.
function DesktopExecQuote(const AArg: String): String;
const
  RESERVED = [' ', #9, #10, '"', '''', '\', '>', '<', '~', '|', '&', ';',
    '$', '*', '?', '#', '(', ')', '`'];
var
  c: Char;
  bQuote: Boolean = False;
begin
  // Byte-wise is safe for UTF-8: every reserved character is ASCII, and no
  // byte of a multi-byte character is below $80.
  for c in AArg do
    if c in RESERVED then
    begin
      bQuote := True;
      Break;
    end;
  if bQuote then
  begin
    Result := '"';
    for c in AArg do
    begin
      if c in ['"', '`', '$', '\'] then Result := Result + '\';
      Result := Result + c;
    end;
    Result := Result + '"';
  end
  else
    Result := AArg;
  Result := StringReplace(Result, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '%', '%%', [rfReplaceAll]);
end;
// DesktopExecQuote (above) is outside the UNIX block: under Wine,
// CreateWineLinuxLaunchers writes Linux launchers with it too.

{$IFDEF UNIX}
// The program an Exec= value runs: the reverse of DesktopExecQuote, for its
// first argument only.
function DesktopExecProgram(const AValue: String): String;
var
  i: Integer;
  s: String;
begin
  Result := '';
  s := StringReplace(Trim(AValue), '\\', '\', [rfReplaceAll]);
  if s = '' then Exit;
  if s[1] = '"' then
  begin
    i := 2;
    while i <= Length(s) do
    begin
      if s[i] = '\' then
      begin
        Inc(i);
        if i <= Length(s) then Result := Result + s[i];
      end
      else if s[i] = '"' then Break
      else
        Result := Result + s[i];
      Inc(i);
    end;
  end
  else
  begin
    i := Pos(' ', s);
    if i > 0 then Result := Copy(s, 1, i - 1)
    else
      Result := s;
  end;
  Result := StringReplace(Result, '%%', '%', [rfReplaceAll]);
end;

// True if the launcher AFileName exists and still starts a program that is
// there. A launcher written by an AppImage run before this fix points into
// /tmp/.mount_xxxx, which is gone once filey exits; one pointing at an
// AppImage that was since moved or deleted is just as dead.
function DesktopLauncherWorks(const AFileName: String): Boolean;
var
  i: Integer;
  sLine, sProgram: String;
  SL: TSmartStrings;
begin
  Result := False;
  if not FileExists(AFileName) then Exit;
  try
    SL.Value.LoadFromFile(AFileName);
  except
    on E: Exception do
    begin
      LogError('DesktopLauncherWorks: could not read ' + AFileName, E);
      Exit;
    end;
  end;
  for i := 0 to SL.Value.Count - 1 do
  begin
    sLine := Trim(SL.Value[i]);
    if Pos('Exec=', sLine) <> 1 then Continue;
    sProgram := DesktopExecProgram(Copy(sLine, 6, MaxInt));
    if sProgram = '' then Exit(False);
    // A bare name ("filey") is looked up on PATH, as the desktop would.
    if Pos('/', sProgram) = 0 then
      Exit(FindDefaultExecutablePath(sProgram) <> '');
    Exit(FileExists(sProgram));
  end;
end;

// The user's desktop folder. Not always ~/Desktop: it follows the
// language the account was set up in (~/Schreibtisch, ~/Bureau, ...), and
// xdg-user-dir knows which. It answers $HOME when no desktop folder is
// configured at all.
function LinuxDesktopDir: String;
var
  iExit: Integer;
  sHome: String;
  SL: TSmartStrings;
begin
  sHome := ExcludeTrailingPathDelimiter(GetEnvironmentVariable('HOME'));
  Result := '';
  if FindDefaultExecutablePath('xdg-user-dir') <> '' then
  begin
    SL.Value.Text := Trim(RunEx('xdg-user-dir', ['DESKTOP'], iExit));
    if (iExit = 0) and (SL.Value.Count > 0) then
      Result := ExcludeTrailingPathDelimiter(Trim(SL.Value[0]));
  end;
  if (Result = '') or (Result = sHome) then
    Result := CombinePath(sHome, 'Desktop');
end;

// Where per-user application-menu entries go: $XDG_DATA_HOME/applications,
// which is ~/.local/share/applications unless XDG_DATA_HOME says otherwise.
// Every desktop (KDE, GNOME, XFCE, Cinnamon, MATE, LXQt...) reads it and
// watches it, so a new entry shows up in the menu without logging out.
function LinuxMenuEntryDir: String;
var
  sData: String;
begin
  sData := Trim(GetEnvironmentVariable('XDG_DATA_HOME'));
  // The spec says a relative XDG_DATA_HOME is invalid and must be ignored.
  if (sData = '') or (sData[1] <> '/') then
    sData := CombinePath(CombinePath(GetEnvironmentVariable('HOME'),
      '.local'), 'share');
  Result := CombinePath(sData, 'applications');
end;

// Creates (or repairs) filey's Linux launchers: the desktop icon
// (g.IsCreateDesktopShortcut) and the application-menu entry
// (g.IsCreateMenuEntry). Both are the same Desktop Entry file, written to
// two places under the same name, filey.desktop - the menu entry's file
// name is its desktop file ID, which is how the desktop matches it to the
// running window and remembers it in favourites.
procedure TForm1.CreateLinuxShortcut; //lowercase "f" filey shortcut in Linux
var
  IconName, sExe, SourceIcon: String;

  // The Desktop Entry for sExe, as lines.
  procedure BuildEntry(st: TStrings);
  var
    sExeEsc: String;
  begin
    // Key values escape '\' as '\\' (Desktop Entry spec, "Possible value
    // types"); Exec= has its own, stricter quoting (DesktopExecQuote).
    sExeEsc := StringReplace(sExe, '\', '\\', [rfReplaceAll]);
    st.Add('[Desktop Entry]');
    // Version= is the Desktop Entry Specification version this file
    // follows, not filey's version (it used to be given filey's
    // FileVersion).
    st.Add('Version=1.0');
    st.Add('Type=Application');
    st.Add(sb(['Name=', efn(Application.ExeName)]));
    st.Add('GenericName=filey - Rename TV show files consistently');
    st.Add('Comment=Rename TV show files consistently');
    st.Add(sb(['Icon=', StringReplace(IconName, '\', '\\', [rfReplaceAll])]));
    st.Add(sb(['Path=', StringReplace(ExcludeTrailingPathDelimiter(
      ExtractFilePath(sExe)), '\', '\\', [rfReplaceAll])]));
    // TryExec: if the program is deleted, menus hide the entry instead of
    // offering one that does nothing. (filey also rewrites a dead entry
    // the next time it runs from somewhere else - see DesktopLauncherWorks.)
    st.Add('TryExec=' + sExeEsc);
    st.Add(sb(['Exec=', DesktopExecQuote(sExe)]));
    st.Add('Terminal=false');
    // One main category only: with two (it used to say Utility;AudioVideo;)
    // menus list the entry twice. FileTools is the additional category for
    // file managers and renamers; Video in Keywords still finds it.
    st.Add('Categories=Utility;FileTools;');
    st.Add('Keywords=rename;TV;episode;series;video;mkv;');
  end;

  // Writes the entry to ATarget unless a working one is already there.
  // True if it was written.
  function WriteEntry(const ATarget, AWhat: String): Boolean;
  var
    st: TSmartStrings;
  begin
    Result := False;
    // A launcher that works is left alone - the user may have edited it.
    // One whose program is gone is replaced.
    if DesktopLauncherWorks(ATarget) then Exit;
    if FileExists(ATarget) then
      DebugLog(sb(['CreateLinuxShortcut: replacing ', AWhat,
        ' with a missing program: ', ATarget]));
    BuildEntry(st.Value);
    try
      st.Value.SaveToFile(ATarget);
    except
      on E: Exception do
      begin
        LogError(sb(['CreateLinuxShortcut: could not write ', AWhat, ' ',
          ATarget]), E);
        Exit;
      end;
    end;
    DebugLog(sb(['CreateLinuxShortcut: wrote ', AWhat, ' ', ATarget, ' -> ',
      sExe]));
    Result := True;
  end;

  procedure MakeDesktopLauncher;
  var
    DesktopDir, TargetName: String;
    iExit: Integer;
  begin
    DesktopDir := LinuxDesktopDir;
    if not DirectoryExists(DesktopDir) then
    begin
      // Not created: a desktop folder that doesn't exist isn't shown as a
      // desktop anyway (some desktop environments have none).
      DebugLog('CreateLinuxShortcut: no desktop folder at ' + DesktopDir);
      Exit;
    end;
    TargetName := CombinePath(DesktopDir,
      efnOnly(Application.ExeName) + '.desktop');
    if not WriteEntry(TargetName, 'desktop launcher') then Exit;
    // Desktop icons, unlike menu entries, must be executable and (on GNOME
    // and others using gio) marked trusted before they will launch.
    // TargetName is passed as its own argument, so spaces in $HOME are
    // safe.
    if FindExecutableFile('gio') <> '' then
      RunEx('gio', ['set', TargetName, 'metadata::trusted', 'true'], iExit);
    RunEx('chmod', ['a+x', TargetName], iExit);
  end;

  procedure MakeMenuEntry;
  var
    MenuDir: String;
  begin
    MenuDir := LinuxMenuEntryDir;
    if not ForceDirectories(MenuDir) then
    begin
      LogError('CreateLinuxShortcut: could not create ' + MenuDir);
      Exit;
    end;
    // Menus need neither the executable bit nor gio's "trusted" mark, and
    // every desktop notices a new file here by itself.
    WriteEntry(CombinePath(MenuDir, efnOnly(Application.ExeName) +
      '.desktop'), 'menu entry');
  end;

begin
  if not g.IsLinux then Exit;
  if not (g.IsCreateDesktopShortcut or g.IsCreateMenuEntry) then Exit;

  // From an AppImage, Application.ExeName is inside the temporary
  // /tmp/.mount_xxxx folder, which disappears when filey exits; the
  // launchers must start the .AppImage file itself.
  if g.IsAppImage then sExe := g.AppImagePath
  else
    sExe := Application.ExeName;

  IconName := CombinePath(CombinePath(
    CombinePath(CombinePath(GetEnv('HOME'), '.local'), 'share'), 'icons'),
    'filey64.png');
  ExtractFromSourceZip('filey64.png');
  SourceIcon := CombinePath(g.OpPath, 'filey64.png');
  if (not FileExists(IconName)) and FileExists(SourceIcon) then
    CopyFileForceDir(SourceIcon, IconName);

  if g.IsCreateDesktopShortcut then MakeDesktopLauncher;
  if g.IsCreateMenuEntry then MakeMenuEntry;
end;
{$ENDIF}

{$IFDEF WINDOWS}//Uppercase "F" Filey for Windows/Wine shortcuts
procedure TForm1.CreateWindowsShortcut;
const
  // Referenced by literal value rather than the ActiveX unit's named
  // constant, since the exact identifier (RPC_E_CHANGEDMODE vs.
  // RPC_E_CHANGED_MODE) varies across FPC RTL versions - the HRESULT
  // value itself is stable and documented by Microsoft.
  LOCAL_RPC_E_CHANGED_MODE = HResult($80010106);
var
  AppDataPath: array[0..MaxPathLen] of char = #0; //Allocate memory
  CommonDesktopPath: array[0..MaxPathLen] of char = #0; //Allocate memory
  COMInitialized: Boolean = False;
  HR: HResult;
  IObject: IUnknown = nil;
  IPFile: IPersistFile = nil;
  ISLink: IShellLink = nil;
  TargetName: String;
  //WideString used here to meet COM API's UTF-16 requirement (IPersistFile.Save)
  LinkName, PublicLinkName: WideString;
begin
  // Real Windows only: CreateDesktopShortcut sends Wine to
  // CreateWineLinuxLaunchers instead.
  if g.IsWine or not g.IsCreateDesktopShortcut then Exit;
  TargetName := Application.ExeName;

  // CreateComObject requires this thread's COM apartment to already be
  // initialized. Real Windows often masks a missing CoInitialize call,
  // because some other part of the process (LCL widgetset setup, a common
  // dialog, etc.) has frequently already initialized COM as a side effect
  // - but that's not guaranteed, and Wine's ole32 implementation is far
  // less forgiving about it: CreateComObject on an uninitialized apartment
  // can hand back a null/invalid interface instead of cleanly raising
  // EOleSysError, and the "as IShellLink" cast immediately below then
  // dereferences that pointer, which is an AV. Always initialize
  // explicitly rather than relying on incidental prior initialization.
  HR := CoInitializeEx(nil, COINIT_APARTMENTTHREADED or
    COINIT_DISABLE_OLE1DDE);
  // RPC_E_CHANGED_MODE means COM is already initialized on this thread in
  // a different concurrency model - still safely usable, so don't treat
  // it as failure and don't pair it with a CoUninitialize we don't own.
  COMInitialized := (HR = S_OK) or (HR = S_FALSE);
  if not (COMInitialized or (HR = LOCAL_RPC_E_CHANGED_MODE)) then
  begin
    LogError(sb(['CreateWindowsShortcut: CoInitializeEx failed (HRESULT=0x',
      IntToHex(HR, 8), '), skipping desktop shortcut creation']));
    Exit;
  end;

  try
    IObject := CreateComObject(CLSID_ShellLink);
    if not Assigned(IObject) then
    begin
      LogError('CreateWindowsShortcut: CreateComObject returned nil, ' +
        'skipping desktop shortcut creation');
      Exit;
    end;
    ISLink := IObject as IShellLink;
    IPFile := IObject as IPersistFile;
    ISLink.SetPath(PChar(TargetName));
    ISLink.SetWorkingDirectory(PChar(ExtractFilePath(TargetName)));
    //to store the path
    AppDataPath := '';
    SHGetSpecialFolderPath(0, AppDataPath, CSIDL_DESKTOP, False);
    CommonDesktopPath := '';
    SHGetSpecialFolderPath(0, CommonDesktopPath,
      CSIDL_COMMON_DESKTOPDIRECTORY, False);
    LinkName := UTF8ToUTF16(CombinePath(AppDataPath,
      Application.Title + '.lnk'));
    PublicLinkName := UTF8ToUTF16(CombinePath(CommonDesktopPath,
      Application.Title + '.lnk'));
    // Created unless the user's or the all-users desktop already has one.
    if (not FileExists(UTF8Encode(LinkName))) and
      (not FileExists(UTF8Encode(PublicLinkName))) then
      IPFile.Save(PWChar(LinkName), False);
  finally
    // Release the interfaces before uninitializing COM - if the apartment
    // is torn down first, these interface variables would try to call
    // through to a Release() on a dead apartment when they go out of
    // scope.
    IPFile := nil;
    ISLink := nil;
    IObject := nil;
    if COMInitialized then CoUninitialize;
  end;
end;

// Under Wine, filey.exe is only useful to the user if the Linux desktop can
// start it, so this writes the Linux launchers itself - a desktop icon
// (g.IsCreateDesktopShortcut) and an application-menu entry
// (g.IsCreateMenuEntry) - instead of saving a .lnk and leaving it to
// winemenubuilder, as this used to.

// Why not the .lnk any more:
// - Wine looks file names up case-insensitively, so the old "is
//   Filey.desktop already on the desktop?" test also matched the native
//   Linux build's own filey.desktop, and then no .lnk was ever saved.
// - winemenubuilder's launcher starts the .lnk itself (through start.exe),
//   so deleting the .lnk as "redundant" afterwards broke that launcher.

// The file is named Filey-Wine.desktop, which no other name it might meet
// matches even ignoring case - a file written from inside Wine as
// "Filey.desktop" would have overwritten the native build's filey.desktop.
// It is rewritten only when its contents would change (filey.exe moved,
// another Wine prefix), so a launcher that is up to date is left alone.
procedure TForm1.CreateWineLinuxLaunchers;
type
  // Wine's own exports from kernel32.dll: both return strings allocated on
  // the process heap, which the caller frees with HeapFree. Unix paths are
  // UTF-8.
  TWineGetUnixFileName = function(ADosName: PWideChar): PAnsiChar; cdecl;
  TWineGetDosFileName = function(AUnixName: PAnsiChar): PWideChar; cdecl;
const
  LAUNCHER_FILE_NAME = 'Filey-Wine.desktop';
  // The About > Info row names for FWineLauncherStatus.
  WHAT_ALL = 'Wine launchers';
  WHAT_DESKTOP = 'Wine desktop launcher';
  WHAT_MENU = 'Wine menu entry';
var
  hKernel: HMODULE;
  sDataHome, sDesktopDir, sExeUnix, sHome, sIconUnix, sMenuDir,
  sMenuDirDos, sPrefix, sWhyNot: String;
  WineToUnix: TWineGetUnixFileName;
  UnixToWine: TWineGetDosFileName;
  Wanted: TSmartStrings;

  // The Unix path Wine maps ADosName to, or ''.
  function ToUnix(const ADosName: String): String;
  var
    p: PAnsiChar;
    r: RawByteString;
    ws: UnicodeString;
  begin
    Result := '';
    ws := UTF8Decode(ADosName);
    p := WineToUnix(PWideChar(ws));
    if p = nil then Exit;
    try
      SetLength(r, StrLen(p));
      if Length(r) > 0 then Move(p^, r[1], Length(r));
      SetCodePage(r, CP_UTF8, False);
      Result := r;
    finally
      HeapFree(GetProcessHeap, 0, p);
    end;
  end;

  // The Windows path (e.g. Z:\home\...) for the Unix path AUnixName, or ''.
  function ToDos(const AUnixName: String): String;
  var
    p: PWideChar;
    u: UTF8String;
  begin
    Result := '';
    if AUnixName = '' then Exit;
    u := AUnixName;
    p := UnixToWine(PAnsiChar(u));
    if p = nil then Exit;
    try
      Result := UTF8Encode(UnicodeString(p));
    finally
      HeapFree(GetProcessHeap, 0, p);
    end;
  end;

  function UnixTrimSlash(const APath: String): String;
  begin
    Result := APath;
    while (Length(Result) > 1) and (Result[Length(Result)] = '/') do
      SetLength(Result, Length(Result) - 1);
  end;

  // CombinePath can't join these: this is the Windows build, so it would
  // use '\' - and ExtractFileDir would also split at the ':' in a Wine
  // "dosdevices/c:" path. Unix paths here are joined and split on '/'
  // only; '/' is ASCII, so byte-wise is UTF-8 safe.
  function UnixPathJoin(const ADir, AName: String): String;
  begin
    Result := UnixTrimSlash(ADir);
    if (Result = '') or (Result[Length(Result)] <> '/') then
      Result := Result + '/';
    Result := Result + AName;
  end;

  function UnixParentDir(const APath: String): String;
  var
    i: Integer;
  begin
    Result := UnixTrimSlash(APath);
    i := LastDelimiter('/', Result);
    if i <= 1 then Exit('/');
    Result := Copy(Result, 1, i - 1);
  end;

  // wine_get_unix_file_name answers through the prefix's drive links:
  // "/home/mark/.wine/dosdevices/z:/home/mark" for Z:\home\mark. That works,
  // but is no path to show anyone or to write into a launcher. When the
  // drive's real folder can be confirmed - "/" for the usual Z:, and
  // "<prefix>/drive_c" for C: - the link is replaced by it. Wine confirms
  // it: it maps a folder to a drive letter by comparing the folders
  // themselves, so the drive's real root comes back as exactly "X:\".
  function TidyUnixPath(const APath: String): String;
  var
    i, j: Integer;
    sDrive, sPrefixHere, sRest: String;
  begin
    Result := APath;
    i := Pos('/dosdevices/', APath);
    if i <= 1 then Exit;
    j := i + Length('/dosdevices/'); // the drive letter
    if (Length(APath) < j + 1) or (APath[j + 1] <> ':') then Exit;
    sDrive := UpCase(APath[j]) + ':\';
    sRest := Copy(APath, j + 2, MaxInt); // '' or '/...'
    if SameText(ToDos('/'), sDrive) then
    begin
      if sRest = '' then Exit('/');
      Exit(sRest);
    end;
    sPrefixHere := Copy(APath, 1, i - 1);
    if SameText(ToDos(UnixPathJoin(sPrefixHere, 'drive_c')), sDrive) then
      Exit(UnixPathJoin(sPrefixHere, 'drive_c') + sRest);
  end;

  // Creates the Windows-path folder ADosDir and any missing parents. ''
  // when it is there afterwards, else why not, with Windows' own error.
  // (Used instead of ForceDirectories, which only says False.)
  function MakeDosDir(const ADosDir: String): String;
  const
    ERROR_ALREADY_EXISTS_CODE = 183;
  var
    iErr: Integer;
    sDir, sParent: String;
  begin
    Result := '';
    sDir := ExcludeTrailingPathDelimiter(ADosDir);
    if (sDir = '') or DirectoryExists(sDir) then Exit;
    sParent := ExtractFileDir(sDir);
    if (sParent <> '') and (sParent <> sDir) then
    begin
      Result := MakeDosDir(sParent);
      if Result <> '' then Exit;
    end;
    if CreateDir(sDir) then Exit;
    iErr := GetLastOSError;
    // Already there after all (DirectoryExists said otherwise): carry on,
    // and let writing the file say whether it can be used.
    if iErr = ERROR_ALREADY_EXISTS_CODE then Exit;
    Result := sb([sDir, ': ', SysErrorMessage(iErr), ' (code ', iErr, ')']);
  end;

  // The Wine prefix (WINEPREFIX, ~/.wine by default). $WINEPREFIX is
  // usually unset for the default prefix, so otherwise it is worked out
  // from where Wine keeps drive C:, which is "<prefix>/dosdevices/c:" (a
  // link to "<prefix>/drive_c").
  function FindWinePrefix: String;
  var
    i: Integer;
    sDriveC: String;
  begin
    Result := UnixTrimSlash(Trim(GetEnvironmentVariable('WINEPREFIX')));
    if (Result <> '') and (Result[1] = '/') then Exit;
    Result := '';
    sDriveC := UnixTrimSlash(ToUnix('C:\'));
    if sDriveC = '' then Exit;
    i := Pos('/dosdevices/', sDriveC);
    if i > 1 then Exit(Copy(sDriveC, 1, i - 1));
    if Copy(sDriveC, LastDelimiter('/', sDriveC) + 1, MaxInt) = 'drive_c' then
      Exit(UnixParentDir(sDriveC));
  end;

  // The user's Linux home folder. Wine does NOT pass $HOME on to Windows
  // programs; it sets WINEHOMEDIR instead, as a Windows NT path
  // ("\??\Z:\home\mark", or "\??\unix\home\mark"), which Wine can turn
  // back into the Unix path. '' if no way works.
  function FindLinuxHome: String;
  var
    sName, sValue: String;
  begin
    sValue := Trim(GetEnvironmentVariable('WINEHOMEDIR'));
    if Pos('\??\', sValue) = 1 then
    begin
      // \??\ is the NT form of the \\?\ prefix Win32 path functions take.
      Result := UnixTrimSlash(ToUnix('\\?\' + Copy(sValue, 5, MaxInt)));
      if (Result <> '') and (Result[1] = '/') then Exit;
    end
    else if sValue <> '' then
    begin
      Result := UnixTrimSlash(ToUnix(sValue));
      if (Result <> '') and (Result[1] = '/') then Exit;
    end;
    // Some setups do pass HOME through unchanged.
    Result := UnixTrimSlash(Trim(GetEnvironmentVariable('HOME')));
    if (Result <> '') and (Result[1] = '/') then Exit;
    // /home/<Linux user name>, if that folder is there. Wine provides the
    // Linux user name as WINEUSERNAME.
    sName := Trim(GetEnvironmentVariable('WINEUSERNAME'));
    if sName = '' then sName := Trim(GetEnvironmentVariable('USERNAME'));
    if sName <> '' then
    begin
      Result := UnixPathJoin('/home', sName);
      if DirectoryExists(ToDos(Result)) then Exit;
    end;
    // A prefix inside /home/<user>/ (the usual ~/.wine) gives it away.
    Result := '';
    if Pos('/home/', sPrefix) = 1 then
    begin
      sValue := Copy(sPrefix, Length('/home/') + 1, MaxInt);
      if Pos('/', sValue) > 0 then
        Result := UnixPathJoin('/home', Copy(sValue, 1, Pos('/', sValue) - 1));
    end;
  end;

  // The user's desktop folder, the way xdg-user-dir finds it (which can't
  // be run from here): XDG_DESKTOP_DIR in user-dirs.dirs, else ~/Desktop.
  // '' when that is $HOME itself, which means "no desktop".
  function LinuxDesktopDirFromWine: String;
  var
    i: Integer;
    sConfig, sFile, sLine, sValue: String;
    SL: TSmartStrings;
  begin
    Result := UnixPathJoin(sHome, 'Desktop');
    sConfig := Trim(GetEnvironmentVariable('XDG_CONFIG_HOME'));
    if (sConfig = '') or (sConfig[1] <> '/') then
      sConfig := UnixPathJoin(sHome, '.config');
    sFile := ToDos(UnixPathJoin(sConfig, 'user-dirs.dirs'));
    if (sFile <> '') and FileExists(sFile) then
    try
      SL.Value.LoadFromFile(sFile);
      for i := 0 to SL.Value.Count - 1 do
      begin
        sLine := Trim(SL.Value[i]);
        if Pos('XDG_DESKTOP_DIR=', sLine) <> 1 then Continue;
        sValue := Trim(Copy(sLine, Length('XDG_DESKTOP_DIR=') + 1, MaxInt));
        if (Length(sValue) >= 2) and (sValue[1] = '"') and
          (sValue[Length(sValue)] = '"') then
          sValue := Copy(sValue, 2, Length(sValue) - 2);
        sValue := StringReplace(sValue, '$HOME', UnixTrimSlash(sHome),
          [rfReplaceAll]);
        if (sValue <> '') and (sValue[1] = '/') then
          Result := UnixTrimSlash(sValue);
        Break;
      end;
    except
      on E: Exception do
        DebugLog('CreateWineLinuxLaunchers: could not read ' + sFile +
          ': ' + E.Message);
    end;
    if UnixTrimSlash(Result) = UnixTrimSlash(sHome) then Result := '';
  end;

  // Desktop Entry values escape '\' as '\\' (see CreateLinuxShortcut).
  function EntryValue(const AValue: String): String;
  begin
    Result := StringReplace(AValue, '\', '\\', [rfReplaceAll]);
  end;

  procedure BuildEntry(st: TStringList);
  begin
    // A .desktop file must use LF line ends: GLib's parser would keep a
    // Windows CR as part of every value, including Exec=.
    st.LineBreak := #10;
    st.Add('[Desktop Entry]');
    st.Add('Version=1.0');
    st.Add('Type=Application');
    st.Add(sb(['Name=', Application.Title, ' (Wine)']));
    st.Add(sb(['GenericName=', Application.Title,
      ' - Rename TV show files consistently (Windows build, via Wine)']));
    st.Add('Comment=Rename TV show files consistently');
    if sIconUnix <> '' then st.Add('Icon=' + EntryValue(sIconUnix));
    st.Add('Path=' + EntryValue(UnixParentDir(sExeUnix)));
    // Hidden by menus if Wine is uninstalled, instead of doing nothing.
    st.Add('TryExec=wine');
    st.Add(sb(['Exec=env ', DesktopExecQuote('WINEPREFIX=' + sPrefix),
      ' wine ', DesktopExecQuote(sExeUnix)]));
    st.Add('Terminal=false');
    // Lets the desktop group filey's window under this launcher.
    st.Add('StartupWMClass=' + LowerCase(ExtractFileName(Application.ExeName)));
    st.Add('Categories=Utility;FileTools;');
    st.Add('Keywords=rename;TV;episode;series;video;mkv;wine;');
  end;

  // Adds one outcome to FWineLauncherStatus (an About > Info row: AWhat in
  // the left column, AText in the right) and to the logs: error.log when
  // AIsError, else debug.log. The row is cut to the column's width; the
  // log keeps all of it.
  procedure Note(const AWhat, AText: String; AIsError: Boolean);
  begin
    FWineLauncherStatus.Value.Add(AWhat + '=' + AText);
    if AIsError then
      LogError(sb(['CreateWineLinuxLaunchers: ', AWhat, ': ', AText]))
    else
      DebugLog(sb(['CreateWineLinuxLaunchers: ', AWhat, ': ', AText]));
  end;

  // Writes Wanted to AUnixFile unless it already holds exactly that.
  procedure WriteLauncher(const AUnixFile, AWhat: String);
  var
    Existing: TSmartStrings;
    sDos: String;
  begin
    sDos := ToDos(AUnixFile);
    if sDos = '' then
    begin
      Note(AWhat, 'NOT written: Wine has no Windows path for ' + AUnixFile,
        True);
      Exit;
    end;
    if FileExists(sDos) then
    try
      Existing.Value.LineBreak := #10;
      Existing.Value.LoadFromFile(sDos);
      if Existing.Value.Text = Wanted.Value.Text then
      begin
        Note(AWhat, 'up to date: ' + AUnixFile, False);
        Exit;
      end;
    except
      on E: Exception do
        DebugLog('CreateWineLinuxLaunchers: could not read ' + AUnixFile +
          ': ' + E.Message);
    end;
    try
      Wanted.Value.SaveToFile(sDos);
      // Read back, so "written" is only ever reported for a file that is
      // really there.
      if FileExists(sDos) then
        Note(AWhat, 'written: ' + AUnixFile, False)
      else
        Note(AWhat, sb(['NOT written (no error, but ', sDos,
          ' is not there afterwards)']), True);
    except
      on E: Exception do
        Note(AWhat, sb(['NOT written: ', E.Message, ' (', AUnixFile, ' = ',
          sDos, ')']), True);
    end;
  end;

begin
  if not g.IsWine then Exit;
  FWineLauncherStatus.Value.Clear;
  if not (g.IsCreateDesktopShortcut or g.IsCreateMenuEntry) then
  begin
    Note(WHAT_ALL, 'none made: IsCreateDesktopShortcut and ' +
      'IsCreateMenuEntry are both off in the ini file', False);
    Exit;
  end;
  hKernel := GetModuleHandle('kernel32.dll');
  if hKernel <> 0 then
  begin
    Pointer(WineToUnix) := GetProcAddress(hKernel, 'wine_get_unix_file_name');
    Pointer(UnixToWine) := GetProcAddress(hKernel, 'wine_get_dos_file_name');
  end
  else
  begin
    WineToUnix := nil;
    UnixToWine := nil;
  end;
  if not (Assigned(WineToUnix) and Assigned(UnixToWine)) then
  begin
    Note(WHAT_ALL, 'none made: wine_get_unix_file_name/' +
      'wine_get_dos_file_name not found in kernel32.dll', True);
    Exit;
  end;

  sPrefix := FindWinePrefix;
  sExeUnix := TidyUnixPath(ToUnix(Application.ExeName));
  sHome := TidyUnixPath(FindLinuxHome);
  if (sExeUnix = '') or (sPrefix = '') or (sPrefix = '/') or (sHome = '') then
  begin
    Note(WHAT_ALL, sb(['none made: Linux paths unknown (home="', sHome,
      '", prefix="', sPrefix, '", exe="', sExeUnix, '", WINEHOMEDIR="',
      GetEnvironmentVariable('WINEHOMEDIR'), '")']), True);
    Exit;
  end;

  sIconUnix := '';
  if ExtractFromSourceZip('filey64.png') then
    sIconUnix := TidyUnixPath(ToUnix(CombinePath(g.OpPath.Value,
      'filey64.png')));
  BuildEntry(Wanted.Value);

  if g.IsCreateDesktopShortcut then
  begin
    sDesktopDir := LinuxDesktopDirFromWine;
    if (sDesktopDir <> '') and DirectoryExists(ToDos(sDesktopDir)) then
      // Not made executable or "trusted" from here - Wine can't run chmod
      // or gio. GNOME asks once (right-click > Allow Launching); KDE and
      // XFCE ask on first launch.
      WriteLauncher(UnixPathJoin(sDesktopDir, LAUNCHER_FILE_NAME),
        WHAT_DESKTOP)
    else
      Note(WHAT_DESKTOP, sb(['NOT written: no desktop folder at "',
        sDesktopDir, '" (', ToDos(sDesktopDir), ')']), True);
  end
  else
    Note(WHAT_DESKTOP, 'off (IsCreateDesktopShortcut=0 in the ini file)',
      False);

  if g.IsCreateMenuEntry then
  begin
    // $XDG_DATA_HOME/applications, as in LinuxMenuEntryDir. Menus need
    // neither the executable bit nor "trusted", and notice the file by
    // themselves.
    sDataHome := Trim(GetEnvironmentVariable('XDG_DATA_HOME'));
    if (sDataHome = '') or (sDataHome[1] <> '/') then
      sDataHome := UnixPathJoin(UnixPathJoin(sHome, '.local'), 'share');
    sMenuDir := UnixPathJoin(sDataHome, 'applications');
    sMenuDirDos := ToDos(sMenuDir);
    if sMenuDirDos = '' then
      Note(WHAT_MENU, 'NOT written: Wine has no Windows path for ' +
        sMenuDir, True)
    else
    begin
      sWhyNot := MakeDosDir(sMenuDirDos);
      if sWhyNot = '' then
        WriteLauncher(UnixPathJoin(sMenuDir, LAUNCHER_FILE_NAME), WHAT_MENU)
      else
        Note(WHAT_MENU, 'NOT written: could not create ' + sWhyNot, True);
    end;
  end
  else
    Note(WHAT_MENU, 'off (IsCreateMenuEntry=0 in the ini file)', False);
end;
{$ENDIF}

procedure TForm1.DBEpsStateChange(Sender: TObject);
var
  DS: TDataSource;
  Grid: TDBGrid;
  Opt: TDBGridOptions;
begin
  DS := FDbf[dbEps].aDB.DataSource;
  Grid := DBGridEps;
  if not Assigned(DS) or not Assigned(Grid) then Exit;
  Opt := Grid.Options;
  case DS.State of
    dsEdit, dsInsert: begin
      Exclude(Opt, dgRowSelect);
      Include(Opt, dgEditing);
      Include(Opt, dgAlwaysShowEditor);
    end;
    dsBrowse: begin
      Include(Opt, dgRowSelect);
      Exclude(Opt, dgEditing);
      Exclude(Opt, dgAlwaysShowEditor);
    end;
  end;
  DBGridEps.Options := Opt;
end;

// Wired to every table's TAccessDbf.OnAccessChange (see InitializeDBFs).
// Fires when a record lock is detected or cleared outside a scroll - e.g.
// an Edit that failed because another user holds the record - so the
// LOCKED badge appears (or goes away) without waiting for the next scroll.
procedure TForm1.DbfAccessChanged(Sender: TObject);
begin
  if FIsShuttingDown or FIsDestroyed then Exit;
  UpdateStatusBar;
end;

procedure TForm1.DBFRecordCountChanged(DataSet: TDataSet);
var
  dbIdx: TDbType;
begin
  // Wired to every table's AfterPost/AfterDelete (see CreateAndOpenDBFs
  // and LogAfterPost, which overrides AfterPost for dbLog and calls this
  // itself). One shared handler, matched by dataset identity, covers
  // every commit/delete call site in the unit without any of them having
  // to remember to invalidate the status-bar record-count cache
  // themselves - see aRecCountDirty in uDBF.TDBRecord.
  for dbIdx := Low(TDbType) to High(TDbType) do
    if FDbf[dbIdx].aDB = DataSet then
    begin
      FDbf[dbIdx].aRecCountDirty := True;
      Exit;
    end;
end;

procedure TForm1.DBGridAboutMouseDown(Sender: TObject;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  col: Integer = 0;
  row: Integer = 0;
  s: String = '';
  sCommand: String = '';
  Send: TDBGrid;
begin
  inherited;
  if Button <> mbRight then Exit;
  Send := TDBGrid(Sender);
  if Send.Columns.Count <= 0 then Exit;
  Send.MouseToCell(X, Y, col, row);
  if dgTitles in Send.Options then Dec(row);
  if dgIndicator in Send.Options then Dec(col);
  if TDBGridHack(Send).DataLink.Active and (row >= 0) and (col >= 0) then
  begin
    TDBGridHack(Send).DataLink.ActiveRecord := row;
    s := TDbf(Send.DataSource.DataSet).FieldByName('VALUE').AsString;
    // An "Install with: ..." row gets its own menu: copy the command, open
    // it in a terminal, or look for the programs again.
    sCommand := ExtractInstallCommand(s);
    if sCommand <> '' then
    begin
      EnsureInstallMenu;
      FInstallMenuCommand := sCommand;
      // '&' would otherwise underline the next letter instead of showing.
      FInstallMenu.Items[INSTALL_MENU_COPY].Caption :=
        'Copy:  ' + StringReplace(sCommand, '&', '&&', [rfReplaceAll]);
      FInstallMenu.Items[INSTALL_MENU_TERMINAL].Enabled := TerminalSupported;
      FInstallMenu.PopUp;
      Exit;
    end;
    s := SafeExpandFileName(s);
    OpenDialog.FileName := s;
    MenuItemOpenFolder.Caption := 'Open ' + s;
    if FileExists(s) or DirectoryExists(s) then PopupMenuAbout.PopUp;
  end;
end;

procedure TForm1.DBGridDblClick(Sender: TObject);
begin
  if dgRowSelect in TDBGrid(Sender).Options then TDBGrid(Sender).Options :=
      TDBGrid(Sender).Options + [dgRowSelect, dgEditing, dgCellHints];
end;

procedure TForm1.DBGridEpsEditingDone(Sender: TObject);
var
  Opt: TDBGridOptions;
begin
  Opt := DBGridEps.Options;
  Opt := Opt + [dgRowSelect] - [dgEditing];
  DBGridEps.Options := Opt;
end;

procedure TForm1.DBGridEpsEnter(Sender: TObject);
begin
  ShowStatusDBF(dbEps);
end;

procedure TForm1.DBGridEpsMouseEnter(Sender: TObject);
begin
  AdjustColumns(DBGridEps);
end;

procedure TForm1.DBGridEpsMouseWheel(Sender: TObject;
  Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint;
  var Handled: Boolean);
begin
  (Sender as TDBGrid).AutoAdjustColumns;
end;

procedure TForm1.DBGridExit(Sender: TObject);
begin
  UpdateStatusBar;
end;

procedure TForm1.DBGridListAfterScroll(DataSet: TDataSet);
begin
  ShowStatusDBF(dbList);
end;

procedure TForm1.DBGridListBeforeScroll(DataSet: TDataSet);
begin
  ShowStatusDBF(dbList);
end;

procedure TForm1.DBGridListSelectEditor(Sender: TObject;
  Column: TColumn; var Editor: TWinControl);
begin
  UpdateStatusBar;
end;

procedure TForm1.DBGridListSetColumnWidths;
var
  NewWidth: Integer;
  Grid: TDBGrid;
  Guard: TDataLayoutGuard;
begin
  Grid := DBGridList;
  // 1. CHEAPEST: Pointer Safety (Always first)
  if not Assigned(Grid) then Exit;
  // 2. STRUCTURAL: Avoid Index-Out-Of-Bounds (Essential for the logic below)
  if Grid.Columns.Count < 2 then Exit;
  // 3. VISUAL STATE: Is the math ready?
  // If not Showing, Grid.Width might be 0 or uninitialized by the LCL layout engine.
  if not Grid.Showing then Exit;
  // --- REMOVED: if not Grid.Enabled then exit; --- }
  // Now we do the work
  Guard := TDataLayoutGuard.CreateLayOut(Grid);
  // Math: Use the local variable once to avoid repeated property calls
  NewWidth := (Grid.Width div 2) - DEFINDICATORCOLWIDTH;
  if NewWidth > 0 then
  begin
    Grid.Columns[0].Width := NewWidth;
    Grid.Columns[1].Width := NewWidth;
  end;
  UpdateStatusBar;
end;

procedure TForm1.DBGridLogCellClick(Column: TColumn);
var
  Field: TField;
  db: TDbf;
  Grid: TDBGrid;
  Guard: TDataLayoutGuard;
begin
  if not (Assigned(Column) and Assigned(Column.Field) and
    Assigned(Column.Grid)) then Exit;
  Field := Column.Field;
  Grid := TDBGrid(Column.Grid);
  // Manual assignment instead of absolute
  db := TDbf(Field.DataSet);
  Guard := TDataLayoutGuard.Create(db, Grid, nil);
  if (Field.FieldName = 'UNDO') and (Field.DataType = ftBoolean) then
  begin
    //if not (DB.State in [dsEdit, dsInsert]) then
    db.Edit;
    Field.AsBoolean := not Field.AsBoolean;
    db.Post;
    Grid.InvalidateCol(Column.Index);
    CheckLogCheckBoxes;
    Exit;
  end;
  // This part now runs for everything ELSE (Non-Boolean OR No-Field)
  // exactly like your original code did.
  if not (dgEditing in Grid.Options) then
    Grid.Options := Grid.Options + [dgEditing] - [dgRowSelect];
  Grid.EditorMode := True;
  CheckLogCheckBoxes;
end;

procedure TForm1.DBGridLogColEnter(Sender: TObject);
begin
  DBGridLog.Options := DBGridLog.Options +
    [dgRowSelect, dgEditing, dgAlwaysShowEditor];
  DBGridLog.EditorMode := True; // Force in-cell editing
end;

procedure TForm1.DBGridLogDblClick(Sender: TObject);
begin
  // Remove row select and enable editing on double-click
  if dgRowSelect in DBGridLog.Options then
    DBGridLog.Options := DBGridLog.Options +
      [dgRowSelect, dgEditing, dgAlwaysShowEditor];
  DBGridLog.EditorMode := True;
end;

procedure TForm1.DBGridLogDrawColumnCell(Sender: TObject;
  const Rect: TRect; DataCol: Integer; Column: TColumn; State: TGridDrawState);
var
  c: TCanvas;
  R: TRect;
  CSize: Integer;
  Flags: Integer;
begin
  // Standard guard: ensure we have data.
  if not (Assigned(Column) and Assigned(Column.Field)) then Exit;
  // Let the grid handle everything except the UNDO Boolean column.
  if (Column.Field.FieldName <> 'UNDO') or
    (Column.Field.DataType <> ftBoolean) then
  begin
    TDBGrid(Sender).DefaultDrawColumnCell(Rect, DataCol, Column, State);
    Exit;
  end;
  // Happy path: draw the UNDO Boolean as a checkbox.
  c := TDBGrid(Sender).Canvas;
  CSize := 13;
  // 1. Handle Colors
  if gdSelected in State then
  begin
    c.Brush.Color := clHighlight;
    c.Font.Color := clHighlightText;
  end
  else
  begin
    c.Brush.Color := clWindow;
    c.Font.Color := clWindowText;
  end;
  c.FillRect(Rect);
  // 2. Calculate Centering
  R.Left := Rect.Left + (Rect.Width - CSize) div 2;
  R.Top := Rect.Top + (Rect.Height - CSize) div 2;
  R.Width := CSize;
  R.Height := CSize;
  // 3. Set Flags
  Flags := DFCS_BUTTONCHECK;
  if Column.Field.AsBoolean then Flags := Flags or DFCS_CHECKED;
  if gdFocused in State then Flags := Flags or DFCS_PUSHED;
  // 4. Render
  {$IFDEF WINDOWS}
  DrawFrameControl(c.Handle, R, DFC_BUTTON, Flags);
  {$ELSE}
  DrawSimpleCheckBox(R, Column.Field.AsBoolean, gdSelected in State);
  {$ENDIF}
  // 5. Focus Rect
  if gdFocused in State then c.DrawFocusRect(Rect);
end;

procedure TForm1.DBGridLogEnter(Sender: TObject);
begin
  // Ensure proper editing setup when grid gets focus
  DBGridLog.Options := DBGridLog.Options +
    [dgRowSelect, dgEditing, dgAlwaysShowEditor];
  DBGridLog.EditorMode := True;
end;

procedure TForm1.DBGridLogKeyDown(Sender: TObject; var Key: word;
  Shift: TShiftState);
var
  col: TColumn;
  DS: TDataSet;
  Grid: TDBGrid absolute Sender;
begin
  // 1. Identify the environment
  if not (Sender is TDBGrid) then Exit;
  // Find the dataset through the Grid's DataSource
  if (Grid.DataSource = nil) or (Grid.DataSource.DataSet = nil) then Exit;
  DS := Grid.DataSource.DataSet;
  // 2. Global Shortcuts (Toggle All)
  if Shift = [ssCtrl] then
  begin
    case Key of
      Ord('A'): begin
        ToggleLogUndoBoxes(True);
        Key := 0;
        Exit;
      end;
      Ord('Z'): begin
        ToggleLogUndoBoxes(False);
        Key := 0;
        Exit;
      end;
    end;
  end;
  // 2. Early Exit if Grid is empty or index is invalid
  if (Grid.SelectedIndex < 0) or (Grid.Columns.Count = 0) then Exit;
  col := Grid.Columns[Grid.SelectedIndex];
  if not (Assigned(col) and Assigned(col.Field)) then Exit;
  // 3. Handle Boolean Toggle (Space/Enter)
  if (col.Field.FieldName = 'UNDO') and (col.Field.DataType = ftBoolean) then
  begin
    if (Key = VK_SPACE) or (Key = VK_RETURN) then
    begin
      if not (FDbf[dbLog].aDB.State in [dsEdit, dsInsert]) then
        FDbf[dbLog].aDB.Edit;
      col.Field.AsBoolean := not col.Field.AsBoolean;
      FDbf[dbLog].aDB.Post;
      CheckLogCheckBoxes;
      Key := 0;
      // Prevent the Grid from opening the text editor
      Exit;
    end;
  end;
  // 4. Standard Navigation / Editing}
  case Key of
    VK_RETURN, VK_TAB, VK_F2: Grid.EditorMode := True;
    VK_ESCAPE: begin
      Grid.EditorMode := False;
      // If you have a specific "Cancel" action for the UI, put it here
      Key := 0;
    end;
  end;
end;

procedure TForm1.DBGridLogMouseEnter(Sender: TObject);
var
  // No memory is allocated for 'Grid'; it just looks at 'Sender'
  Grid: TDBGrid absolute Sender;
  DS: TDataSet; // Same as TDbf }
  // Don't use a TDataLayoutGuard here, to see Ctrl-A in action
begin
  if not (Sender is TDBGrid) then Exit;
  //{The "Chain of Command" check}
  if (Grid.DataSource = nil) or (Grid.DataSource.DataSet = nil) then Exit;
  DS := Grid.DataSource.DataSet;
  if not DS.Active then Exit;
  if Grid.Focused and Grid.EditorMode then Exit;

  if not (DS.State in [dsEdit, dsInsert]) then
  begin
    if (DS is TDbf) and IsPhysicallyReadOnly(TDbf(DS)) then Exit;
    try
      DS.Edit;
    except
      // Someone else holds this record: the LOCKED badge is already
      // showing, and a mouse-over shouldn't pop an error dialog.
      on EDbfRecordLocked do Exit;
    end;
  end;

  SafeSetFocus(Grid);
  // UpdateUndoState(DS, BitBtnUndo);
  CheckLogCheckBoxes;
  Grid.Options := Grid.Options + [dgRowSelect, dgEditing,
    dgAlwaysShowEditor, dgCellHints] - [dgAlwaysShowSelection];
  // Final step: trigger the editor
  Grid.EditorMode := True;
end;

procedure TForm1.DBGridLogMouseLeave(Sender: TObject);
var
  Grid: TDBGrid absolute Sender;
  DS: TDataSet;
begin
  // 1. Identify the Grid
  if not (Sender is TDBGrid) then Exit;
  // 2. Identify the Data
  if (Grid.DataSource = nil) or (Grid.DataSource.DataSet = nil) then Exit;
  DS := Grid.DataSource.DataSet;
  // 3. Refresh the UI State
  //UpdateUndoState(DS, BitBtnUndo);
  CheckLogCheckBoxes;
  // Note: We are deliberately NOT changing Grid.Options or EditorMode
  // here to let the user keep typing even if the mouse slips off the grid
end;

procedure TForm1.DBGridLogSelectEditor(Sender: TObject;
  Column: TColumn; var Editor: TWinControl);
begin
  // Force editor mode when editor is being selected
  DBGridLog.EditorMode := True;
  // Ensure column is not read-only
  if Assigned(Column) then Column.ReadOnly := False;
  UpdateStatusBar;
end;

procedure TForm1.DBGridMakeHint(const Sender: TObject; const X, Y: Integer);
var
  //No DataLayoutGuard, don't lock/repaint whole form for every mousemove
  col, row, TempRecord: Integer;
  Fld: TField;
  Grid: TDBGridHack absolute Sender; // Direct alias "cracker class"
  aDataLink: TDataLink;
  sHint: String;
begin
  // 1. Basic UI Guard
  if Grid.Columns.Count <= 0 then Exit;
  // 2. Coordinate Mapping
  Grid.MouseToCell(X, Y, col, row);
  if dgTitles in Grid.Options then Dec(row);
  if dgIndicator in Grid.Options then Dec(col);
  // 3. Debounce & Bounds Guard
  //if (row = FLastHintRow) and (col = FLastHintCol) then Exit;
  if (row < 0) or (col < 0) then Exit;
  // 4. Data State Guard
  aDataLink := Grid.DataLink;
  if (not Assigned(aDataLink)) or (not aDataLink.Active) then Exit;
  // 5. RAII Context & State Management
  TempRecord := aDataLink.ActiveRecord;
  try
    aDataLink.ActiveRecord := row;
    // The Shortest Path: Direct access via the DataLink
    sHint := '';
    for Fld in aDataLink.DataSet.Fields do sb(sHint, sAddHint(Fld));
    Grid.Hint := sHint;
    Application.ActivateHint(Mouse.CursorPos);
  finally
    aDataLink.ActiveRecord := TempRecord;
  end;
  UpdateStatusBar;
end;

procedure TForm1.DBGridMouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Integer);
begin
  // No inherited needed here for standard forms
  DBGridMakeHint(Sender, X, Y);
end;

procedure TForm1.DBGridShowsAfterScroll(DataSet: TDataSet);
var
  curRec: Integer = 0;
begin
  if FDbf[dbShows].aDB.ControlsDisabled = True then Exit;
  if not (DataSet.Active or FDbf[dbEps].aDB.Active) then Exit;
  if not Assigned(FDbf[dbEps].aDB) then Exit;
  // don't try this until after Eps is created
  g.URL := sb([g.EpGuidesURL, GetShowsDirectory, '/']);
  FDbf[dbEps].aFilterText := GetShowsTitle;
  curRec := FDbf[dbEps].aDB.PhysicalRecNo;
  if not FDbf[dbEps].aDB.Locate('TITLE', GetShowsTitle, []) then
    FDbf[dbEps].aDB.PhysicalRecNo := curRec; // Eps.physicalrecno?
  ShowStatusDBF(dbShows);
end;

procedure TForm1.DBGridShowsBeforeScroll(DataSet: TDataSet);
begin
  ShowStatusDBF(dbShows);
end;

procedure TForm1.DBGridShowsEditingDone(Sender: TObject);
var
  Opt: TDBGridOptions;
begin
  Opt := DBGridShows.Options;
  Opt := Opt + [dgRowSelect] - [dgEditing];
  DBGridShows.Options := Opt;
end;

procedure TForm1.DBGridShowsEnter(Sender: TObject);
begin
  AdjustColumns(Sender);
end;

procedure TForm1.DBGridShowsMouseEnter(Sender: TObject);
begin
  SafeSetFocus(DBGridShows);
end;

procedure TForm1.DBGridShowsMouseWheel(Sender: TObject;
  Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint;
  var Handled: Boolean);
begin
  (Sender as TDBGrid).AutoAdjustColumns;
end;

procedure TForm1.DBGridTitleClick(Column: TColumn);
begin
  AdjustColumns(Column.Grid);
end;

procedure TForm1.DBNavigatorEpsClick(Sender: TObject;
  Button: TDBNavButtonType);
begin
  case Button of
    nbEdit: MenuItemEpsEditClick(Sender);
    nbRefresh: ConfirmThenZapPackTable(FDbf[dbEps].aDB);
    nbFirst: FDbf[dbEps].aDB.First;
    nbLast: FDbf[dbEps].aDB.Last;
    else
      NoOp
  end;
  UpdateStatusBar;
end;

procedure TForm1.DBNavigatorEpsResize(Sender: TObject);
begin
  AdjustColumns(DBGridEps);
end;

procedure TForm1.DBNavigatorLogClick(Sender: TObject;
  Button: TDBNavButtonType);
begin
  case Button of
    nbEdit: begin
      //{CRITICAL: Do NOT add dgRowSelect - it causes floating editors}
      DBGridLog.Options :=
        DBGridLog.Options + [dgRowSelect, dgEditing, dgCellHints,
        dgAlwaysShowEditor] - [dgAlwaysShowSelection];
      DBGridLog.ReadOnly := False;
      DBGridLog.EditorMode := True;
    end;
    nbRefresh: ConfirmThenZapPackTable(FDbf[dbLog].aDB);
    else
      NoOp
  end;
  UpdateStatusBar;
end;

procedure TForm1.DBNavigatorShowsClick(Sender: TObject;
  Button: TDBNavButtonType);
begin
  case Button of
    nbEdit, nbInsert: MenuItemShowsEditClick(Sender);
    nbPost, nbCancel: { Optional: Turn RowSelect}
      { back on after saving?}
      {MenuItemViewClick(Sender);}
    else;
  end;
end;

procedure TForm1.DBShowsStateChange(Sender: TObject);
var
  DS: TDataSource;
  Grid: TDBGrid;
  Opt: TDBGridOptions;
begin
  DS := FDbf[dbShows].aDB.DataSource;
  Grid := DBGridShows;
  if not Assigned(Grid) then Exit;
  Opt := Grid.Options;
  if not Assigned(DS) or not Assigned(Grid) then Exit;
  case DS.State of
    dsEdit, dsInsert: begin
      Exclude(Opt, dgRowSelect);
      Include(Opt, dgEditing);
      Include(Opt, dgAlwaysShowEditor);
    end;
    dsBrowse: begin
      Include(Opt, dgRowSelect);
      Exclude(Opt, dgEditing);
      Exclude(Opt, dgAlwaysShowEditor);
    end;
    else
  end;
  DBGridShows.Options := Opt;
end;

procedure TForm1.DealWithSpecialFiles;
var
  db: TDbf;
  FRegEx: TSmartRegEx;
  i, SpecialRecNo: Integer;
  Op: TRenameOperationState;
  sTestExt, sTestName, sSpecialName, sTargetPiece: String;
begin
  Op := Default(TRenameOperationState);  //freshly zeroed, every time
  db := FDbf[dbList].aDB;
  FRegEx.Value.Expression := '^\d{8}$';
  // Same reset as RenameThisList: a leftover mrAll from a previous run
  // would otherwise make QueryThenRename below rename silently, and a
  // leftover IsCancel would make the loop below exit immediately.
  g.buttonSelected := mrNone;
  Op.IsCancel := False;
  db.First;
  while (not db.EOF) and (not Op.IsCancel) do
  begin
    if GetListTo.IsNotEmpty then
    begin
      db.Next;
      Continue;
    end;
    sTestExt := UTF8UpperCase(ExtractFileExt(GetListFrom));
    // Use 'i' here for the Find result
    if Video_File_Extensions.Value.Find(sTestExt, i) then
    begin
      sTestName := efnOnly(GetListFrom);
      if FRegEx.Value.Exec(sTestName) and
        (FRegEx.Value.Match[0] = sTestName) then
      begin
        sSpecialName := sTestName;
        SpecialRecNo := db.PhysicalRecNo;
        db.First;
        while (not db.EOF) and (not Op.IsCancel) do
        begin
          if (GetListTo = '') and
            (UTF8UpperCase(ExtractFileExt(GetListFrom)) = '.NFO') then
          begin
            sTestName := efnOnly(GetListFrom);
            if Pos(sSpecialName, sTestName) = 1 then
            begin
              FPieces.Value.Clear;
              FRegEx.Value.Split(sTestName, FPieces.Value);
              if (FPieces.Value.Count > 1) and
                (FPieces.Value.Strings[1].IsNotEmpty) then
              begin
                sTargetPiece := FPieces.Value.Strings[1];
                QueryThenRename(sTargetPiece, Op);
                SafeGo(db, SpecialRecNo);
                QueryThenRename(sTargetPiece, Op);
                Break;
              end;
            end;
          end;
          db.Next;
        end;
        SafeGo(db, SpecialRecNo);
      end;
    end;
    db.Next;
  end;
  db.First;
end;

// Opens FPendingBrowserURL, queued by IpHtmlPanel1HotClick and
// BrowseToURL (for NavigateBrowser) with Data = 1 - reload even if it is
// already showing - and by tsBrowserShow with Data = 0.
procedure TForm1.DeferredBrowse(Data: PtrInt);
var
  sURL: String;
begin
  sURL := FPendingBrowserURL;
  FPendingBrowserURL := '';
  if sURL.IsEmpty or FIsShuttingDown then Exit;
  BrowseToURL(sURL, Data <> 0);
end;

// Opens FReadmePendingLink, queued by ReadmeLinkClick: in vwReadme, added
// to FReadmeHistory for Back, or - for README_EXTERNAL_DOCS - in the
// default browser.
procedure TForm1.DeferredReadmeLink(Data: PtrInt);
var
  iLast: Integer;
  sAnchor: String = '';
  sDoc, sLink: String;
begin
  sLink := FReadmePendingLink;
  FReadmePendingLink := '';
  if sLink.IsEmpty or FIsShuttingDown or not Assigned(vwReadme.Value) then
    Exit;
  sDoc := BundledDocForLink(sLink, sAnchor);
  if sDoc.IsEmpty then Exit;
  if IndexStr(sDoc, README_EXTERNAL_DOCS) >= 0 then
  begin
    OpenBundledDocExternally(sDoc, sLink);
    Exit;
  end;
  iLast := FReadmeHistory.Value.Count - 1;
  // A link into the document already showing only scrolls.
  if (iLast >= 0) and (FReadmeHistory.Value.Names[iLast] = sDoc) then
  begin
    if not sAnchor.IsEmpty then
      vwReadme.Value.PositionTo(UTF8Decode(sAnchor));
    Exit;
  end;
  // Where the reader was, for Back to return to.
  if iLast >= 0 then
    FReadmeHistory.Value.ValueFromIndex[iLast] :=
      IntToStr(vwReadme.Value.Position);
  if ShowReadmeDoc(sDoc, 0, sAnchor) then
    FReadmeHistory.Value.Add(sDoc + '=0')
  else if sLink.StartsWith('http', True) then
    // This build doesn't carry it after all (ShowReadmeDoc logged that),
    // so the web copy will have to do.
    LCLIntf.OpenURL(sLink);
  UpdateReadmeBack;
end;

// Everything slow that used to run before Form1 was ever drawn: copying
// filey-src.zip out of the executable and unpacking whatever is missing from
// it, running ffprobe/mkvmerge/mkvpropedit to prove they work, probing the
// network, and opening (on a first run, possibly importing) the tables.
// Queued by FormShow, so it starts only once the form is on screen.
procedure TForm1.DeferredStartup(Data: PtrInt);
var
  Completed: Boolean = False;

  function StartupAborted: Boolean;
  begin
    // The title-bar close box still works while every control is disabled;
    // FormCloseQuery sets FIsShuttingDown.
    Result := FIsShuttingDown or Application.Terminated;
  end;

  // Show has been called, but under X11 (GTK2/Qt) the window manager maps
  // the window and delivers its first expose asynchronously, so it may not
  // have been painted yet - and the steps below can each block for seconds
  // without pumping messages (ToolRunsOK under Wine, HasInternetConnection
  // on a dead network). Pump until the status bar reports its first paint,
  // or MAX_WAIT_MS passes. On Win32 and Wine the first pass is normally
  // enough.
  procedure WaitForFirstPaint;
  const
    MAX_WAIT_MS = 500;
  var
    StartTick: QWord;
  begin
    StartTick := GetTickCount64;
    repeat
      Application.ProcessMessages;
      if FStatusBarPainted or StartupAborted then Break;
      Sleep(10);
    until GetTickCount64 - StartTick >= MAX_WAIT_MS;
    // One more pass for anything that painting the status bar left pending.
    Application.ProcessMessages;
  end;

  // Busy lives only as long as this nested routine (same pattern as
  // actSelectExecute's RefreshSelection), so every control is disabled for
  // exactly the duration of the work - nothing can reach a table that isn't
  // open yet - and is back to normal before the final page and status text
  // are chosen below. AStatusControl is nil on purpose: otherwise Busy would
  // put back the (empty) pre-startup status text when it ends, wiping e.g.
  // SyncShowsDatabase's "Synced N records" summary.
  procedure RunStartupSteps;
  var
    Busy: TSmartBusyState;
  begin
    Busy := TSmartBusyState.Start(Self, nil, nil, True);
    WaitForFirstPaint;
    if StartupAborted then Exit;
    CheckResourceFiles;
    if StartupAborted then Exit;
    CleanUpStrayFiles;
    CreateDesktopShortcut;
    StatusBar.Panels[0].Text := 'Checking internet connection...';
    Application.ProcessMessages;
    g.IsInternetConnected := HasInternetConnection;
    if StartupAborted then Exit;
    StatusBar.Panels[0].Text := 'Opening databases...';
    Application.ProcessMessages;
    InitializeDBFs;
    Completed := True;
  end;

begin
  DebugLog('Enter DeferredStartup');
  try
    try
      if not StartupAborted then RunStartupSteps;
    except
      on E: Exception do
      begin
        // Reported the way the LCL reported an exception from FormCreate,
        // where InitializeDBFs used to run: shown, and the application
        // keeps running. Logged as well, as everywhere else.
        LogError('DeferredStartup failed', E);
        Application.ShowException(E);
      end;
    end;
  finally
    FIsStartingUp := False;
  end;
  if StartupAborted or not Completed then Exit;
  // CheckResourceFiles puts back the page it found, but SyncShowsDatabase
  // leaves tsProgress up when it bails out part-way (no internet, empty
  // allshows.txt). After a completed import it switches to tsShows on
  // purpose; leave that, along with its "Synced..." status text.
  if pcMain.ActivePage = tsProgress then pcMain.ActivePage := tsList;
  // Busy has just re-enabled every control it disabled - including
  // BitBtnLookupEps/BitBtnRename, which SetupDbList -> actClearExecute
  // disabled on purpose because the list is empty.
  SetTabSheetListButtons;
  SetBitBtnUndoEnabled;
  if pcMain.ActivePage = tsList then UpdateStatusBar;
  // Queued, not called: the window should be up and idle before asking.
  if g.IsAppImage then Application.QueueAsyncCall(@AskToMoveAppImage, 0);
  DebugLog('Exit DeferredStartup');
end;

function TForm1.DiscoverExternalTool(
  const ALinuxExeName, AWindowsExeName, AVersionArg: String;
  out AWinePrefix, AResolvedFileName: String): TFilePath;
var
  sFoundPath: String;
begin
  AWinePrefix := EmptyStr;
  AResolvedFileName := EmptyStr;
  Result := EmptyStr;

  // 1. Prefer a native Linux build already on PATH - no Wine needed.
  if g.IsLinux then
  begin
    sFoundPath := FindPathTo(ALinuxExeName);
    if sFoundPath <> EmptyStr then
    begin
      AResolvedFileName := ALinuxExeName;
      Result := SafeExpandFileName(sFoundPath);
    end;
  end;

  // 2. No native build on this OS/PATH: fall back to the bundled Windows
  // build, extracting it from the app's zip resource if it is missing or
  // isn't this build's copy.

  // The Wine prefix is conditional on actually BEING on Linux, not on
  // "the native binary wasn't found". On Windows the bundled .exe IS the
  // native build. Prefixing it with 'wine ' there made step 3's
  // ToolRunsOK shell out to a "wine" that doesn't exist, which failed,
  // which discarded the tool - so a Windows build silently ended up with
  // FilePathFFProbe / FilePathMKVMerge / FilePathMKVPropEdit all empty
  // and every downstream IsBlank guard exiting early.
  if Result = EmptyStr then
  begin
    if g.IsLinux then AWinePrefix := 'wine ';
    AResolvedFileName := AWindowsExeName;
    ExtractFromSourceZip(AResolvedFileName);
    sFoundPath := FindPathTo(AResolvedFileName);
    if sFoundPath <> EmptyStr then Result := SafeExpandFileName(sFoundPath);
  end;

  // 3. Precise verification: a resolved path is only trusted once the file
  // is confirmed to exist AND actually runs its version check successfully -
  // through Wine when this is the bundled Windows build, exactly the way
  // the tool is actually invoked elsewhere in the app. This catches
  // stale/corrupt downloads and wrong-arch binaries that a bare FileExists
  // check would miss.
  if (Result <> EmptyStr) and not (Result.Exists and
    ToolRunsOK(AWinePrefix, Result.Value, AVersionArg)) then
  begin
    DebugLog(sb(['DiscoverExternalTool: "', AResolvedFileName,
      '" resolved to "', Result.Value,
      '" but the file is missing or would not run - discarding.']));
    AWinePrefix := EmptyStr;
    AResolvedFileName := EmptyStr;
    Result := EmptyStr;
  end;
end;

// Fetches AURL on a background thread (see uBrowser) while the window
// keeps responding. The caller frees the result. nil if the load was
// stopped first: another address (NavigateBrowser), or the program
// closing.
function TForm1.DownloadBrowserPage(const AURL: String): TBrowserDownload;
var
  Batch: TBrowserDownloadBatch;
  URLs: TSmartStrings;
begin
  URLs.Value.Add(AURL);
  Batch := TBrowserDownloadBatch.Create(URLs.Value, True);
  try
    RunBrowserDownloads(Batch, 1, 0, '');
    Result := Batch.TakeFinished(0);
    if Batch.Cancelled then FreeAndNil(Result);
  finally
    Batch.Release;
  end;
end;

procedure TForm1.DownLoadEps;
var
  Busy: TSmartBusyState;
begin
  if not g.IsInternetConnected then Exit;
  if GetShowsTitle.IsEmpty then Exit;
  StatusBar.Panels[0].Text := 'Downloading Episode Names...';
  if GetShowsLookUpDate = g.Today then Exit;
  // only 1 Lookup per day per show
  Busy := TSmartBusyState.Start(Form1, nil, StatusBar, False);
  g.URL := g.EpGuidesURL + GetShowsDirectory + '/';
  ParseHTMLToMemo;
  actMemoToEpsExecute(Self);
  SetDbField(dbShows, 'LOOKUPDATE', g.Today);
  FDbf[dbEps].aDB.First;
  AdjustColumns(DBGridEps);
end;

// Downloads allshows.txt to ShowsFile. Returns False (having already
// logged the reason) if SSL setup fails; the caller treats that the same
// as "file still doesn't exist".
function TForm1.DownloadShowsFile(const ShowsFile: String): Boolean;
var
  RawText: TSmartStrings; // RAII: scratch buffer for the raw HTTP payload
begin
  Result := False;
  ProgressLabel.Caption := 'Downloading shows list...';
  UI.Check; // Keep UI responsive during download

  if not InitializeShowsDownloadSSL then Exit;

  RawText.Setup(Self);
  RawText.Value.Text :=
    TFPHTTPClient.SimpleGet('https://epguides.com/common/allshows.txt');
  RawText.Value.SaveToFile(ShowsFile);
  Result := True;
end;

procedure TForm1.DrawSimpleCheckBox(const Rect: TRect;
  Checked: Boolean; Selected: Boolean);
var c: TCanvas;
begin
  c := DBGridLog.Canvas;
  // Draw checkbox border
  c.Pen.Color := IfThen(Selected, clHighlightText, clGray);
  c.Pen.Style := psSolid;
  c.Brush.Style := bsClear;
  c.Rectangle(Rect);
  if not Checked then Exit;
  // Draw a simple checkmark if checked
  c.Pen.Color := IfThen(Selected, clHighlightText, clBlack);
  c.Pen.Width := 2;
  c.MoveTo(Rect.Left + 2, Rect.Top + 5);
  c.LineTo(Rect.Left + 5, Rect.Top + 8);
  c.LineTo(Rect.Left + 10, Rect.Top + 3);
  c.Pen.Width := 1;
end;

procedure TForm1.EditButtonClick(Sender: TObject);
begin
  if Sender.ClassName = 'TEditButton' then TEditButton(Sender).Text := '';
  g.SearchDirectionForward := True;
  SetTabSheetMemoButtons;
end;

procedure TForm1.EditChange(Sender: TObject);
var
  ASearch, s: String;
  EditBtn: TEditButton;
  p: Integer;
  Page: TTabSheet;
  SynEdit: TSynEdit;
begin
  if pcSourceCode.PageCount = 0 then Exit;
  p := pcSourceCode.ActivePageIndex;
  if p < 0 then Exit;
  Page := pcSourceCode.Page[p] as TTabSheet;
  s := 'EditButton' + p.toString;
  EditBtn := Page.FindComponent(s) as TEditButton;
  if EditBtn = nil then Exit;
  ASearch := EditBtn.Text;
  if g.SearchDirectionForward then
  begin
    s := 'SynEdit' + p.toString;
    SynEdit := Page.FindComponent(s) as TSynEdit;
    if SynEdit <> nil then SynEdit.SearchReplace(ASearch, '', []);
  end;
end;

procedure TForm1.EditKeyDown(Sender: TObject; var Key: word;
  Shift: TShiftState);
var
  s: String = '';
  CP: Integer = 0;
begin
  if pcSourceCode.PageCount = 0 then Exit;
  if pcSourceCode.ActivePageIndex < 0 then Exit;
  CP := pcSourceCode.ActivePageIndex;
  s := TObject(Sender).ClassName + CP.toString;
  s := RightStr(s, Length(s) - 1);
  // chop off the 'T' from component name
  MyComponent := pcSourceCode.Page[CP].FindComponent(s);
  case Key of
    VK_RETURN: if g.SearchDirectionForward then BitBtnNextClick(Sender)
      else
        BitBtnPrevClick(Sender);
    VK_F3: if ssShift in Shift then BitBtnPrevClick(Sender)
      else
        BitBtnNextClick(Sender)
    else
      NoOp
  end;
end;

procedure TForm1.EditKeyUp(Sender: TObject; var Key: word; Shift: TShiftState);
begin
  SetTabSheetMemoButtons;
end;

procedure TForm1.EditMouseEnter(Sender: TObject);
begin
  SetTabSheetSourceCodeButtons(Sender);
end;

procedure TForm1.edUrlEditingDone(Sender: TObject);
begin
  // EditingDone fires on Enter and also whenever focus leaves the box, so
  // only an address the user has actually typed is loaded. Modified is
  // cleared whenever the program sets Text (BrowseToURL,
  // IpHtmlPanel1DocumentOpen). Go! reloads regardless.
  if not edUrl.Modified then Exit;
  NavigateBrowser(edUrl.Text, False);
end;

procedure TForm1.edUrlMouseEnter(Sender: TObject);
const
  TYPE_HINT = 'Type a web address, then press Enter or click Go!';
begin
  // Used to copy g.URL into the box, which threw away whatever was being
  // typed there. Shows the full address of the page in the hint instead,
  // for when it is wider than the box.
  if g.LastURL.IsEmpty then edUrl.Hint := TYPE_HINT
  else
    edUrl.Hint := sb(['Showing: ', g.LastURL, LE, TYPE_HINT]);
end;

function TForm1.EnsureMKVToolsAvailable(ANeedMKVMerge,
  ANeedMKVPropEdit: Boolean): Boolean;
  // mkvmerge and mkvpropedit are discovered together in ValidateAndDiscoverTools
  // (deliberately - see its sibling-fallback comment: mkvmerge can be found
  // simply by looking next to an already-resolved mkvpropedit, and vice
  // versa), so re-validating them individually via EnsureToolAvailable would
  // fork that fallback logic into a second, divergent copy. Instead, if
  // either of the two tools this caller actually needs has gone stale, this
  // re-runs the full ValidateAndDiscoverTools pass - which re-populates
  // both g.FilePathMKVMerge and g.FilePathMKVPropEdit together - and only
  // then reports whether the specific tool(s) the caller asked about came
  // back available.
begin
  Result :=
    ((not ANeedMKVMerge) or (g.FilePathMKVMerge.Value.IsNotEmpty and
    g.FilePathMKVMerge.Exists)) and ((not ANeedMKVPropEdit) or
    (g.FilePathMKVPropEdit.Value.IsNotEmpty and g.FilePathMKVPropEdit.Exists));
  if Result then Exit;
  DebugLog('EnsureMKVToolsAvailable: mkvmerge/mkvpropedit stale, ' +
    're-running ValidateAndDiscoverTools');
  ValidateAndDiscoverTools;
  Result :=
    ((not ANeedMKVMerge) or (g.FilePathMKVMerge.Value.IsNotEmpty and
    g.FilePathMKVMerge.Exists)) and ((not ANeedMKVPropEdit) or
    (g.FilePathMKVPropEdit.Value.IsNotEmpty and g.FilePathMKVPropEdit.Exists));
  if not Result then LogError(
      'EnsureMKVToolsAvailable: mkvmerge/mkvpropedit still ' +
      'unavailable after re-discovery');
end;

function TForm1.EnsureToolAvailable(var AFilePath: TFilePath;
  var AWinePrefix: String;
  const ALinuxExeName, AWindowsExeName, AVersionArg: String): Boolean;
  // Re-validates a single tool path cached in g.FilePath* at startup
  // (ValidateAndDiscoverTools) before each actual use, rather than trusting
  // that cache for the rest of the session. Startup discovery already
  // extracts proactively from filey-src.zip when nothing is found on PATH
  // (see DiscoverExternalTool) - this closes the remaining gap where a
  // bundled .exe that existed at startup is later deleted, moved, or
  // corrupted out from under an already-cached path (mirrors the
  // EnsureOpenSSLDllsPresent/InitSSLInterface fix above, for the same
  // underlying "cached at startup, never re-checked" shape of bug).

  // Cheap on the common case: a single FileExists (no process spawn) covers
  // "still there, unchanged" and returns immediately. Only reaches for
  // ToolRunsOK/DiscoverExternalTool - both of which spawn a process - once
  // that first check already fails.
var
  sWinePrefix, sFileName: String;
begin
  Result := AFilePath.Value.IsNotEmpty and AFilePath.Exists;
  if Result then Exit;
  DebugLog(sb(['EnsureToolAvailable: "', AFilePath.Value,
    '" missing or empty - re-running DiscoverExternalTool for "',
    ALinuxExeName, '"/"', AWindowsExeName, '"']));
  AFilePath := DiscoverExternalTool(ALinuxExeName, AWindowsExeName,
    AVersionArg, sWinePrefix, sFileName);
  AWinePrefix := sWinePrefix;
  Result := AFilePath.Value.IsNotEmpty;
  if not Result then LogError(
      sb(['EnsureToolAvailable: "', ALinuxExeName, '"/"',
      AWindowsExeName, '" still unavailable after re-discovery']));
end;

procedure TForm1.EpsAfterScroll(DataSet: TDataSet);
begin
  ShowStatusDBF(dbEps);
end;

procedure TForm1.EpsBeforeScroll(DataSet: TDataSet);
begin
  ShowStatusDBF(dbEps);
end;

// Brings AFileName in g.OpPath up to date with the copy in filey-src.zip
// (g.FilePathSourceZip): extracted when missing and - unless
// AOnlyIfMissing - replaced when it isn't this build's copy (one an older
// build left, or damaged since; see uUtils.IsExtractedFileCurrent).
// AOnlyIfMissing is for files Filey itself writes to after extracting them
// (CheckResourceFiles' SeedFiles), which must never be replaced. True if
// the file is there afterwards - and, when checked, current.
function TForm1.ExtractFromSourceZip(const AFileName: String;
  AOnlyIfMissing: Boolean): Boolean;
var
  DiskFileName, ZipFileName: String;
  Progress: Zipper.TProgressEvent;
begin
  // Wrapper lives on TForm1 so uUtils doesn't need access to the g global
  // (source zip path comes from g).
  DiskFileName := CombinePath(g.OpPath, AFileName);
  ZipFileName := g.FilePathSourceZip.Value;
  // Already there (and current): nothing to extract, so nothing to show.
  if AOnlyIfMissing then
  begin
    if FileExists(DiskFileName) then Exit(True);
  end
  else if uUtils.IsExtractedFileCurrent(ZipFileName, AFileName,
    DiskFileName) then Exit(True);
  // Outside CheckResourceFiles (a tool re-discovered by EnsureToolAvailable
  // in the middle of a rename, the Linux desktop icon, ...) this stays
  // silent: switching the user to the Progress page in the middle of some
  // other operation would be worse than showing no progress at all.
  Progress := nil;
  if FIsCheckingResources then
  begin
    ShowExtractProgress(AFileName);
    Progress := @ZipperProgress;
  end;
  Result := uUtils.ReplaceFromZip(ZipFileName, AFileName, DiskFileName,
    Progress);
  if Result and FIsCheckingResources then Inc(FExtractedCount);
end;

procedure TForm1.ExtractResourceToObject(const AFileName: TFilePath;
  AObject: TObject);
var
  dlg: TSmartManagedDialog;
begin
  // 1. Exit Clause Waterfall
  if not Assigned(AObject) then Exit;
  if (AObject is TSynEdit) and (TSynEdit(AObject).Lines.Count > 0) then Exit;
  if (AObject is THtmlViewer) and
    (Length(THtmlViewer(AObject).DocumentSource) > 0) then Exit;
  // 2. Extraction
  try
    // ExtractFileFromZip below opens g.FilePathSourceZip.Value from DISK via
    // TSmartUnZipper - it never touches an in-memory resource stream, so
    // there is nothing to set up here.
    MyObject := AObject;
    uUtils.ExtractFileFromZip(g.FilePathSourceZip.Value, AFileName,
      @OnZipEntryExtracted); // No s.Free needed!
  except
    on E: Exception do
    begin
      // Update the status bar as requested
      StatusBar.Panels[0].Text := 'Error: ' + E.Message;
      // Use your DialogID system instead of haphazard booleans
      dlg.Setup('ExtractFail_' + AFileName);
      // Unique ID based on the file
      dlg.Value.Caption := 'Extraction Error';
      dlg.Value.Text := 'Failed to extract ' + AFileName.Value;
      dlg.Value.ExpandedText := E.Message;
      dlg.Value.MainIcon := tdiError;
      // Execute will automatically check the INI to see if this ID is "Silenced"
      dlg.Execute;
    end;
  end;
end;

// Makes filey-src.zip in g.OpPath (g.FilePathSourceZip, which everything
// else is extracted from) the archive embedded in this executable: written
// when missing, and replaced when it is another build's. Only the sizes
// and central directories are compared (uUtils.SameZipArchive), so an
// up-to-date copy costs a few KB of reading, not the whole archive.
function TForm1.ExtractZipResourceIfStale(aResourceName: String): Boolean;
var
  s: TSmartResourceStream;
  OrigResourceName, sDiskName, sTempName: String;

  // True if sDiskName already holds exactly the embedded archive. One that
  // can't be read counts as stale, so it gets rewritten.
  function DiskCopyIsCurrent: Boolean;
  var
    fs: TSmartFileStream;
  begin
    Result := False;
    if not FileExists(sDiskName) then Exit;
    try
      fs.Setup(sDiskName, fmOpenRead or fmShareDenyWrite);
      Result := SameZipArchive(s.Value, fs.Value);
    except
      on E: Exception do
        LogError(sb(['ExtractZipResourceIfStale: could not compare "',
          sDiskName, '" with the embedded archive']), E);
    end;
  end; // fs is closed here

  // Copies the embedded archive to sTempName. Nested so that fs - and with
  // it sTempName - is closed before the caller renames it.
  procedure WriteTempCopy;
  var
    fs: TSmartFileStream;
  begin
    fs.Setup(sTempName, fmCreate);
    s.Value.Position := 0;
    // During startup this is the single biggest copy Filey makes - the
    // archive carries ffprobe.exe, mkvmerge.exe and mkvpropedit.exe - so it
    // gets the same name-and-percentage treatment as every file later
    // extracted from it. ShowExtractProgress comes after s.Setup, so a
    // missing resource never flashes the Progress page.
    if FIsCheckingResources then
    begin
      ShowExtractProgress(OrigResourceName);
      CopyStreamWithProgress(s.Value, fs.Value, @ZipperProgress, Self);
    end
    else
      fs.Value.CopyFrom(s.Value, s.Value.Size);
  end;

begin
  if aResourceName.IsBlank then Exit(False);
  OrigResourceName := aResourceName;
  // Deliberately a direct path in g.OpPath, NOT FileSearch. FileSearch's
  // sfoImplicitCurrentDir flag ALWAYS checks the process's current working
  // directory first, ahead of (and regardless of) the DirList passed in -
  // so if Filey is ever launched from a directory that happens to also
  // contain a "filey-src.zip" (e.g. the project/build directory during
  // development), FileSearch reports a false-positive match from CWD and
  // the real g.OpPath copy is never checked, let alone populated. That
  // silently skipped the real extraction and left g.FilePathSourceZip
  // pointing at a file that was never actually written to OpPath - the
  // root cause of every downstream "from ''" extraction failure,
  // independent of and in addition to the resource-name-casing issue fixed
  // below. The on-disk name is the one g.FilePathSourceZip uses (the name
  // as passed in), not aResourceName, which by the time the resource is
  // looked up holds the UPPERCASE resource-lookup name.
  sDiskName := CombinePath(g.OpPath.Value, OrigResourceName);
  sTempName := sDiskName + '.part';
  // The embedded RT_RCDATA resource itself, in contrast, is registered
  // under UpperCase(filename) - that's what Lazarus's own <Resources>
  // block in filey.lpi ("FILEY-SRC.ZIP") compiles into filey.res, which is
  // what {$R *.res} in filey.lpr actually links in. Looking this up with
  // the lowercased name (as before) silently failed to find the resource
  // on this platform, which is exactly the "g.FilePathSourceZip.Value
  // empty" symptom this function's own diagnostic comment below describes.
  aResourceName := UpperCase(OrigResourceName);
  // TEMPORARY DIAGNOSTIC - remove once the Wine embedded-resource extraction
  // failure is confirmed/fixed. TResourceStream.Create (inside s.Setup)
  // raises if aResourceName isn't found as an RT_RCDATA resource in this
  // executable - previously that exception propagated uncaught out of here,
  // out of CheckResourceFiles, and up through the TForm1 constructor chain.
  // g.FilePathSourceZip.Value being empty in the field (mkvmerge.exe
  // extraction failing with 'from "" to ...') was this resource lookup
  // failing: filey.lpi's <Resources> block embeds the archive with
  // ResourceName="FILEY-SRC.ZIP" (Lazarus always upper-cases the filename
  // for the auto-generated .res that {$R *.res} in filey.lpr links in),
  // but this code was looking it up as lowercase "filey-src.zip" - a name
  // that resource simply isn't registered under, so s.Setup raised every
  // time on every platform, not just under Wine. Fixed by looking the
  // resource up under UpperCase(OrigResourceName) instead. Logging +
  // catching here still turns a failure into a recoverable, diagnosable
  // one, e.g. if a future rename of the embedded resource reintroduces a
  // mismatch.
  Result := False;
  try
    {$IFDEF WINDOWS}
    s.Setup(HInstance, aResourceName, Windows.RT_RCDATA);
    {$ELSE}
    s.Setup(HInstance, aResourceName, RT_RCDATA);
    {$ENDIF}
    // Opened first because it is what the copy on disk is compared with.
    if DiskCopyIsCurrent then Exit(True);
    // Written beside it and then moved over it, so an interrupted copy
    // never leaves a truncated archive behind.
    DeleteIfExists(sTempName); // left over from an interrupted run
    WriteTempCopy;
    if not MoveFileOver(sTempName, sDiskName) then
      raise Exception.Create(sb(['could not replace "', sDiskName,
        '" (in use?)']));
    if FIsCheckingResources then Inc(FExtractedCount);
    Result := True;

    if IsDebugBuild then
      DebugLog(sb(['ExtractZipResourceIfStale: extracted "',
        OrigResourceName, '" (looked up as "', aResourceName,
        '") to "', sDiskName, '", ', s.Value.Size, ' bytes']));
  except
    on E: Exception do
    begin
      Result := False;
      DeleteIfExists(sTempName);
      LogError(sb(['ExtractZipResourceIfStale: could not extract "',
        OrigResourceName, '" (looked up as "', aResourceName,
        '") from this executable''s embedded RT_RCDATA resources - ',
        IfThen(FileExists(sDiskName),
        'the copy already in OpPath is used this run.',
        'g.FilePathSourceZip and everything extracted from it will be ' +
        'unavailable this run.')]), E);
    end;
  end;
end;

procedure TForm1.FilterEpsOnTitle(DataSet: TDataSet; var Accept: Boolean);
begin
  // No variable assignments, no string searches, no redundant property updates.
  if FDbf[dbEps].aFilterText.IsEmpty then Accept := True
  else
    // FTitleField is a direct pointer to the data buffer
    Accept := (FTitleField.AsString = FDbf[dbEps].aFilterText);
end;

procedure TForm1.FilterLogOnUndo(DataSet: TDataSet; var Accept: Boolean);
begin
  FDbf[dbLog].aFilterDescription := 'SELECTED';
  Accept := GetUndo;
end;

procedure TForm1.FilterShowsOnDirInTitle(DataSet: TDataSet;
  var Accept: Boolean);
begin
  Accept := True;
  if DataSet.Active then
  begin
    { Set the description explicitly}
    FDbf[dbShows].aFilterDescription :=
      'DIRinTITLE';
    if FDbf[dbShows].aFilterText = '' then Accept := True
    else
      { Using DataSet directly is faster and clearer than calling GetShowsDirectory}
      { but if GetShowsDirectory is required for specific logic, use the explicit reference:}
      Accept := UTF8ContainsText(DataSet.FieldByName('DIRECTORY').AsString,
        FDbf[dbShows].aFilterText);
  end;
end;

procedure TForm1.FilterShowsOnExactTitle(DataSet: TDataSet;
  var Accept: Boolean);
begin
  Accept := True;
  // 1. Safety check
  if DataSet.Active then
  begin
    // 2. Set the Filter Description using explicit array indexing
    // Note: We use FDbf[dbEps].aFilterText instead of the naked 'aFilterText'

    FDbf[dbShows].aFilterDescription := g.ExactFind;
    // 3. Perform the actual filter logic
    // Using DataSet directly (passed as parameter) is more reliable than aDB
    Accept := UTF8ContainsText(DataSet.FieldByName('SEARCHTHIS').AsString,
      g.ExactFind);
  end;
end;

procedure TForm1.FilterShowsOnTitleDir(DataSet: TDataSet; var Accept: Boolean);
begin
  // Broad match: Keep the list populated with anything containing the string

  // This allows the user to see "Preacher" in the grid if "Reacher" isn't exactly what they wanted.
  Accept := UTF8ContainsText(DataSet.FieldByName('TITLE').AsString,
    FDbf[dbShows].aFilterText) or UTF8ContainsText(
    DataSet.FieldByName('DIRECTORY').AsString, FDbf[dbShows].aFilterText);
end;

// Packs the table, rebuilds the TITLE index, and reports the outcome.
// Only reached when the loop above finished without a shutdown request.
procedure TForm1.FinalizeShowsImport(aDB: TDbf; ProcessedCount: Integer;
  const StartTime: TDateTime);
begin
  ProgressLabel.Caption := 'Finalizing indexes...';
  UI.Check;
  PackThisTable(aDB);
  DBFRecordCountChanged(aDB);
  AddIndexExclusive(aDB, 'TITLE', 'TITLE', [ixCaseInsensitive, ixunique]);
  aDB.IndexName := 'TITLE';
  // Every row was just keyed by ImportShowsRows with the current Key, so
  // RefreshShowsSearchKeys has nothing to do.
  SearchKeysAreCurrent;
  StatusBar.Panels[0].Text :=
    Format('Synced %d records in %d seconds',
    [ProcessedCount, SecondsBetween(Now, StartTime)]);
  pcMain.ActivePage := tsShows;
  DebugLog('SyncShowsDatabase completed - end.');
end;

function TForm1.FindExecutableFile(const FileName: String): String;
begin
  Result := '';
  try
    Result := FindDefaultExecutablePath(FileName);
  except
    on E: Exception do
    begin
      LogError(sb(['Error finding executable: ', FileName]), E);
      Result := '';
    end;
  end;
end;

function TForm1.FindMyTitle(const sFind: String): String;
var
  db: TDbf;
  Guard: TDataLayoutGuard;
begin
  Result := '';
  db := FDbf[dbShows].aDB;
  Guard := TDataLayoutGuard.Create(db);
  // Speed up the scan
  //g.ExactFind := sb(['|', Trim(UTF8UpperCase(sFind)), '|']);
  g.ExactFind := sFind.Key; //standardize Title with KEY stringhelper
  db.OnFilterRecord := @FilterShowsOnExactTitle;
  db.Filtered := True;
  DBFRecordCountChanged(db); // filter changed what ExactRecordCount reports
  db.First;
  if db.ExactRecordCount = 1 then Result := GetShowsTitle;
  if Result <> '' then Exit;
  // This ensures the Grid is populated with all potential candidates
  // (Reacher, Preacher, etc) just in case we need to show the dialog.
  FDbf[dbShows].aFilterDescription := 'TITLE';
  FDbf[dbShows].aFilterText := Trim(UTF8UpperCase(sFind));
  db.OnFilterRecord := @FilterShowsOnTitleDir;
  db.Filtered := True;
  DBFRecordCountChanged(db); // filter changed again
  db.First;
  //DebugLog('Broad Found count= ' + db.ExactRecordCount.toString);
  //SelectAShow;
  Result := GetShowsTitle;
  DebugLog('FindMyTitle, Result= ' + Result);
end;

function TForm1.FindPathTo(const sFind: String): String;
begin
  Result := ExcludeTrailingPathDelimiter(
    FileSearch(sFind, sb([g.OpPath.Value, PathSeparator,
    GetEnvironmentVariable('PATH')]), [sfoImplicitCurrentDir]));
end;

function TForm1.FindTitleByDirectory: String;
begin
  Result := '';
  try
    Result := FindMyTitle(GetDeepestDir(GetListFromPath));
    DebugLog('FindTitleByDirectory, Result= ' + Result);
  except
    on E: Exception do
    begin
      LogError('Error finding title by directory', E);
      Result := '';
    end;
  end;
end;

function TForm1.FindTitleByEpisodeName: String;
var
  db: TDbf;
  sFind, sEpRaw: String;
  Guard: TDataLayoutGuard;
begin
  Result := '';
  sFind := GetListEpName;   //ep name from file list, not scraped database
  // Exit if there is no name to search for, or if the file itself is just "Pilot"
  if (sFind = '') or SameText(sFind, 'Pilot') then Exit;
  db := FDbf[dbEps].aDB;
  Guard := TDataLayoutGuard.Create(db);
  StatusBar.Panels[0].Text := 'Searching for Title by Episode Name...';
  FDbf[dbEps].aFilterText := GetListTitle;
  SetFilterEpsOnTitle;
  DownLoadEps;
  db.First;
  while not db.EOF do
  begin
    //DownLoadEps(Sender);  //probably doesn't belong in this loop
    sEpRaw := GetEpsSortOrder; // Example: "REACHERS01E01PILOT"
    // Check if 'S01E01PILOT' is CONTAINED inside the SortOrder,
    // rather than trying to match it perfectly.
    if (not UTF8ContainsText(sEpRaw, 'S01E01PILOT')) and
      UTF8ContainsText(sEpRaw, sFind) then
    begin
      Result := GetEpsTitle;
      Break; // Found it!
    end;
    db.Next;
  end;
  DebugLog('FindTitleByEpisodeName, Result= ' + Result);
end;

function TForm1.FindTitleWithYear: String;
begin
  Result := '';
  try
    Result := FindMyTitle(sYearAndEpNumOnlyNoEpName);
  except
    on E: Exception do
    begin
      LogError('Error finding title with year', E);
      Result := '';
    end;
  end;
  DebugLog('FindTitleByEpisodeName, Result= ' + Result);
end;

function TForm1.FindYear(const sInputname: String): String;
begin
  Result := FindYearExec(sInputname, '(19|20)\d{2}');  // find: 1900-2099
end;

function TForm1.FindYearExec(const sInputname, sExpr: String): String;
var
  sCleanName: String;
  YearRegEx: TSmartRegEx;
begin
  Result := '';
  g.Year := '';
  g.Title := '';
  g.EpName := '';
  sCleanName := efn(sInputname);
  if sCleanName.IsBlank or sExpr.IsBlank then Exit;
  if not HasValidFileNameChars(sCleanName, False) then Exit;
  YearRegEx.Value.Expression := sExpr;
  if not YearRegEx.Value.Exec(sInputname) then Exit;
  g.Year := YearRegEx.Value.Match[0];
  FPieces.Value.Clear;
  YearRegEx.Value.Split(sInputname, FPieces.Value);
  if FPieces.Value.Count > 0 then g.Title := FPieces.Value.Strings[0];
  if FPieces.Value.Count > 1 then g.EpName := FPieces.Value.Strings[1];
  Result := g.Year;
  DebugLog('FindYearExec, Result= ' + Result);
end;

procedure TForm1.FitStatusBarHeight;
var
  bmp: TSmartBitmap;
begin
  bmp.Value.Canvas.Font.Assign(StatusBar.Canvas.Font);
  StatusBar.Height := bmp.Value.Canvas.TextHeight('Wg') + 6;
end;

procedure TForm1.ForceDBGridLogInCellEditing;
begin
  // Ensure dataset is active and not readonly
  if Assigned(DBGridLog.DataSource) and
    Assigned(DBGridLog.DataSource.DataSet) and not
    (DBGridLog.DataSource.DataSet.State in [dsEdit, dsInsert]) then
    DBGridLog.DataSource.DataSet.Edit;
  // Set proper options
  DBGridLog.Options :=
    DBGridLog.Options + [dgRowSelect, dgEditing, dgAlwaysShowEditor,
    dgCellHints] - [dgAlwaysShowSelection];
  // Ensure grid properties
  DBGridLog.ReadOnly := False;
  DBGridLog.AutoEdit := True;
  // Force editor mode
  DBGridLog.EditorMode := True;
end;

procedure TForm1.FormActivate(Sender: TObject);
begin
  //if First Run, then width = all buttons at current font size
  if not FileExists(g.IniFileName) then
    Form1.Width := ToolBarWidthSize(ToolBarFiles);
end;

procedure TForm1.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  FIsShuttingDown := True;
end;

procedure TForm1.FormCreate(Sender: TObject);
begin
  FEpisodeMatcher := TEpisodeMatcher.Create;
  FEpisodeMatcher.OnSanitizeFileName := @uUtils.FixWinFileName;
  // 150ms comfortably absorbs same-action multi-handler bursts (e.g. a
  // single keystroke firing KeyPress/KeyUp/Change in succession, or
  // tsShowsShow's queued AfterShowsShow follow-up) while staying well
  // under normal inter-keystroke typing speed, so a deliberate second
  // keystroke still gets its own column refresh.
  FShowsColumnsThrottle := TThrottledUI.Create(150);
  Application.AddOnActivateHandler(@AppActivate);
  // InitializeDBFs no longer runs here. It needs CheckResourceFiles to have
  // extracted SHOWS.DBF on a first run, and SetupDbShows -> SyncShowsDatabase
  // can spend a long time importing allshows.txt behind a Progress page that
  // nobody could see while the form wasn't on screen yet. Both now run from
  // DeferredStartup, queued by FormShow. That is also later than the "every
  // owned component fully realized" point this call was originally moved
  // here from TForm1.Create to reach, so the Wine AV that move fixed stays
  // fixed.
end;

procedure TForm1.FormDestroy(Sender: TObject);
begin
  // DeferredStartup (queued by FormShow) and AfterEpsShow/AfterShowsShow are
  // queued with Application.QueueAsyncCall. If the form goes away before one
  // of them has run, nothing may call into it afterwards.
  Application.RemoveAsyncCalls(Self);
  Application.RemoveOnActivateHandler(@AppActivate);
  // A terminal opened for an install command stays open; only filey's
  // wait for it ends here.
  if Assigned(FInstallTimer) then FInstallTimer.Enabled := False;
  FreeAndNil(FInstallTerminal);
  // A Browser tab download that was stopped may still be finishing a
  // request (a connection attempt can't be interrupted). Give it a moment
  // rather than unloading OpenSSL underneath it.
  WaitForBrowserThreads(2000);

  // Must run before `inherited Destroy`'s automatic owner-cascade gets to
  // the source-view controls. FSourceManager.AddSourceView creates each
  // TabSheet/BitBtn/EditButton/Panel/SynEdit with its LCL parent as OWNER
  // (not just visual Parent), so the LCL will free all of them on its own
  // the moment the owning PageControl is destroyed - which happens
  // automatically as part of TForm1's own teardown, with no way for
  // FSourceManager's record fields to find out.

  // Normally that's harmless: tsSourceCodeExit already calls
  // FSourceManager.Clear the moment you leave that tab, which empties the
  // arrays, so the record's own Finalize operator later finds nothing to
  // do. But if the app closes while tsSourceCode is still the active tab,
  // tsSourceCodeExit never fires - so FTabSheets/FBitBtnNexts/etc are
  // still populated when TForm1 starts destructing. The LCL's automatic
  // cascade then frees the controls first (as a side effect of freeing
  // the PageControl), and FSourceManager's Finalize - which runs only
  // AFTER TForm1.Destroy's inherited chain completes - tries to free them
  // again. Assigned() doesn't catch this: the pointer isn't nil, it's
  // just dangling, so the second Free is a genuine double-free -> GPF.

  // Calling Clear here guarantees it always runs exactly once, on live
  // objects, before that cascade starts - so there's nothing left for the
  // automatic cascade OR the later record Finalize to double-free.
  FSourceManager.Clear;
  FreeAndNil(FEpisodeMatcher);
end;

procedure TForm1.FormDropFiles(Sender: TObject;
  const FileNames: array of String);
var
  Files: TSmartStrings; // Managed record - no .Create/.Free required!
  i: Integer;
begin

  // Drops reach the form even while TSmartBusyState has every control
  // disabled, and AddFiles needs LIST.DBF, which isn't open until
  // DeferredStartup finishes.
  if FIsStartingUp then Exit;
  for i := Low(FileNames) to High(FileNames) do Files.Value.Add(FileNames[i]);

  if Files.Value.Count <= 0 then Exit;
  AddFiles(Files.Value);
end;

procedure TForm1.FormResize(Sender: TObject);
begin
  if not Self.Showing then Exit;
  Self.DisableAutoSizing;
  try
    DBGridListSetColumnWidths;
    StatusBar.Panels[0].Width := StatusBar.Width - 2;
    // Maintain fixed column after resize
    if Assigned(DBGridLog) and (DBGridLog.Columns.Count > 0) then
      g.IsFormSnapped := (Self.Width = Screen.WorkAreaWidth div 2) or
        (Self.Width = Screen.WorkAreaWidth);
  finally
    Self.EnableAutoSizing;
  end;
end;

procedure TForm1.FormShow(Sender: TObject);
begin
  // Queued rather than called: OnShow fires from inside Show, before the
  // window has been painted even once. One-shot, because OnShow fires again
  // whenever Visible goes False -> True.
  if FStartupQueued then Exit;
  FStartupQueued := True;
  Application.QueueAsyncCall(@DeferredStartup, 0);
end;

procedure TForm1.FormShowHint(Sender: TObject; HintInfo: PHintInfo);
var
  c: Integer = 0;
  R: Integer = 0;
begin
  if (HintInfo^.HintControl <> DBGridLog) or Self.IsResizing or
    not Self.Showing then Exit;
  Self.DisableAlign;
  R := 0;
  c := 0;
  DBGridLog.MouseToCell(HintInfo^.CursorPos.X,
    HintInfo^.CursorPos.Y, c, R);
  HintInfo^.CursorRect := DBGridLog.CellRect(c, R);
  HintInfo^.HintStr := 'R= ' + IntToStr(R) + #13 + 'C=' + IntToStr(c);
  DBGridLog.Hint := HintInfo^.HintStr;
  Self.EnableAlign;
end;

function TForm1.GetDbField(aDbType: TDbType; const aField: String): String;
begin
  Result := SafeGetDbField(aDbType, aField);
end;

function TForm1.GetEpName(const curFile: String): String;
var
  curFileNameOnly: String = '';
  EpisodeNumber: String = '';
  Match: TEpisodeMatch;
begin
  Result := '';
  PanelFilesGrid.ShowHint := True;
  if Length(curFile) = 0 then Exit;
  curFileNameOnly := efnOnly(curFile);
  if Length(curFileNameOnly) = 0 then Exit;
  Match := FEpisodeMatcher.GetEpNumName(curFile);
  if not Match.Found then
  begin
    // Fallback: Use cleaned filename as title if no episode number found
    SetListTitle(FixWinFileName(curFileNameOnly));
    Exit;
  end;
  g.EpNum := Match.EpNum;
  g.EpName := Match.EpName; // Explicit global assignment!
  EpisodeNumber := Match.EpNum;
  Result := FEpisodeMatcher.ExtractEpisodeName(curFile, EpisodeNumber);
  SetListEpName(Result);
  // Extract title (everything before episode number)
  SetListTitle(FEpisodeMatcher.ExtractTitleFromFilename(curFile,
    EpisodeNumber));
  DebugLog('GetEpName, Result= ' + Result);
end;

function TForm1.GetEpsEpName: String;
begin
  Result := SafeGetDbField(dbEps, 'EPNAME');
end;

function TForm1.GetEpsSortOrder: String;
begin
  Result := SafeGetDbField(dbEps, 'SORTORDER');
end;

function TForm1.GetEpsTitle: String;
begin
  Result := SafeGetDbField(dbEps, 'TITLE');
end;

function TForm1.GetGridForDataset(const aDB: TDbf): TDBGrid;
var
  i: Integer;
  CurrentGrid: TDBGrid;
begin
  Result := nil;
  if aDB = nil then Exit;
  // Walk through every component owned by the Form
  for i := 0 to ComponentCount - 1 do
  begin
    // Guard 1: Skip if it's not a TDBGrid
    if not (Components[i] is TDBGrid) then Continue;
    CurrentGrid := TDBGrid(Components[i]);
    // Guard 2: Skip if there's no DataSource assigned
    if not Assigned(CurrentGrid.DataSource) then Continue;
    // Guard 3: Skip if it doesn't point to our dataset
    if CurrentGrid.DataSource.DataSet <> aDB then Continue;
    // If it survived all guards, we found our match!
    Result := CurrentGrid;
    Break;
  end;
end;

function TForm1.GetListEpName: String;
begin
  Result := SafeGetDbField(dbList, 'EPNAME');
end;

function TForm1.GetListEpNum: String;
begin
  Result := SafeGetDbField(dbList, 'EPNUM');
end;

function TForm1.GetListExt: String;
begin
  Result := SafeGetDbField(dbList, 'EXTENSION');
end;

function TForm1.GetListFrom: String;
begin
  Result := SafeGetDbField(dbList, 'FROM');
end;

function TForm1.GetListFromPath: String;
begin
  Result := SafeGetDbField(dbList, 'FROMPATH');
end;

function TForm1.GetListTitle: String;
begin
  Result := SafeGetDbField(dbList, 'TITLE');
end;

function TForm1.GetListTo: String;
begin
  Result := SafeGetDbField(dbList, 'TO');
end;

function TForm1.GetListTreeLevel: String;
begin
  Result := SafeGetDbField(dbList, 'TREELEVEL');
end;

procedure TForm1.GetMKVAttributes(const curFile: String);
var
  db: TDbf;
  checkdup, sCodec, sHeight, sAudioChan, sSubtitles: String;
  s: String = '';
begin
  s := ProbeFile(curFile);
  db := FDbf[dbList].aDB;
  db.Edit;
  {checkdup prevents re-adding info that's already there}
  checkdup := db.FieldByName('TO').AsString;
  sCodec := UTF8UpperCase(ExtractAfterStr('codec_name=', s));
  if UTF8ContainsText(sCodec, '264') then sCodec := 'x264';
  if UTF8ContainsText(checkdup, sCodec) then sCodec := '';
  sHeight := ExtractAfterStr('height=', s);
  if UTF8ContainsText(checkdup, sHeight) then sHeight := '';
  sAudioChan := ExtractAfterStr('channels=', s);
  if sAudioChan = '2' then sAudioChan := '';
  if sAudioChan = '6' then sAudioChan := 'DD5.1';
  if UTF8ContainsText(s, 'codec_name=eac3') or
    UTF8ContainsText(s, 'E-AC-3,') then sAudioChan := 'EAC3' + sAudioChan;
  if UTF8ContainsText(s, 'codec_name=mp3') then sAudioChan := 'MP3';
  if UTF8ContainsText(checkdup, sAudioChan) then sAudioChan := '';
  sSubtitles :=
    IfThen(UTF8ContainsText(s, '=SubRip ') or UTF8ContainsText(s, '=subtitle'),
    'Subs', '');
  if UTF8ContainsText(checkdup, sSubtitles) then sSubtitles := '';
  db.FieldByName('CODEC').AsString := sCodec;
  db.FieldByName('HEIGHT').AsString := sHeight;
  db.FieldByName('AUDIOCHAN').AsString := sAudioChan;
  db.FieldByName('SUBTITLES').AsString := sSubtitles;
  db.Post;
end;

function TForm1.GetShowsDirectory: String;
begin
  Result := SafeGetDbField(dbShows, 'DIRECTORY');
end;

function TForm1.GetShowsLookUpDate: String;
begin
  Result := SafeGetDbField(dbShows, 'LOOKUPDATE');
end;

function TForm1.GetShowsSearchThis: String;
begin
  Result := SafeGetDbField(dbShows, 'SEARCHTHIS');
end;

function TForm1.GetShowsTitle: String;
begin
  Result := SafeGetDbField(dbShows, 'TITLE');
end;

function TForm1.GetStreamFromZipResource(
  const AMemoryTarget: String): TMemoryStream;
var
  LRes: TSmartResourceStream; // Cleans itself up
  LUnz: TSmartUnZipper; // Cleans itself up (assuming it's a record)
begin
  Result := nil;
  try
    LRes.Setup(HInstance, 'FILEY-SRC.ZIP', RT_RCDATA);
  except
    on E: EResNotFound do
    begin
      LogError('GetStreamFromZipResource: embedded source FILEY-SRC.ZIP missing', E);
      Exit; // Result stays nil - caller must handle this
    end;
  end;
  Result := LUnz.QuickExtractToStream(LRes.Value, 'FILEY-SRC.ZIP',
    AMemoryTarget);
  if Assigned(Result) then Result.Position := 0;
end;

function TForm1.GetSubtitleTrackInfo(const AFilePath: String;
  out AEnglishID: Integer): TSmartStrings;
var
  i, iExit, iID: Integer;
  oJSON: TJSONData;
  oRoot, oTrack, oProps: TJSONObject;
  oTracks: TJSONArray;
  sOutput, sLang, sLangIETF: String;
begin
  AEnglishID := -1;
  if not EnsureMKVToolsAvailable(True, False) then Exit;

  // Run mkvmerge once and capture its JSON track listing. RunCommand drains
  // stdout as the child writes it, so there's no poUsePipes/poWaitOnExit
  // deadlock risk here. A single invocation now serves both the full
  // subtitle-track list and the first-English-track lookup, where
  // previously each was fetched by a separate mkvmerge call.
  sOutput := RunEx(g.FilePathMKVMerge.Value, ['-J', AFilePath], iExit);

  // Don't gate on RunCommand's own boolean result: mkvmerge can exit
  // with a nonzero status on warnings while still emitting valid JSON
  // on stdout, so check the captured output itself instead.
  if Trim(sOutput) = '' then Exit;

  oJSON := GetJSON(sOutput);
  try
    if not (oJSON is TJSONObject) then Exit;
    oRoot := TJSONObject(oJSON);
    oTracks := oRoot.Get('tracks', TJSONArray(nil));
    if not Assigned(oTracks) then Exit;

    for i := 0 to oTracks.Count - 1 do
    begin
      oTrack := oTracks.Objects[i];
      if oTrack.Get('type', '') <> 'subtitles' then Continue;

      iID := oTrack.Get('id', -1);
      Result.Value.Add(IntToStr(iID));

      // Only the first matching English track is kept, mirroring the
      // original GetFirstEngSubTrackID behaviour.
      if AEnglishID = -1 then
      begin
        oProps := oTrack.Get('properties', TJSONObject(nil));
        if Assigned(oProps) then
        begin
          sLang := oProps.Get('language', '');
          sLangIETF := oProps.Get('language_ietf', '');
          if (sLang = 'eng') or sLangIETF.StartsWith('en') then
            AEnglishID := iID;
        end;
      end;
    end;
  finally
    FreeAndNil(oJSON);
  end;
end;

function TForm1.GetUndo: Boolean;
begin
  Result := FDbf[dbLog].aDB.FieldByName('UNDO').AsBoolean;
end;

function TForm1.HackFrom(const sFind: String;
  var s, sLeft, sRight: String): String;
var
  k: Integer = 0;
begin
  // sloppy routine to scrape info out of web pages
  k := UTF8Pos(sFind, s);
  if k = 0 then Result := ''
  else
  begin
    sRight := UTF8Copy(s, k + UTF8Length(sFind), MaxInt);
    sLeft := sLeft + UTF8Copy(s, 1, k);
    s := sRight;
    Result := s;
  end;
end;

function TForm1.HackTo(const sFind: String;
  var s, sLeft, sRight: String): String;
var
  k: Integer = 0;
begin
  // more sloppy routine to scrape info out of web pages
  k := UTF8Pos(sFind, s);
  if k = 0 then Result := ''
  else
  begin
    sRight := UTF8Copy(s, k + UTF8Length(sFind), MaxInt);
    sLeft := UTF8Copy(s, 1, k - 1);
    sLeft := ReplaceStr(sLeft, '&nbsp;', '');
    s := sRight;
    Result := sLeft;
  end;
end;

// For an address that isn't a page the Browser tab can show (a .zip, a
// PDF): the system's own program for it gets it, and the page on show
// stays.
procedure TForm1.HandBrowserPageToSystem(const AURL: String);
begin
  FBrowserHandedOff := True;
  if LCLIntf.OpenURL(AURL) then
    FBrowserStatus := sb(['Not a web page, so it was opened outside ',
      Application.Title, ': ', AURL])
  else
    FBrowserStatus := sb(['Not a web page, and no program is set up to ',
      'open it: ', AURL]);
  // The page on show hasn't changed, so neither should the address.
  if g.LastURL.IsNotBlank then edUrl.Text := g.LastURL;
end;

procedure TForm1.IHtmlViewer1LinkClick(Sender: TObject;
  const SRC: ThtString; var Handled: Boolean);
begin
  // Check if the link is a web URL
  if not SRC.StartsWith('http', True) then Exit;
  // This opens the link in the system's default web browser
  OpenURL(ansistring(SRC));
  // Set Handled to True so the viewer doesn't try to load the
  // HTML page internally (which usually fails for complex CSS/JS sites)
  Handled := True;
end;

// The main import loop: walks CSVLines (skipping the header), appends
// one aDB row per non-blank, well-formed line. Returns rows processed.
// Honors cancel/shutdown by breaking early, same as before.
function TForm1.ImportShowsRows(aDB: TDbf; const CSVLines: TSmartStrings;
  TotalLines: Integer; const StartTime: TDateTime): Integer;
var
  Fields: TSmartStrings; // RAII: For CSV line parsing
  CurrentLine, UpdateCounter: Integer;
  FldTitle, FldDir, FldSearch: TField; // looked up once, not per row
  sTitle: String = '';
  sDir: String = '';
const
  BATCH_SIZE = 250;
begin
  Fields.Setup(Self);
  Fields.Value.StrictDelimiter := True;
  Fields.Value.Delimiter := ',';
  FldTitle := aDB.FieldByName('TITLE');
  FldDir := aDB.FieldByName('DIRECTORY');
  FldSearch := aDB.FieldByName('SEARCHTHIS');
  CurrentLine := 1; // Skip header
  Result := 0;
  UpdateCounter := 0;
  while (CurrentLine < TotalLines) do
  begin
    if g.IsProgressCanceled or FIsShuttingDown then Break;
    if CSVLines.Value[CurrentLine].IsNotBlank then
    begin
      Fields.Value.DelimitedText := CSVLines.Value[CurrentLine];
      if (Fields.Value.Count >= 3) and not IsEmptyRecord(Fields.Value) then
      begin
        // Compute once into locals; don't read back from the record buffer.
        sTitle := DecodeHTMLEntities(Fields.Value[0].Trim).Replace(#10, '');
        sDir := Fields.Value[1].Trim;
        aDB.Append;
        FldTitle.AsString := sTitle;
        FldDir.AsString := sDir;
        FldSearch.AsString := ShowsSearchKey(sTitle, sDir);
        aDB.Post;
        Inc(Result);
        Inc(UpdateCounter);
      end;
    end;
    Inc(CurrentLine);
    if UpdateCounter >= BATCH_SIZE then
    begin
      ReportShowsImportProgress(CurrentLine, TotalLines, Result, StartTime);
      UI.Check;
      UpdateCounter := 0;
    end;
  end;
end;

procedure TForm1.InitializeDBFs;
begin
  // Table creation/opening itself now lives in uDBFManager.CreateAndOpenDBFs.
  // What's left here is genuinely UI: the busy cursor, and the grid/column
  // setup (SetupDbShows/SetupDbEps/SetupDbList/SetupDbLog) that has to run
  // after every table is open.
  SetAllCursors(crHourGlass);
  // rmOpenInPlace: a read-only table (optical media, permissions, ...) is
  // opened read-only and says why. A template program that needs to sort
  // or edit such data locally would pass rmWorkingCopy instead - see
  // uDBF.TReadOnlyMediaPolicy.
  CreateAndOpenDBFs(FDbf, Form1, g.OpPath, @DBGridListAfterScroll,
    @DBGridListBeforeScroll, @DBFRecordCountChanged,
    @ConfigureDBFDataSource, @DbfAccessChanged, rmOpenInPlace);
  SetupDbShows;
  SetupDbEps;
  SetupDbList;
  SetupDbLog;
  SetAllCursors(crDefault);
end;

// One-time SSL bring-up for the download below. Idempotent - safe to call
// on every sync, cheap on repeat calls. Retries once if the first failure
// looks like a missing-DLL problem that EnsureOpenSSLDllsPresent can fix.
function TForm1.InitializeShowsDownloadSSL: Boolean;
begin
  Result := False;
  // Unlike the HackFrom-based scrape below, which calls InitSSLInterface
  // explicitly right before its own first HTTPS use (see that call site's
  // comment, and uManagedUtils.pas's initialization section for why the
  // eager call was removed from there), this call site used to rely
  // entirely on TFPHTTPClient.SimpleGet's own fully-lazy auto-init. That
  // left it exposed to the same fragility described there - FPC's
  // InitSSLInterface takes a screenshot via _RandScreen on its first
  // successful call (freepascal.org/fpc/source#36045), and an
  // uninitialized SSL interface here previously surfaced downstream as
  // "Could not initialize OpenSSL library" with no clear point of origin.
  // InitSSLInterface is idempotent (early-exits if already loaded), so
  // calling it explicitly here - in the same deliberate, single-point
  // style as the other call site - costs nothing on repeat calls and
  // gives this path the same controlled initialization moment instead
  // of an implicit one. Its own openssl.pas implementation is what
  // determines and logs success/failure; not duplicated here.
  EnsureOpenSSLDllsPresent;
  try
    InitSSLInterface;
    Result := True;
  except
    on E: Exception do
    begin
      if UTF8ContainsText(E.Message, 'Could not initialize OpenSSL') and
        EnsureOpenSSLDllsPresent then
      begin
        try
          InitSSLInterface; // retry once, now that the DLLs are in place
          Result := True;
        except
          on E2: Exception do
            LogError('SyncShowsDatabase: InitSSLInterface retry failed', E2);
        end;
      end
      else
        LogError('SyncShowsDatabase: InitSSLInterface failed', E);
    end;
  end;
end;

procedure TForm1.InitializeVariables;
begin
  Video_File_Extensions.Value.Delimiter := ';';
  Video_File_Extensions.Value.StrictDelimiter := True;
  Video_File_Extensions.Value.DelimitedText :=
    '.MKV;.AVI;.ASF;.MPG;.WMV;.DIVX;.EVO;.F4V;.FLV;.MVK;.M4V;.MP4;.MPEG;' +
    '.M2P;.TS;.M2TS;.OGG;.OGV;.OGX;.MOV;.QT;.RMVB;.VOB;.WEBM';
  Video_File_Extensions.Value.Sorted := True;
  EpNameRegEx := SmartEpNameRegEx.GetValue;
  // This ensures you only match the link inside the eptitle cell
  EpNameRegEx.Expression := '<a[^>]*>(.*?)</a>';
  EpNameRegEx.ModifierI := True;  //Case-insensitive
  EpNameRegEx.ModifierS := True;  //Dot matches newlines
  EpNameRegEx.Compile;
  EpNumRegEx := SmartEpNumRegEx.GetValue;
  // The \s* matches any spaces, tabs, or newlines around the digits
  EpNumRegEx.Expression :=
    '(<td class=''epinfo left pad''>)\s*(\d{1,3}-\d{1,3})\s*(&nbsp;</td>)';
  EpNumRegEx.Compile;
  DebugLog('EpNumRegEx.Expression= ' + EpNumRegEx.Expression);
end;

// Wired in SetupBrowser. Fires once IpHtmlPanel1 has opened a page -
// whether BrowseToURL or Back/Forward asked for it.
procedure TForm1.IpHtmlPanel1DocumentOpen(Sender: TObject);
var
  List: TStringList;
  sURL: String;
begin
  // CurURL reads MasterFrame.FCurURL without checking MasterFrame first.
  if not Assigned(IpHtmlPanel1.MasterFrame) then Exit;
  sURL := IpHtmlPanel1.CurURL;
  if sURL.IsEmpty then Exit;
  g.LastURL := sURL;
  edUrl.Text := sURL;
  List := FBrowserHistory.Value;
  if FBrowserMovingInHistory then
  begin
    // Back/Forward: already in the list. Store it as the panel spelled it.
    if (FBrowserHistoryIndex >= 0) and (FBrowserHistoryIndex < List.Count) then
      List[FBrowserHistoryIndex] := sURL;
  end
  else if (FBrowserHistoryIndex < 0) or
    (List[FBrowserHistoryIndex] <> sURL) then
  begin
    // A new page: whatever was "forward" of the old one is dropped.
    while List.Count > FBrowserHistoryIndex + 1 do List.Delete(List.Count - 1);
    List.Add(sURL);
    FBrowserHistoryIndex := List.Count - 1;
  end;
  UpdateBrowserButtons;
end;

// Wired in SetupBrowser. IpHtmlPanel1 calls this in two cases:
// - a link was clicked. TFileyHttpDataProvider.CanHandle sends every link
//   here, so this decides what happens.
// - a page it was asked to open isn't one it can show. BrowseToURL checks
//   pages itself before IPro sees them, so this only happens for a frame
//   of a <frameset> page. HotURL is then its full address.
procedure TForm1.IpHtmlPanel1HotClick(Sender: TObject);
var
  IsLinkClick: Boolean;
  sHRef, sURL: String;
begin
  IsLinkClick := FBrowserProvider.TakeLinkClicked;
  sHRef := Trim(IpHtmlPanel1.HotURL);
  if sHRef.IsEmpty then Exit;
  if FIsBrowsing then
  begin
    // A link clicked while a page loads (the second click of a
    // double-click, say) is ignored. Only the page being loaded is
    // handed off.
    if not IsLinkClick then HandBrowserPageToSystem(sHRef);
    Exit; // BrowseToURL shows FBrowserStatus
  end;
  if sHRef[1] = '#' then
  begin
    IpHtmlPanel1.MakeAnchorVisible(Copy(sHRef, 2, MaxInt));
    Exit;
  end;
  // Links are usually relative to the page they're on.
  sURL := ResolveWebAddress(g.LastURL, sHRef);
  if not IsWebAddress(sURL) then
  begin
    // mailto: and the like
    if LCLIntf.OpenURL(sURL) then
      FBrowserStatus := sb(['Opened outside ', Application.Title, ': ', sURL])
    else
      FBrowserStatus := sb(['No program is set up to open ', sURL]);
    ShowStatusBrowser;
    Exit;
  end;
  // Queued rather than loaded here: this runs inside the page's own mouse
  // handler, and loading a new page frees the old one.
  FPendingBrowserURL := sURL;
  Application.QueueAsyncCall(@DeferredBrowse, 1);
end;

function TForm1.IsDbOpen(aDbType: TDbType): Boolean;
begin
  Result := Assigned(FDbf[aDbType].aDB) and FDbf[aDbType].aDB.Active;
end;

procedure TForm1.LazyLoadSourceCode;
var
  c, comp: TComponent;
  ini: TIniFile;
  Page: TTabSheet;
  Syn: TSynEdit;
begin
  if (pcMain.ActivePage <> tsAbout) or (pcAbout.ActivePage <> tsSourceCode) or
    (pcSourceCode.PageCount <> 0) then Exit;
  MakeSourceSheets;
  // The TIniFile actSouceCodeFontExecute and SaveConfiguration write to,
  // rather than a second one opened on the same file.
  ini := AppIni.Value;
  // Used to be guarded by "if pcSourceCode.PageCount = 0", which is never
  // true straight after MakeSourceSheets, so no saved font was applied.
  for c in pcSourceCode do
    if c is TTabSheet then
    begin
      Page := TTabSheet(c);
      for comp in Page do
        if comp is TSynEdit then
        begin
          Syn := TSynEdit(comp);
          // Keys: see WriteSourceCodeFont. Defaults are what
          // AddtsSourceCode already gave the editor.
          Syn.Font.Name := ini.ReadString('Main', Page.Name + '.Font.Name',
            Syn.Font.Name);
          Syn.Font.Size := ini.ReadInteger('Main', Page.Name + '.Font.Size',
            Syn.Font.Size);
        end;
    end;
  pcSourceCode.Realign; //realign inner PageControl's new children
end;

// Fetches the images of the page about to be shown - several at once, on
// background threads - into FBrowserProvider, where IPro finds them
// instead of downloading each one while it paints. ASources are the
// addresses as written in the page (SimplifyHtmlForViewer). Gives up after
// BROWSER_IMAGES_TIME_LIMIT_MS; images not in by then show as IPro's
// placeholder. Returns how many will be missing.
function TForm1.LoadBrowserImages(const APageURL: String;
  ASources: TStrings): Integer;
var
  Batch: TBrowserDownloadBatch;
  i: Integer;
  Item: TBrowserDownload;
  sAddress: String;
  Wanted: TSmartStrings;
begin
  Result := 0;
  for i := 0 to ASources.Count - 1 do
  begin
    // Resolved the way IPro resolves it (TIpHtml.BuildPath calls the
    // provider's BuildURL with the page address), so it is the same string
    // IPro will ask GetImage for.
    sAddress := FBrowserProvider.BuildURL(APageURL, ASources[i]);
    if (not IsWebAddress(sAddress)) or FBrowserProvider.HasImage(sAddress) or
      (Wanted.Value.IndexOf(sAddress) >= 0) then Continue;
    if Wanted.Value.Count >= BROWSER_MAX_IMAGES then Inc(Result)
    else
      Wanted.Value.Add(sAddress);
  end;
  if Wanted.Value.Count = 0 then Exit;
  Batch := TBrowserDownloadBatch.Create(Wanted.Value, False);
  try
    RunBrowserDownloads(Batch, BROWSER_IMAGE_WORKERS,
      BROWSER_IMAGES_TIME_LIMIT_MS, sb(['Loading images for ', APageURL]));
    for i := 0 to Batch.Count - 1 do
    begin
      Item := Batch.Finished(i);
      if Assigned(Item) and Item.OK then
        FBrowserProvider.AddImage(Item.URL, Item.Data)
      else
        Inc(Result);
    end;
  finally
    Batch.Release;
  end;
end;

// Shows ADoc, as FILEY-SRC.ZIP carries it, in AViewer. The copy inside the
// executable always matches the running build, where one extracted to
// g.OpPath may be left over from an older one. False (and logged), with
// AViewer left as it was, if the zip doesn't have ADoc.
function TForm1.LoadBundledDoc(var AViewer: TSmartHtmlViewer;
  const ADoc: String): Boolean;
var
  MS: TSmartMemoryStream;
  SrcStream: TMemoryStream;
begin
  Result := False;
  if not Assigned(AViewer.Value) then Exit;
  // GetStreamFromZipResource hands over a new stream the caller must free.
  // Take ownership with "MS.Value :=" (SetValue); MS.Value.LoadFromStream()
  // would copy it into another stream and leak the original, and would
  // crash on the nil it returns when the zip lacks ADoc.
  SrcStream := GetStreamFromZipResource(ADoc);
  if not Assigned(SrcStream) then
  begin
    LogError('Could not read from source zip: ' + ADoc);
    Exit;
  end;
  MS.Value := SrcStream;
  MS.Value.Position := 0;
  AViewer.Value.LoadFromStream(MS.Value);
  AViewer.Value.Invalidate;
  Result := True;
end;

procedure TForm1.LoadConfiguration(ini: TIniFile);

  // The one place the form and status-bar fonts are set at startup (SetupUI
  // used to set them too, AFTER this, which threw away whatever the ini
  // held). The constructor then copies Self.Canvas.Font to every control.
  procedure LoadFonts;
  var
    bUseSavedNames: Boolean = False;
    f: TFont;
    sMain: String = '';
    sStatus: String = '';
    iMain: Integer = DEFAULT_FORM_FONT_SIZE;
    iStatus: Integer = DEFAULT_STATUSBAR_FONT_SIZE;
    bMainBold: Boolean = False;
    bStatusBold: Boolean = True;
  begin
    if Assigned(ini) then
    begin
      bUseSavedNames := ini.ReadInteger('Main', 'FontSettingsVersion', 0) >=
        FONT_SETTINGS_VERSION;
      if bUseSavedNames then
      begin
        sMain := ini.ReadString('Main', 'Self.Canvas.Font.Name', '');
        sStatus := ini.ReadString('Main', 'StatusBar.Canvas.Font.Name', '');
      end;
      // Sizes and Bold were never overwritten, so they're kept from any ini.
      iMain := ini.ReadInteger('Main', 'Self.Canvas.Font.Size', iMain);
      bMainBold := ini.ReadBool('Main', 'Self.Canvas.Font.Bold', bMainBold);
      iStatus := ini.ReadInteger('Main', 'StatusBar.Canvas.Font.Size',
        iStatus);
      bStatusBold := ini.ReadBool('Main', 'StatusBar.Canvas.Font.Bold',
        bStatusBold);
    end;
    // Same limits the Font dialog enforces (see SetupUI).
    iMain := EnsureRange(iMain, MIN_FONT_SIZE, MAX_FONT_SIZE);
    iStatus := EnsureRange(iStatus, MIN_FONT_SIZE, MAX_FONT_SIZE);
    f := Self.Canvas.Font;
    f.Name := BestInstalledFont(sMain, DEFAULT_SERIF_FONTS, 'Serif');
    f.Size := iMain;
    f.Bold := bMainBold;
    f := StatusBar.Canvas.Font;
    f.Name := BestInstalledFont(sStatus, DEFAULT_MONO_FONTS, 'Monospace');
    f.Size := iStatus;
    f.Bold := bStatusBold;
    DebugLog(sb(['LoadConfiguration: fonts "', Self.Canvas.Font.Name, '" ',
      iMain, 'pt, status bar "', StatusBar.Canvas.Font.Name, '" ', iStatus,
      'pt', IfThen(bUseSavedNames, '', ' (default names)')]));
  end;

begin
  LoadFonts; // before the Exit below: the fonts need defaults regardless
  if not Assigned(ini) then Exit;
  OpenDialog.InitialDir := ini.ReadString('Main', 'InitialDir', '');
  Self.AutoSize := False; // Must be FALSE to restore window bounds
  SetBounds(Self,
    ini.ReadInteger('Main', 'Left', 530),
    ini.ReadInteger('Main', 'Top', 200),
    ini.ReadInteger('Main', 'Width', 846),
    ini.ReadInteger('Main', 'Height', 570));
  g.IsHideRenamedCount := False;

  g.IsHideSelectAShow := False;
  // CheckResourceFiles used to run here, inside the constructor, before the
  // form had been drawn. It now runs from DeferredStartup.
  g.IsCreateDesktopShortcut :=
    ini.ReadBool('Main', 'IsCreateDesktopShortcut', True);
  g.IsCreateMenuEntry := ini.ReadBool('Main', 'IsCreateMenuEntry', True);
  g.IsAskMoveAppImage := ini.ReadBool('Main', 'AskMoveAppImage', True);
  // Anything but the other value means the default.
  if SameText(Trim(ini.ReadString('Main', 'ReservedCharacters', '')),
    'underscore') then g.ReservedCharStyle := rcsUnderscore
  else
    g.ReservedCharStyle := rcsLookalike;
  if SameText(Trim(ini.ReadString('Main', 'WordSeparator', '')), 'dot') then
    g.WordSeparator := wsDot
  else
    g.WordSeparator := wsSpace;
end;

function TForm1.LoadResourceToString(const ResourceName: String): String;
var
  RS: TResourceStream;
  ss: TStringStream;
begin
  Result := '';
  try
    // 1. Create a stream targeting the compiled-in resource
    // RT_RCDATA is the standard type for arbitrary data files
    RS := TResourceStream.Create(HInstance, ResourceName, RT_RCDATA);
    try
      ss := TStringStream.Create('');
      try
        ss.CopyFrom(RS, RS.Size);
        Result := ss.DataString;
      finally
        ss.Free;
      end;
    finally
      RS.Free;
    end;
  except
    on E: Exception do
      // Return error info so you can see it in the THtmlViewer
      Result := '<html><body>Error loading resource: ' +
        ResourceName + '<br>' + E.Message + '</body></html>';
  end;
end;

// Loads ShowsFile into CSVLines (already Setup by the caller), correctly
// decoded. Returns the resulting line count.
function TForm1.LoadShowsCSV(const ShowsFile: String;
  const CSVLines: TSmartStrings): Integer;
begin
  // allshows.txt comes down from epguides.com as Windows-1252, not UTF-8
  // (see ProcessCP1252CSV's banner) - a plain LoadFromFile here lets the
  // CP1252 bytes get (mis)interpreted as UTF-8/system codepage, which is
  // exactly what produces mojibake for any show title with an accented or
  // curly-quote character. ProcessCP1252CSV decodes it properly and
  // clears/repopulates CSVLines.Value itself.
  ProcessCP1252CSV(CSVLines.Value, ShowsFile);
  Result := CSVLines.Value.Count;
end;

function TForm1.LocateRecordInBackground(aDB: TDbf; const FieldName: String;
  const Value: variant; Options: TLocateOptions = []): Boolean;
var
  SavedState: TDBGridState;
  Grid: TDBGrid = nil;
  Guard: TDataLayoutGuard;
begin
  Result := False;
  Grid := GetGridForDataset(aDB);
  SavedState := SaveDBGridState(aDB, Grid);
  Guard := TDataLayoutGuard.Create(aDB);
  // DisableControls, auto-EnableControls
  if Assigned(Grid) then Grid.Enabled := False;
  try
    Result := aDB.Locate(FieldName, Value, Options);
  except
    on E: Exception do
    begin
      LogError('Error in LocateRecordInBackground', E);
      Result := False;
    end;
  end;
  RestoreDBGridState(aDB, Grid, SavedState);
end;

procedure TForm1.LogAfterPost(DataSet: TDataSet);
begin
  // This overrides the generic AfterPost that CreateAndOpenDBFs would
  // otherwise have wired to DBFRecordCountChanged, so it has to call that
  // itself to keep dbLog's status-bar record-count cache honest.
  DBFRecordCountChanged(DataSet);
  SetBitBtnUndoEnabled;
end;

procedure TForm1.LogAfterScroll(DataSet: TDataSet);
begin
  ShowStatusDBF(dbLog);
end;

procedure TForm1.LogBeforeEdit(DataSet: TDataSet);
begin
  BitBtnUndo.Enabled := True; {NoOp;}
end;

procedure TForm1.LogBeforeScroll(DataSet: TDataSet);
begin
  ShowStatusDBF(dbLog);
end;

procedure TForm1.LogIt(const Op: TRenameOperationState);
var
  db: TDbf;
  fDateTime, fFrom, fFromPath, fTo, fToPath: TField;
  Guard: TDataLayoutGuard;
begin
  StatusBar.Panels[0].Text := 'LogIt: ' + Op.sTo;
  db := FDbf[dbLog].aDB;
  if IsPhysicallyReadOnly(db) then
  begin
    // The rename itself succeeded; only the undo record can't be kept.
    StatusBar.Panels[0].Text :=
      sb([STATUS_READONLY_TAG, ' Renamed, but not logged for Undo: ',
      db.TableName, ' is read-only because ', DbfReadOnlyReason(db)]);
    Exit;
  end;
  Guard := TDataLayoutGuard.Create(db, DBGridLog, nil);
  fDateTime := db.FieldByName('DATETIME');
  fFrom := db.FieldByName('FROM');
  fFromPath := db.FieldByName('FROMPATH');
  fTo := db.FieldByName('TO');
  fToPath := db.FieldByName('TOPATH');
  db.Append;
  fDateTime.AsString := FormatDateTime('YYYY/MM/DD hh:nn', Now);
  fFrom.AsString := Op.From;
  fFromPath.AsString := Op.FromPath;
  fTo.AsString := Op.sTo;
  fToPath.AsString := Op.ToPath;
  SetLogUndo(False);
  PostRecord(db);
end;

// Diagnostic snapshot taken at entry, before the IsEmpty check decides
// whether to exit early. See original comment for what it's chasing.
procedure TForm1.LogSyncShowsEntryState(aDB: TDbf; const ShowsFile: String);
begin
  // TEMPORARY DIAGNOSTIC - remove once the Wine SHOWS.DBF reimport cause is
  // confirmed. Captures the exact state IsEmpty below decides on. Compare
  // against the two SetupDbShows/InitializeDBFs checkpoints: if RecordCount
  // is already 0 here but was nonzero right after Open, something between
  // Open and this line (index rebuild, First) is the culprit; if it's 0
  // even at Open, the file itself is opening empty on Wine.
  if IsDebugBuild then DebugLog(
      sb(['SyncShowsDatabase: entry, before IsEmpty check - ' +
      'Active=', IfThen(aDB.Active), ' RecordCount=',
      aDB.RecordCount, ' PhysicalRecordCount=', aDB.PhysicalRecordCount,
      ' IndexName="', aDB.IndexName, '" Filtered=',
      IfThen(aDB.Filtered), ' BOF=', IfThen(aDB.BOF), ' EOF=',
      IfThen(aDB.EOF), ' IsEmpty=', IfThen(aDB.IsEmpty),
      ' ShowsFile="', ShowsFile, '" ShowsFileExists=',
      IfThen(FileExists(ShowsFile))]));
end;

function TForm1.MakeSourceSheets: Integer;

  // Builds every source tab under one layout lock, so the whole batch gets
  // a single layout pass. The guard is released when this nested routine
  // returns - before the focus code below, which needs the new controls to
  // have real window handles (the LCL only creates those once layout runs).
  procedure BuildSheets;
  var
    Guard: TDataLayoutGuard;
    i: Integer;
    s: String;
    z: TUnZipper;
    zSmart: TSmartUnZipper;
  begin
    Guard := TDataLayoutGuard.CreateLayOut(pcSourceCode);
    z := zSmart.Value;
    g.SourceFilesCount := 0;
    z.FileName := g.FilePathSourceZip.Value;
    // Examine() only reads the central directory to populate z.Entries - it
    // never decompresses anything, so it has no OnCreateStream/OnDoneStream
    // to wire up.
    z.Examine;
    for i := 0 to z.Entries.Count - 1 do
    begin
      s := z.Entries[i].ArchiveFileName;
      if UTF8ContainsText('.lpi,.lpr,.pas,.lfm', ExtractFileExt(s)) then
      begin
        Inc(g.SourceFilesCount);
        AddtsSourceCode(pcSourceCode, s);
      end;
    end;
  end;

begin
  BuildSheets;
  Result := pcSourceCode.PageCount;
  if g.SourceFilesCount = 0 then Exit;
  // Layout has run, so the first editor now has a handle and is Showing.
  // SetFocus also makes it the form's ActiveControl.
  pcSourceCode.ActivePageIndex := 0;
  SafeSetFocus(FSourceManager.GetSynEdit(0));
end;

procedure TForm1.MenuItem10Click(Sender: TObject);
begin
  //FDbf[dbShows].aDB.Zap;  //for testing purposes only
end;

procedure TForm1.MenuItem11Click(Sender: TObject);
begin
  StatusBar.Visible := not StatusBar.Visible;
end;

procedure TForm1.MenuItemDeleteShowClick(Sender: TObject);
begin
  DBNavigatorShows.BtnClick(nbDelete);
end;

procedure TForm1.MenuItemEpsEditClick(Sender: TObject);
var
  Opt: TDBGridOptions;
begin
  Opt := DBGridEps.Options;
  Opt := Opt - [dgRowSelect] + [dgEditing];
  DBGridEps.Options := Opt;
end;

procedure TForm1.MenuItemInsertClick(Sender: TObject);
begin
  if MessageDlg('Confirm Insert', 'Confirm Insert', mtConfirmation,
    [mbYes, mbNo], 0) = mrYes then DBNavigatorShows.BtnClick(nbInsert);
end;

procedure TForm1.MenuItemShowsEditClick(Sender: TObject);
var
  Opt: TDBGridOptions;
begin
  Opt := DBGridShows.Options;
  Opt := Opt - [dgRowSelect] + [dgEditing];
  DBGridShows.Options := Opt;
end;

procedure TForm1.MenuShowEnvClick(Sender: TObject);
var
  i: Integer = 0;
  sAccum: String;
begin
  sAccum := '';
  for i := 1 to DOS.EnvCount do  //DOS.EnvStr is 1-based
  begin
    sb(sAccum, [DOS.EnvStr(i), LE]);
    if (i > 0) and (i mod 32 = 0) then
    begin
      MessageDlgEx(sb(['Environment Variables:', LE, LE, sAccum]),
        mtConfirmation, [mbOK]);
      sAccum := '';
    end;
  end;
  MessageDlgEx(sb(['Environment Variables:', LE, LE, sAccum]),
    mtConfirmation, [mbOK]);
end;

procedure TForm1.MenuShowsToggleHiddenClick(Sender: TObject);
var
  i: Integer;
  db: TDbf;
  Grid: TDBGrid;
begin
  Grid := DBGridShows;
  Grid.BeginUpdate;
  db := FDbf[dbShows].aDB;
  for i := 3 to Grid.Columns.Count - 1 do
    Grid.Columns[i].Visible := not Grid.Columns[i].Visible;
  Grid.Visible := True;
  Grid.Enabled := True;
  Grid.AutoFillColumns := not Grid.AutoFillColumns;
  if Grid.Columns[3].Visible or not DbfHasIndex(db, 'TITLE') then
    db.IndexName := ''
  else
    db.IndexName := 'TITLE';
  db.EnableControls;
  db.Active := True;
  Grid.AutoAdjustColumns;
  Grid.EndUpdate;
  UpdateStatusBar;
end;

procedure TForm1.MessageList(const Title: String; const SL: TStringList);
var
  i: Integer = 0;
  sResult: String;
begin
  sResult := '';
  sb(sResult, [Title, ':', LE]);
  for i := 0 to SL.Count - 1 do sb(sResult, [SL[i], LE]);
  ShowMessage(sResult);
end;

procedure TForm1.MessageRenamedCount(var Op: TRenameOperationState);
var
  s: String = '';
  sResult: String;
begin
  sResult := '';
  //if not g.IsHideRenamedCount then
  begin
    if (Op.CopiedCount > 0) then
      sb(sResult, ['Renamed ', ns(Op.CopiedCount), IfThen(
        (Op.CopiedCount = 1), ' file.', ' files.')]);
    if (Op.CopiedCount = 0) and (Op.buttonSelected <> mrCancel) then
      sb(sResult, ['Files NOT renamed.', LE]);
    if (Op.CopiedCount = 0) and (Op.buttonSelected = mrCancel) then
      sb(sResult, ['Canceled.', LE]);
    s := 'Skipped ' + ns(Op.SkipCount) + ' file' + IfThen(
      (Op.SkipCount = 1), '.', 's.');
    sb(sResult, [LE, IfThen(Op.SkipCount > 0, s, '')]);
    //Op.IsHideRenamedCount := ShowMessage(sResult, Op.IsHideRenamedCount);
    //ShowMessage(sResult, False, 'HideRenamedCount');
    StatusBar.Panels[0].Text := sResult;
  end;
end;

procedure TForm1.MouseWheelScaleToFont(Sender: TObject;
  Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint;
  var Handled: Boolean);
begin
  MousePos := MousePos;
  Handled := Handled;
  if (g.IsLinux and (ssCtrl in Shift)) or (g.IsWindows and
    ([ssCtrl] * Shift = [ssCtrl])) then if WheelDelta > 0 then
      uUtils.IncreaseAllFonts(Form1, StatusBar, ToolBarFiles, 1)
    else
      uUtils.IncreaseAllFonts(Form1, StatusBar, ToolBarFiles, -1);;
end;

procedure TForm1.NameStyleMenuClick(Sender: TObject);
const
  RESERVED_TEXT: array[TReservedCharStyle] of String = (
    'look-alikes for : ? * / \ | < > "', 'underscores for : ? * / \ | < > "');
  SEP_TEXT: array[TWordSeparator] of String = ('spaces', 'dots');
begin
  if not (Sender is TMenuItem) then Exit;
  case TMenuItem(Sender).Tag of
    NAME_STYLE_RESERVED_LOOKALIKE: g.ReservedCharStyle := rcsLookalike;
    NAME_STYLE_RESERVED_UNDERSCORE: g.ReservedCharStyle := rcsUnderscore;
    NAME_STYLE_SPACES: g.WordSeparator := wsSpace;
    NAME_STYLE_DOTS: g.WordSeparator := wsDot;
    else
      Exit;
  end;
  FNameStyleItems[NAME_STYLE_RESERVED_LOOKALIKE].Checked :=
    g.ReservedCharStyle = rcsLookalike;
  FNameStyleItems[NAME_STYLE_RESERVED_UNDERSCORE].Checked :=
    g.ReservedCharStyle = rcsUnderscore;
  FNameStyleItems[NAME_STYLE_SPACES].Checked := g.WordSeparator = wsSpace;
  FNameStyleItems[NAME_STYLE_DOTS].Checked := g.WordSeparator = wsDot;
  // Saved now, not only on exit, so a crash doesn't lose the choice.
  if not g.IsIniFileDeleted then
  try
    AppIni.Value.WriteString('Main', 'ReservedCharacters',
      IfThen(g.ReservedCharStyle = rcsUnderscore, 'underscore', 'lookalike'));
    AppIni.Value.WriteString('Main', 'WordSeparator',
      IfThen(g.WordSeparator = wsDot, 'dot', 'space'));
  except
    on E: Exception do LogError('NameStyleMenuClick: could not save', E);
  end;
  // Names already in the list were composed with the old style.
  StatusBar.Panels[0].Text := sb(['New file names: ',
    RESERVED_TEXT[g.ReservedCharStyle],
    ', words separated by ', SEP_TEXT[g.WordSeparator],
    '. Names already in the list keep their style; Clear and add the ',
    'files again to restyle them.']);
end;

// Go! and Enter in the address box. If another page is still loading, that
// load stops and this address opens as soon as it has (BrowseToURL).
procedure TForm1.NavigateBrowser(const AURL: String; AForce: Boolean);
begin
  if not FIsBrowsing then
  begin
    BrowseToURL(AURL, AForce);
    Exit;
  end;
  FPendingBrowserURL := AURL;
  FPendingBrowserForce := AForce;
  FBrowserCancel := True;
end;

function TForm1.NormalizeTitleAndYear(const s: String): String;
  // Single forward pass instead of six full ReplaceStr passes followed by a
  // separate filter pass. The year-prefix patterns ('.20'/'.19'/'(20'/'(19')
  // are checked first at each position - same precedence the six sequential
  // calls had, since each earlier pass ran before the general '.'/'(' passes
  // that would otherwise have already consumed those characters.
const
  // Read-only - never reassigned - so this belongs in const, not as a
  // var-with-initializer (which FPC treats as one-time-initialized static
  // storage rather than a per-call reset; harmless here since nothing ever
  // writes to it, but const says so honestly instead of by accident).
  GoodChars: set of char = ['0'..'9', 'A'..'Z', 'a'..'z', '-', '_'];
var
  i: Integer = 1;
  Len: Integer = 0;
  ULen: Integer = 0;
  CP: cardinal = 0;
begin
  Result := '';
  if s = '' then Exit;
  Len := Length(s);
  while i <= Len do
  begin
    case s[i] of
      '.':
        if (i + 2 <= Len) and (s[i + 1] = '2') and (s[i + 2] = '0') then
        begin
          sb(Result, '_'); sb(Result, '2'); sb(Result, '0');
          Inc(i, 3);
        end
        else if (i + 2 <= Len) and (s[i + 1] = '1') and (s[i + 2] = '9') then
        begin
          sb(Result, '_'); sb(Result, '1'); sb(Result, '9');
          Inc(i, 3);
        end
        else
          Inc(i); // lone '.' - dropped, matching the original '.' -> '' pass
      '(':
        if (i + 2 <= Len) and (s[i + 1] = '2') and (s[i + 2] = '0') then
        begin
          sb(Result, '_'); sb(Result, '2'); sb(Result, '0');
          Inc(i, 3);
        end
        else if (i + 2 <= Len) and (s[i + 1] = '1') and (s[i + 2] = '9') then
        begin
          sb(Result, '_'); sb(Result, '1'); sb(Result, '9');
          Inc(i, 3);
        end
        else
        begin
          sb(Result, '_');
          Inc(i);
        end;
      else
      begin
        // Byte-only here would test each byte of a multi-byte character
        // against an ASCII-only set and drop all of them - silently
        // destroying accented/non-Latin letters in the title instead of
        // keeping them. Decode the codepoint for anything non-ASCII.
        ULen := UTF8CodepointSize(@s[i]);
        if ULen = 1 then
        begin
          if s[i] in GoodChars then sb(Result, s[i]);
        end
        else
        begin
          CP := UTF8CodepointToUnicode(@s[i], ULen);
          if (CP <= $FFFF) and TCharacter.IsLetterOrDigit(widechar(CP)) then
            sb(Result, Copy(s, i, ULen));
        end;
        Inc(i, ULen);
      end;
    end;
  end;
end;

procedure TForm1.OfferRenameDeepestDir;
var
  db: TDbf;
  Guard: TDataLayoutGuard;
  SavedBookmark: TBookmark;
  OldDirPath, OldDirName, NewDirName, NewDirPath: String;
  OldDirStored, NewDirStored: String;
  OldFolder: TFilePath;
  UpdatedCount: Integer;
begin
  if FIsShuttingDown or g.FoundTitle.IsEmpty then Exit;
  OldDirPath := ExcludeTrailingPathDelimiter(GetListFromPath);
  OldFolder := OldDirPath;
  if OldDirPath.IsEmpty or not OldFolder.DirExists then Exit;
  OldDirName := efn(OldDirPath);
  // Title, not Directory: Shows.Directory is the epguides.com URL slug
  // (e.g. "breaking-bad"), not a filesystem-friendly display name.
  // The reserved-character style applies (a folder named "Star Trek꞉
  // Strange New Worlds"); the word separator doesn't - folder names keep
  // their spaces. Windows silently drops a dot or space at the end of a
  // folder name, so a "S.W.A.T." folder would be created as "S.W.A.T" -
  // and then never match the name compared against it here, so this would
  // offer the same rename every time. They are dropped here first.
  NewDirName := TrimRightSet(FixWinFileName(ApplyReservedCharStyle(
    g.FoundTitle)), ['.', ' ']);
  // Nothing to do if we couldn't build a usable name, or the folder is
  // already named after the show.
  if NewDirName.IsEmpty or SameText(OldDirName, NewDirName) then Exit;
  if MessageDlgEx(sb(['Rename this folder to match "', g.FoundTitle,
    '"?', LE, LE, 'From:', LE, OldDirName, LE, 'To:', LE,
    NewDirName, LE, LE,
    'This renames the folder on disk so future episodes inside it are ',
    'found automatically, without asking again.', LE, LE,
    'Only agree if every file in this folder belongs to "',
    g.FoundTitle, '". Choose No if the folder mixes episodes from ',
    'more than one show.']), mtConfirmation, [mbYes, mbNo]) <> mrYes then Exit;
  if not OldFolder.Rename(TFilePath(NewDirName)) then
  begin
    StatusBar.Panels[0].Text := 'Could not rename folder: ' + OldDirPath;
    Exit;
  end;
  NewDirPath := OldFolder.Value; // Rename() updates Value on success
  // LIST stores FROMPATH/TOPATH exactly as ExtractFilePath produced them in
  // ParseTitleNEpNum - i.e. WITH a trailing delimiter. OldDirPath has had
  // that delimiter stripped by ExcludeTrailingPathDelimiter above, so
  // comparing the two never matched: UpdatedCount was always 0, and every
  // other pending row in this folder was left pointing at a directory that
  // had just been renamed out from under it.
  OldDirStored := IncludeTrailingPathDelimiter(OldDirPath);
  NewDirStored := IncludeTrailingPathDelimiter(NewDirPath);
  // Every other pending row in the List DBF that pointed at the old
  // folder (e.g. the rest of this season) now needs to point at the
  // renamed one, or the next file this app tries to open won't be
  // there any more.
  UpdatedCount := 0;
  db := FDbf[dbList].aDB;
  Guard := TDataLayoutGuard.Create(db, DBGridList, nil);
  SavedBookmark := db.GetBookmark;
  db.DisableControls;
  try
    db.First;
    while not db.EOF do
    begin
      if SameText(Trim(db.FieldByName('FROMPATH').AsString),
        OldDirStored) then
      begin
        db.Edit;
        db.FieldByName('FROMPATH').AsString := NewDirStored;
        if SameText(Trim(db.FieldByName('TOPATH').AsString),
          OldDirStored) then db.FieldByName('TOPATH').AsString := NewDirStored;
        db.Post;
        Inc(UpdatedCount);
      end;
      db.Next;
    end;
  finally
    if db.BookmarkValid(SavedBookmark) then db.GotoBookmark(SavedBookmark);
    db.EnableControls;
  end;
  StatusBar.Panels[0].Text :=
    sb(['Renamed folder to "', NewDirName, '" (', IntToStr(UpdatedCount),
    ' pending item(s) updated).']);
end;

// Callback for uUtils.ExtractFileFromZip's callback overload - fires once
// the requested entry has been fully decompressed into AStream (positioned
// at 0). Loads the entry straight into whichever control ExtractResourceTo
// Object stashed in MyObject; never touches disk. Do not hold onto AStream
// past this call - uUtils frees it as soon as this callback returns.
procedure TForm1.OnZipEntryExtracted(AStream: TStream;
  const AArchiveFileName: String);
var
  sHtml: TSmartStringStream;
begin
  if MyObject is TSynEdit then
  begin
    TSynEdit(MyObject).Lines.LoadFromStream(AStream);
    if IsDebugBuild then DebugLog('Unzipped OK (TSynEdit): ' +
        AArchiveFileName);
  end
  else if MyObject is THtmlViewer then
  begin
    sHtml.Setup('');
    sHtml.Value.CopyFrom(AStream, AStream.Size);
    THtmlViewer(MyObject).LoadFromString(sHtml.Value.DataString);
    if IsDebugBuild then DebugLog('Unzipped OK (THtmlViewer): ' +
        AArchiveFileName);
  end
  else if IsDebugBuild then
    DebugLog('Unzip FAILED - MyObject not a recognised control for: ' +
      AArchiveFileName);
end;

// Opens ADoc (a README_EXTERNAL_DOCS name) in the system's default program,
// from the copy CheckResourceFiles extracted to g.OpPath - extracting it
// again first if it has gone missing or isn't this build's - so it works
// offline and keeps every embedded image. If even that fails,
// AFallbackURL (the copy on GitLab) opens instead, when there is one.
procedure TForm1.OpenBundledDocExternally(const ADoc, AFallbackURL: String);
var
  sFile: String;
begin
  sFile := CombinePath(g.OpPath, ADoc);
  if ExtractFromSourceZip(ADoc) and OpenDocument(sFile) then Exit;
  LogError('Could not open ' + sFile);
  if AFallbackURL.StartsWith('http', True) then LCLIntf.OpenURL(AFallbackURL);
end;

procedure TForm1.PanelShowsTopResize(Sender: TObject);
var
  NewWidth: Integer;
begin
  // DBNavigator side takes half less 4 px; the filter side (alClient)
  // takes the rest, i.e. half plus 4 px.
  NewWidth := Max(0, PanelShowsTop.ClientWidth div 2 - 4);
  if PanelNav.Width <> NewWidth then PanelNav.Width := NewWidth;
end;

procedure TForm1.ParseFilesList;
var
  db: TDbf;
  ProcessedCount, TotalCount: Integer;

// The guard lives only as long as this nested routine (same pattern as
// actSelectExecute's RefreshSelection), so LIST's controls are disabled
// for the fast parse pass only and are live again before
// actLookupEpsExecute starts - which is what lets the user watch rows
// fill in during the lookup. Previously the guard lived for the whole
// procedure and actLookupEpsExecute cancelled it from the inside with an
// unbalanced EnableControls. RAII still restores LIST on every path,
// including an exception from ParseTitleNEpNum/GetEpName mid-loop.
  procedure ParsePass;
  var
    Guard: TDataLayoutGuard;
  begin
    Guard := TDataLayoutGuard.Create(db);
    db.First;
    while not db.EOF do
    begin
      ParseTitleNEpNum(GetListFrom);
      GetEpName(GetListFrom);
      Inc(ProcessedCount);
      if (ProcessedCount mod 25) = 0 then
      begin
        StatusBar.Panels[0].Text :=
          sb(['Processing file ', ns(ProcessedCount), ' of ',
          ns(TotalCount), '...']);
        StatusBar.Repaint;
      end;
      db.Next;
    end;
  end;

begin
  if FIsShuttingDown then Exit;
  db := FDbf[dbList].aDB;
  TotalCount := db.RecordCount;
  ProcessedCount := 0;
  StatusBar.Panels[0].Text :=
    sb(['Processing ', ns(TotalCount), ' files...']);
  UI.Check;
  ParsePass;
  actLookupEpsExecute(Form1);
  AssignRootNameToAssociatedFiles;
  SetListTextWidth;
  db.IndexName := 'SORTORDER';
  db.RegenerateIndexes;
  // reindexing this stoMemory dbf should be very fast
  StatusBar.Panels[0].Text :=
    sb(['Processed ', ns(ProcessedCount), ' files successfully']);
end;

procedure TForm1.ParseHTMLToMemo;
const sDigit = ['0'..'9'];
var
  Client: TSmartHTTP;
  IsDone: Boolean = False;
  s, sCurTitle, sEpNum, sLeft, sOut, sRight: String;

// sDigit is a set of AnsiChar, and s[1]/sRight[1] below are raw byte
// indexing, not codepoint indexing - deliberately, not by accident.
// This is safe for UTF-8: ASCII bytes 0x30-0x39 ('0'..'9') can never
// occur as part of a multi-byte UTF-8 sequence (continuation bytes are
// always 0x80-0xBF, lead bytes always >=0xC0), and index 1 is always a
// genuine character boundary. Contrast with HackFrom/HackTo above, which
// use UTF8Pos/UTF8Copy because they search for and slice out arbitrary
// substrings, not a single known ASCII character.
  procedure SkipEmptyRow;
  begin
    // Guards s[1] explicitly rather than relying on the fact that
    // HackFrom's "Result := s" coupling currently guarantees s is
    // non-empty whenever IsDone is False (see HackFrom above) - that
    // invariant lives in a different function and shouldn't have to be
    // re-derived just to trust this line.
    if (s <> '') and not (s[1] in sDigit) then repeat
        s := sRight;
        IsDone := (HackFrom('epinfo left pad''>', s, sLeft, sRight) = '');
      until IsDone or (s = '') or (s[1] in sDigit);
  end;

begin
  if not Assigned(FDbf[dbTempEps].aDB) then Exit;
  g.URL := Trim(g.URL);
  if g.URL.IsEmpty or (g.URL = g.EpGuidesURL) then Exit;
  ZapPackTable(FDbf[dbTempEps].aDB);
  FDbf[dbTempEps].aRecCountDirty := True;
  FDbf[dbTempEps].aDB.Append;
  Memo1.Clear;
  EnsureOpenSSLDllsPresent;
  try
    InitSSLInterface; //initialize SSL by hand here
  except
    on E: Exception do
    begin
      if UTF8ContainsText(E.Message, 'Could not initialize OpenSSL') and
        EnsureOpenSSLDllsPresent then
      begin
        try
          InitSSLInterface; // retry once, now that the DLLs are in place
        except
          on E2: Exception do
          begin
            LogError('ParseHTMLToMemo: InitSSLInterface retry failed', E2);
            Exit;
          end;
        end;
      end
      else
      begin
        LogError('ParseHTMLToMemo: InitSSLInterface failed', E);
        Exit;
      end;
    end;
  end;
  Client.Get(g.URL, s);
  if s.IsEmpty then Exit;
  Memo1.Lines.BeginUpdate;
  // this crazyness weeds out html pages which don't conform to what's expected
  IsDone := (HackFrom('<a href="http://www.imdb.com/title/',
    s, sLeft, sRight) = '');
  //IsDone := (HackFrom('>Titles</th>', s, sLeft, sRight) = '');
  if not IsDone then
  begin
    s := sRight;
    IsDone := (HackTo('>', s, sLeft, sRight) = '');
  end;
  if not IsDone then
  begin
    s := sRight;
    IsDone := (HackTo('</a></h2>', s, sLeft, sRight) = '');
  end;
  if not IsDone then
  begin
    s := sRight;
    Memo1.Lines.Add(sLeft);
    sCurTitle := sLeft;
  end;
  IsDone := (HackFrom('epinfo left pad''>', s, sLeft, sRight) = '');

  while not IsDone do
  begin
    SkipEmptyRow;
    SetDbField(dbTempEps, 'TITLE', sCurTitle);
    if IsDebugBuild then
      DebugLog(sb(['sLeft= ', SafeCopy(sLeft, 1, 50), LE, LE,
        'sRight= ', SafeCopy(sRight, 1, 50), LE, LE, 's=',
        SafeCopy(s, 1, 50)]));
    sEpNum := FEpisodeMatcher.FormatEpStr(HackTo('</td>', s, sLeft, sRight));
    if IsDebugBuild then
      DebugLog(sb(['sEpNum= ', sEpNum, '  sLeft= ', sLeft]));
    SetDbField(dbTempEps, 'EPNUM', sEpNum);
    sOut := sb([sOut, Space, GetDbField(dbTempEps, 'EPNUM')]);
    HackFrom('href=', s, sLeft, sRight);
    HackTo('>', s, sLeft, sRight);
    SetDbField(dbTempEps, 'EPNAME', HackTo('</a>', s, sLeft, sRight));
    sOut := sb([sOut, Space, GetDbField(dbTempEps, 'EPNAME')]);
    Memo1.Lines.Add(sOut);
    sOut := '';
    IsDone := (HackFrom('epinfo left pad''>', s, sLeft, sRight) = '');
    PostRecord(FDbf[dbTempEps].aDB);
    FDbf[dbTempEps].aDB.Append;
    UI.Check;
  end;
  Memo1.Lines.EndUpdate;
  SetTabSheetMemoButtons;
end;

function TForm1.ParseTitleNEpNum(const curFile: String): String;
var
  curFilePath, EpisodeName, EpisodeNumber, sUpExt: String;
  IndexOf: Integer = 0;
  Match: TEpisodeMatch;
begin
  DebugLog('ParseTitleNEpNum, curFile= ' + curFile);
  Result := '';
  Match := Default(TEpisodeMatch);
  if Length(curFile) = 0 then Exit;
  // Check if file contains extension separator
  if UTF8ContainsText(GetListFrom, ExtractFileExt(curFile)) then
    SetListFrom(efn(curFile));
  DebugLog('ParseTitleNEpNum, GetListFrom= ' + GetListFrom);
  SetListExt(ExtractFileExt(curFile));
  SetListTitle('');
  curFilePath := ExtractFilePath(curFile);
  SetListFromPath(curFilePath);
  SetListToPath(curFilePath);
  sUpExt := UTF8UpperCase(GetListExt);
  // assign video file 0, associated file 1, anything else 9
  if Video_File_Extensions.Value.Find(sUpExt, IndexOf) then
    SetListTreeLevel('0')
  else
    // IndexStr (StrUtils) instead of "in". The in-operator over an
    // array-of-String is not available in any RELEASED FPC - it fails to
    // compile on 3.2.2 in both objfpc and delphi modes ("Operator is not
    // overloaded"), and there is no operator overload for it in this
    // project. IndexStr accepts the static array directly as an open array
    // and does the same case-sensitive linear match on every version.
    SetListTreeLevel(IfThen(IndexStr(sUpExt, Subtitle_Extensions) >
      -1, '1', '9'));
  // Only process video and subtitle files
  if (IndexStr(sUpExt, Subtitle_Extensions) < 0) and not
    (Video_File_Extensions.Value.Find(sUpExt, IndexOf)) then Exit;
  GetMKVAttributes(curFile);
  Match := FEpisodeMatcher.GetEpNumName(curFile);
  if Match.Found then
  begin
    g.EpNum := Match.EpNum;
    g.EpName := Match.EpName; // Explicit global assignment!
  end;
  EpisodeNumber := Match.EpNum;
  if Length(EpisodeNumber) = 0 then Exit;
  // Validate the episode number format
  if not FEpisodeMatcher.ValidateEpisodeNumber(EpisodeNumber) then
  begin
    LogError(sb(['Invalid episode number format: ', EpisodeNumber,
      ' from file: ', Copy(curFile, 1, 50)]));
    Exit;
  end;
  SetListEpNum(EpisodeNumber);
  EpisodeName := FEpisodeMatcher.ExtractEpisodeName(curFile, EpisodeNumber);
  if Length(EpisodeName) > 0 then SetListEpName(EpisodeName);
  Result := EpisodeNumber;
  DebugLog('ParseTitleNEpNum, EpisodeNumber= ' + EpisodeNumber);
end;

procedure TForm1.pcAboutChange(Sender: TObject);
begin
  // Using ActivePage is robust against tab reordering
  if pcAbout.ActivePage = tsSourceCode then
  begin
    if pcSourceCode.PageCount = 0 then
    begin
      MakeSourceSheets;
      SetTabSheetMemoButtons;
    end;
  end;
  if pcAbout.Showing and pcAbout.Visible and pcAbout.Enabled then
    UpdateStatusBar;
end;

procedure TForm1.pcMainChange(Sender: TObject);
begin
  if DBGridList.Showing then DBGridListSetColumnWidths;
  AdjustColumns(DBGridEps);
  if pcMain.ActivePage = tsShows then SafeSetFocus(ShowsFilterEdit);
  LazyLoadSourceCode;
  UpdateStatusBar;
end;

procedure TForm1.pcMainChanging(Sender: TObject; var AllowChange: Boolean);
begin
  // Fires BEFORE the switch, while pcMain.ActivePage is still the page
  // being left - unlike pcMainChange (above), which only sees the new
  // page. That's what lets this catch "leaving tsAbout while pcAbout is
  // still showing tsInfo" (see SaveAboutRecNo's banner comment); by the
  // time pcMainChange ran, there'd be no way left to tell which page on
  // pcMain had just been given up.
  if (pcMain.ActivePage = tsAbout) and (pcAbout.ActivePage = tsInfo) then
    SaveAboutRecNo;
end;

procedure TForm1.pcMainResize(Sender: TObject);
begin
  UpdateStatusBar; // show correct DBF for current tab on statusbar
end;

procedure TForm1.pcSourceCodeChange(Sender: TObject);
var
  CurrentSheet: TTabSheet;
  i: Integer;
  Syn: TSynEdit;
begin
  if pcSourceCode.PageCount = 0 then Exit;
  CurrentSheet := pcSourceCode.ActivePage;
  if (CurrentSheet = nil) then Exit;
  // Search for the SynEdit on this tab
  Syn := nil;
  for i := 0 to CurrentSheet.ComponentCount - 1 do
    if CurrentSheet.Components[i] is TSynEdit then
    begin
      Syn := TSynEdit(CurrentSheet.Components[i]);
      Break;
    end;
  // Only load if the editor is currently empty
  if Assigned(Syn) and (Syn.Lines.Count = 0) then
  begin
    if FileExists(CurrentSheet.Caption) then
      Syn.Lines.LoadFromFile(CurrentSheet.Caption);
  end;
  SetTabSheetMemoButtons;
  ShowStatusSourceCode;
end;

procedure TForm1.PerformTitleLookup;
begin
  FDbf[dbShows].aFilterText := GetListTitle;
  DebugLog('PerformTitleLookup, GetListTitle= ' + GetListTitle);
  // Reset before the chain runs: only actSelectExecute (via SelectAShow's
  // ElseExec fallback) sets this True, which is the one signal we need
  // to know whether a rename should be offered afterward.
  g.WasSelected := False;
  g.FoundTitle := TLookupRunner.Start
    //.OnError(DebugLog) // Inject your existing LogError method here
    .TryValue(FindMyTitle(GetListTitle))
    .TryValue(FindTitleByEpisodeName).TryMethod(@FindTitleWithYear)
    .TryValue(FindMyTitle(g.LastTitleFound))
    .TryMethod(@FindTitleByDirectory).ElseExec(@SelectAShow).FoundValue;
  DebugLog('PerformTitleLookup, g.FoundTitle= ' + g.FoundTitle);
  // The directory name was demonstrably the problem only when every
  // automatic matcher -- including FindTitleByDirectory -- failed and
  // SelectAShow had to be shown. Offer to fix it so the rest of this
  // folder's episodes match automatically next time.
  if g.WasSelected then OfferRenameDeepestDir;
end;

procedure TForm1.PostRecord(var aDB: TDbf);
var
  bReadOnly: Boolean = False;
begin
  // PHYSICALLY read-only (optical media, permissions, ...) is not the same
  // as the POLICY ReadOnly flag this routine lifts below: the file itself
  // was opened read-only, so there is no bypassing it. Say why and stop,
  // instead of letting TAccessDbf raise and filling error.log.
  if IsPhysicallyReadOnly(aDB) then
  begin
    if aDB.State in dsEditModes then aDB.Cancel;
    StatusBar.Panels[0].Text :=
      sb([STATUS_READONLY_TAG, ' Not saved: ', aDB.TableName,
      ' is read-only because ', DbfReadOnlyReason(aDB)]);
    Exit;
  end;
  bReadOnly := aDB.ReadOnly;
  aDB.ReadOnly := False;
  try
    try
      if not (aDB.State in [dsInsert, dsEdit]) then aDB.Edit;
      // No TryExclusive/EndExclusive here. On a file-backed table those
      // physically CLOSE and REOPEN the .dbf, every index file and the memo
      // file - twice per record - while this dataset is in dsEdit with a
      // live record buffer, and they invalidate TPagedFile's cached record
      // count each time. ParseHTMLToMemo and ConfirmThenZapPackTable both
      // call this in a loop. Post on a shared table is already correctly
      // locked by TDbf; the escalation bought nothing and cost a great deal.
      aDB.Post;
    except
      on E: EDbfRecordLocked do
      begin
        // Another user/program holds this record. TAccessDbf has already
        // flagged it, so the LOCKED badge and its hint are showing. This
        // is an expected, transient condition, not a bug, so it isn't
        // logged.
        if aDB.State in dsEditModes then aDB.Cancel;
        StatusBar.Panels[0].Text :=
          sb([STATUS_LOCKED_TAG, ' Not saved: ', E.Message]);
      end;
      on E: Exception do
      begin
        // Cancel leaves the dataset in dsBrowse instead of stranding it in
        // dsEdit, which is what made the NEXT Post fail too.
        if aDB.State in dsEditModes then aDB.Cancel;
        StatusBar.Panels[0].Text :=
          sb(['Error: could not post to ', aDB.TableName, ' - ', E.Message]);
        LogError(sb(['PostRecord failed on ', aDB.TableName,
          LE, GetDBFStatus(aDB)]), E);
      end;
    end;
  finally
    // ReadOnly is restored on every path, including the exception ones.
    aDB.ReadOnly := bReadOnly;
  end;
end;

// Clears out the old rows and drops the TITLE index before the bulk load,
// so uniqueness isn't re-checked on every single Append/Post.
procedure TForm1.PrepareShowsTableForImport(aDB: TDbf);
begin
  ZapPackTable(aDB);
  DBFRecordCountChanged(aDB);
  // A TITLE unique index surviving from a prior sync (Zap/PackTable clears
  // rows, not index files) would otherwise stay live through every single
  // Append/Post below, paying for a uniqueness check per row instead of
  // once at the end. Drop it now; FinalizeShowsImport rebuilds it in one
  // pass once the bulk load is done.
  DeleteIndexIfPresentExclusive(aDB, 'TITLE');
end;

function TForm1.ProbeFile(const sFind: String): String;
var
  sCommandLine: String = '';
begin
  Result := '';
  if sFind.IsEmpty then Exit;
  if not EnsureToolAvailable(g.FilePathFFProbe, g.WineFFProbe,
    'ffprobe', 'ffprobe.exe', '-version') then Exit;
  sCommandLine := sb([g.WineFFProbe, g.FilePathFFProbe.Value,
    ' -v quiet -show_format -show_streams "', sFind, '"']);
  Result := RunEx(sCommandLine, True);
  DebugLog('Probefile ' + sFind + ' = ' + Result);
end;

procedure TForm1.ProcessEpisodeLookup;
begin
  if FIsShuttingDown then Exit;
  // 1. Sync manual selection
  if g.SelectedTitle.IsNotEmpty then
  begin
    g.FoundTitle := g.SelectedTitle;
    g.LastTitleFound := g.SelectedTitle;
  end;
  // 2. Lookup if data is missing (PerformTitleLookup handles its own logging)
  if (g.LastTitleFound.IsEmpty) or (GetListTo.IsEmpty) then PerformTitleLookup;
  DebugLog('ProcessEpisodeLookup, g.FoundTitle= ' + g.FoundTitle);
  // Guard: Final check before updating UI
  if g.FoundTitle.IsEmpty then Exit;
  // 3. Update UI and State (AssignFoundEp handles its own logging)
  AssignFoundEp;
  FDbf[dbEps].aDB.Filtered := True;
  FDbf[dbEps].aRecCountDirty := True;
  pcMain.ActivePageIndex := tsList.PageIndex;
end;

procedure TForm1.ProgressBitBtnClick(Sender: TObject);
begin
  g.IsProgressCanceled := True;
end;

function TForm1.QueryThenRename(const ATargetPiece: String;
  var Op: TRenameOperationState): Boolean;
var
  db: TDbf;
begin
  Result := False;
  db := FDbf[dbList].aDB;
  if db.EOF then Exit;
  Op.From := efnOnly(GetListFrom) + ExtractFileExt(GetListFrom);
  Op.FromPath := ExtractFilePath(GetListFrom);
  Op.sTo := Trim(efn(ATargetPiece) + ExtractFileExt(GetListFrom));
  Op.ToPath := Op.FromPath;
  //{put new in same dir as old}
  if (Op.buttonSelected <> mrAll) then Op.buttonSelected :=
      MessageDlgEx(sb(['Rename?', LE, LE, 'From:', LE,
      Op.FromPath.Value, Op.From, LE, 'To:', LE, Op.ToPath.Value, Op.sTo]),
      mtConfirmation, [mbYes, mbNo, mbAll, mbCancel]);
  // See RenameThisList: mrCancel had no button to produce it and mrNone
  // (window close box) matched nothinOp. Op.IsCancel lets DealWithSpecialFiles'
  // loops below notice and stop.
  if Op.buttonSelected in [mrCancel, mrNone] then
  begin
    Op.IsCancel := True;
    Exit;
  end;
  if Op.buttonSelected in [mrYes, mrAll] then Result := RenameListItem(db, Op);
  if not Result then Exit;
  SetListTo(Op.sTo);
  SetListToPath(Op.ToPath);
  SetListNameNPath(CombinePath(Op.ToPath, Op.sTo));
  SetListTitle('');
  SetListEpNum('');
  SwapFromTo(Op);
end;

function TForm1.QuickLocateInBackground(const aDB: TDbf;
  const FieldName: String; const Value: variant): Boolean;
var
  aBookMark: TBookmark;
  SelectedCol: Integer = -1;
  Grid: TDBGrid;
  Guard: TDataLayoutGuard;
begin
  Grid := DBGridLog;
  Guard := TDataLayoutGuard.Create(aDB, Grid, nil);
  if Assigned(Grid) then
  begin
    SelectedCol := Grid.SelectedIndex;
    Grid.Enabled := False;
  end;
  try
    aBookMark := aDB.GetBookmark;
    Result := aDB.Locate(FieldName, Value, []);
    // Do your work here...
  finally
    aDB.GotoBookmark(aBookMark);
    if Assigned(Grid) then
    begin
      Grid.Enabled := True;
      Grid.SelectedIndex := SelectedCol;
    end;
  end;
end;

// FReadmeBack: back to the document before this one, where the reader
// left it.
procedure TForm1.ReadmeBackClick(Sender: TObject);
var
  iLast: Integer;
begin
  iLast := FReadmeHistory.Value.Count - 1;
  if iLast < 1 then Exit;
  if ShowReadmeDoc(FReadmeHistory.Value.Names[iLast - 1],
    StrToIntDef(FReadmeHistory.Value.ValueFromIndex[iLast - 1], 0)) then
    FReadmeHistory.Value.Delete(iLast);
  UpdateReadmeBack;
end;

// vwReadme's links, through TSmartHtmlViewer.OnClick, so this sees each one
// before the bridge's own handling. One pointing at a document this build
// carries is taken over: Privacy_Policy.html opens right here in vwReadme,
// and Back returns; README2.html ("More Information") opens the extracted
// copy in the default browser (README_EXTERNAL_DOCS). Anything else is
// left unhandled: the bridge then opens web and mail addresses in the
// default browser, and THtmlViewer scrolls to #anchors itself.
procedure TForm1.ReadmeLinkClick(Sender: TObject; const SRC: ThtString;
  var Handled: Boolean);
var
  sAnchor: String = '';
  sLink, sLower: String;
begin
  sLink := UTF8Encode(SRC);
  if BundledDocForLink(sLink, sAnchor).IsEmpty then
  begin
    // Not ours, and not something the bridge or THtmlViewer will act on
    // either, so the click would do nothing at all: log it, since that
    // usually means a mangled href (see README.md's links).
    sLower := UTF8LowerCase(Trim(sLink));
    if not (sLower.StartsWith('#') or sLower.StartsWith('http://') or
      sLower.StartsWith('https://') or sLower.StartsWith('ftp://') or
      sLower.StartsWith('mailto:')) then
      DebugLog('vwReadme: link goes nowhere: ' + sLink);
    Exit;
  end;
  Handled := True;
  // Queued rather than loaded here: this runs inside the viewer's own
  // mouse handler, and loading a new page frees the old one.
  FReadmePendingLink := sLink;
  Application.QueueAsyncCall(@DeferredReadmeLink, 0);
end;

// SEARCHTHIS holds the Key of each show's title and directory, so it goes
// stale whenever Key changes what it returns. While filey.ini's [Main]
// SearchKeyVersion is older than SEARCH_KEY_VERSION, this recomputes the
// keys and writes back only the ones that differ.
//
// Only rows with a non-ASCII character are recomputed: every Key change so
// far (see SEARCH_KEY_VERSION) is about non-ASCII characters, and that
// leaves a few dozen Key calls out of some 20,000 rows. A title that fills
// TITLE completely is left alone as well: the import may have cut it
// short, and its stored key, made from the whole title, matches more than
// a key made from the stored part would.
procedure TForm1.RefreshShowsSearchKeys;
const
  BATCH_SIZE = 1000; // rows between UI.Check calls
var
  db: TDbf;
  Guard: TDataLayoutGuard;
  SuspendedBeforeScroll: TEventSuspender;
  FldTitle, FldDir, FldSearch: TField;
  sTitle: String = '';
  sDir: String = '';
  sKey: String = '';
  sPrevStatus: String = '';
  iChecked: Integer = 0;
  iChanged: Integer = 0;
  bWasFiltered: Boolean = False;
  bComplete: Boolean = False;

  function HasNonASCII(const s: String): Boolean;
  var
    c: Char;
  begin
    for c in s do
      if c >= #$80 then Exit(True);
    Result := False;
  end;

begin
  if FSearchKeysCurrent then Exit;
  if Assigned(AppIni.Value) and (AppIni.Value.ReadInteger('Main',
    'SearchKeyVersion', 1) >= SEARCH_KEY_VERSION) then
  begin
    FSearchKeysCurrent := True;
    Exit;
  end;
  db := FDbf[dbShows].aDB;
  if not (Assigned(db) and db.Active) then Exit;
  // Read-only media can't take the new keys. Matching still works for
  // every title the change doesn't touch, and the version stays
  // unrecorded, so this runs again once SHOWS.DBF can be written.
  if IsPhysicallyReadOnly(db) or db.ReadOnly then
  begin
    DebugLog(sb(['RefreshShowsSearchKeys: ', db.TableName,
      ' is read-only; search keys left as they are']));
    Exit;
  end;
  FldTitle := db.FieldByName('TITLE');
  FldDir := db.FieldByName('DIRECTORY');
  FldSearch := db.FieldByName('SEARCHTHIS');
  Guard := TDataLayoutGuard.Create(db);
  // As in SyncShowsDatabase: BeforeScroll would redraw the status bar for
  // every row. (AfterScroll does nothing while controls are disabled.)
  SuspendedBeforeScroll := TEventSuspender.Start(db, 'BeforeScroll');
  bWasFiltered := db.Filtered;
  sPrevStatus := StatusBar.Panels[0].Text;
  StatusBar.Panels[0].Text :=
    sb(['Updating search keys in ', db.TableName, '...']);
  UI.Check;
  try
    try
      db.Filtered := False;
      db.First;
      while not db.EOF do
      begin
        if FIsShuttingDown then Break;
        // TrimRight: dBase pads character fields with spaces, and the
        // length test below must see the title's own length.
        sTitle := TrimRight(FldTitle.AsString);
        sDir := TrimRight(FldDir.AsString);
        if (HasNonASCII(sTitle) or HasNonASCII(sDir)) and
          (Length(sTitle) < FldTitle.Size) then
        begin
          sKey := ShowsSearchKey(sTitle, sDir);
          if FldSearch.AsString <> sKey then
          begin
            db.Edit;
            FldSearch.AsString := sKey;
            db.Post;
            Inc(iChanged);
          end;
        end;
        Inc(iChecked);
        if iChecked mod BATCH_SIZE = 0 then UI.Check;
        db.Next;
      end;
      bComplete := db.EOF;
    except
      on E: Exception do
      begin
        if db.State in dsEditModes then db.Cancel;
        LogError(sb(['RefreshShowsSearchKeys: stopped after ', iChecked,
          ' rows']), E);
      end;
    end;
  finally
    db.Filtered := bWasFiltered;
    db.First;
  end;
  if not bComplete then
  begin
    // Closing, or an error (logged above): it runs again next time.
    StatusBar.Panels[0].Text := sPrevStatus;
    Exit;
  end;
  SearchKeysAreCurrent;
  DebugLog(sb(['RefreshShowsSearchKeys: ', iChanged, ' of ', iChecked,
    ' rows given version ', SEARCH_KEY_VERSION, ' search keys']));
  if iChanged = 0 then StatusBar.Panels[0].Text := sPrevStatus
  else
    StatusBar.Panels[0].Text := sb(['Search keys updated for ', iChanged,
      IfThen(iChanged = 1, ' show', ' shows')]);
end;

procedure TForm1.RegenerateResourceFile(const ARCFile, AResFile: String);
var
  ExitCode: Integer;
  Output: String;
begin
  // On Linux, windres is usually the go-to for dBase/Lazarus compatibility.
  // RunEx (uUtils.pas) wraps Execute in its own try/except - a missing
  // /usr/bin/windres is caught internally, logged, and reported back as
  // ExitCode = -1, so no separate try/except is needed here.
  Output := RunEx('/usr/bin/windres', ['-i', ARCFile, '-o', AResFile],
    ExitCode, True); // bRedirectErr: fold windres' stderr into Output
  if ExitCode = 0 then DebugLog('Resource file regenerated successfully.')
  else if Output.IsNotEmpty then
    LogError('Resource compiler failed with exit code: ' +
      IntToStr(ExitCode) + ' - ' + Output)
  else
    LogError('Resource compiler failed with exit code: ' + IntToStr(ExitCode));
end;

function TForm1.RenameListItem(const aDB: TDbf;
  var Op: TRenameOperationState): Boolean;
var
  IsMKV: Boolean;
  LLastError: Integer = 0;
  s, sCommandLine, sFullFrom, sGroup, sOriginalDir, sTagFile: String;
begin
  DebugLog('RenameListitem');
  Result := False;
  if (Op.FromPath + Op.From = EmptyStr) or (Op.ToPath + Op.sTo = EmptyStr) then
  begin
    Inc(Op.SkipCount);
    Exit; // Clean exit if paths are empty
  end;

  // 1. Build robust cross-platform paths
  sFullFrom := CombinePath(Op.FromPath, Op.From);
  StatusBar.Panels[0].Text := 'RenameListItem: ' + sFullFrom;
  // 2. Proactive "CheckPathExists" logic
  if not FileExists(sFullFrom) then
  begin
    StatusBar.Panels[0].Text :=
      'Error: Source file missing - ' + Op.From;
    DebugLog(StatusBar.Panels[0].Text);
    Inc(Op.SkipCount);
    Exit; // Exit early if source doesn't exist
  end;
  StatusBar.Panels[0].Text :=
    'Attempt DirectoryExists: ' + Op.ToPath.Value;
  if not DirectoryExists(Op.ToPath.Value) then
  begin
    StatusBar.Panels[0].Text :=
      'Error: Destination path invalid - ' + Op.ToPath.Value;
    DebugLog(StatusBar.Panels[0].Text);
    Inc(Op.SkipCount);
    Exit; // Exit early if destination doesn't exist
  end;

  try
    sOriginalDir := GetCurrentDir;
    SetCurrentDir(Op.FromPath.Value); //shorten relative path

    StatusBar.Panels[0].Text := 'Attempt rename to: ' + Op.sTo;
    // 3. Attempt the actual rename, in relative path
    //Result := RenameFile(sFullFrom, sFullTo);
    Result := RenameFile(Op.From, Op.sTo);
    // Capture the OS error HERE, immediately. The finally block below runs
    // SetCurrentDir (and, for an MKV, a RunEx), and both of those reset the
    // process-wide last-error value - so reading GetLastOSError after the
    // try block reported SetCurrentDir's result, not the failed rename's.
    if not Result then LLastError := GetLastOSError;

    // 3.4 Clear old subtitle flags and force English subtitles in MKV files
    IsMKV := UTF8UpperCase(ExtractFileExt(Op.sTo)) = '.MKV';
    if Result and IsMKV then ApplySubtitleFlags(Op.sTo);

    // 3.5 Embed title (and, if one can be guessed from the ORIGINAL name,
    // the release group) into mkv files
    if Result and IsMKV and EnsureMKVToolsAvailable(False, True) then
    begin
      sCommandLine :=
        sb([g.WineMKVPropEdit + g.FilePathMKVPropEdit.Value,
        Space, Op.sTo.Quote, ' -e info -s ', ('title=' + Op.sTo).Quote]);
      sGroup := GuessReleaseGroup(Op.From);
      sTagFile := '';
      if sGroup.IsNotEmpty then
      begin
        sTagFile := CombinePath(g.OpPath.Value, 'release_group_tags.xml');
        if WriteReleaseGroupTagsFile(sGroup, sTagFile) then
          sCommandLine := sb([sCommandLine, ' --tags ',
            ('global:' + sTagFile).Quote])
        else
          sTagFile := '';
      end;
      RunEx(sCommandLine, True);
      if sTagFile.IsNotEmpty then DeleteIfExists(sTagFile);
      DebugLog(sb(['RenameListItem: release group for ', Op.From,
        ' = "', sGroup, '"']));
    end;

  finally
    SetCurrentDir(sOriginalDir); //restore dir
  end;

  // 4. Handle results and logging
  if Result then
  begin
    Inc(Op.CopiedCount);
    case UTF8UpperCase(aDB.TableName) of
      'LIST.DBF': LogIt(Op);
      // LOG.DBF rows are no longer deleted here. Deleting mid-iteration
      // shifts the dataset's cursor out from under the caller's own
      // Next, silently skipping the following record. RenameThisList
      // now tags successfully-undone rows and deletes them in a
      // separate pass once iteration is complete.
    end;
    Exit; // Job done, get out now
  end;

  // If we reach this point, Result MUST be False.
  // Counted ONCE - this used to be incremented here and again five lines
  // down, so every failed rename inflated the reported skip count by two.
  Inc(Op.SkipCount);
  // LLastError was captured at the rename itself (see above). It is also
  // read once into a local rather than calling GetLastOSError twice in one
  // expression, which could yield two different values for the message and
  // the code.
  s := sb(['Failed to rename.', LE, 'Reason: ',
    SysErrorMessage(LLastError), ' (Code ', IntToStr(LLastError),
    ')', LE, LE, 'From: ', Op.FromPath.Value, Op.From, LE, 'To: ',
    Op.ToPath.Value, Op.sTo]);
  ShowMessage(s, g.IsHideBadPath);
  StatusBar.Panels[0].Text :=
    'System Error: Could not rename ' + Op.From;
  DebugLog(StatusBar.Panels[0].Text);
  // SetLogUndo(False) removed. It edits and posts LOG.DBF's CURRENT row -
  // but on the LIST.DBF path nothing was logged for this file, so it was
  // clearing the Undo flag of whatever unrelated LOG row the cursor
  // happened to be sitting on. On the LOG.DBF (undo) path the row is
  // already handled by RenameThisList's PendingDeletes pass. If LOG is
  // empty it would raise from db.Edit outright.
end;

procedure TForm1.RenameThisList(aDB: TDbf);
var
  Busy: TSmartBusyState;
  fFrom, fFromPath, fTo, fToPath: TField;
  i: Integer;
  Op: TRenameOperationState;
  PendingDeletes: array of TBookmark;
begin
  // Guard against re-entrancy: MessageDlgEx pumps the message queue while
  // this runs, so a second trigger of the Rename action (or the Undo
  // button, which also calls RenameThisList) can fire while the first pass
  // is still iterating. Just drop the re-entrant call. FIsRenaming is the
  // actual gate; TSmartBusyState (ADisableUI=True) additionally disables
  // every control for the duration, which blocks most GUI-click re-entry
  // before it even reaches this check, and restores cursor/status/enabled
  // state automatically - including on an exception - when it goes out of
  // scope.
  if FIsRenaming then Exit;
  Op := Default(TRenameOperationState);  //freshly zeroed, every time
  FIsRenaming := True;
  try
    Busy := TSmartBusyState.Start(Form1, nil, StatusBar, True);
    SetLength(PendingDeletes, 0);
    aDB.First;
    Op.CopiedCount := 0;
    Op.SkipCount := 0;
    // UTF8UpperCase rather than the byte-wise UpCase, matching how every
    // other "uppercase for comparison" call site in this codebase already
    // treats this operation (see IsMKV above, uDBFManager.CreateAndOpenDBFs,
    // uUtils.ValidateFileName). TableName is always an ASCII .DBF filename
    // today, so this is a consistency fix rather than a live buOp.
    Op.CurDB := UTF8UpperCase(aDB.TableName);
    Op.IsCancel := False;
    // Reset the sticky "All" answer. Without this, once the user picks
    // All in ANY rename or undo run, g.buttonSelected stays mrAll for the
    // rest of the session and every later run renames its whole list
    // without asking.
    g.buttonSelected := mrNone;
    // Looked up once, not once per row: FROM/FROMPATH/TO/TOPATH are read
    // on every iteration below, and the TField references stay valid for
    // aDB's whole scan (aDB itself is never reassigned in this loop).
    fFrom := aDB.FieldByName('FROM');
    fFromPath := aDB.FieldByName('FROMPATH');
    fTo := aDB.FieldByName('TO');
    fToPath := aDB.FieldByName('TOPATH');
    while (not aDB.EOF) and (not Op.IsCancel) do
    begin
      Op.From := Trim(fFrom.AsString);
      Op.FromPath := Trim(fFromPath.AsString);
      Op.sTo := Trim(fTo.AsString);
      Op.ToPath := Trim(fToPath.AsString);
      // reverse TO/FROM fields
      if (Op.CurDB = 'LOG.DBF') then
      begin
        SwapString(Op.From, Op.sTo);
        SwapString(Op.FromPath.Value, Op.ToPath.Value);
      end;
      // {it's already been or} shouldn't be re-named
      if {(FileExists(Op.ToPath + Op.sTo)) or} (Op.sTo = '') or
        (Op.From = '') then Inc(Op.SkipCount)
      else
      begin
        if Op.buttonSelected <> mrAll then Op.buttonSelected :=
            MessageDlgEx(sb(['Rename this episode?', LE, LE,
            'From:', LE, Op.From, LE, 'To:', LE, Op.sTo]),
            mtConfirmation, [mbYes, mbNo, mbAll, mbCancel]);
        // mrCancel is the Cancel button, which the dialog previously did
        // not offer at all - so this test could never fire and a 200-file
        // run could not be stopped. mrNone is what ShowModal returns when
        // the dialog is dismissed via the window close box; it used to
        // match none of the three tests below, so that file was neither
        // renamed nor counted as skipped and simply vanished from the
        // tally. Both now mean "stop", and Op.IsCancel makes the enclosing
        // while loop agree.
        if Op.buttonSelected in [mrCancel, mrNone] then
        begin
          Op.IsCancel := True;
          Break;
        end;
        if Op.buttonSelected = mrNo then Inc(Op.SkipCount);
        if Op.buttonSelected in [mrYes, mrAll] then
          // Tag rather than delete now: deleting mid-loop would move the
          // cursor out from under the Next call below and skip a record.
          if RenameListItem(aDB, Op) and (Op.CurDB = 'LOG.DBF') then
          begin
            SetLength(PendingDeletes, Length(PendingDeletes) + 1);
            PendingDeletes[High(PendingDeletes)] := aDB.GetBookmark;
          end;
      end;
      aDB.Next;
    end;
    // Batch-delete now that iteration is finished, so no cursor movement
    // here can interfere with the loop above.
    for i := 0 to High(PendingDeletes) do
    begin
      aDB.GotoBookmark(PendingDeletes[i]);
      aDB.Delete;
    end;
    MessageRenamedCount(Op);
    if (Op.CurDB = 'LOG.DBF') then
    begin
      PackThisTable(aDB);
      // Belt-and-suspenders: the aDB.Delete calls above already
      // invalidated this table's cache via the AfterDelete handler
      // (DBFRecordCountChanged, wired generically in CreateAndOpenDBFs),
      // but PackTable is itself a schema-level mutation worth covering
      // explicitly too, consistent with every other Zap/Pack call site.
      DBFRecordCountChanged(aDB);
    end;
  finally
    FIsRenaming := False;
  end;
end;

// Throttled progress update, called every BATCH_SIZE rows from the
// import loop below.
procedure TForm1.ReportShowsImportProgress(
  CurrentLine, TotalLines, ProcessedCount: Integer;
  const StartTime: TDateTime);
begin
  ProgressBar.Position := CurrentLine;
  ProgressLabel.Caption :=
    Format('%d/%d (%d sec)', [ProcessedCount, TotalLines,
    SecondsBetween(Now, StartTime)]);
end;

procedure TForm1.RestoreDBGridState(aDB: TDbf; Grid: TDBGrid;
  const SavedState: TDBGridState);
begin
  try
    // Restore dataset position first
    if aDB.Active and (SavedState.BookMark <> Default(TBookmark)) then
    begin
      try
        aDB.GotoBookmark(SavedState.BookMark);
      except //{ If bookmark is invalid (record deleted, etc.), go to nearest position
        try
          aDB.First; // Fallback to first record
        except // Dataset might be empty now
        end;
      end;
    end;
    // Re-enable controls
    aDB.EnableControls;
    // Restore grid state
    if Assigned(Grid) then
    begin
      Grid.Enabled := SavedState.WasEnabled;
      // Restore selected column
      if (SavedState.SelectedColumn >= 0) and
        (SavedState.SelectedColumn < Grid.Columns.Count) then
        Grid.SelectedIndex := SavedState.SelectedColumn;
      // Restore editing mode
      if SavedState.IsEditing then Grid.EditorMode := True;
      // Restore focus
      if SavedState.GridHasFocus and Grid.CanFocus then SafeSetFocus(Grid);
    end;
  except
    on E: Exception do LogError('Error restoring DBGrid state', E);
  end;
end;

procedure TForm1.RightMouseFonts(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if Button = mbRight then actFormFontsExecute(Sender);
end;

// Starts ABatch's downloads on up to AWorkers background threads and keeps
// the window responding until they are done. Stops waiting - cancelling
// whatever is left - after ATimeLimitMs (0: no limit), when
// NavigateBrowser asks for another address, or when the program starts
// closing. AStatus, if given, is shown with the progress meanwhile.
procedure TForm1.RunBrowserDownloads(ABatch: TBrowserDownloadBatch;
  AWorkers: Integer; ATimeLimitMs: QWord; const AStatus: String);
var
  LastShown, Start: QWord;
begin
  // Also what stops the downloads in a build without threads, where
  // StartBrowserDownloads does them itself and returns when they're done.
  if ATimeLimitMs > 0 then ABatch.Deadline := GetTickCount64 + ATimeLimitMs;
  StartBrowserDownloads(ABatch, AWorkers);
  Start := GetTickCount64;
  LastShown := 0;
  while not ABatch.AllDone do
  begin
    if FBrowserCancel or FIsShuttingDown or Application.Terminated or
      ((ATimeLimitMs > 0) and (GetTickCount64 - Start >= ATimeLimitMs)) then
    begin
      ABatch.Cancel;
      Exit;
    end;
    if (AStatus <> '') and (GetTickCount64 - LastShown >= 250) then
    begin
      FBrowserStatus := sb([AStatus, ' (', ABatch.DoneCount, ' of ',
        ABatch.Count, ') ...']);
      ShowStatusBrowser;
      LastShown := GetTickCount64;
    end;
    Application.ProcessMessages;
    Sleep(10);
  end;
end;

function TForm1.SafeGetDbField(aDbType: TDbType; const aField: String): String;
var
  db: TDbf;
begin
  Result := '';
  db := FDbf[aDbType].aDB;
  if FIsShuttingDown or not FDbf[aDbType].aIsInitialized then Exit;
  try
    if not db.Active then Exit;
    if db.EOF and db.BOF then Exit;
    Result := Trim(db.FieldByName(aField).AsString);
  except
    on E: Exception do
    begin
      LogError('Error reading field ' + aField + ' from ' +
        GetEnumName(TypeInfo(TDbType), Ord(aDbType)), E);
      Result := '';
    end;
  end;
end;

procedure TForm1.SafeSetDbField(const aDbType: TDbType;
  const aField, AValue: String);
var
  bReadOnly: Boolean = False;
  db: TDbf;
  Guard: TDataLayoutGuard;
begin
  if FIsShuttingDown or not FDbf[aDbType].aIsInitialized then Exit;
  // Read-only media isn't an error worth an exception here: callers such
  // as DownLoadEps' "LookUpDate := today" are best-effort bookkeeping.
  if IsPhysicallyReadOnly(FDbf[aDbType].aDB) then
  begin
    StatusBar.Panels[0].Text :=
      sb([STATUS_READONLY_TAG, ' Not saved: ', FDbf[aDbType].aDB.TableName,
      '.', aField, ' - ', DbfReadOnlyReason(FDbf[aDbType].aDB)]);
    Exit;
  end;
  try
    db := FDbf[aDbType].aDB;
    Guard := TDataLayoutGuard.Create(db);
    if not db.Active then Exit;
    bReadOnly := db.ReadOnly;
    db.ReadOnly := False;
    try
      db.Edit;
      db.FieldByName(aField).AsString := AValue;
      db.Post;
    except
      on E: Exception do
      begin
        db.Cancel;
        raise EFileyDatabaseException.CreateFmt(
          'Error updating %s.%s to "%s": %s',
          [db.TableName, aField, AValue, E.Message]);
      end;
    end;
    db.ReadOnly := bReadOnly;
  except
    on E: EFileyDatabaseException do raise;
    on E: Exception do raise EFileyDatabaseException.CreateFmt(
        'Unexpected error in SafeSetDbField: %s', [E.Message]);
  end;
end;

// Saves where the user was in ABOUT.DBF, for SetupDbAbout to restore after
// its next Zap-and-rebuild. Two call sites need this, not one: tsInfo's own
// OnHide (below) catches leaving tsInfo via pcAbout, and pcMainChanging
// catches leaving tsAbout via pcMain while pcAbout is still showing tsInfo
// underneath it - a case tsInfoHide alone misses, since tsInfo's own
// ActivePage/Showing state never changes when only its ancestor container
// (tsAbout, on the outer pcMain) is hidden. See uDBF.TDBRecord.aSavedRecNo
// for why this is a plain record number rather than a TBookmark.
procedure TForm1.SaveAboutRecNo;
begin
  if Assigned(FDbf[dbAbout].aDB) then
    FDbf[dbAbout].aSavedRecNo := FDbf[dbAbout].aDB.PhysicalRecNo;
end;

procedure TForm1.SaveConfiguration(ini: TIniFile);
var
  bWasCaching: Boolean;
  f: TFont;
  i: Integer;

  procedure SaveTabFonts(APageIndex: Integer);
  var
    Page: TTabSheet;
    Edit: TSynEdit;
    j: Integer;
  begin
    Page := pcSourceCode.Pages[APageIndex];
    for j := 0 to Page.ComponentCount - 1 do
      if Page.Components[j] is TSynEdit then
      begin
        Edit := TSynEdit(Page.Components[j]);
        // Was 'TabSheetSourceCode<n>.Font.*', which nothing read back.
        WriteSourceCodeFont(ini, Page, Edit);
      end;
  end;

begin
  if g.IsIniFileDeleted or not Assigned(ini) then Exit;
  // One write of the file at the end instead of one per key (TIniFile
  // rewrites the whole file on every write unless CacheUpdates is on).
  bWasCaching := ini.CacheUpdates;
  ini.CacheUpdates := True;
  try
    ini.WriteBool('Main', 'IsCreateDesktopShortcut',
      g.IsCreateDesktopShortcut);
    ini.WriteBool('Main', 'IsCreateMenuEntry', g.IsCreateMenuEntry);
    ini.WriteBool('Main', 'AskMoveAppImage', g.IsAskMoveAppImage);
    ini.WriteString('Main', 'ReservedCharacters',
      IfThen(g.ReservedCharStyle = rcsUnderscore, 'underscore', 'lookalike'));
    ini.WriteString('Main', 'WordSeparator',
      IfThen(g.WordSeparator = wsDot, 'dot', 'space'));
    // FileName is empty if nothing has been opened or dropped this run;
    // keep the folder the dialog last started in rather than writing ''.
    if OpenDialog.FileName <> '' then
      ini.WriteString('Main', 'InitialDir',
        ExtractFileDir(OpenDialog.FileName))
    else if OpenDialog.InitialDir <> '' then
      ini.WriteString('Main', 'InitialDir', OpenDialog.InitialDir);
    ini.WriteInteger('Main', 'Height', Self.Height);
    ini.WriteInteger('Main', 'Left', Self.Left);
    ini.WriteInteger('Main', 'Top', Self.Top);
    ini.WriteInteger('Main', 'Width', Self.Width);
    ini.WriteInteger('Main', 'FontSettingsVersion', FONT_SETTINGS_VERSION);
    ini.WriteInteger('Main', 'IniVersion', INI_VERSION);
    // Only when known: a read-only SHOWS.DBF that couldn't be refreshed
    // keeps the older version, so the refresh runs once it can.
    if FSearchKeysCurrent then
      ini.WriteInteger('Main', 'SearchKeyVersion', SEARCH_KEY_VERSION);
    f := Self.Canvas.Font;
    ini.WriteString('Main', 'Self.Canvas.Font.Name', f.Name);
    ini.WriteInteger('Main', 'Self.Canvas.Font.Size', f.Size);
    ini.WriteBool('Main', 'Self.Canvas.Font.Bold', f.Bold);
    f := StatusBar.Canvas.Font;
    ini.WriteString('Main', 'StatusBar.Canvas.Font.Name', f.Name);
    ini.WriteInteger('Main', 'StatusBar.Canvas.Font.Size', f.Size);
    ini.WriteBool('Main', 'StatusBar.Canvas.Font.Bold', f.Bold);
    // (PageControlSourceCode.PageCount, once written here, was never read:
    // UpgradeIniFile removes it from older inis.)
    for i := 0 to pcSourceCode.PageCount - 1 do SaveTabFonts(i);
    ini.UpdateFile;
  except
    on E: Exception do LogError('Error saving configuration', E);
  end;
  try
    ini.CacheUpdates := bWasCaching;
  except
    on E: Exception do LogError('Error saving configuration', E);
  end;
end;

function TForm1.SaveDBGridState(aDB: TDbf; Grid: TDBGrid): TDBGridState;
begin
  Result.BookMark := Default(TBookmark);
  Result.SelectedColumn := -1;
  Result.IsEditing := False;
  Result.WasEnabled := True;
  Result.GridHasFocus := False;
  // Save dataset position
  if aDB.Active and (aDB.RecordCount > 0) then
  begin
    try
      Result.BookMark := aDB.GetBookmark;
    except
      Result.BookMark := Default(TBookmark);
      // Handle invalid bookmark
    end;
  end;
  // Save grid state
  if not Assigned(Grid) then Exit;
  Result.SelectedColumn := Grid.SelectedIndex;
  Result.IsEditing := Grid.EditorMode;
  Result.WasEnabled := Grid.Enabled;
  Result.GridHasFocus := Grid.Focused;
end;

function TForm1.SelectAShow: String;
var
  // SelectAShow runs its own wait loop INSIDE whatever called it, so any
  // RAII state held further up the stack stays in force for the whole
  // wait. On the drag-and-drop path that is AddFiles' TSmartBusyState
  // (ADisableUI=True): AddFiles -> ParseFilesList -> actLookupEpsExecute
  // -> ProcessEpisodeLookup -> PerformTitleLookup -> SelectAShow. That
  // busy state has set Enabled=False (and crHourGlass) on every component
  // the form owns - pcMain, tsShows, the panels, ShowsFilterEdit,
  // DBGridShows, DBNavigatorShows, both BitBtns and their TActions - so
  // the panel appeared but nothing on it could be used. It also made
  // AdjustColumns bail out early (it skips a disabled grid).
  // PickScope re-enables just what is needed to pick a show (plus every
  // parent up to the form), and on scope exit disables exactly those
  // again so the outer TSmartBusyState's own restore is unaffected. When
  // nothing up the stack disabled them, PickScope changes nothing.
  PickScope: TEnabledScope;
begin
  Result := '';
  if g.IsHideSelectAShow then Exit;
  PanelSelect.Visible := True; //re-layout triggers TabSheetAlignButtons
  pcMain.ActivePageIndex := tsShows.PageIndex;
  // Must come before AdjustColumns and SafeSetFocus below: both silently
  // do nothing on a disabled control.
  PickScope.Enable([ShowsFilterEdit, DBNavigatorShows, DBGridShows,
    PanelSelect, BitBtnSelect, BitBtnCancel, actSelect,
    actFilterEditCancel]);
  AdjustColumns(DBGridShows);
  g.IsHideSelectAShow :=
    ShowMessage('Did not match Series Name' + LE +
    'based upon Title or Episode Names.' + LE + LE +
    'Select series, or Cancel.', g.IsHideSelectAShow);
  g.IsModalWait := True;
  // (The former PanelSelect/BitBtnSelect/BitBtnCancel.Cursor := crDefault
  // lines were treating the hourglass symptom of the same busy state;
  // PickScope.Enable now sets and later restores those cursors.)
  StatusBar.Panels[0].Text := 'SELECT A SHOW';
  ShowsFilterEdit.Text := FDbf[dbShows].aFilterText;
  if ShowsFilterEdit.Showing then SafeSetFocus(ShowsFilterEdit);
  FDbf[dbShows].aDB.Filtered := True;
  FDbf[dbShows].aRecCountDirty := True;
  repeat
    UI.Check;
    // UI.Check exits immediately when its interval hasn't elapsed, so
    // without this the wait pegs a core for as long as the Select-a-Show
    // panel is up. 10ms is far below the threshold of noticeable input lag
    // and costs essentially nothing.
    Sleep(10);
  until (g.IsModalWait = False) or FIsShuttingDown;
  // g.WasSelected is only True if actSelectExecute actually confirmed a
  // pick (BitBtnSelect or the "Select This Show" menu item); Cancel or a
  // shutdown mid-wait leaves it False, so Result correctly comes back
  // empty in both of those cases.
  if g.WasSelected then Result := g.SelectedTitle;
end;

procedure TForm1.SearchKeysAreCurrent;
begin
  FSearchKeysCurrent := True;
  // No ini yet is a first run, which FormActivate recognises by the file
  // not being there, so nothing may create it now; SaveConfiguration
  // records the version on exit instead.
  if g.IsIniFileDeleted or not AppIni.Exists then Exit;
  try
    AppIni.Value.WriteInteger('Main', 'SearchKeyVersion', SEARCH_KEY_VERSION);
  except
    // A read-only or locked ini: the refresh just runs again next time.
    on E: Exception do
      LogError('SearchKeysAreCurrent: could not update ' + g.IniFileName, E);
  end;
end;

procedure TForm1.SetBitBtnUndoEnabled;
var
  FoundUndo: Boolean = False;
begin
  // tsLogResize calls this, and Show resizes every tab - tsLog included -
  // before DeferredStartup has opened LOG.DBF. DeferredStartup calls it
  // again once the tables are open.
  if not IsDbOpen(dbLog) then Exit;

  FDbf[dbLog].aDB.DisableControls;
  try
    // Use background locate instead of filtering. No local bookmark needed
    // here: QuickLocateInBackground saves and restores the cursor position
    // itself (see its own aBookMark local).
    FoundUndo := QuickLocateInBackground(FDbf[dbLog].aDB, 'UNDO', True);
    BitBtnUndo.Enabled := FoundUndo;
  finally
    FDbf[dbLog].aDB.EnableControls;
  end;
end;

procedure TForm1.SetBounds(aCtrl: TControl;
  ALeft, ATop, AWidth, AHeight: Integer);
begin
  if not Assigned(aCtrl) then Exit;
  if (aCtrl.Left <> ALeft) or (aCtrl.Top <> ATop) or
    (aCtrl.Width <> AWidth) or (aCtrl.Height <> AHeight) then
    aCtrl.InvalidatePreferredSize;
  // Acts on aCtrl. The old body called "inherited SetBounds(...)", which
  // always moved TForm1 regardless of what was passed in - aCtrl was used
  // only for the comparison. It looked correct solely because the one
  // caller (LoadConfiguration) passes Self.
  aCtrl.SetBounds(ALeft, ATop, AWidth, AHeight);
end;

procedure TForm1.SetDbField(const aDbType: TDbType;
  const aField, aString: String);
begin
  SafeSetDbField(aDbType, aField, DecodeHTMLEntities(aString));
end;

procedure TForm1.SetFilterEpsOnTitle;
var
  db: TDbf;
  Guard: TDataLayoutGuard;
begin
  // Only the table is needed locally. This used to copy the whole
  // FDbf[dbEps] record (two refcounted strings, plus the implicit
  // try/finally that finalizes them) just to read its aDB; writes still go
  // to FDbf[dbEps] itself, so the status bar and record-count cache see
  // them.
  db := FDbf[dbEps].aDB;
  // 1. Prepare Data
  // The filter target must be GetShowsTitle (the currently SELECTED show,
  // from dbShows), not GetEpsTitle (dbEps's OWN current row) - this used
  // to read GetEpsTitle, which is provably wrong: AfterEpsShow only calls
  // this procedure when "if (GetEpsTitle = GetShowsTitle) then Exit" has
  // already found them DIFFERENT, specifically to correct that mismatch by
  // filtering to the selected show. Filtering by GetEpsTitle instead just
  // re-applies whichever wrong title was already on screen - a no-op at
  // best. It "worked" in practice only when something upstream (e.g. a
  // fresh Append/Locate onto a newly-downloaded episode in
  // actMemoToEpsExecute) happened to leave dbEps's cursor sitting on a
  // row matching the intended show by coincidence; whenever that didn't
  // happen - table already up to date, download skipped or failed, or
  // simply enough shows in EPS.DBF that the coincidence stopped landing -
  // the Episodes tab silently filtered to whatever show was last viewed
  // instead of the one just selected.
  FDbf[dbEps].aFilterText := GetShowsTitle;
  FDbf[dbEps].aFilterDescription := FDbf[dbEps].aFilterText.Quote;
  // 2. Prepare the High-Speed Pointer
  // We do this BEFORE the filter loop starts
  FTitleField := db.FieldByName('TITLE');
  // 3. Apply the Guard (Now simplified/overloaded)
  Guard := TDataLayoutGuard.Create(db);
  // 4. Trigger the Filter
  db.Filtered := False;
  db.OnFilterRecord := @FilterEpsOnTitle;
  db.Filtered := True;
  FDbf[dbEps].aRecCountDirty := True;
  db.First;
end;

procedure TForm1.SetListDirectory(const aString: String);
begin
  SetDbField(dbList, 'DIRECTORY', aString);
end;

procedure TForm1.SetListEpName(const aString: String);
begin
  SetDbField(dbList, 'EPNAME', aString);
end;

procedure TForm1.SetListEpNum(const aString: String);
begin
  SetDbField(dbList, 'EPNUM', aString);
end;

procedure TForm1.SetListExt(const aString: String);
begin
  SetDbField(dbList, 'EXTENSION', aString);
end;

procedure TForm1.SetListFrom(const aString: String);
begin
  SetDbField(dbList, 'FROM', aString);
end;

procedure TForm1.SetListFromPath(const aString: String);
begin
  if GetDbField(dbList, 'FROMPATH') = '' then
    SetDbField(dbList, 'FROMPATH', aString);
end;

procedure TForm1.SetListNameNPath(const aString: String);
begin
  SetDbField(dbList, 'NAMENPATH', aString);
end;

procedure TForm1.SetListTextWidth;
var
  bmp: TSmartBitMap;
  curRec: Integer = 0;
  curWidth: Integer = 0;
  Widest: Integer = 0;
  db: TDbf;
begin
  if g.IsFormSnapped then Exit;
  db := FDbf[dbList].aDB;
  if db.RecordCount <= 0 then Exit;
  curRec := db.RecNo;
  curWidth := 0;
  Widest := 0;
  db.DisableControls;
  db.First;
  while not db.EOF do
  begin
    curWidth := bmp.Value.Canvas.TextWidth(GetListFrom);
    if Widest < curWidth then Widest := curWidth;
    db.Next;
  end;
  Widest := Widest + 60;
  if Widest * 2 > Form1.Width then Form1.Width := Widest * 2;
  DBGridList.Width := Widest;
  db.RecNo := curRec;
  db.EnableControls;
end;

procedure TForm1.SetListTitle(const aString: String);
begin
  SetDbField(dbList, 'TITLE', aString);
end;

procedure TForm1.SetListTo(const aString: String);
begin
  SetDbField(dbList, 'TO', aString);
end;

procedure TForm1.SetListToPath(const aString: String);
begin
  if GetDbField(dbList, 'TOPATH') = '' then
    SetDbField(dbList, 'TOPATH', aString);
end;

procedure TForm1.SetListTreeLevel(const aString: String);
begin
  SetDbField(dbList, 'TREELEVEL', aString);
end;

procedure TForm1.SetLogUndo(const aBoolean: Boolean);
var
  db: TDbf;
begin
  db := FDbf[dbLog].aDB;
  db.Edit;
  db.FieldByName('UNDO').AsBoolean := aBoolean;
  db.Post;
end;

procedure TForm1.SetTabSheetListButtons;
var
  CountFrom, CountTo: Integer;
  db: TDbf;
  SavedBM: TBookmark;
  Guard: TDataLayoutGuard;
begin
  db := FDbf[dbList].aDB;
  if not Assigned(db) then Exit;
  CountFrom := 0;
  CountTo := 0;
  Guard := TDataLayoutGuard.Create(db);
  // Bookmark prevents List grid jumping to the last row on every
  // tsListShow / tsListResize / actClearExecute /
  // actLookupEpsExecute / BitBtnLookupEpsMouseEnter.
  SavedBM := db.GetBookmark;
  try
    BitBtnClear.Enabled := True;
    db.First;
    while not db.EOF do
    begin
      if GetListFrom <> '' then Inc(CountFrom);
      if GetListTo <> '' then Inc(CountTo);
      db.Next;
    end;
    BitBtnLookupEps.Enabled := (CountFrom > 0) and (CountTo < CountFrom);
    BitBtnRename.Enabled := (CountTo > 0);
  finally
    if db.BookmarkValid(SavedBM) then db.GotoBookmark(SavedBM);
  end;
end;

procedure TForm1.SetTabSheetMemoButtons;
var
  p: Integer = 0;
  b: Boolean = False;
  EditBtn: TEditButton;
  NextBtn, PrevBtn: TBitBtn;
begin
  //EXIT GUARD: Check if there are any pages or if the index is valid
  if (pcSourceCode.PageCount = 0) or (pcSourceCode.ActivePageIndex < 0) then
    Exit;
  p := pcSourceCode.ActivePageIndex;
  EditBtn := pcSourceCode.Page[p].FindComponent(
    sb(['EditButton', p.toString])) as TEditButton;
  if EditBtn = nil then Exit;
  b := (EditBtn.Text <> '');
  EditBtn.Button.Enabled := b;
  NextBtn := pcSourceCode.Page[p].FindComponent(
    sb(['BitBtnNext', p.toString])) as TBitBtn;
  if Assigned(NextBtn) then NextBtn.Enabled := b;
  PrevBtn := pcSourceCode.Page[p].FindComponent(
    sb(['BitBtnPrev', p.toString])) as TBitBtn;
  if Assigned(PrevBtn) then PrevBtn.Enabled := b;
end;

procedure TForm1.SetTabSheetSourceCodeButtons(Sender: TObject);
begin
  BitBtnCopyEps.Enabled := (Memo1.Lines.Count > 0);
end;

// Called once, from SetupUI.
procedure TForm1.SetupBrowser;
begin
  // TIpHtmlPanel.OpenURL can't fetch anything without a data provider.
  FBrowserProvider := TFileyHttpDataProvider.Create(Self);
  IpHtmlPanel1.DataProvider := FBrowserProvider;
  IpHtmlPanel1.OnDocumentOpen := @IpHtmlPanel1DocumentOpen;
  IpHtmlPanel1.OnHotClick := @IpHtmlPanel1HotClick;
  // btBack was tied to actPrior, which has no OnExecute - and the LCL keeps
  // an action without one disabled - and btForward to nothing at all.
  btBack.Action := nil;
  btBack.OnClick := @acBackExecute;
  btBack.Hint := 'Back';
  btForward.OnClick := @acForwardExecute;
  btForward.Hint := 'Forward';
  btGo.Hint := 'Open the address in the box (reloads the page showing)';
  // The .lfm's 'http://epguides.com/' looked like a page that was showing.
  edUrl.Text := '';
  edUrl.TextHint := 'Type a web address, then press Enter or click Go!';
  FBrowserHistoryIndex := -1;
  UpdateBrowserButtons;
end;

procedure TForm1.SetupDbAbout;
var
  db: TDbf;
  Grid: TDBGrid;
begin
  db := FDbf[dbAbout].aDB;
  if not Assigned(db) then Exit;
  Grid := DBGridAbout;
  // Set here, after SetupUI gave every grid the generic DBGridDblClick;
  // DBGridAboutDblClick still calls that first.
  Grid.OnDblClick := @DBGridAboutDblClick;
  BuildAboutReport;
  // Restore the position tsInfoHide captured BEFORE the user left this tab
  // - not anything grabbed mid-rebuild, since BuildAboutReport just
  // deleted and recreated every row in ABOUT.DBF. Applied exactly once,
  // here, now that the rebuild is fully done. SafeGo (uDBF.pas) is the
  // bounds-checked move-to-this-recno-if-it-still-exists helper already
  // used elsewhere in this unit for the same save-position/rebuild/
  // restore-position pattern (see DealWithSpecialFiles' use of SpecialRecNo).
  SafeGo(db, FDbf[dbAbout].aSavedRecNo);
  Grid.Options := Grid.Options + [dgRowSelect, dgCellHints];
  Grid.Columns[0].SizePriority := 0;
  Grid.Columns[1].SizePriority := 0;
  Grid.AutoAdvance := aaDown;
  Grid.AutoFillColumns := True;
  Grid.AutoSize := False;
  FDbf[dbAbout].aTabIndex := tsAbout.TabIndex;
  Grid.AutoAdjustColumns;
end;

procedure TForm1.SetupDbEps;
var
  col: TColumn;
  db: TDbf;
  Fld: TField;
  Grid: TDBGrid;
  Guard: TDataLayoutGuard;
  HasIdxLookup, HasSortOrder: Boolean;
  i: Integer;
begin
  db := FDbf[dbEps].aDB;
  Grid := DBGridEps;
  Guard := TDataLayoutGuard.Create(db, Grid, nil);
  // Without this, dbEps silently kept running on the generic
  // DBGridListAfterScroll/BeforeScroll default from CreateAndOpenDBFs,
  // which reports FDbf[dbList]'s (always-empty) filter description
  // instead of dbEps's own - EpsAfterScroll existed but was never
  // actually assigned anywhere.
  db.AfterScroll := @EpsAfterScroll;
  db.BeforeScroll := @EpsBeforeScroll;
  db.Open;
  db.Active := True;
  Grid.BeginUpdate;
  Grid.DataSource := FDbf[dbEps].ADataSource;
  SafeClearGridColumns(Grid);
  for Fld in db.Fields do
  begin
    col := DBGridEps.Columns.Add;
    col.Field := Fld;
    col.Title.Caption := UTF8ProperCase(Fld.FieldName, [Space, '_']);
    col.ButtonStyle := cbsAuto;
    if SameText(Fld.FieldName, 'SORTORDER') then col.Visible := False;
  end;
  Grid.Columns[0].SizePriority := 0;
  Grid.Columns[1].SizePriority := 0;
  Grid.Columns[2].SizePriority := 1;
  // 2. Safe Index Management
  db.IndexName := '';
  db.IndexDefs.Update;
  HasIdxLookup := False;
  HasSortOrder := False;
  // Checks db.IndexDefs for an actual index named SORTORDER - that's
  // what AddIndexExclusive below is gated on, so this needs to check
  // for an INDEX, not a FIELD (a previous version of this loop iterated
  // db.Fields instead, checking for a column named SORTORDER rather
  // than an index of that name; it happened to work only because the
  // column and the index share a name here, which is a coincidence,
  // not a guarantee). Uses a classic indexed loop rather than "for..in"
  // for compatibility across Lazarus versions, per the original intent
  // of this comment.
  for i := 0 to db.IndexDefs.Count - 1 do
  begin
    if SameText(db.IndexDefs[i].Name, 'SORTORDER') then HasSortOrder := True;
  end;

  if (not HasSortOrder) and not IsPhysicallyReadOnly(db) then
  begin
    AddIndexExclusive(db, 'SORTORDER', 'SORTORDER',
      [ixCaseInsensitive, ixunique]);
    HasSortOrder := True;
  end;
  // Setting IndexName to an index that doesn't exist raises, so a
  // read-only EPS.DBF shipped without its .MDX stays in natural order.
  db.IndexName := IfThen(HasSortOrder, 'SORTORDER', '');

  // 3. UI Finalization
  Grid.Options := Grid.Options + [dgRowSelect, dgCellHints];
  Grid.Enabled := True;
  Grid.ReadOnly := IsPhysicallyReadOnly(db);
  Grid.ShowHint := True;
  Grid.AutoFillColumns := True;
  Grid.PopupMenu := MenuEps;
  DBNavigatorEps.DataSource := FDbf[dbEps].ADataSource;
  // Refresh is deliberately left enabled even when there's nothing to Zap
  // (a disabled button doesn't show its hint on most widgetsets), and
  // db.TableName never changes for the life of the app, so this hint only
  // needs to be set once, here - not re-set on every hover/resize/scroll.
  THackDBNavigator(DBNavigatorEps).Buttons[nbRefresh].Hint :=
    'Zap ' + db.TableName;
  FDbf[dbEps].aTabIndex := tsEps.TabIndex;
  if Assigned(FDbf[dbTempEps].aDB) then FDbf[dbTempEps].aTabIndex := -1;
  db.First;
  Grid.EndUpdate;
end;

procedure TForm1.SetupDbList;
var
  db: TDbf;
  fFrom, fTo: TField;
  Grid: TDBGrid;
  Guard: TDataLayoutGuard;
begin
  db := FDbf[dbList].aDB;
  Grid := DBGridList;
  Guard := TDataLayoutGuard.Create(db, Grid, nil);
  db.AfterScroll := @DBGridListAfterScroll;
  // must be inactive to set this
  db.BeforeScroll := @DBGridListBeforeScroll;
  db.Open;
  db.EnableControls;
  db.Active := True; // active, to get physicalrecordcount}
  Grid.DataSource := FDbf[dbList].ADataSource;
  SafeClearGridColumns(Grid);
  // Looked up once each instead of twice (Field, then FieldName below).
  fFrom := db.FieldByName('FROM');
  fTo := db.FieldByName('TO');
  Grid.Columns.Add;
  Grid.Columns[0].Field := fFrom;
  Grid.Columns[0].Title.Caption :=
    UTF8ProperCase(fFrom.FieldName, [Space, '_']);
  Grid.Columns[0].ButtonStyle := cbsAuto;
  Grid.Columns[0].Width := (Grid.Width div 2) - DEFINDICATORCOLWIDTH;
  Grid.Columns.Add;
  Grid.Columns[1].Field := fTo;
  Grid.Columns[1].Title.Caption := UTF8ProperCase(fTo.FieldName, [Space, '_']);
  Grid.Columns[1].ButtonStyle := cbsAuto;
  Grid.Columns[1].Width := Grid.Columns[0].Width;
  Grid.Options := Grid.Options + [dgRowSelect, dgCellHints];
  Grid.Enabled := True;
  Grid.Visible := True;
  Grid.AutoAdvance := aaDown;
  PanelFilesGrid.ShowHint := True;
  PanelFilesGrid.Hint := 'Drop here files to be renamed';
  actClearExecute(db);
  db.First;
  DBGridListSetColumnWidths;
  FDbf[dbList].aTabIndex := tsList.TabIndex;
end;

procedure TForm1.SetupDbLog;
var
  db: TDbf;
  fDateTime, fFrom, fTo, fUndo: TField;
  Fld: TField;
  Grid: TDBGrid;
  Guard: TDataLayoutGuard;
begin
  db := FDbf[dbLog].aDB;
  Grid := DBGridLog;
  Guard := TDataLayoutGuard.Create(db, Grid, nil);
  db.AfterPost := @LogAfterPost;
  db.AfterScroll := @LogAfterScroll;
  db.BeforeScroll := @LogBeforeScroll;
  db.BeforeEdit := @LogBeforeEdit;
  db.EnableControls;
  db.Active := True;
  DBNavigatorLog.DataSource := FDbf[dbLog].ADataSource;
  // See the matching comment in SetupDbEps: this hint is static for the
  // life of the app, so it's set once here rather than repeatedly.
  THackDBNavigator(DBNavigatorLog).Buttons[nbRefresh].Hint :=
    'Zap ' + db.TableName;
  Grid.DataSource := FDbf[dbLog].ADataSource;
  SafeClearGridColumns(Grid);
  // Looked up once each instead of twice (Field, then FieldName below).
  fUndo := db.FieldByName('UNDO');
  fDateTime := db.FieldByName('DATETIME');
  fFrom := db.FieldByName('FROM');
  fTo := db.FieldByName('TO');
  // UNDO Column - SPECIAL HANDLING FOR BOOLEAN FIELD
  Grid.Columns.Add;
  Grid.Columns[0].Field := fUndo;
  Grid.Columns[0].Title.Caption :=
    UTF8ProperCase(fUndo.FieldName, [Space, '_']);
  // CRITICAL: Set ButtonStyle to cbsNone for Boolean field to prevent floating editor
  Grid.Columns[0].ButtonStyle := cbsNone; // NOT cbsAuto!
  Grid.Columns[0].MinSize := 20;
  Grid.Columns[0].SizePriority := 0;
  Grid.Columns[0].ReadOnly := False; // DATETIME Column
  Grid.Columns.Add;
  Grid.Columns[1].Field := fDateTime;
  Grid.Columns[1].Title.Caption :=
    UTF8ProperCase(fDateTime.FieldName, [Space, '_']);
  Grid.Columns[1].ButtonStyle := cbsNone;
  //Use cbsNone for consistent behavior
  Grid.Columns[1].MinSize := 100;
  Grid.Columns[1].SizePriority := 0;
  Grid.Columns[1].ReadOnly := False; //FROM Column
  Grid.Columns.Add;
  Grid.Columns[2].Field := fFrom;
  Grid.Columns[2].Title.Caption :=
    UTF8ProperCase(fFrom.FieldName, [Space, '_']);
  Grid.Columns[2].ButtonStyle := cbsNone;
  //Use cbsNone for consistent behavior}
  Grid.Columns[2].Width :=
    ((Grid.Width - Grid.Columns[0].Width - Grid.Columns[1].Width) div 2) -
    DEFINDICATORCOLWIDTH;
  Grid.Columns[2].SizePriority := 0;
  Grid.Columns[2].ReadOnly := False;  // TO Column
  Grid.Columns.Add;
  Grid.Columns[3].Field := fTo;
  Grid.Columns[3].Title.Caption := UTF8ProperCase(fTo.FieldName, [Space, '_']);
  Grid.Columns[3].ButtonStyle := cbsNone;
  //Use cbsNone for consistent behavior
  Grid.Columns[3].Width :=
    Grid.Columns[2].Width;
  Grid.Columns[3].SizePriority := 0;
  Grid.Columns[3].ReadOnly := False;
  // CRITICAL: Proper options for Boolean field editing
  Grid.Options := Grid.Options - [dgAlwaysShowSelection] +
    [dgRowSelect, dgEditing, dgCellHints, dgAlwaysShowEditor, dgDisableInsert];
  // Ensure fields are not ReadOnly
  for Fld in db.Fields do Fld.ReadOnly := False;
  Grid.Enabled := True;
  Grid.Visible := True;
  Grid.Top := 2;
  Grid.Left := 2;
  Grid.ShowHint := True;
  Grid.AutoAdvance := aaDown;
  Grid.AutoEdit := True;
  Grid.AutoFillColumns := True;
  db.ReadOnly := IsPhysicallyReadOnly(db);
  Grid.OnDrawColumnCell := @DBGridLogDrawColumnCell;
  AssignDBGridLogEvents;
  AdjustColumns(Grid);
  FDbf[dbLog].aTabIndex := tsLog.TabIndex;
end;

procedure TForm1.SetupDbShows;
var
  db: TDbf;
  Grid: TDBGrid;
  HasTitle: Boolean;
  i: Integer;
begin
  db := FDbf[dbShows].aDB;
  if not Assigned(db) then Exit;
  if not Assigned(DBGridShows) then Exit;
  if not Assigned(Self.Canvas.Font) then Exit;
  Grid := DBGridShows;
  db.AfterScroll := @DBGridShowsAfterScroll;
  // must be inactive to set this
  db.BeforeScroll := @DBGridShowsBeforeScroll;
  // Only (re)build TITLE when it isn't already there - same pattern as
  // SetupDbEps's HasSortOrder check below. Unconditionally clearing
  // IndexDefs and calling AddIndexExclusive on every single launch meant
  // every startup needed a fresh exclusive lock on SHOWS.DBF for no
  // reason once the index already existed - exactly the lock a
  // just-exited prior run can leave transiently unavailable under Wine
  // (see AcquireExclusive's retry in uDBFManager.pas for the other half
  // of this fix).
  db.IndexDefs.Update;
  HasTitle := False;
  for i := 0 to db.IndexDefs.Count - 1 do
    if SameText(db.IndexDefs[i].Name, 'TITLE') then HasTitle := True;
  if not HasTitle then
  begin
    if IsPhysicallyReadOnly(db) then
    begin
      // Can't write an index to read-only media. Use TITLE if it came with
      // the table (the .MDX alongside it), otherwise stay in natural order.
      if DbfHasIndex(db, 'TITLE') then db.IndexName := 'TITLE'
      else db.IndexName := '';
    end
    else
    begin
      db.IndexDefs.Clear;
      AddIndexExclusive(db, 'TITLE', 'TITLE', [ixCaseInsensitive, ixunique]);
      db.IndexName := 'TITLE';
      db.RegenerateIndexes;
    end;
    db.First;
  end;
  db.IndexName := 'TITLE';
  db.First;
  Grid.DataSource := FDbf[dbShows].ADataSource;
  SafeClearGridColumns(Grid);
  if (db.Fields.Count > 0) then for i := 0 to (db.Fields.Count - 1) do
    begin
      Grid.Columns.Add;
      Grid.Columns[i].Field := db.Fields[i];
      Grid.Columns[i].Title.Caption :=
        UTF8ProperCase(db.Fields[i].FieldName, [Space, '_']);
      Grid.Columns[i].ButtonStyle := cbsAuto;
      Grid.Columns[i].MinSize := Max(0, Grid.Columns[i].Tag);
    end;
  if (Grid.Columns.Count >= 2) then
  begin
    Grid.Columns[0].MinSize := 140;
    Grid.Columns[0].SizePriority := 0;
    Grid.Columns[1].MinSize := 140;
    Grid.Columns[1].SizePriority := 0;
  end;
  Grid.Enabled := True;
  Grid.AutoAdjustColumns;
  Grid.Columns.Move(Grid.Columns.ColumnByFieldname('LOOKUPDATE').Index, 2);
  Grid.Columns[2].MinSize := 140;
  Grid.Columns[2].SizePriority := 1;
  for i := 3 to (db.Fields.Count - 1) do Grid.Columns[i].Visible := False;
  Grid.ShowHint := True;
  Grid.AutoAdvance := aaDown;
  Grid.AutoFillColumns := True;
  Grid.Enabled := True;
  AdjustColumns(Grid);
  Grid.Options := Grid.Options + [dgRowSelect, dgCellHints];
  Grid.PopupMenu := MenuShows;
  // Policy default only - never lifts PHYSICAL read-only.
  db.ReadOnly := IsPhysicallyReadOnly(db);
  DBNavigatorShows.DataSource := FDbf[dbShows].ADataSource;
  FDbf[dbShows].aTabIndex := tsShows.TabIndex;
  // TEMPORARY DIAGNOSTIC - remove once the Wine SHOWS.DBF reimport cause is
  // confirmed. Captures SHOWS after AddIndexExclusive/RegenerateIndexes/
  // First, right before SyncShowsDatabase makes its IsEmpty decision - if
  // this already shows RecordCount=0 where checkpoint 1 (InitializeDBFs)
  // didn't, the index rebuild itself is what's losing the rows on Wine.
  if IsDebugBuild then DebugLog(
      sb(['SetupDbShows: SHOWS after RegenerateIndexes/First - ' +
      'Active=', IfThen(db.Active), ' RecordCount=',
      db.RecordCount, ' PhysicalRecordCount=', db.PhysicalRecordCount,
      ' IndexName="', db.IndexName, '" Filtered=', IfThen(db.Filtered),
      ' BOF=', IfThen(db.BOF), ' EOF=', IfThen(db.EOF)]));
  SyncShowsDatabase;
  // After the import, which (when it ran) leaves nothing to refresh.
  RefreshShowsSearchKeys;
end;

// File menu > New file names: the reserved-character and word-separator
// choices, as two groups of radio items, above the separator before Exit.
// Made here rather than in uMain.lfm, like the Readme tab's Back button.
// Owned by the form.
procedure TForm1.SetupNameStyleMenu;

  function AddItem(AParent: TMenuItem; const ACaption: String;
    ATag, AGroup: Integer): TMenuItem;
  begin
    Result := TMenuItem.Create(Self);
    Result.Caption := ACaption;
    Result.Tag := ATag;
    Result.RadioItem := True;
    Result.GroupIndex := AGroup;
    Result.OnClick := @NameStyleMenuClick;
    AParent.Add(Result);
  end;

var
  Divider, Sub: TMenuItem;
begin
  if Assigned(FNameStyleItems[NAME_STYLE_RESERVED_LOOKALIKE]) then Exit;
  Sub := TMenuItem.Create(Self);
  Sub.Caption := 'New file names';
  // The captions show the result, so a menu font without the look-alike
  // shows that straight away.
  // RESERVED_LOOKALIKES[0] is the colon's look-alike.
  FNameStyleItems[NAME_STYLE_RESERVED_LOOKALIKE] := AddItem(Sub,
    'Look-alikes for  : ? * / " and the rest:   Star Trek' +
    RESERVED_LOOKALIKES[0].Lookalike + ' Strange New Worlds',
    NAME_STYLE_RESERVED_LOOKALIKE, 1);
  FNameStyleItems[NAME_STYLE_RESERVED_UNDERSCORE] := AddItem(Sub,
    'Underscores for  : ? * / " and the rest:   Star Trek_ Strange New Worlds',
    NAME_STYLE_RESERVED_UNDERSCORE, 1);
  Divider := TMenuItem.Create(Self);
  Divider.Caption := '-';
  Sub.Add(Divider);
  FNameStyleItems[NAME_STYLE_SPACES] := AddItem(Sub,
    'Words separated by spaces:  Show S01E01 Episode Name 1080p.mkv',
    NAME_STYLE_SPACES, 2);
  FNameStyleItems[NAME_STYLE_DOTS] := AddItem(Sub,
    'Words separated by dots:  Show.S01E01.Episode.Name.1080p.mkv',
    NAME_STYLE_DOTS, 2);
  FNameStyleItems[NAME_STYLE_RESERVED_LOOKALIKE].Checked :=
    g.ReservedCharStyle = rcsLookalike;
  FNameStyleItems[NAME_STYLE_RESERVED_UNDERSCORE].Checked :=
    g.ReservedCharStyle = rcsUnderscore;
  FNameStyleItems[NAME_STYLE_SPACES].Checked := g.WordSeparator = wsSpace;
  FNameStyleItems[NAME_STYLE_DOTS].Checked := g.WordSeparator = wsDot;
  MenuItem1.Insert(MenuItemSeparator.MenuIndex, Sub);
end;

// The Readme tab's Back button, made here rather than in uMain.lfm so the
// whole feature lives in code. It borrows the Browser tab's Back arrow so
// the two look alike. Owned by the form, which frees it.
procedure TForm1.SetupReadmeBack;
begin
  if Assigned(FReadmeBack) then Exit;
  FReadmeBack := TBitBtn.Create(Self);
  FReadmeBack.Caption := 'Back';
  FReadmeBack.Hint := 'Back to the previous document';
  FReadmeBack.Glyph.Assign(btBack.Glyph);
  FReadmeBack.AutoSize := True;
  FReadmeBack.Enabled := False;
  FReadmeBack.OnClick := @ReadmeBackClick;
  // TToolBar lays its controls out by row, then by Left: same row as
  // BitBtnOpenReadme and a smaller Left puts Back first.
  FReadmeBack.Top := BitBtnOpenReadme.Top;
  FReadmeBack.Left := 0;
  FReadmeBack.Parent := ToolBarMemo1;
end;

procedure TForm1.SetupUI;
begin
  // Fonts are NOT set here: LoadConfiguration (which runs first) sets them
  // from the ini, or from DEFAULT_SERIF_FONTS/DEFAULT_MONO_FONTS. Setting
  // them here as well discarded the user's saved choice on every start.
  FontDialog.MinFontSize := 6;
  FontDialog.MaxFontSize := 48;
  FontDialog.Options := [fdForceFontExist, fdLimitSize];
  StatusBar.Panels[0].Style := psOwnerDraw;
  StatusBar.Panels[0].Width := StatusBar.Width - 2;
  StatusBar.Align := alBottom;
  StatusBar.AutoSize:= True;
  StatusBar.BringToFront; // win32 sometimes hides it behind the alClient control
  pcMain.Align := alClient;
  StatusBar.Invalidate;
  // Progress page geometry: anchored once. Anchors keep it right through any
  // resize, and a fixed-size label never needs an autosize pass to show new
  // text - so a DisableAutoSizing lock elsewhere can't hide it.
  ProgressPanelHeader.Height := 50;
  ProgressPanelMiddle.DisableAlign;
  ProgressPanelBottom.DisableAlign;
  try
    ProgressBitBtn.Anchors := [];
    ProgressBitBtn.AnchorHorizontalCenterTo(ProgressPanelBottom);
    ProgressBitBtn.AnchorVerticalCenterTo(ProgressPanelBottom);
    ProgressBar.Anchors := [];
    ProgressBar.AnchorParallel(akLeft, 1, ProgressPanelMiddle);
    ProgressBar.AnchorParallel(akRight, 1, ProgressPanelMiddle);
    ProgressBar.AnchorVerticalCenterTo(ProgressPanelMiddle);
    ProgressLabel.AutoSize := False;
    ProgressLabel.WordWrap := True;
    ProgressLabel.Alignment := taCenter;
    ProgressLabel.Caption := '';
    ProgressLabel.Anchors := [];
    ProgressLabel.AnchorToNeighbour(akTop, 10, ProgressBar);
    ProgressLabel.AnchorParallel(akLeft, 4, ProgressPanelMiddle);
    ProgressLabel.AnchorParallel(akRight, 4, ProgressPanelMiddle);
    ProgressLabel.AnchorParallel(akBottom, 4, ProgressPanelMiddle);
  finally
    ProgressPanelBottom.EnableAlign;
    ProgressPanelMiddle.EnableAlign;
  end;
  TabSheetAlignButtons;
  SetupBrowser;
  SetupNameStyleMenu;
  // Set here, overriding uMain.lfm. The .lfm's set included ofShowHelp,
  // which makes Windows add a Help button that posts its click to the
  // owner window - nothing here handles it, and the classic XP-era dialog
  // is known to refuse to open with it in some configurations - and
  // ofReadOnly, which pre-ticks an "Open as read-only" box nothing reads.
  // ofHideReadOnly removes that box; ofPathMustExist matches
  // ofFileMustExist.
  OpenDialog.Options := [ofAllowMultiSelect, ofFileMustExist,
    ofPathMustExist, ofHideReadOnly, ofEnableSizing, ofViewDetail];
  OpenDialog.Title := 'Add files to rename';
  //FitStatusBarHeight;
end;

// Shows APage, fetched by DownloadBrowserPage: an HTML page (simplified,
// with its images fetched first), an image, or text. Anything else goes to
// the system's own program. True if it is now showing in IpHtmlPanel1.
function TForm1.ShowBrowserPage(APage: TBrowserDownload): Boolean;
var
  ImageSources: TSmartStrings;
  iMissing: Integer;
  sData, sImageURL, sPageURL, sTitle: String;
begin
  Result := False;
  // Redirects included - relative links on the page are relative to this.
  sPageURL := APage.FinalURL;
  if APage.NotViewable then
  begin
    HandBrowserPageToSystem(sPageURL);
    Exit;
  end;
  if not APage.OK then raise Exception.Create(APage.ErrorText);
  // Before anything is added for this page, so none of it is thrown away.
  FBrowserProvider.TrimImageCache;
  case BrowserContentKind(APage.ContentType, APage.Data) of
    bckHtml: sData := SimplifyHtmlForViewer(APage.Data, ImageSources.Value);
    bckText: sData := PlainTextAsHtml(APage.Data);
    bckImage:
      begin
        // A page holding just the image, which IPro then asks GetImage for
        // - by this same address, so that is the cache key too.
        sImageURL := StringReplace(sPageURL, '"', '%22', [rfReplaceAll]);
        FBrowserProvider.AddImage(sImageURL, APage.Data);
        sData := ImagePageHtml(sImageURL);
      end;
    else
      begin
        HandBrowserPageToSystem(sPageURL);
        Exit;
      end;
  end;
  // Everything is shown as HTML by now, the image and the text included.
  FBrowserProvider.SetDocument(sPageURL, 'text/html', sData);
  iMissing := LoadBrowserImages(sPageURL, ImageSources.Value);
  if FBrowserCancel or FIsShuttingDown then Exit;
  IpHtmlPanel1.OpenURL(sPageURL);
  // IPro handed it over after all (a frame it can't show).
  if FBrowserHandedOff then Exit;
  Result := True;
  sTitle := Trim(IpHtmlPanel1.Title);
  FBrowserStatus := IfThen(sTitle.IsEmpty, g.LastURL,
    sb([sTitle, '  -  ', g.LastURL]));
  if iMissing > 0 then
    FBrowserStatus := sb([FBrowserStatus, '   (', iMissing,
      ' of its images could not be loaded)']);
end;

// sanity check to ShowMessage DBF's current condition
function TForm1.ShowDataSetStates(const DataSet: TDataSet): String;
begin
  Result := sb([DataSet.Name, LE]);
  case DataSet.State of
    dsInactive: sb(Result, 'dsInactive ');
    dsBrowse: sb(Result, 'dsBrowse ');
    dsEdit: sb(Result, 'dsEdit ');
    dsInsert: sb(Result, 'dsInsert ');
    dsSetKey: sb(Result, 'dsSetKey ');
    dsCalcFields: sb(Result, 'dsCalcFields ');
    dsFilter: sb(Result, 'dsFilter ');
    dsNewValue: sb(Result, 'dsNewValue ');
    dsOldValue: sb(Result, 'dsOldValue ');
    dsCurValue: sb(Result, 'dsCurValue ');
    dsBlockRead: sb(Result, 'dsBlockRead ');
    dsInternalCalc: sb(Result, 'dsInternalCalc ');
    dsOpening: sb(Result, 'dsOpening ');
    dsRefreshFields: sb(Result, 'dsRefreshFields ');
  end;
  ShowMessage(Result);
end;

procedure TForm1.ShowDBFsStatusClick(Sender: TObject);
var
  DForm: TSmartDialogForm; // RAII
  DbIndex: TDbType;
begin
  DForm.Setup('Status of DBF files:', Self.Canvas.Font);
  for DbIndex in TDbType do
  begin
    DForm.Value.DialogMemo.Lines.Add(
      GetDBFStatus(FDbf[DbIndex].aDB));
    DForm.Value.DialogMemo.Lines.Add('');
  end;
  DForm.Value.Height := Self.Height - 170;
  DForm.ShowModal;
end;

procedure TForm1.ShowDBFStatus(aDB: TDbf);
begin
  ShowMessage(GetDBFStatus(aDB));
end;

procedure TForm1.ShowEpisodeParsingStats;
var
  db: TDbf;
  Guard: TDataLayoutGuard;
  ParsedFiles: Integer = 0;
  s: TStringList;
  StatsList: TSmartStrings;
  TotalFiles: Integer = 0;
  ValidEpisodes: Integer = 0;
begin
  db := FDbf[dbList].aDB;
  // RAII: the previous code called DisableControls here but never called
  // EnableControls anywhere in this procedure - the grid was left
  // permanently disabled after every single call, success or not.
  // TDataLayoutGuard re-enables it automatically when this scope exits.
  Guard := TDataLayoutGuard.Create(db);
  TotalFiles := db.RecordCount;
  ParsedFiles := 0;
  ValidEpisodes := 0;
  db.First;
  while not db.EOF do
  begin
    if Length(GetListEpNum) > 0 then
    begin
      Inc(ParsedFiles);
      if FEpisodeMatcher.ValidateEpisodeNumber(GetListEpNum) then
        Inc(ValidEpisodes);
    end;
    UI.Check;
    db.Next;
  end;
  s := StatsList.Value;
  s.Add('Episode Parsing Statistics:');
  s.Add('=========================');
  s.Add(sb(['Total files: ', ns(TotalFiles)]));
  s.Add(sb(['Files with episode numbers: ', ns(ParsedFiles)]));
  s.Add(sb(['Valid episode formats: ', ns(ValidEpisodes)]));
  // Both denominators are 0 on an empty (or entirely unparsed) List table,
  // which is the normal state right after a Clear.
  if TotalFiles > 0 then
    s.Add(sb(['Parse success rate: ', Format('%.1f%%',
      [(ParsedFiles / TotalFiles) * 100])]))
  else
    s.Add('Parse success rate: n/a (no files loaded)');
  if ParsedFiles > 0 then
    s.Add(sb(['Validation success rate: ', Format('%.1f%%',
      [(ValidEpisodes / ParsedFiles) * 100])]))
  else
    s.Add('Validation success rate: n/a (no episode numbers found)');
  MessageList('Episode Statistics', s);
end;

// Shows one file's extraction on the Progress page the way
// actZipSourcesExecute shows each file it zips: the file name under the bar,
// the bar driven 0..100 by ZipperProgress, and a line in the StatusBar. Only
// CheckResourceFiles' extractions come through here.
procedure TForm1.ShowExtractProgress(const AFileName: String);
begin
  // Switches on the first file that actually needs extracting, not on entry
  // to CheckResourceFiles: on an ordinary launch everything is already on
  // disk, and flashing an empty Progress page every time would be noise.
  if pcMain.ActivePage <> tsProgress then pcMain.ActivePage := tsProgress;
  ProgressPanelHeader.Caption := 'Extracting resource files';
  ProgressBar.Min := 0;
  ProgressBar.Max := 100;
  ProgressBar.Position := 0;
  ProgressLabel.Caption := 'Extracting: ' + AFileName;
  StatusBar.Panels[0].Text :=
    sb(['Extracting ', AFileName, ' to ', g.OpPath.Value]);
  // Unthrottled, unlike UI.Check: this runs once per file, and the new name
  // belongs on screen before a multi-megabyte entry starts decompressing.
  StatusBar.Invalidate;
  Application.ProcessMessages;
end;

procedure TForm1.ShowMessageList(var aList: TStringList);
var
  s: String;
  sResult: String;
begin
  sResult := '';
  for s in aList do sb(sResult, [s, LE]);
  ShowMessage(sResult);
end;

// Loads ADoc (a README_DOCS name) into vwReadme, scrolled to AAnchor when
// that names a place in it, otherwise to APosition. False, with the page
// on show left as it was, if this build doesn't carry ADoc.
function TForm1.ShowReadmeDoc(const ADoc: String; APosition: Integer;
  const AAnchor: String): Boolean;
begin
  Result := LoadBundledDoc(vwReadme, ADoc);
  if not Result then Exit;
  if AAnchor.IsEmpty or not vwReadme.Value.PositionTo(UTF8Decode(AAnchor)) then
    vwReadme.Value.Position := APosition;
end;

procedure TForm1.ShowsFilterEditButtonClick(Sender: TObject);
begin
  actFilterEditCancelExecute(Sender);
end;

procedure TForm1.ShowsFilterEditChange(Sender: TObject);
begin
  FindMyTitle(ShowsFilterEdit.Text);
  ShowsFilterEdit.Button.Enabled := ShowsFilterEdit.Text <> '';
  SmartAutoAdjustColumns(DBGridShows, FShowsColumnsThrottle);
end;

procedure TForm1.ShowsFilterEditEditingDone(Sender: TObject);
begin
  // Do NOT Put FindMyTitle(ShowsFilterEdit.Text) here, causes MAYHEM!
  // if ShowsFilterEdit.GetTextLen=0 then ShowsFilterEdit.Button.Click;
  SmartAutoAdjustColumns(DBGridShows, FShowsColumnsThrottle);
end;

procedure TForm1.ShowsFilterEditKeyPress(Sender: TObject; var Key: char);
begin
  LastKeyTyped := Key;
  SmartAutoAdjustColumns(DBGridShows, FShowsColumnsThrottle);
end;

procedure TForm1.ShowsFilterEditKeyUp(Sender: TObject;
  var Key: word; Shift: TShiftState);
begin
  if (Key <> VK_BACK) then Exit;
  if ShowsFilterEdit.Text = '' then ShowsFilterEdit.Button.Click;
  SmartAutoAdjustColumns(DBGridShows, FShowsColumnsThrottle);
end;

procedure TForm1.ShowsFilterEditMouseEnter(Sender: TObject);
begin
  if ShowsFilterEdit.CanFocus then ShowsFilterEdit.SetFocus;
end;

procedure TForm1.ShowsFilterEditMouseLeave(Sender: TObject);
begin
  if ShowsFilterEdit.Text = '' then ShowsFilterEdit.Button.Click;
end;

procedure TForm1.ShowStatusBrowser;
var
  s: String;
begin
  if pcMain.ActivePage <> tsBrowser then Exit;
  StatusBar.Visible := True;
  s := FBrowserStatus;
  if s.IsEmpty then s := 'Type a web address, then press Enter or click Go!';
  StatusBar.Panels[0].Text := s;
  StatusBar.Hint := s;
end;

procedure TForm1.ShowStatusDBF(aDbType: TDbType);
var
  db: TDbf;
  sHint: String;
begin
  db := FDbf[aDbType].aDB;
  if tsSourceCode.Showing then Exit;
  if not (Assigned(db) and db.Active) then Exit;
  // GetDBStatus below calls aDB.ExactRecordCount (via the aCachedRecCount/
  // aRecCountDirty cache on FDbf[ADbType] - see uDBF.TDBRecord), which for
  // a DBF has to walk the table to honor any active filter when the cache
  // is dirty - there's no query engine to cache it for us. Even with that
  // cache, there's no reason to touch the StatusBar at all while a bulk
  // loop has this table's controls disabled - DBGridShowsAfterScroll
  // already guarded against this itself; DBGridListBeforeScroll/
  // AfterScroll, DBGridShowsBeforeScroll, and LogBeforeScroll/AfterScroll
  // did not, so any loop that disables controls and then navigates
  // dbList/dbShows/dbLog record-by-record (ParseFilesList, RenameThisList,
  // actLookupEpsExecute, AssignRootNameToAssociatedFiles,
  // ShowEpisodeParsingStats, the shows sync, undo, etc.) was doing this
  // work on every single row. Guarding it once here, rather than in each
  // handler, protects every existing and future caller without relying on
  // remembering to add it per call site.
  if db.ControlsDisabled then Exit;
  StatusBar.Visible := True;
  StatusBar.Panels[0].Text := GetDBStatus(FDbf[aDbType]);
  // The badge (READ-ONLY / LOCKED / COPY) costs almost no bar space; the
  // reason behind it goes in the hint, which costs none.
  sHint := GetDBStatusHint(db);
  if sHint = '' then StatusBar.Hint := StatusBar.Panels[0].Text
  else StatusBar.Hint := sb([StatusBar.Panels[0].Text, LE, LE, sHint]);
end;

procedure TForm1.ShowStatusSourceCode;
var
  se: TSynEdit;
begin
  if (pcMain.ActivePage <> tsAbout) or (pcAbout.ActivePage <>
    tsSourceCode) then Exit;
  se := ActiveSourceSynEdit;
  if not Assigned(se) then Exit;
  // sheets not built yet; UpdateStatusBar retries
  StatusBar.Visible := True;
  StatusBar.Panels[0].Text :=
    sb([IfThen(se.ReadOnly, STATUS_READONLY_TAG + ' ', ''),
    pcSourceCode.ActivePage.Caption, ' Ln ', ns(se.CaretY),
    '/', ns(se.Lines.Count), ' Col ', ns(se.CaretX)]);
  StatusBar.Hint := StatusBar.Panels[0].Text;
end;

// Exception: while ShowsFilterEdit has focus, the person is actively
// typing and watching results update per keystroke, so the debounce is
// skipped entirely - every keystroke gets its own immediate refresh.
// The debounce still protects the tab-show burst (tsShowsShow + its
// queued AfterShowsShow) and any Button.Click-triggered path that
// fires while the edit does NOT have focus (e.g. MouseLeave).
procedure TForm1.SmartAutoAdjustColumns(aGrid: TDBGrid;
  var AThrottle: TThrottledUI);
begin
  if not Assigned(aGrid) then Exit;
  if not ShowsFilterEdit.Focused then if not AThrottle.TryProceed then Exit;
  aGrid.AutoAdjustColumns;
end;

procedure TForm1.StatusBarDrawPanel(statBar: TStatusBar;
  Panel: TStatusPanel; const Rect: TRect);
const
  BADGE_PAD = 4;
var
  BadgeBack, BadgeFore, SavedBrush, SavedFont: TColor;
  BadgeRect: TRect;
  BadgeTag, s: String;
  c: TCanvas;
  X, TextH, TextY: Integer;

// True if s starts with ATag as a whole word; records its colours.
  function MatchBadge(const ATag: String; ABack, AFore: TColor): Boolean;
  begin
    Result := (Copy(s, 1, Length(ATag)) = ATag) and
      ((Length(s) = Length(ATag)) or (s[Length(ATag) + 1] = ' '));
    if not Result then Exit;
    BadgeTag := ATag;
    BadgeBack := ABack;
    BadgeFore := AFore;
  end;

begin
  FStatusBarPainted := True; // first-paint signal for DeferredStartup
  if (Panel <> statBar.Panels[0]) then Exit;

  c := statBar.Canvas;
  SavedBrush := c.Brush.Color;
  SavedFont := c.Font.Color;
  c.FillRect(Rect);
  s := Panel.Text;
  // Centred in the panel. 'Wg' (ascender + descender) rather than s, so
  // the baseline doesn't jump when the text changes.
  TextH := c.TextHeight('Wg');
  TextY := Rect.Top + (Rect.Height - TextH) div 2;
  X := Rect.Left + 2;
  BadgeTag := '';
  // System colours so the badges follow light and dark themes: READ-ONLY
  // uses the selection colours, COPY the tooltip colours. LOCKED is a
  // fixed white-on-maroon, which reads on either theme and stands apart
  // from both.
  if MatchBadge(STATUS_LOCKED_TAG, clMaroon, clWhite) or
    MatchBadge(STATUS_READONLY_TAG, clHighlight, clHighlightText) or
    MatchBadge(STATUS_WORKCOPY_TAG, clInfoBk, clInfoText) then
  begin
    BadgeRect.Left := X;
    BadgeRect.Top := Rect.Top + 1;
    BadgeRect.Right := X + c.TextWidth(BadgeTag) + 2 * BADGE_PAD;
    BadgeRect.Bottom := Rect.Bottom - 1;
    c.Brush.Color := BadgeBack;
    c.FillRect(BadgeRect);
    c.Brush.Style := bsClear;
    c.Font.Color := BadgeFore;
    c.TextOut(X + BADGE_PAD, TextY, BadgeTag);
    c.Brush.Style := bsSolid;
    c.Brush.Color := SavedBrush;
    c.Font.Color := SavedFont;
    X := BadgeRect.Right + BADGE_PAD;
    // Tags are pure ASCII, so byte-indexed Copy is UTF-8 safe here.
    s := TrimLeft(Copy(s, Length(BadgeTag) + 1, MaxInt));
  end;
  c.TextOut(X, TextY, s);
end;

procedure TForm1.StatusBarMouseDown(Sender: TObject;
  Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if Button = mbRight then actStatusBarFontExecute(Sender);
end;

procedure TForm1.SwapFromTo(var Op: TRenameOperationState);
var
  LField: TField;
  db: TDbf;
begin
  db := FDbf[dbList].aDB;
  Op.From := GetListTo;
  if Op.ToPath <> '' then Op.FromPath := Op.ToPath;
  db.Edit;
  try
    for LField in db.Fields do LField.Clear;
    //Clear is safer/faster than AsString := ''
    SetListFrom(CombinePath(Op.FromPath, Op.From));
    PostRecord(db);
  except
    on E: Exception do
    begin
      db.Cancel;
      //Log it or show a safe message
      LogError('SwapFromTo Error: ' + E.Message);
    end;
  end;
end;

function TForm1.sYearAndEpNumOnlyNoEpName: String;
var
  curFile: String = '';
  Match: TEpisodeMatch;
begin
  Result := '';
  Match := Default(TEpisodeMatch);
  curFile := efnOnly(GetListFrom);
  // FindYear (-> FindYearExec) now unconditionally resets g.Year, g.Title,
  // and g.EpName itself on every exit path, so these three lines are
  // redundant. Left commented rather than deleted until that's proven out
  // in practice - if FindYearExec's guarantee ever turns out to have a gap,
  // uncommenting this is the one-line fix.
  //g.Year := '';
  //g.Title := '';
  //g.EpName := '';
  FindYear(curFile);
  if g.Year = '' then Exit;
  Match := FEpisodeMatcher.GetEpNumName(g.EpName);
  if not Match.Found then Exit;
  g.EpNum := Match.EpNum;
  if g.EpNum = '' then Exit;
  SetListTitle(NormalizeTitleAndYear(g.Title + g.Year));
  SetListEpNum(g.EpNum);
  Result := GetListTitle;
end;

// Orchestrator - same 7 steps as before, each step now a call instead of
// an inline block.
procedure TForm1.SyncShowsDatabase;
var
  CSVLines: TSmartStrings;  // RAII: Managed StringList
  db: TDbf;
  Guard: TDataLayoutGuard;  // RAII: Restores UI/DB on crash or shutdown
  ProcessedCount, TotalLines: Integer;
  ShowsFile: String;
  StartTime: TDateTime;
  SuspendedBeforeScroll: TEventSuspender;
begin
  db := FDbf[dbShows].aDB;
  ShowsFile := CombinePath(g.OpPath, g.AllShowsTxt);

  LogSyncShowsEntryState(db, ShowsFile);

  // 1. Exit if data is already present
  if not db.IsEmpty then Exit;

  // An empty SHOWS.DBF on read-only media can't be filled. Leave it empty
  // and say why, rather than downloading allshows.txt for nothing.
  if IsPhysicallyReadOnly(db) then
  begin
    StatusBar.Panels[0].Text :=
      sb([STATUS_READONLY_TAG, ' ', db.TableName,
      ' is empty and read-only because ', DbfReadOnlyReason(db),
      ', so the shows list cannot be imported.']);
    Exit;
  end;

  // 2. Resource/UI Guarding
  // Automatically handles DisableControls and prevents UI flickering
  pcMain.ActivePage := tsProgress;
  Guard := TDataLayoutGuard.Create(db, DBGridShows, nil);//muat use nil here
  StartTime := Now;

  // 3. Conditional Download
  if not FileExists(ShowsFile) and g.IsInternetConnected then
    if not DownloadShowsFile(ShowsFile) then Exit;

  if not FileExists(ShowsFile) then Exit;

  // 4. Load & Prepare Data
  CSVLines.Setup(Self);
  TotalLines := LoadShowsCSV(ShowsFile, CSVLines);
  if TotalLines = 0 then Exit;

  // 5. Database & UI Prep
  pcMain.ActivePage := tsProgress;
  ProgressBar.Max := TotalLines;
  PrepareShowsTableForImport(db);

  // 6. MAIN IMPORT LOOP
  SuspendedBeforeScroll := TEventSuspender.Start(db, 'BeforeScroll');
  // BeforeScroll is nil from here until SyncShowsDatabase returns (whether
  // normally or via an exception); AfterScroll (and its StatusBar
  // feedback) keeps firing normally throughout the import and the
  // indexing step below - SuspendedBeforeScroll is a local of THIS
  // procedure and stays alive across both the ImportShowsRows and
  // FinalizeShowsImport calls, exactly as it did in the original single
  // procedure.
  ProcessedCount := ImportShowsRows(db, CSVLines, TotalLines, StartTime);

  // 7. Cleanup / Indexing (Only if not shutting down)
  if FIsShuttingDown then Exit;
  FinalizeShowsImport(db, ProcessedCount, StartTime);
end;

procedure TForm1.SynEditKeyDown(Sender: TObject; var Key: word;
  Shift: TShiftState);
begin
  case Key of
    VK_F3: begin
      // F3 = Search Next, Shift+F3 = Search Previous
      if ssShift in Shift then BitBtnPrevClick(Sender)
      else
        BitBtnNextClick(Sender);
      // Consume the key so SynEdit doesn't try to process it
      Key := 0;
    end;
    // Optional: Add Ctrl+F to jump focus back to the search box
    VK_F: begin
      if not (ssCtrl in Shift) then Exit;
      // Find the EditButton on this page and focus it
      // Uses the same 'UniqueSuffix' logic from your AddtsSourceCode
      MyComponent := pcSourceCode.ActivePage.FindComponent(
        'EditButton' + pcSourceCode.ActivePageIndex.toString);
      if Assigned(MyComponent) and (MyComponent is TWinControl) then
        SafeSetFocus(TWinControl(MyComponent));
      Key := 0;
    end;
  end;
end;

procedure TForm1.SynEditOnEnter(Sender: TObject);
begin
  SafeSetFocus(Sender as TControl);
end;

procedure TForm1.SynEditStatusChange(Sender: TObject;
  Changes: TSynStatusChanges);
begin
  // Every editor fires this while loading; only the visible one matters.
  if Sender <> ActiveSourceSynEdit then Exit;
  if Changes * [scCaretX, scCaretY, scReadOnly] <> [] then
    ShowStatusSourceCode;
end;

procedure TForm1.TabSheetAlignButtons;
begin
  // One-time layout for the AllShows tab, called once from SetupUI.
  // Anchors re-resolve on every resize, show, caption change and AutoSize
  // pass, so nothing here needs to run again, and nothing here reads a
  // control's current size, so deferred layout can't hand it stale values.
  PanelSelect.DisableAlign;
  try
    BitBtnSelect.AutoSize := True;
    BitBtnSelect.Anchors := [];
    BitBtnSelect.AnchorParallel(akLeft, 5, PanelSelect);
    BitBtnSelect.AnchorParallel(akTop, 10, PanelSelect);
    // PanelSelect is AutoSize: this gives it the same 10 px below the
    // button that the old "Height + 20" arithmetic was reaching for.
    BitBtnSelect.BorderSpacing.Bottom := 10;

    BitBtnCancel.AutoSize := True;
    BitBtnCancel.Anchors := [];
    BitBtnCancel.AnchorToNeighbour(akLeft, 10, BitBtnSelect);
    BitBtnCancel.AnchorParallel(akTop, 0, BitBtnSelect);
    BitBtnCancel.BorderSpacing.Bottom := 10;
  finally
    PanelSelect.EnableAlign;
  end;

  // PanelShowsNav is alClient, so a Width assigned to it never sticks; the
  // split is controlled by sizing its alRight sibling, PanelNav.
  PanelShowsTop.OnResize := @PanelShowsTopResize;
  PanelShowsTopResize(PanelShowsTop);
  DBNavigatorShows.Align := alClient;
end;

procedure TForm1.TestKeyDown(Sender: TObject; var Key: word;
  Shift: TShiftState);
begin
  if not (ssCtrl in Shift) then Exit;
  case Key of
    VK_ADD: uUtils.IncreaseAllFonts(Form1, StatusBar, ToolBarFiles, 1);
    VK_SUBTRACT: uUtils.IncreaseAllFonts(Form1, StatusBar, ToolBarFiles, -1);
    else
      NoOp
  end;
end;

procedure TForm1.ToggleLogUndoBoxes(Value: Boolean);
var
  Guard: TDataLayoutGuard;
  db: TDbf;
begin
  db := FDbf[dbLog].aDB;
  Guard := TDataLayoutGuard.Create(db, DBGridLog, nil);
  try
    db.First;
    while not db.EOF do
    begin
      // Check if Escape is pressed
      if (GetKeyState(VK_ESCAPE) < 0) then Break; // Exit the loop early
      db.Edit;
      db.FieldByName('UNDO').AsBoolean := Value;
      db.Post;
      db.Next;
      UI.Check; // Allow the OS to process the Escape key press
    end;
  finally
    CheckLogCheckBoxes;
  end;
end;

procedure TForm1.ToolBarFilesResize(Sender: TObject);
begin
  PanelTop.Constraints.MinHeight :=
    BitBtnExit.Top + BitBtnExit.Height + PanelTop.Top +
    ToolBarFiles.BorderWidth + 1;
end;

procedure TForm1.tsAboutShow(Sender: TObject);
begin
  if (pcAbout.ActivePageIndex = tsInfo.PageIndex) and
    {pcAbout.Showing and} pcAbout.Visible then SetupDbAbout;
  AdjustColumns(DBGridAbout);
end;

procedure TForm1.tsBrowserResize(Sender: TObject);
begin
  btBack.Top := (pnTop.Height - btBack.Height) div 2;
  btForward.Top := (pnTop.Height - btForward.Height) div 2;
  edUrl.Top := (pnTop.Height - edUrl.Height) div 2;
  btGo.Top := (pnTop.Height - btGo.Height) div 2;
end;

procedure TForm1.tsBrowserShow(Sender: TObject);
begin
  UI.Check;
  ShowStatusBrowser;
  // g.URL is the epguides page the program last read (or is about to read)
  // for the selected show - where the data comes from. Loaded only when it
  // has changed since this tab last loaded it, so a page the user browsed
  // to isn't replaced every time they come back to the tab.
  if g.URL.IsEmpty or (g.URL = FBrowserSourceURL) then Exit;
  if not g.IsInternetConnected then
  begin
    FBrowserStatus := sb(['No internet connection, so ', g.URL,
      ' cannot be shown.']);
    ShowStatusBrowser;
    Exit;
  end;
  FBrowserSourceURL := g.URL;
  // Queued for the same reason as AfterEpsShow: OnShow fires before the
  // tab has been laid out.
  FPendingBrowserURL := g.URL;
  Application.QueueAsyncCall(@DeferredBrowse, 0);
end;

procedure TForm1.tsEpsResize(Sender: TObject);
var
  Guard: TDataLayoutGuard;
begin
  Guard := TDataLayoutGuard.CreateLayOut(DBGridEps);
  PanelEpsTop.Width := tsEps.ClientWidth;
  DBNavigatorEps.SetBounds(0, 0, PanelEpsTop.Width - 2,
    PanelEpsTop.Height - 2);
  // DBGridEps.Realign;
  AdjustColumns(DBGridEps);
end;

procedure TForm1.tsEpsShow(Sender: TObject);
begin
  // Tell Lazarus to run AfterEpsShow as soon as the main loop is idle
  Application.QueueAsyncCall(@AfterEpsShow, PtrInt(Sender));
end;

procedure TForm1.tsInfoHide(Sender: TObject);
begin
  SaveAboutRecNo;
end;

procedure TForm1.tsInfoResize(Sender: TObject);
begin
  AdjustColumns(DBGridAbout);
end;

procedure TForm1.tsInfoShow(Sender: TObject);
begin
  SetupDbAbout;
  AdjustColumns(DBGridAbout);
end;

procedure TForm1.tsLicenseHide(Sender: TObject);
begin
  vwAttribution.Value.Clear;
  MemoLicense.Clear;
  StatusBar.Visible := True;
end;

procedure TForm1.tsLicenseShow(Sender: TObject);
var
  s: String;
  Guard: TDataLayoutGuard;
  Res: TSmartResourceStream; // Manages the resource access
  MS: TSmartMemoryStream; // Manages the extracted memory
  SrcStream: TMemoryStream;
begin
  s := sb(['<div>Attribution:</div>',
    '<div>TV Icon made by <a href="https://www.flaticon.com',
    '/authors/photo3idea-studio" title="photo3idea_studio">',
    'photo3idea_studio</a> from <a href="https://www.flaticon',
    '.com/" title="Flaticon">www.flaticon.com</a></div>',
    '<div><a href="https://www.flaticon.com/free-icon/',
    'television_926087">https://www.flaticon.com/free-icon',
    '/television_926087</a>']);
  // Guard automatically handles DisableAlign and BeginUpdate for the tab
  Guard := TDataLayoutGuard.CreateLayOut(tsLicense);
  vwAttribution.Setup(PanelAttributionContainer, alClient);
  vwAttribution.LoadFromString(s);
  // Only extract if we haven't loaded it yet
  if MemoLicense.Lines.Count > 0 then Exit;
  // Ownership pattern as in LoadBundledDoc: "MS.Value :=" takes the new
  // stream over (MS.Value.LoadFromStream(...) leaked it).
  SrcStream := GetStreamFromZipResource('license.txt');
  if Assigned(SrcStream) then
  begin
    MS.Value := SrcStream;
    MS.Value.Position := 0;
    MemoLicense.Lines.LoadFromStream(MS.Value);
  end
  else
    LogError('Could not read from source zip: license.txt');
  MemoLicense.ReadOnly := True;
  StatusBar.Visible := False;
end;

procedure TForm1.tsListResize(Sender: TObject);
begin
  DBGridListSetColumnWidths;
  PanelTop.Height := BitBtnOpen.Height + 2;
  SetTabSheetListButtons;
end;

procedure TForm1.tsListShow(Sender: TObject);
begin
  SetTabSheetListButtons;
end;

procedure TForm1.tsLogResize(Sender: TObject);
var
  b: TBitBtn;
begin
  SetBitBtnUndoEnabled;
  PanelLogTop.Height := BitBtnUndo.Height + 1;
  b := BitBtnUndo;
  b.SetBounds(0, 0, b.Width, b.Height);
  DBNavigatorLog.SetBounds(b.Width + 2, 0, PanelLogTop.Width -
    b.Width - 2, PanelLogTop.ClientHeight);
end;

procedure TForm1.tsLogShow(Sender: TObject);
var
  SavedBookmark: TBookmark;
  db: TDbf;
  Guard: TDataLayoutGuard;
begin
  db := FDbf[dbLog].aDB;

  // Assigned rather than IsDbOpen: an unopened-but-created LOG.DBF is what
  // the SetupDbLog call below exists to handle.
  if not Assigned(db) then Exit;

  Guard := TDataLayoutGuard.Create(db, DBGridLog, tsLog);
  if tsLog.Visible and (db.IsEmpty) then SetupDbLog;
  SavedBookmark := db.GetBookmark; // Save position
  CheckLogCheckBoxes;
  // Apply/remove filters WITHOUT calling FindFirst
  db.OnFilterRecord := @FilterLogOnUndo;
  db.Filtered := True;
  db.Filtered := False;
  DBFRecordCountChanged(db);
  // Remove filter
  db.OnFilterRecord := nil;
  db.GotoBookmark(SavedBookmark);
  // Restore position
  DBGridLog.AutoAdjustColumns;
end;

procedure TForm1.tsMemoResize(Sender: TObject);
begin
  SetTabSheetMemoButtons;
end;

procedure TForm1.tsPrivacyHide(Sender: TObject);
begin
  vwPrivacy.Value.Clear;
end;

procedure TForm1.tsPrivacyShow(Sender: TObject);
var
  Guard: TDataLayoutGuard;
begin
  StatusBar.Visible := False;
  Guard := TDataLayoutGuard.CreateLayOut(tsPrivacy);
  vwPrivacy.Setup(PanelPrivacyContainer, alClient);
  // Only extract if we haven't loaded it yet
  if vwPrivacy.Value.GetTextLen > 0 then Exit;
  LoadBundledDoc(vwPrivacy, 'Privacy_Policy.html');
end;

procedure TForm1.tsProgressHide(Sender: TObject);
begin
  ProgressBar.Position := 0;
  ProgressLabel.Caption := '';
  // Each user of this page sets its own heading (ShowExtractProgress,
  // actMeasureExecute); clear it so the next one doesn't inherit it.
  ProgressPanelHeader.Caption := '';
end;

procedure TForm1.tsProgressShow(Sender: TObject);
begin
  // OnShow fires inside "pcMain.ActivePage := tsProgress", so these defaults
  // are in place before the caller's next line; a caller wanting different
  // values sets them after switching pages.
  g.IsProgressCanceled := False;
  ProgressBitBtn.Enabled := False;
end;

procedure TForm1.tsReadmeHide(Sender: TObject);
var
  iLast: Integer;
begin
  // Remember the reader's place: tsReadmeShow reopens this document (and
  // FReadmeHistory keeps Back working) rather than starting over.
  iLast := FReadmeHistory.Value.Count - 1;
  if (iLast >= 0) and Assigned(vwReadme.Value) then
    FReadmeHistory.Value.ValueFromIndex[iLast] :=
      IntToStr(vwReadme.Value.Position);
  vwReadme.Value.Clear;
  StatusBar.Visible := True;
end;

procedure TForm1.tsReadmeShow(Sender: TObject);
var
  Guard: TDataLayoutGuard;
  iLast: Integer;
begin
  StatusBar.Visible := False;
  Guard := TDataLayoutGuard.CreateLayOut(tsReadme);
  vwReadme.Setup(PanelReadmeContainer, alClient);
  // vwReadme.LoadFromFile(sb([g.CnfgFilePath, DirSep, 'README.html']));
  vwReadme.OnClick := @ReadmeLinkClick;
  SetupReadmeBack;
  UpdateReadmeBack;
  if vwReadme.Value.GetTextLen > 0 then Exit;
  if FReadmeHistory.Value.Count = 0 then
    FReadmeHistory.Value.Add(README_DOCS[0] + '=0');
  iLast := FReadmeHistory.Value.Count - 1;
  ShowReadmeDoc(FReadmeHistory.Value.Names[iLast],
    StrToIntDef(FReadmeHistory.Value.ValueFromIndex[iLast], 0));
end;

procedure TForm1.tsShowsShow(Sender: TObject);
begin
  if ShowsFilterEdit.Text = '' then ShowsFilterEdit.Button.Click;
  SmartAutoAdjustColumns(DBGridShows, FShowsColumnsThrottle);
  Application.QueueAsyncCall(@AfterShowsShow, 0);
  SafeSetFocus(ShowsFilterEdit);
end;

procedure TForm1.tsSourceCodeExit(Sender: TObject);
begin
  FSourceManager.Clear; // returns in nanoseconds if already empty
end;

procedure TForm1.tsSourceCodeShow(Sender: TObject);
begin
  ShowStatusSourceCode;
end;

procedure TForm1.UpdateBrowserButtons;
begin
  btBack.Enabled := FBrowserHistoryIndex > 0;
  btForward.Enabled := (FBrowserHistoryIndex >= 0) and
    (FBrowserHistoryIndex < FBrowserHistory.Value.Count - 1);
end;

procedure TForm1.UpdateReadmeBack;
begin
  if Assigned(FReadmeBack) then
    FReadmeBack.Enabled := FReadmeHistory.Value.Count > 1;
end;

procedure TForm1.UpdateStatusBar;
var
  CurrentPage: TTabSheet;
  HasStatus: Boolean;
begin
  if Self.IsResizing or pcMain.IsResizing or not pcMain.Showing then Exit;

  CurrentPage := pcMain.ActivePage;
  if (CurrentPage = nil) or (not CurrentPage.Showing) then Exit;

  DisableAlign;
  try
    if not StatusBar.Visible then StatusBar.Visible := True;

    HasStatus := True;

    // Pure pointer comparisons: lightning fast and no magic numbers!
    if CurrentPage = tsList then ShowStatusDBF(dbList)
    else if CurrentPage = tsShows then ShowStatusDBF(dbShows)
    else if CurrentPage = tsEps then ShowStatusDBF(dbEps)
    else if CurrentPage = tsLog then ShowStatusDBF(dbLog)
    else if CurrentPage = tsBrowser then ShowStatusBrowser
    else if CurrentPage = tsProgress then
      HasStatus := False // Explicitly handle the progress tab
    else if CurrentPage = tsAbout then
    begin
      if pcAbout.ActivePage = tsInfo then ShowStatusDBF(dbAbout)
      else if pcAbout.ActivePage = tsSourceCode then ShowStatusSourceCode
      else
      begin
        // License/Readme/Privacy: documents nobody expects to edit, so no
        // badge. Their OnShow handlers hide the StatusBar; this stops a
        // resize (pcMainResize -> here) from resurrecting it as "Ready".
        StatusBar.Visible := False;
        Exit; // finally still runs EnableAlign
      end;
    end
    else
    begin
      // Catch-all for any future tabs added down the road
      HasStatus := False;
    end;

    // Handle the status bar text update. When HasStatus is True the
    // Show* routine above has already set both the text and the hint (the
    // hint carries the reason behind a READ-ONLY/LOCKED/COPY badge), so
    // it must not be overwritten here.
    if not HasStatus then
    begin
      if StatusBar.Panels.Count > 0 then StatusBar.Panels[0].Text := 'Ready';
      StatusBar.Hint := '';
    end;

  finally
    EnableAlign;
  end;
end;

procedure TForm1.UpgradeIniFile;
const
  // Retired by IniVersion 2. Matched ignoring case; '*' stands for any run
  // of characters (TSmartIni.DeleteKeys).
  RETIRED_IN_2: array[0..1] of String = (
    // Source Code tab fonts, keyed by tab position. They are keyed by the
    // tab's name now (WriteSourceCodeFont), so a font follows its file.
    'TabSheetSourceCode*',
    // Written on every save, never read.
    'PageControlSourceCode.PageCount');
  // Retired by IniVersion 3: the colon-only setting, which became
  // ReservedCharacters (same values) when every character Windows forbids
  // got a look-alike.
  RETIRED_IN_3: array[0..0] of String = ('ColonReplacement');
var
  iFound, iRemoved: Integer;
  ini: TIniFile;
begin
  // No ini is a first run, which FormActivate recognises by the file not
  // being there - so nothing is written here; SaveConfiguration gives the
  // new file INI_VERSION when filey closes.
  if not AppIni.Exists then Exit;
  iFound := AppIni.Value.ReadInteger('Main', 'IniVersion', 1);
  if iFound >= INI_VERSION then Exit;
  iRemoved := 0;
  try
    if iFound < 2 then Inc(iRemoved, AppIni.DeleteKeys('Main', RETIRED_IN_2));
    if iFound < 3 then
    begin
      ini := AppIni.Value;
      if ini.ValueExists('Main', 'ColonReplacement') and not
        ini.ValueExists('Main', 'ReservedCharacters') then
        ini.WriteString('Main', 'ReservedCharacters',
          ini.ReadString('Main', 'ColonReplacement', 'lookalike'));
      Inc(iRemoved, AppIni.DeleteKeys('Main', RETIRED_IN_3));
    end;
    AppIni.Value.WriteInteger('Main', 'IniVersion', INI_VERSION);
    DebugLog(sb(['UpgradeIniFile: ', g.IniFileName, ' from IniVersion ',
      iFound, ' to ', INI_VERSION, ', ', iRemoved, ' old key(s) removed']));
  except
    // A read-only or locked ini: filey still runs with what it could read.
    on E: Exception do
      LogError('UpgradeIniFile: could not update ' + g.IniFileName, E);
  end;
end;

procedure TForm1.ValidateAndDiscoverTools;
var
  sDetectedDir, sMKVMergeExeName, sWinePrefix, sFileName: String;
begin
  // Each tool is discovered the same, precise way: prefer a native Linux
  // build on PATH, otherwise fall back to the bundled Windows build run
  // through Wine - and the result is only trusted once verified to both
  // exist AND actually run (see DiscoverExternalTool).
  g.FilePathFFProbe := DiscoverExternalTool('ffprobe',
    'ffprobe.exe', '-version', sWinePrefix, sFileName);
  g.WineFFProbe := sWinePrefix;
  g.FileNameFFProbe := sFileName;

  // mkvpropedit.exe / mkvmerge.exe (Windows builds) are PINNED to v64.0.0
  // "Willows" (2021-12-27), 32-bit - deliberately, not by neglect. This is
  // the last official mkvtoolnix release built against Qt5. Every build
  // from v64.0.0.45 onward moved to Qt6, whose minimum supported Windows
  // version is 10 - those builds call Windows-10+-only APIs unconditionally
  // (e.g. kernel32's SetThreadDescription) and fail to launch at all on
  // Windows 7/8.1 with "Entry Point Not Found... could not be located in
  // the dynamic link library". This isn't visible from mkvtoolnix's own
  // "officially supported OS" page, which only ever describes the CURRENT
  // policy, not when Windows 7/8.1 support was actually dropped - that
  // history lives only in the Qt5->Qt6 migration itself.
  // Do not update these two bundled binaries without re-verifying Windows
  // 7/8.1 compatibility first (i.e. confirming any replacement is still a
  // Qt5-era build), since a newer official release will silently break
  // launching on those two OSes even though it works fine on Windows 10/11.
  g.FilePathMKVPropEdit := DiscoverExternalTool('mkvpropedit',
    'mkvpropedit.exe', '--version', sWinePrefix, sFileName);
  g.WineMKVPropEdit := sWinePrefix;
  g.FileNameMKVPropEdit := sFileName;

  g.FilePathMKVMerge := DiscoverExternalTool('mkvmerge',
    'mkvmerge.exe', '--version', sWinePrefix, sFileName);
  g.WineMKVMerge := sWinePrefix;
  g.FileNameMKVMerge := sFileName;

  // Fallback: MKVToolNix always ships mkvmerge and mkvpropedit side by side.
  // If independent discovery above found mkvpropedit but somehow missed
  // mkvmerge, look for it right next to mkvpropedit - matching whichever
  // variant (native or the Wine-hosted .exe) mkvpropedit resolved to,
  // rather than guessing from the compile-time target OS.
  if (g.FilePathMKVMerge = EmptyStr) and (g.FilePathMKVPropEdit <>
    EmptyStr) then
  begin
    sDetectedDir := ExtractFilePath(g.FilePathMKVPropEdit.Value);
    sMKVMergeExeName := 'mkvmerge' + ExtractFileExt(g.FileNameMKVPropEdit);
    if FileExists(CombinePath(sDetectedDir, sMKVMergeExeName)) then
    begin
      g.FileNameMKVMerge := sMKVMergeExeName;
      g.WineMKVMerge := g.WineMKVPropEdit; // inherit its sibling's Wine prefix
      g.FilePathMKVMerge := CombinePath(sDetectedDir, sMKVMergeExeName);
      if not (g.FilePathMKVMerge.Exists and
        ToolRunsOK(g.WineMKVMerge, g.FilePathMKVMerge.Value, '--version')) then
      begin
        StatusBar.Panels[0].Text :=
          sb(['Warning: mkvmerge not found or would not run at ',
          g.FilePathMKVMerge.Value]);
        g.FileNameMKVMerge := EmptyStr;
        g.WineMKVMerge := EmptyStr;
        g.FilePathMKVMerge := EmptyStr;
      end;
    end;
  end;
end;

procedure TForm1.ViewerHotClick(Sender: TObject; const SRC: ThtString;
  var Handled: Boolean);
begin
  if not SRC.StartsWith('http', True) then Exit;
  OpenURL(ansistring(SRC)); // Opens in system default browser
  Handled := True;
end;

// Keyed by the tab's Name (e.g. tsSrc_uMain_pas - see
// uManagedUtils.MakeUniqueTabSheetName), so a font follows its file rather
// than the tab's position. LazyLoadSourceCode reads these back.
procedure TForm1.WriteSourceCodeFont(ini: TIniFile; APage: TTabSheet;
  AEdit: TSynEdit);
begin
  if not (Assigned(ini) and Assigned(APage) and Assigned(AEdit)) then Exit;
  ini.WriteString('Main', APage.Name + '.Font.Name', AEdit.Font.Name);
  ini.WriteInteger('Main', APage.Name + '.Font.Size', AEdit.Font.Size);
end;

// Empties SHOWS.DBF and EPS.DBF and rebuilds SHOWS.DBF from allshows.txt -
// downloaded afresh when online, the copy already in g.OpPath otherwise -
// so every LOOKUPDATE starts out blank. Asks nothing: actZapExecute asks
// first, actZipSourcesExecute never does. False, with AFailure saying why,
// if the tables couldn't be emptied (another running copy of Filey has
// them open, say) or SHOWS.DBF is still empty afterwards.
function TForm1.ZapAndRebuildShows(out AFailure: String): Boolean;
var
  db: TDbf;
  //Guard: TDataLayoutGuard; //*NO!!* Causes Intermittent AV Errors here
begin
  Result := False;
  AFailure := '';
  db := FDbf[dbShows].aDB;
  StatusBar.Panels[0].Text := 'ZAPPING...';
  try
    // Perform the heavy lifting. Same "confirmed, destructive, worth an
    // audit trail" case as ConfirmThenZapPackTable - see uDBFManager's
    // unit banner for why DebugLog (a plain function) can be passed
    // directly. ZapPackTable raises if it can't get exclusive access (e.g.
    // another running instance has the table open) -- caught below rather
    // than left to crash, and the destructive re-download/reinitialize
    // sequence is skipped entirely in that case.
    ZapPackTable(db, @DebugLog);
    ZapPackTable(FDbf[dbEps].aDB, @DebugLog);
    FDbf[dbShows].aRecCountDirty := True;
    FDbf[dbEps].aRecCountDirty := True;
  except
    on E: EDatabaseError do
    begin
      LogError('ZapAndRebuildShows: ZapPackTable failed', E);
      StatusBar.Panels[0].Text := 'Zap cancelled.';
      AFailure := E.Message;
      Exit;
    end;
  end;
  actFilterEditCancelExecute(self);
  if g.IsInternetConnected then
    DeleteIfExists(CombinePath(g.OpPath, g.AllShowsTxt));
  // Re-initialize and Re-download
  InitializeDBFs;
  // InitializeDBFs (CreateAndOpenDBFs) may have replaced the TDbf in
  // FDbf[dbShows]; never keep using a pointer taken before it ran - the
  // same stale-object hazard the removed TDataLayoutGuard had here.
  db := FDbf[dbShows].aDB;
  SyncShowsDatabase;
  // Explicitly update the Grid through its own name
  DBGridShows.Options :=
    DBGridShows.Options + [dgRowSelect, dgCellHints];
  // DEFENSIVE: Only call First if the DB successfully opened
  if db.Active and (db.RecordCount > 0) then db.First;
  // SyncShowsDatabase leaves SHOWS.DBF empty when allshows.txt couldn't be
  // downloaded or read, and stops part-way if Filey is closing.
  Result := IsDbOpen(dbShows) and not db.IsEmpty and not FIsShuttingDown;
  if Result then
    StatusBar.Panels[0].Text := 'Ready'
  else
  begin
    if FIsShuttingDown then
      AFailure := 'Filey is closing.'
    else
      AFailure := sb(['SHOWS.DBF is still empty: "', g.AllShowsTxt,
        '" could not be downloaded or read.']);
    LogError('ZapAndRebuildShows: ' + AFailure);
  end;
end;

procedure TForm1.ZipperProgress(Sender: TObject; const Pct: double);
begin
  ProgressBar.Position := EnsureRange(Round(Pct), ProgressBar.Min,
    ProgressBar.Max);
  UI.Check; // Keep UI responsive
end;

procedure TForm1.ZipperStartFile(Sender: TObject; const AFileName: String);
begin
  ProgressLabel.Caption := 'Compressing: ' + AFileName;
  StatusBar.Panels[0].Text := sb(['Compressing ', AFileName]);
  StatusBar.Invalidate;
  Inc(FProgressUpdateCounter);
  UI.Check; // Keep UI responsive
end;

destructor TForm1.Destroy;
var
  DbIndex: TDbType;
begin
  // Guards against Destroy itself running twice, NOT against a normal
  // close having already happened - that used to be FIsShuttingDown's
  // job here, but FIsShuttingDown is set True well before Destroy is ever
  // reached on the ordinary close path (actExitExecute/FormCloseQuery, so
  // every other background-loop guard in this unit sees "shutting down"
  // in time). Checking FIsShuttingDown here meant a normal close always
  // took the "already shutting down" branch below and skipped
  // SaveConfiguration/AppIni.UpdateFile/closing the DBFs entirely - only an
  // abnormal teardown that reached Destroy without going through either
  // of those (FIsShuttingDown still False) ever actually saved anything.
  // That inversion, not a missing SaveConfiguration routine (this rewrite
  // renamed it to SaveConfiguration - see the call below), is why filey.ini
  // stopped being (re)written on exit.
  if FIsDestroyed then
  begin
    inherited Destroy;
    Exit;
  end;
  FIsDestroyed := True;
  FIsShuttingDown := True;
  try
    // 1. Save state
    SaveConfiguration(AppIni.Value);
    if Assigned(AppIni.Value) and (not g.IsIniFileDeleted) then try
      AppIni.Value.UpdateFile;
    except
      on E: Exception do LogError('Error saving ini file', E);
    end;
    // 2. Close databases
    for DbIndex := Low(TDbType) to High(TDbType) do
      if FDbf[DbIndex].aIsInitialized and Assigned(FDbf[DbIndex].aDB) then try
        if FDbf[DbIndex].aDB.Active then FDbf[DbIndex].aDB.Close;
      except
        on E: Exception do
          LogError('Error closing database: ' + FDbf[DbIndex].aDB.TableName, E);
      end;
  except
    on E: Exception do LogError('Error during form destruction', E);
  end;
  inherited Destroy;
end;


//jcf:format=on

// ---------------------------------------------------------------------
// SyncShowsDatabase and its helpers.

// Split from one 227-line procedure into a thin orchestrator plus 8
// focused private methods, each declared alphabetically among TForm1's
// other private methods (not grouped together - see their declarations
// above). Every comment, including the two "TEMPORARY DIAGNOSTIC"
// blocks, moved verbatim with the code it was attached to; no behavior
// changed except one incidental fix noted at DownloadShowsFile's use in
// SyncShowsDatabase below (raw path '+' concatenation replaced with
// CombinePath).
// ---------------------------------------------------------------------

initialization

  DebugLog('uMain.pas initialization');
  Application.Scaled := True;
  Application.Title := 'filey'; // this name affects GetAppConfigDir
  {$IFDEF WINDOWS}
  Application.Title := Application.Title.ProperCase; //upcase Windows version
  {$ENDIF}

finalization

end.
