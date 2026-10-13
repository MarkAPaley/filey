unit uUtils;
//jcf:format=on

{ ==============================================================================
   Stand-alone, non-RAII utility routines.

   This unit holds every plain (forward-declared) function/procedure that was
   previously bundled into uManagedUtils.pas. Nothing in here is a RAII
   record/class (no Initialize/Finalize operators) - those remain in
   uManagedUtils.pas by design.

   NOTE ON THE MUTUAL DEPENDENCY:
   A handful of these routines (FindAllFilesThrottled, RunEx,
   ShowMessage, HasInternetConnection) delegate work to RAII helper types
   (TThrottledUI, TSearchHandler, TSmartProcess, TSmartBitmap,
   TSmartManagedDialog, TSmartHTTP) that live in uManagedUtils.pas. None of
   those types appear in this unit's public signatures, so uManagedUtils is
   only pulled into this unit's IMPLEMENTATION uses clause. uManagedUtils.pas
   likewise only needs this unit's routines (FileExists, IfThen, ToggleBoolean,
   etc.) inside its own implementation. Because both cross-references are
   implementation-only, the two units may legally reference each other -
   this is the standard two-unit "implementation only" pattern for breaking
   what would otherwise be a circular interface dependency.

   NOTE ON RUNEX:
   Always use this unit's safer RunEx, rather than naked Process.RunCommand.
   Call graph (sync/async/batch all funnel into RunExDrain):
     RunEx(sCmd)/RunEx(sCmd,exitcode)  -> RunExCore -> RunExDrain
     RunEx(exe,params,exitcode)        -> RunExDrain directly (no parsing needed)
     RunExAsync                        -> TRunExThread -> RunExCore -> RunExDrain
     RunExBatch                        -> TRunExBatchCoordinator -> N x TRunExThread -> RunExCore -> RunExDrain
   On a TRunExThread nothing is logged: DebugLog (LazLogger) and LogError
   aren't thread-safe. The command line is logged on the main thread before
   the thread starts, and a failure to start it once the thread is done.
============================================================================== }

{$mode objfpc}{$H+}
{$MODESWITCH ImplicitFunctionSpecialization}
{$INLINE ON}
{$WARN 6018 off : Unreachable code}
{$WARN 6058 off : Call to subroutine "$1" marked as inline is not inlined}
{$WARN 5027 off : Local variable "$1" is assigned but never used}
{$WARN 5024 off : Parameter "$1" not used}
interface

uses
  {$IFDEF UNIX}baseunix,{$ENDIF}
  {$IFDEF WINDOWS}winsock2, Windows, JwaWindows,{$ENDIF}
  Classes, ComCtrls, Controls, DBGrids, Dialogs, Forms, LazLogger,
  LCLType, Masks, StdCtrls, SysUtils, Zipper;

  // =============================================================================
  //  HTML ENTITY TABLE
  // =============================================================================
type
  THTMLEntity = record
    Name: String;
    Value: String;
  end;

  // =============================================================================
  //  RunEx() THREADING TYPES
  // =============================================================================
  // Callback for a single asynchronous RunEx call (see RunExAsync). Always
  // invoked on the main thread, so it is safe to touch the UI from here.
  TRunExCallback = procedure(const AOutput: String;
    AExitCode: Integer) of object;
  // Fired once per finished command line in a RunExBatch call, in whatever
  // order the commands happen to complete (not necessarily AIndex order).
  // Always invoked on the main thread.
  TRunExBatchItemCallback = procedure(AIndex: Integer;
    const ACommandLine: String; const AOutput: String;
    AExitCode: Integer) of object;
  // Fired once, after every command line passed to RunExBatch has finished.
  // Always invoked on the main thread.
  TRunExBatchCompleteCallback =
    procedure(ASucceededCount, AFailedCount: Integer) of object;

  // =============================================================================
  //  RunParallel() / RunExBatchAndWait() TYPES
  // =============================================================================
  // One job of a RunParallel call, run on a worker thread. It must not touch
  // the LCL, any TDbf, or anything else the main thread may be using; it
  // works only on data prepared for it beforehand, at its own AIndex.
  // DebugLog and LogError are safe to call from it.
  TParallelJob = procedure(AIndex: Integer) of object;
  TBooleanArray = array of Boolean;
  TIntegerArray = array of Integer;
  // How many jobs (or commands) have finished, of how many. Main thread.
  TParallelProgress = procedure(ADone, ATotal: Integer) of object;
  // Asked now and then on the main thread; True stops RunParallel handing
  // out jobs that haven't started yet.
  TParallelCancelCheck = function: Boolean of object;

  // =============================================================================
  //  ExtractFileFromZip() CALLBACK TYPE
  // =============================================================================
  // Passed to the callback overload of ExtractFileFromZip in place of a disk
  // destination, for callers that want the extracted entry handed to them
  // in memory (e.g. loading straight into a UI control) instead of written
  // to a file. AStream is positioned at 0 and is a TMemoryStream owned by
  // ExtractFileFromZip - it is freed the moment the callback returns, so
  // don't keep a reference to it.
  TZipExtractCallback = procedure(AStream: TStream;
    const AArchiveFileName: String) of object;

  // =============================================================================
  //  OS-DETECTION CONSTANTS
  // =============================================================================
const
  {$IFDEF LINUX}
  DEFAULT_PICTURES_DIR = 'Pictures';
  IS_LINUX = True;
  IS_WINDOWS = False;
  {$ELSE}
  DEFAULT_PICTURES_DIR = 'My Pictures';
  IS_LINUX = False;
  IS_WINDOWS = True;
  {$ENDIF}

const
  {$IFDEF DEBUG}
  IsDebugBuild = True;
  {$ELSE}
  IsDebugBuild = False;
  {$ENDIF}

const
  DirSep: String = DirectorySeparator;
  // Was 255. On Windows, MAX_PATH is 260 (and long-path-aware apps go well
  // past that); on Linux, the real filesystem limit (NAME_MAX/PATH_MAX) is
  // much higher. 4096 matches Linux's PATH_MAX and comfortably covers
  // Windows too - this was never a hard OS ceiling, just too conservative
  // for either platform once counted correctly (see UTF8Length below).
  MAX_PATH_LENGTH = 4096;
  // Bakes case-sensitivity per OS into a constant, so you don't have to
  // remember which OS is which in TMaskList calls.
  OS_CASE_SENSITIVE = IS_LINUX;

  // Characters that are invalid (or reserved) in a Windows file name. Kept
  // as the single source of truth here so FixWinFileName and
  // HasValidFileNameChars can't quietly drift apart from each other.
  cInvalidFileNameChars: set of char =
    ['<', '>', ':', '"', '/', '\', '|', '?', '*', #0..#31, #127];
  LIBEAY_NAME = 'libeay32.dll'; //Needed for Windows connectivity
  SSLEAY_NAME = 'ssleay32.dll';

var
  // The canonical, single source of truth for the app's config/data
  // directory. Set in this unit's own initialization section (guaranteed
  // to run before any form-level code, including TForm1.Create),
  // deliberately so this unit never has to depend on TGlobals/g just to
  // know its own working directory. fileyfrm.pas's g.OpPath (a TFilePath,
  // used everywhere a TFilePath's own operators/methods are wanted)
  // derives from this value at startup rather than independently
  // recomputing it - see TForm1.Create. Declared here in the interface
  // (not the implementation section) specifically so other units can
  // read it as uUtils.OpPath.
  OpPath: UnicodeString;
  CnfgFilePath: UnicodeString; // uUtils owns this, resolved once, early
  // The current directory filey was started in, before this unit's
  // initialization made OpPath the current directory instead. Launched
  // from a file manager that is the folder being shown (~/Downloads, for
  // an AppImage just downloaded); from a desktop launcher, usually $HOME.
  // Anything that wrote a relative path used to land there - see
  // IsStrayManifestFile and TForm1.CleanUpStrayFiles.
  LaunchDir: String;

var
  BannerString: String;
  ErrorLogger: TLazLoggerFile; // separate instance from DebugLogger - always

  // active in both Debug and Release, unlike
  // debug.log which is Debug-only

  // =============================================================================
  //  FORWARD DECLARATIONS  (alphabetical)
  // =============================================================================

procedure ApplyFormFonts(AForm: TCustomForm; AFontDialog: TFontDialog);
function ASCIIFold(const s: String): String;
function CombinePath(const APath, AFileName: String): String;
procedure ConcatenateFiles(const InFileNames: array of String;
  const OutFileName: String);
// Renames AFileName (and, if present, the same-stem .DBT/.CDX/.FPT
// companion files) aside into OpPath's 'backup' subdirectory, timestamped,
// so whatever's left at AFileName's original path no longer exists.
// Non-interactive and never raises - meant to be called from startup
// paths (before Form1 exists, e.g. TDBFManager.CreateAndOpenDBFs) where
// there's no dialog to show and nothing sensible to retry. Returns True
// if AFileName no longer exists at its original path afterward (whether
// because the rename succeeded, or because AFileName didn't exist to
// begin with); returns False only if AFileName exists and the rename
// failed, which the caller should treat as "still can't safely proceed".
function QuarantineFile(const AFileName: String): Boolean;
procedure ConfigureDllSearchPath;
function ContainsInsensitive(const Sub, Main: String): Boolean;
function CopyFileForceDir(const aSource, aDest: String): Boolean;

// Copies the rest of ASource (from its current Position) into ADest in 1 MB
// chunks, raising AOnProgress (0..100) each time the whole-number percentage
// changes. Returns the number of bytes copied. Meant for multi-megabyte
// copies worth showing on a progress bar; a plain CopyFrom is simpler for
// anything small.
function CopyStreamWithProgress(aSource, aDest: TStream;
  AOnProgress: Zipper.TProgressEvent; ASender: TObject = nil): int64;

procedure DebugLog(const Msg: String);
function DecodeHTMLEntities(const s: String): String;
function DecodeHTMLEntity(const AEntity: String): String;
function DeleteIfExists(const AFileName: String): Boolean;
function efn(const fn: String): String;
function efnOnly(const fn: String): String;
function ExpandPathName(const Dir: String): String;
function ExtractAfterStr(const sFind, s: String): String;
// AOnProgress (optional) is raised with 0..100 as the entry decompresses,
// measured against that entry's own uncompressed size.
function ExtractFileFromZip(const AZipFileName, AArchiveFileName,
  ADiskFileName: String; AOnProgress: Zipper.TProgressEvent = nil): Boolean;
  overload;

function ExtractFileFromZip(const AZipFileName, AArchiveFileName: String;
  ACallback: TZipExtractCallback): Boolean; overload;
function ExtractFromZipIfNotFound(
  const AZipFileName, AArchiveFileName, ADiskFileName: String;
  AOnProgress: Zipper.TProgressEvent = nil): Boolean;

// Extracts AArchiveFileName from AZipFileName to ADiskFileName unless the
// file already there is exactly that entry (IsExtractedFileCurrent) - so a
// copy left behind by an older build, or damaged since, gets replaced.
// (ExtractFromZipIfNotFound only ever puts back a missing file; a file the
// program changes after extracting it, like SHOWS.DBF, must be treated
// that way, never replaced.) True if ADiskFileName is current afterwards.
function ExtractFromZipIfStale(
  const AZipFileName, AArchiveFileName, ADiskFileName: String;
  AOnProgress: Zipper.TProgressEvent = nil): Boolean;


// Guarantees libeay32.dll and ssleay32.dll exist on disk in OpPath before
// any caller (uMain.pas/uManagedUtils.pas) invokes InitSSLInterface. A
// no-op on non-Windows platforms, where those DLLs are neither needed nor
// shipped.

// Both DLLs live inside the embedded '<Application.Title>-src.zip'
// resource (RT_RCDATA), the same source archive CheckResourceFiles/
// ExtractZipResourceIfNotFound already unpacks to OpPath on first run. If
// either DLL is missing - e.g. deleted after startup, or this is somehow
// reached before CheckResourceFiles has run - this re-extracts that
// archive resource (if it isn't already sitting in OpPath) and pulls both
// DLLs out of it, then re-checks. Deliberately lives here (not TForm1)
// so it's reachable from both uMain.pas and uManagedUtils.pas (the
// latter cannot see TForm1's methods - see this unit's mutual-dependency
// note above) with a single shared implementation instead of two
// diverging copies.

// Returns True if both DLLs are present on disk by the time this
// returns (whether they already were, or were just extracted); False if
// at least one is still missing afterward. Never raises.
function EnsureOpenSSLDllsPresent: Boolean;
function FastRemovePunctuation(const s: String): String;
function FileExists(const Path: String): Boolean;
function FileExistsStr(const aCaseSensitiveFileName: String): Boolean;
function FindAllFilesThrottled(const APath: String;
  const AMask: String = ''; ASearchSubDirs: Boolean = True): TStringList;
function FindBestFont(const PriorityList: array of String): String;
procedure FindFilesWithMaskList(AList: TStrings; const APath: String;
  AMaskList: TMaskList);
function FindHTMLEntity(const AName: String): String;
function FixWinFileName(const s: String): String;
procedure FreeAndNilIfAssigned(var Obj);
function GetDeepestDir(const AFileName: String): String;
function GetSubDirs(const APath: String): TStringList;
function GetToolVer(const AExecutable: String;
  const AVersionArg: String = '--version'): String;
function HasInternetConnection: Boolean;
function GetWineVersion: UnicodeString;
function HasValidFileNameChars(const s: String;
  AllowPathSeparators: Boolean = False): Boolean;
function IfExists(const s: String): String; overload;
function IfExists(const s: String; const v1, v2: variant): String; overload;
function IfThen(const AValue: Boolean): String; overload;
// Bumps (or shrinks, for negative AAmount) the font size of every TControl
// on AForm by AAmount (floor of 8pt), re-adjusts any visible TDBGrid's
// column widths, syncs AStatusBar's font (one point smaller) and AForm's
// own Canvas font, then resizes AForm to fit AToolBar at the new font size.
procedure IncreaseAllFonts(AForm: TCustomForm; AStatusBar: TStatusBar;
  AToolBar: TToolBar; const AAmount: Integer);
procedure InitializeDebugLog(const FileName: String = 'debug.log');
function IsDirectoryEmpty(const directory: String): Boolean;
function IsEmptyRecord(const Fields: TStringList): Boolean;

// True if ADiskFileName holds exactly the AArchiveFileName entry of
// AZipFileName: same size and CRC-32. A missing, stale or damaged copy// gives False. Usually costs no more than a directory lookup: a file
// already checked (or extracted) and untouched since is recognised by the
// size and timestamp recorded for it in OpPath's extracted-files.txt;
// anything else is read once in full to compute its CRC-32. With no zip,
// or no such entry in it, there is nothing to compare against, so an
// existing ADiskFileName counts as current.
function IsExtractedFileCurrent(
  const AZipFileName, AArchiveFileName, ADiskFileName: String): Boolean;

function IsGridEmpty(const AGrid: TDBGrid): Boolean;
function IsNativeWin32Control(const ACtrl: TWinControl): Boolean;
function IsReservedFileName(const AFileName: String): Boolean;
function IsStringAllUpper(const s: String): Boolean;
procedure LoadEnvironment(AList: TStringList);
procedure LogError(const AMessage: String; AException: Exception = nil);
function MessageDlgEx(const AMsg: String; ADlgType: TMsgDlgType;
  AButtons: TMsgDlgButtons; AParent: TForm = nil): TModalResult;

// Moves ASourceFileName onto ADestFileName, replacing it. False, with both
// files left as they were, if ADestFileName can't be replaced - on
// Windows, an .exe that is running or a .dll that is loaded, by this or
// another copy of the program.
function MoveFileOver(const ASourceFileName, ADestFileName: String): Boolean;

procedure NoOp;
// True if AFileName is a file an earlier filey wrote by mistake: before
// 3.1.0.800, ExtractManifestFileName returned no path at all, so each
// extracted-files.txt entry was saved as a one-line file named after its
// CRC-32 (e.g. "8DE146F7") in whatever the current directory was. Only a
// file that is exactly that - an 8-hex-digit name, small, holding one
// "<path>=<the same 8 hex digits>,<size>,<timestamp>" line - counts.
function IsStrayManifestFile(const AFileName: String): Boolean;
function ns(const AValue: Integer): String; inline; overload;
function ns(const AValue: int64): String; inline; overload;
function ns(const AValue: double; const ADecimals: Integer = 2): String;
  inline; overload;
function PosInsensitive(const SubStr, s: String): Integer;
function PosInsensitiveASCII(const SubStr, s: String): Integer;
// Decodes AFileName from disk as Windows-1252 (not UTF-8) and appends each
// line, converted to UTF-8, onto CSVLines - clearing it first. Windows-1252
// is what epguides.com's allshows.txt is actually encoded in.
function ProcessCP1252CSV(CSVLines: TStrings;
  const AFileName: String): TStrings;
function RemoveAllSpacesAndDots(const s: String): String;
function RemoveDiacritics(const s: String): String;

// Extracts AArchiveFileName from AZipFileName to ADiskFileName, replacing
// whatever is there, by way of a temporary file beside it: a failed or
// interrupted extraction never leaves a half-written ADiskFileName, and
// one that can't be replaced (see MoveFileOver) stays as it was. Logs
// failures. AOnProgress as for ExtractFileFromZip.
function ReplaceFromZip(const AZipFileName, AArchiveFileName,
  ADiskFileName: String; AOnProgress: Zipper.TProgressEvent = nil): Boolean;

function ReplAllCI(const s, OldVal: String; const NewVal: String = ''): String;
  inline;
function ReplAllCITrim(const s, OldVal: String;
  const NewVal: String = ''): String; inline;
procedure ResolveSmartInput(var AInput: String);
function RunEx(const sCommandLine: String;
  bRedirectErr: Boolean = False): String; overload;
function RunEx(const sCommandLine: String; out AExitCode: Integer;
  bRedirectErr: Boolean = False): String; overload;
function RunEx(const AExecutable: String; const AParams: array of String;
  out AExitCode: Integer; bRedirectErr: Boolean = False): String; overload;
// Fire-and-forget async version of RunEx: launches the command on a
// background thread and returns immediately, so the caller (typically the
// UI thread) never blocks. ACallback is invoked once the command finishes,
// marshalled back onto the main thread automatically.
procedure RunExAsync(const sCommandLine: String; ACallback: TRunExCallback;
  bRedirectErr: Boolean = False);
// Runs many command lines in parallel, at most AMaxConcurrency at a time,
// re-filling the pool as each one finishes. AItemCallback fires per command
// (completion order, not submission order); ACompleteCallback fires once
// after the whole batch is done. Both callbacks are marshalled onto the
// main thread automatically.
procedure RunExBatch(const ACommandLines: array of String;
  AItemCallback: TRunExBatchItemCallback;
  ACompleteCallback: TRunExBatchCompleteCallback = nil;
  AMaxConcurrency: Integer = 4; bRedirectErr: Boolean = False); overload;
// The same, with each command run in its own working directory:
// ACurrentDirs[i] for ACommandLines[i] ('' or a missing entry: the
// program's own). Unlike SetCurrentDir, that is per process, so it is safe
// with several commands running at once.
procedure RunExBatch(const ACommandLines, ACurrentDirs: array of String;
  AItemCallback: TRunExBatchItemCallback;
  ACompleteCallback: TRunExBatchCompleteCallback = nil;
  AMaxConcurrency: Integer = 4; bRedirectErr: Boolean = False); overload;
// Runs ACommandLines through RunExBatch (in ACurrentDirs, as above) and
// waits for them, keeping the window responsive (Application.
// ProcessMessages), then returns each command's output and exit code at
// the same index. AOnProgress, if given, is told as commands finish.
// Returns False only if it stopped waiting: no command finished for
// AStallMs (0: never stop). The commands still running then finish on
// their own, and their results are dropped; AOutputs holds '' and
// AExitCodes -1 for them.
function RunExBatchAndWait(const ACommandLines, ACurrentDirs: array of String;
  out AOutputs: TStringArray; out AExitCodes: TIntegerArray;
  AMaxConcurrency: Integer = 4; bRedirectErr: Boolean = False;
  AOnProgress: TParallelProgress = nil; AStallMs: QWord = 120000): Boolean;
// Runs AJob(0) .. AJob(ACount - 1) on up to AMaxThreads worker threads
// and waits for all of them, keeping the window responsive (Application.
// ProcessMessages). AOnProgress, if given, is told as jobs finish;
// ACancelCheck, if given, can stop jobs that haven't started yet. An
// exception in a job is caught, logged and counted as that job failing;
// the other jobs carry on. Returns the number of jobs that ran to the end
// without one. With one job, one thread or no thread support, the jobs
// simply run here, on the main thread.
function RunParallel(ACount: Integer; AJob: TParallelJob;
  AMaxThreads: Integer; AOnProgress: TParallelProgress = nil;
  ACancelCheck: TParallelCancelCheck = nil): Integer;
// Worker threads worth starting for disk- or process-bound jobs: the
// processor count, but never fewer than 2 nor more than AMax.
function ParallelThreadCount(AMax: Integer = 8): Integer;
procedure SafeClearGridColumns(Grid: TDBGrid);
function SafeCopy(const Source: String; StartPos, Length: Integer): String;
function SafeExpandFilename(const FileName: String): String;
// Focuses AControl only if it is non-nil, focusable (CanFocus), and actually
// on-screen (Showing) - e.g. not sitting on an inactive TPageControl tab.
// Silently does nothing otherwise; never raises.
procedure SafeSetFocus(AControl: TControl);

// True if AZip1 and AZip2 are the same zip archive: the same size and a
// byte-identical central directory, which lists every entry's name, size,
// date and CRC-32 - so the compressed data itself is never read. Streams
// that don't look like zip archives are compared in full.
function SameZipArchive(AZip1, AZip2: TStream): Boolean;

function sb(const s: String): String; overload;
function sb(const Args: array of const): String; overload;
// Shared accumulator built on top of sb()'s VarRecToStr helper. Strings are
// refcounted, so there is nothing to leak or Free - the only real hazard is
// reentrancy: two call sites interleaving sbClear/sbAppend/sbResult on the
// same global buffer. Treat the trio as a strict, non-nested unit inside a
// single routine - sbClear, a run of sbAppend calls, one sbResult read into
// a local var/Result - and never call another routine that itself touches
// sbAppend/sbClear/sbResult while your own accumulation is still in
// progress. See the comment above the implementation for more detail.
procedure sbClear;
procedure sbAppend(const s: String); overload;
procedure sbAppend(const Args: array of const); overload;
function sbResult: String;
// Local-accumulator variant: appends into the caller's own String var, in
// place, so there is no shared state at all - no reentrancy hazard, no
// thread-safety caveat, nothing to clear between uses. Prefer this over
// sbAppend/sbResult/sbClear whenever the accumulation is entirely local to
// one routine (which is most of the current call sites).
procedure sb(var Accum: String; const s: String); overload;
procedure sb(var Accum: String; const Args: array of const); overload;
procedure SetAllCursors(const CursorConstant: Integer);
procedure SetReadOnly(AObject: TObject; AValue: Boolean);
function ShowMessage(const AMessage: String; const bIsHidden: Boolean;
  const ADialogID: String = ''): Boolean; overload;
function StripNonAlphaNum(const s: String): String;
procedure SwapString(var a, b: String);
procedure ToggleBoolean(AObject: TObject;
  const APropName: String = 'ReadOnly');
function ToolBarWidthSize(const AToolBar: TToolBar): Integer;
function ToolRunsOK(const AWinePrefix, AExePath: String;
  const AVersionArg: String = '--version'): Boolean;
function TrimPeriod(const s: String): String;
function UpPipe(const s: String): String;
function UTF8ContainsText(const AText, ASubText: String): Boolean;
function UTF8ProperCase(const AText: String;
  const AWordDelims: TSysCharSet): String;
function ValidateFileName(const AFileName: String): Boolean;
function ValidatePath(const APath: String): Boolean;
function VarRecToVariant(const AVarRec: TVarRec): variant;

//jcf:format=on

// =============================================================================
implementation

// =============================================================================

uses
  Character, crc, db, FileUtil, Graphics, LazFileUtils, LazUTF8,
  LConvEncoding, Math, Process, StrUtils, SynEdit, TypInfo,
  Variants, uManagedUtils, URIParser; //, ZStream {for clmax};

var
  // Serializes DebugLog and LogError (see DebugLog), so worker threads can
  // log. Set up first thing in this unit's initialization.
  //
  // System.TRTLCriticalSection, and System.EnterCriticalSection/
  // LeaveCriticalSection below, are qualified on purpose: on Windows the
  // Windows and JwaWindows units (interface uses) declare their own
  // TRTLCriticalSection (= _RTL_CRITICAL_SECTION) and Enter/Leave
  // functions, which would otherwise win, while InitCriticalSection and
  // DoneCriticalSection exist only in System and insist on its type.
  LogLock: System.TRTLCriticalSection;
  // Serializes ReadManifestEntry and WriteManifestEntry: each reads
  // extracted-files.txt and WriteManifestEntry writes it back whole, so two
  // extractions running at once (RunParallel) would otherwise lose one
  // another's entries.
  ManifestLock: System.TRTLCriticalSection;

const
  // Compile-time constant table: built once by the compiler into the data
  // segment, not the heap, so there's no SetLength/Add loop to run at
  // startup and nothing for multiple threads to race over or free.
  HTML_ENTITIES: array[0..85] of THTMLEntity = (
    // Core XML/HTML entities
    (Name: 'amp'; Value: '&'),
    (Name: 'lt'; Value: '<'),
    (Name: 'gt'; Value: '>'),
    (Name: 'quot'; Value: '"'),
    (Name: 'apos'; Value: ''''),
    (Name: 'nbsp'; Value: ' '),
    // Latin Extended
    (Name: 'Agrave'; Value: 'À'), (Name: 'agrave'; Value: 'à'),
    (Name: 'Aacute'; Value: 'Á'), (Name: 'aacute'; Value: 'á'),
    (Name: 'Acirc'; Value: 'Â'), (Name: 'acirc'; Value: 'â'),
    (Name: 'Atilde'; Value: 'Ã'), (Name: 'atilde'; Value: 'ã'),
    (Name: 'Auml'; Value: 'Ä'), (Name: 'auml'; Value: 'ä'),
    (Name: 'Aring'; Value: 'Å'), (Name: 'aring'; Value: 'å'),
    (Name: 'AElig'; Value: 'Æ'), (Name: 'aelig'; Value: 'æ'),
    (Name: 'Egrave'; Value: 'È'), (Name: 'egrave'; Value: 'è'),
    (Name: 'Eacute'; Value: 'É'), (Name: 'eacute'; Value: 'é'),
    (Name: 'Ecirc'; Value: 'Ê'), (Name: 'ecirc'; Value: 'ê'),
    (Name: 'Euml'; Value: 'Ë'), (Name: 'euml'; Value: 'ë'),
    (Name: 'Igrave'; Value: 'Ì'), (Name: 'igrave'; Value: 'ì'),
    (Name: 'Iacute'; Value: 'Í'), (Name: 'iacute'; Value: 'í'),
    (Name: 'Icirc'; Value: 'Î'), (Name: 'icirc'; Value: 'î'),
    (Name: 'Iuml'; Value: 'Ï'), (Name: 'iuml'; Value: 'ï'),
    (Name: 'Ocirc'; Value: 'Ô'), (Name: 'ocirc'; Value: 'ô'),
    (Name: 'Otilde'; Value: 'Õ'), (Name: 'otilde'; Value: 'õ'),
    (Name: 'Ouml'; Value: 'Ö'), (Name: 'ouml'; Value: 'ö'),
    (Name: 'Ugrave'; Value: 'Ù'), (Name: 'ugrave'; Value: 'ù'),
    (Name: 'Uacute'; Value: 'Ú'), (Name: 'uacute'; Value: 'ú'),
    (Name: 'Ucirc'; Value: 'Û'), (Name: 'ucirc'; Value: 'û'),
    (Name: 'Uuml'; Value: 'Ü'), (Name: 'uuml'; Value: 'ü'),
    (Name: 'Ccedil'; Value: 'Ç'), (Name: 'ccedil'; Value: 'ç'),
    (Name: 'szlig'; Value: 'ß'),
    (Name: 'yacute'; Value: 'ý'), (Name: 'yuml'; Value: 'ÿ'),
    (Name: 'iexcl'; Value: '¡'), (Name: 'iquest'; Value: '¿'),
    // Typographic punctuation
    (Name: 'mdash'; Value: '—'),
    (Name: 'ndash'; Value: '–'),
    (Name: 'lsquo'; Value: #$E2#$80#$98),
    (Name: 'rsquo'; Value: #$E2#$80#$99),
    (Name: 'ldquo'; Value: #$E2#$80#$9C),
    (Name: 'rdquo'; Value: #$E2#$80#$9D),
    (Name: 'hellip'; Value: '…'),
    (Name: 'laquo'; Value: '«'),
    (Name: 'raquo'; Value: '»'),
    (Name: 'bull'; Value: '•'),
    (Name: 'dagger'; Value: '†'),
    (Name: 'Dagger'; Value: '‡'),
    // Symbols
    (Name: 'copy'; Value: '©'),
    (Name: 'reg'; Value: '®'),
    (Name: 'trade'; Value: '™'),
    (Name: 'euro'; Value: '€'),
    (Name: 'pound'; Value: '£'),
    (Name: 'yen'; Value: '¥'),
    (Name: 'cent'; Value: '¢'),
    (Name: 'deg'; Value: '°'),
    (Name: 'plusmn'; Value: '±'),
    (Name: 'frac12'; Value: '½'),
    (Name: 'frac14'; Value: '¼'),
    (Name: 'frac34'; Value: '¾'),
    (Name: 'times'; Value: '×'),
    (Name: 'divide'; Value: '÷'),
    (Name: 'para'; Value: '¶'),
    (Name: 'sect'; Value: '§'),
    (Name: 'middot'; Value: '·')
    );

  // =============================================================================
  // KEEPING EXTRACTED FILES CURRENT
  // =============================================================================
  {$REGION 'Extracted-file freshness'}
const
  // One line per file ExtractFromZipIfStale/ReplaceFromZip has verified or
  // extracted: "<disk path>=<entry CRC-32>,<size>,<timestamp>", as they
  // were at that moment. Only a cache: without it (deleted, unreadable)
  // each file is just read once more to recheck its CRC-32.
  EXTRACT_MANIFEST_NAME = 'extracted-files.txt';

function ExtractManifestFileName: String;
begin
  // The assignment below was once joined onto the end of the comment line
  // above it, so it never ran: Result came back holding whatever the
  // caller's temporary happened to contain - in WriteManifestEntry, the
  // IntToHex CRC just built - and each entry was saved as a stray file
  // named after its CRC, in the current directory (see IsStrayManifestFile).
  // With no OpPath there is nowhere it belongs, so '' (callers skip it)
  // rather than a relative name.
  if OpPath = '' then Exit('');
  // OpPath is a UnicodeString; UTF8Encode says how to make it a String,
  // rather than leaving that to the default code page.
  Result := CombinePath(UTF8Encode(OpPath), EXTRACT_MANIFEST_NAME);
end;

// Size and last-write timestamp of AFileName, from a single directory
// lookup. The timestamp is only ever compared with another read the same
// way, never converted. On Windows it is local time, so a daylight-saving
// change makes it differ; that costs one CRC-32 recheck in
// IsExtractedFileCurrent, not a re-extraction. Its resolution is 1 second
// (2 on FAT drives), so a same-size rewrite by some other program within
// that second of Filey's last check would go unnoticed - until the file's
// timestamp next moves.
function FileSizeAndStamp(const AFileName: String;
  out ASize, AStamp: int64): Boolean;
var
  Info: TUnicodeSearchRec;
begin
  ASize := -1;
  AStamp := -1;
  Info := Default(TUnicodeSearchRec);
  Result := (SysUtils.FindFirst(UTF8Decode(AFileName), faAnyFile, Info) =
    0) and ((Info.Attr and faDirectory) = 0);
  if Result then
  begin
    ASize := Info.Size;
    AStamp := Info.Time;
  end;
  SysUtils.FindClose(Info);
end;

// CRC-32 of AFileName's contents - the same checksum a zip records for
// each entry.
function FileCRC32(const AFileName: String; out ACRC: longword): Boolean;
const
  CHUNK_SIZE = 1024 * 1024;
var
  Buffer: TBytes;
  fs: TSmartFileStream;
  n: LongInt;
begin
  Result := False;
  ACRC := 0;
  try
    fs.Setup(AFileName, fmOpenRead or fmShareDenyWrite);
    SetLength(Buffer, CHUNK_SIZE);
    ACRC := crc.crc32(0, nil, 0);
    repeat
      n := fs.Value.Read(Buffer[0], CHUNK_SIZE);
      if n > 0 then ACRC := crc.crc32(ACRC, @Buffer[0], n);
    until n <= 0;
    Result := True;
  except
    on E: Exception do LogError('FileCRC32: could not read ' + AFileName, E);
  end;
end;

// CRC-32 and uncompressed size of AArchiveFileName inside AZipFileName,
// from the zip's central directory. Names are matched the way
// TUnZipper.UnZipFiles matches them: ignoring case.
function ZipEntryInfo(const AZipFileName, AArchiveFileName: String;
  out ACRC: longword; out ASize: int64): Boolean;
var
  Entry: TFullZipFileEntry;
  i: Integer;
  uz: TSmartUnZipper;
begin
  Result := False;
  ACRC := 0;
  ASize := -1;
  if (AZipFileName = '') or not FileExists(AZipFileName) then Exit;
  try
    uz.Value.FileName := AZipFileName;
    uz.Value.Examine;
    for i := 0 to uz.Value.Entries.Count - 1 do
    begin
      Entry := uz.Value.Entries.FullEntries[i];
      if UTF8CompareText(Entry.ArchiveFileName, AArchiveFileName) = 0 then
      begin
        ACRC := Entry.crc32;
        ASize := Entry.Size;
        Exit(True);
      end;
    end;
  except
    on E: Exception do LogError('ZipEntryInfo: could not read ' +
        AZipFileName, E);
  end;
end;

// The manifest entry for ADiskFileName (see EXTRACT_MANIFEST_NAME), if any.
function ReadManifestEntry(const ADiskFileName: String;
  out ACRC: longword; out ASize, AStamp: int64): Boolean;
var
  Parts: TStringArray;
  sManifest: String;
  SL: TSmartStrings;
begin
  Result := False;
  ACRC := 0;
  ASize := -1;
  AStamp := -1;
  sManifest := ExtractManifestFileName;
  // An '=' would split the key, so such a path is simply never cached.
  if (sManifest = '') or (Pos('=', ADiskFileName) > 0) then Exit;
  System.EnterCriticalSection(ManifestLock);
  try
    if not FileExists(sManifest) then Exit;
    try
      SL.Value.CaseSensitive := True; // Linux paths are
      SL.Value.LoadFromFile(sManifest);
      Parts := SL.Value.Values[ADiskFileName].Split([',']);
      Result := (Length(Parts) = 3) and
        TryStrToDWord('$' + Parts[0], ACRC) and
        TryStrToInt64(Parts[1], ASize) and TryStrToInt64(Parts[2], AStamp);
    except
      on E: Exception do DebugLog('ReadManifestEntry: could not read ' +
          sManifest + ': ' + E.Message);
    end;
  finally
    System.LeaveCriticalSection(ManifestLock);
  end;
end;

// Records that ADiskFileName, as it is right now, is the zip entry whose
// CRC-32 is ACRC.
procedure WriteManifestEntry(const ADiskFileName: String; ACRC: longword);
var
  DiskSize, DiskStamp: int64;
  sManifest: String;
  SL: TSmartStrings;
begin
  if Pos('=', ADiskFileName) > 0 then Exit;
  // Fetched once, into a variable of its own, so it is computed exactly
  // once per call.
  sManifest := ExtractManifestFileName;
  if sManifest = '' then Exit;
  if not FileSizeAndStamp(ADiskFileName, DiskSize, DiskStamp) then Exit;
  System.EnterCriticalSection(ManifestLock);
  try
    try
      SL.Value.CaseSensitive := True;
      if FileExists(sManifest) then SL.Value.LoadFromFile(sManifest);
      SL.Value.Values[ADiskFileName] :=
        sb([IntToHex(ACRC, 8), ',', DiskSize, ',', DiskStamp]);
      SL.Value.SaveToFile(sManifest);
    except
      // Only a cache, so no error.log entry: the cost of failing is one
      // extra CRC-32 check next time.
      on E: Exception do DebugLog('WriteManifestEntry: could not update ' +
          sManifest + ': ' + E.Message);
    end;
  finally
    System.LeaveCriticalSection(ManifestLock);
  end;
end;

function IsStrayManifestFile(const AFileName: String): Boolean;
const
  // A real line is a path plus about 30 characters; this leaves room for a
  // long path while ruling out anything that is plainly something else.
  MAX_STRAY_SIZE = 4096;
var
  i: Integer;
  Parts: TStringArray;
  sLine, sName: String;
  DiskSize, DiskStamp: int64;
  SL: TSmartStrings;
begin
  Result := False;
  sName := ExtractFileName(AFileName);
  if Length(sName) <> 8 then Exit;
  for i := 1 to 8 do
    if not (sName[i] in ['0'..'9', 'A'..'F']) then Exit;
  if not FileSizeAndStamp(AFileName, DiskSize, DiskStamp) then Exit;
  if (DiskSize <= 0) or (DiskSize > MAX_STRAY_SIZE) then Exit;
  try
    SL.Value.LoadFromFile(AFileName);
  except
    Exit;
  end;
  // Exactly one non-blank line (SaveToFile adds a line ending).
  sLine := '';
  for i := 0 to SL.Value.Count - 1 do
    if Trim(SL.Value[i]) <> '' then
    begin
      if sLine <> '' then Exit;
      sLine := SL.Value[i];
    end;
  // "<path>=<CRC>,<size>,<timestamp>": the part after the LAST '=' (a path
  // never holds one - WriteManifestEntry refuses those), its CRC the very
  // name of the file, and two whole numbers.
  i := LastDelimiter('=', sLine);
  if i <= 1 then Exit;
  Parts := Copy(sLine, i + 1, MaxInt).Split([',']);
  Result := (Length(Parts) = 3) and (Parts[0] = sName) and
    TryStrToInt64(Parts[1], DiskSize) and TryStrToInt64(Parts[2], DiskStamp);
end;

// True if AStream1 and AStream2 hold the same ACount bytes from AStart on.
function SameStreamRange(AStream1, AStream2: TStream;
  AStart, ACount: int64): Boolean;
const
  CHUNK_SIZE = 64 * 1024;
var
  Buffer1, Buffer2: TBytes;
  n: Integer;
begin
  Result := True;
  SetLength(Buffer1, CHUNK_SIZE);
  SetLength(Buffer2, CHUNK_SIZE);
  AStream1.Position := AStart;
  AStream2.Position := AStart;
  while ACount > 0 do
  begin
    n := integer(Min(int64(CHUNK_SIZE), ACount));
    AStream1.ReadBuffer(Buffer1[0], n);
    AStream2.ReadBuffer(Buffer2[0], n);
    if not CompareMem(@Buffer1[0], @Buffer2[0], n) then Exit(False);
    Dec(ACount, n);
  end;
end;

function ExtractFromZipIfStale(
  const AZipFileName, AArchiveFileName, ADiskFileName: String;
  AOnProgress: Zipper.TProgressEvent): Boolean;
begin
  if IsExtractedFileCurrent(AZipFileName, AArchiveFileName,
    ADiskFileName) then
    Exit(True);
  Result := ReplaceFromZip(AZipFileName, AArchiveFileName,
    ADiskFileName, AOnProgress);
end;

function IsExtractedFileCurrent(
  const AZipFileName, AArchiveFileName, ADiskFileName: String): Boolean;
var
  DiskCRC, EntryCRC, KnownCRC: longword;
  DiskSize, DiskStamp, EntrySize, KnownSize, KnownStamp: int64;
begin
  if not FileSizeAndStamp(ADiskFileName, DiskSize, DiskStamp) then
    Exit(False); // missing
  if not ZipEntryInfo(AZipFileName, AArchiveFileName, EntryCRC,
    EntrySize) then
    Exit(True); // nothing to compare against: keep what is there
  if DiskSize <> EntrySize then Exit(False);
  // The quick way: this exact file (same size and timestamp) was already
  // found to be the entry with this CRC-32.
  if ReadManifestEntry(ADiskFileName, KnownCRC, KnownSize, KnownStamp) and
    (KnownCRC = EntryCRC) and (KnownSize = DiskSize) and
    (KnownStamp = DiskStamp) then Exit(True);
  // The sure way, once; recorded so that next time is the quick way.
  Result := FileCRC32(ADiskFileName, DiskCRC) and (DiskCRC = EntryCRC);
  if Result then WriteManifestEntry(ADiskFileName, EntryCRC);
end;

function MoveFileOver(const ASourceFileName, ADestFileName: String): Boolean;
begin
  {$IFDEF UNIX}
  // rename() replaces ADestFileName in one step, even while it is in use.
  Result := RenameFile(ASourceFileName, ADestFileName);
  {$ELSE}// RenameFile (MoveFile) won't overwrite on Windows, and DeleteFile fails
  // on a running .exe or a loaded .dll - which leaves that one in place.
  if FileExists(ADestFileName) and not DeleteFile(ADestFileName) then
  Exit(False);
  Result := RenameFile(ASourceFileName, ADestFileName);
  {$ENDIF}
end;

function ReplaceFromZip(const AZipFileName, AArchiveFileName,
  ADiskFileName: String; AOnProgress: Zipper.TProgressEvent): Boolean;
var
  EntryCRC: longword;
  EntrySize: int64;
  sTemp: String;
begin
  Result := False;
  // Beside the target, so the final move is a rename on the same volume.
  sTemp := ADiskFileName + '.part';
  try
    DeleteIfExists(sTemp); // left over from an interrupted run
    // TUnZipper checks each entry's CRC-32 as it decompresses, raising on a
    // mismatch, so a file that gets as far as MoveFileOver is intact.
    if not ExtractFileFromZip(AZipFileName, AArchiveFileName,
      sTemp, AOnProgress) then
      LogError(sb(['ReplaceFromZip: "', AArchiveFileName,
        '" could not be extracted from "', AZipFileName, '"']))
    else if not MoveFileOver(sTemp, ADiskFileName) then
      LogError(sb(['ReplaceFromZip: could not replace "', ADiskFileName,
        '" (in use?) - the copy already there stays for now']))
    else
    begin
      if ZipEntryInfo(AZipFileName, AArchiveFileName, EntryCRC, EntrySize) then
        WriteManifestEntry(ADiskFileName, EntryCRC);
      Result := True;
    end;
  except
    on E: Exception do LogError(
        sb(['ReplaceFromZip: failed to extract "', AArchiveFileName,
        '" from "', AZipFileName, '" to "', ADiskFileName, '"']), E);
  end;
  DeleteIfExists(sTemp);
end;

function SameZipArchive(AZip1, AZip2: TStream): Boolean;
const
  EOCD_SIGNATURE = $06054B50; // "PK"#5#6: end of central directory record
  EOCD_SIZE = 22; // that record, without its trailing comment
  MAX_COMMENT_SIZE = $FFFF;
var
  DirOffset, Signature: longword;
  DirStart, Size, TailStart: int64;
  i, TailLen: Integer;
  Tail: TBytes;
begin
  Result := False;
  if not (Assigned(AZip1) and Assigned(AZip2)) then Exit;
  Size := AZip1.Size;
  if Size <> AZip2.Size then Exit;
  // Where the central directory starts, from the end-of-central-directory
  // record: normally the last 22 bytes, further back if the zip has a
  // comment. Not found (or a Zip64 archive, which keeps the offset
  // elsewhere): DirStart stays 0 and the whole of both is compared.
  DirStart := 0;
  if Size >= EOCD_SIZE then
  begin
    TailLen := integer(Min(Size, int64(EOCD_SIZE + MAX_COMMENT_SIZE)));
    TailStart := Size - TailLen;
    SetLength(Tail, TailLen);
    AZip1.Position := TailStart;
    AZip1.ReadBuffer(Tail[0], TailLen);
    for i := TailLen - EOCD_SIZE downto 0 do
    begin
      Move(Tail[i], Signature, SizeOf(Signature));
      if LEtoN(Signature) <> EOCD_SIGNATURE then Continue;
      Move(Tail[i + 16], DirOffset, SizeOf(DirOffset));
      DirOffset := LEtoN(DirOffset);
      if (DirOffset <> $FFFFFFFF) and (int64(DirOffset) <= TailStart + i) then
        DirStart := DirOffset;
      Break;
    end;
  end;
  Result := SameStreamRange(AZip1, AZip2, DirStart, Size - DirStart);
end;
{$ENDREGION}

generic procedure GenericSwap<T>(var Left, Right: T);
var
  Temp: T;
begin
  Temp := Left;
  Left := Right;
  Right := Temp;
end;

procedure ApplyFormFonts(AForm: TCustomForm; AFontDialog: TFontDialog);
var
  LComp: TComponent;
begin
  AFontDialog.Font.Assign(AForm.Canvas.Font);
  AFontDialog.Title := 'Change Fonts';
  if AFontDialog.Execute then
  begin
    for LComp in AForm do if (LComp is TControl) and not
        (LComp is TSynEdit) then TControl(LComp).Font.Assign(AFontDialog.Font);
    AForm.Canvas.Font.Assign(AFontDialog.Font);
  end;
end;

function ASCIIFold(const s: String): String;
  // Converts accented/diacritic characters to their ASCII base equivalents.
  // Applied before building SEARCHTHIS so that searches for 'AKTA MANNISKOR'
  // correctly match 'ÄKTA MÄNNISKOR'.
var
  i: Integer = 0;
  CP: cardinal = 0;
  U: String = '';
  ULen: Integer = 0;
begin
  Result := '';
  if s.IsEmpty then Exit('');
  i := 1;
  while i <= Length(s) do
  begin
    ULen := UTF8CodepointSize(@s[i]);
    U := Copy(s, i, ULen);
    CP := UTF8CodepointToUnicode(@s[i], ULen);
    {(*}
      case CP of
        // A variants
        $00C0..$00C6, $0100, $0102, $0104 : Result := Result + 'A';
        $00E0..$00E6, $0101, $0103, $0105 : Result := Result + 'a';
        // C variants
        $00C7, $0106, $0108, $010C        : Result := Result + 'C';
        $00E7, $0107, $0109, $010D        : Result := Result + 'c';
        // D variants
        $00D0, $010E, $0110               : Result := Result + 'D';
        $00F0, $010F, $0111               : Result := Result + 'd';
        // E variants
        $00C8..$00CB, $0112, $0114, $0116,
        $0118, $011A                      : Result := Result + 'E';
        $00E8..$00EB, $0113, $0115, $0117,
        $0119, $011B                      : Result := Result + 'e';
        // G variants
        $011C, $011E, $0120, $0122        : Result := Result + 'G';
        $011D, $011F, $0121, $0123        : Result := Result + 'g';
        // H variants
        $0124, $0126                      : Result := Result + 'H';
        $0125, $0127                      : Result := Result + 'h';
        // I variants
        $00CC..$00CF, $0128, $012A, $012C,
        $012E, $0130                      : Result := Result + 'I';
        $00EC..$00EF, $0129, $012B, $012D,
        $012F, $0131                      : Result := Result + 'i';
        // J variants
        $0134                             : Result := Result + 'J';
        $0135                             : Result := Result + 'j';
        // K variants
        $0136                             : Result := Result + 'K';
        $0137                             : Result := Result + 'k';
        // L variants
        $0139, $013B, $013D, $013F, $0141 : Result := Result + 'L';
        $013A, $013C, $013E, $0140, $0142 : Result := Result + 'l';
        // N variants
        $00D1, $0143, $0145, $0147, $014A : Result := Result + 'N';
        $00F1, $0144, $0146, $0148, $014B : Result := Result + 'n';
        // O variants
        $00D2..$00D6, $00D8, $014C, $014E,
        $0150                             : Result := Result + 'O';
        $00F2..$00F6, $00F8, $014D, $014F,
        $0151                             : Result := Result + 'o';
        // R variants
        $0154, $0156, $0158               : Result := Result + 'R';
        $0155, $0157, $0159               : Result := Result + 'r';
        // S variants
        $015A, $015C, $015E, $0160        : Result := Result + 'S';
        $015B, $015D, $015F, $0161        : Result := Result + 's';
        // T variants
        $0162, $0164, $0166               : Result := Result + 'T';
        $0163, $0165, $0167               : Result := Result + 't';
        // U variants
        $00D9..$00DC, $0168, $016A, $016C,
        $016E, $0170, $0172               : Result := Result + 'U';
        $00F9..$00FC, $0169, $016B, $016D,
        $016F, $0171, $0173               : Result := Result + 'u';
        // W variants
        $0174                             : Result := Result + 'W';
        $0175                             : Result := Result + 'w';
        // Y variants
        $00DD, $0176, $0178               : Result := Result + 'Y';
        $00FD, $00FF, $0177               : Result := Result + 'y';
        // Z variants
        $0179, $017B, $017D               : Result := Result + 'Z';
        $017A, $017C, $017E               : Result := Result + 'z';
        // AE, OE, ss ligatures
        $0152                             : Result := Result + 'OE';
        $0153                             : Result := Result + 'oe';
        $00DF                             : Result := Result + 'ss';
        else
          Result := Result + U;  // Pass through unchanged (ASCII, Arabic, CJK, etc.)
      end;
      {(*}
      Inc(I, ULen);
    end;
end;

function BackupFileForWrite(const FileName: String): Integer;
const
  //DefaultBackupAddExt = 'bak';
  MaxCounter = 9;
var
  AText, BackupDir, BackupFileName, CounterFileName: String;
  i: Integer = 0;
begin
  Result := 0;
  // The backup directory was never created, so even a correct CopyFile
  // would have failed on a clean install.
  BackupDir := CombinePath(OpPath, 'backup');
  if not ForceDirectories(BackupDir) then
  begin
    LogError('BackupFileForWrite: could not create ' + BackupDir);
    Exit(mrAbort);
  end;
  BackupFileName := CombinePath(BackupDir, efn(FileName)) + ';';
  // rename all backup files (increase number)
  i := 1;
  while FileExists(BackupFileName + ns(i)) and (i <= MaxCounter) do Inc(i);
  if i > MaxCounter then
  begin
    Dec(i);
    CounterFileName := BackupFileName + IntToStr(MaxCounter);
    // remove old backup file
    repeat
      if FileExists(CounterFileName) then if not DeleteFile(CounterFileName) then
        begin
          AText := Format('Unable to remove old backup file "%s"!',
            [CounterFileName]);
          Result := MessageDlgEx(AText, mtError, [mbAbort, mbRetry, mbIgnore]);
          if Result = mrAbort then Exit;
          if Result = mrIgnore then Result := mrOk;
        end;
    until Result <> mrRetry;
  end;
  // rename all old backup files
  Dec(i);
  while i >= 1 do
  begin
    repeat
      if not RenameFile(BackupFileName + ns(i), BackupFileName +
        ns(i + 1)) then
      begin
        AText := Format('Unable to rename file "%s" to "%s"!',
          [BackupFileName + IntToStr(i), BackupFileName +
          IntToStr(i + 1)]);
        Result := MessageDlgEx(AText, mtError, [mbAbort, mbRetry, mbIgnore]);
        if Result = mrAbort then Exit;
        if Result = mrIgnore then Result := mrOk;
      end;
    until Result <> mrRetry;
    Dec(i);
  end;
  // Was "BackupFileName := BackupFileName + '1';" - which computed the new
  // name and then threw it away. CounterFileName is only assigned inside
  // the rare "9 backups already exist" branch above, so on the normal path
  // this called CopyFile(FileName, ''), which failed, which popped an
  // Abort/Retry/Ignore dialog on every single backup attempt.
  CounterFileName := BackupFileName + '1';
  repeat
    if not CopyFile(FileName, CounterFileName) then
    begin
      AText := Format('Unable to backup file "%s" to "%s"!',
        [FileName, CounterFileName]);
      Result := MessageDlgEx(AText, mtError, [mbAbort, mbRetry, mbIgnore]);
      if Result = mrAbort then Exit;
      if Result = mrIgnore then Result := mrOk;
    end
    else
      Result := mrOk;
  until Result <> mrRetry;
end;

//jcf:format=on

function QuarantineFile(const AFileName: String): Boolean;
const
  // Every file a dBase table can be spread across, keyed by extension.
  // Only .DBF's companions are handled here (not, say, an .NDX/.MDX -
  // this app's tables use TDbf's native index format, not those) - see
  // uDBFManager.ConfigureDbfDefaults for the Version/TableLevel this app
  // writes, which is what determines which companion files can exist.
  Companions: array[0..2] of String = ('.DBT', '.CDX', '.FPT');
var
  BackupDir, Companion, Dest, Stamp: String;
  i: Integer;

// Moves ASource into BackupDir under the same base name plus Stamp, if
// ASource exists. Logs and returns False only on an actual failed
// rename of a file that does exist - a missing companion file (the
// common case; most tables don't have a .DBT/.CDX/.FPT at all) is not
// a failure.
  function QuarantineOne(const aSource: String): Boolean;
  begin
    Result := True;
    if not FileExists(aSource) then Exit;
    Dest := CombinePath(BackupDir, efn(ChangeFileExt(aSource, '')) +
      '_' + Stamp + ExtractFileExt(aSource));
    if not RenameFile(aSource, Dest) then
    begin
      LogError('QuarantineFile: could not rename "' + aSource +
        '" to "' + Dest + '"');
      Result := False;
    end;
  end;

begin
  Result := True;
  if not FileExists(AFileName) then Exit; // Nothing to quarantine.
  BackupDir := CombinePath(OpPath, 'backup');
  if not ForceDirectories(BackupDir) then
  begin
    LogError('QuarantineFile: could not create ' + BackupDir);
    Exit(False);
  end;
  // One timestamp shared by AFileName and all its companions, so a
  // .DBF/.DBT/.CDX/.FPT quarantined together are easy to identify as
  // having come from the same event, and so two tables quarantined in
  // the same call to CreateAndOpenDBFs don't collide on name.
  Stamp := FormatDateTime('YYYYMMDD_hhnnss', Now);
  if not QuarantineOne(AFileName) then Exit(False);
  for i := 0 to High(Companions) do
  begin
    Companion := ChangeFileExt(AFileName, Companions[i]);
    if not QuarantineOne(Companion) then Result := False;
    // Deliberately keeps going rather than Exit(False) here - AFileName
    // itself is already safely out of the way by this point, which is
    // the part that actually unblocks CreateAndOpenDBFs; a companion
    // file left behind gets logged above but shouldn't stop the table
    // from being recreated.
  end;
end;

// Cross-platform, delimiter-correct path join (directory + filename).
// A shorter spelling of TFilePath.Combine for call sites that just want
// the resulting String and don't need to chain a TFilePath method (like
// .Exists) off the result directly - assign the result to a TFilePath
// variable first if you need that (TFilePath converts from String
// implicitly). Deliberately returns String, not TFilePath: TFilePath
// lives in uManagedUtils.pas, and this unit's public signatures never
// expose that unit's types - see the banner comment at the top of this
// file. uManagedUtils is already an implementation-only dependency here.
function CombinePath(const APath, AFileName: String): String;
begin
  Result := TFilePath.Combine(APath, AFileName);
end;

procedure ConcatenateFiles(const InFileNames: array of String;
  const OutFileName: String);
var
  i: Integer = 0;
  InStream: TSmartFileStream;
  OutStream: TSmartFileStream;
begin
  OutStream.Setup(OutFileName, fmCreate);
  for i := 0 to High(InFileNames) do
  begin
    InStream.Setup(InFileNames[i], fmOpenRead);
    OutStream.Value.CopyFrom(InStream.Value, InStream.Value.Size);
  end;
end;

//jcf:format=on
procedure ConfigureDllSearchPath;
{$IFDEF WINDOWS}
begin
  if not SetDllDirectoryW(pwidechar(CnfgFilePath)) then
    LogError('Could not set DLL search directory: ' +
      SysErrorMessage(GetLastError));
end;
{$ELSE}
begin
  NoOp
end;
{$ENDIF}

function ContainsInsensitive(const Sub, Main: String): Boolean;
begin
  Result := PosInsensitive(Sub, Main) > 0;
end;

function ContainsText(const AText, ASubText: String): Boolean;
begin
  Result := UTF8ContainsText(AText, ASubText);
end;

function UTF8ContainsText(const AText, ASubText: String): Boolean;
begin
  Result := UTF8Pos(UTF8LowerCase(ASubText), UTF8LowerCase(AText)) > 0;
end;

function UTF8ProperCase(const AText: String;
  const AWordDelims: TSysCharSet): String;
var
  i, CharLen: Integer;
  AtWordStart: Boolean;
  CurChar: String;
begin
  Result := '';
  AtWordStart := True;
  i := 1;
  while i <= Length(AText) do
  begin
    CharLen := UTF8CodepointSize(PChar(@AText[i]));
    CurChar := Copy(AText, i, CharLen);
    if AtWordStart then Result := Result + UTF8UpperCase(CurChar)
    else
      Result := Result + CurChar;
    AtWordStart := (CharLen = 1) and (AText[i] in AWordDelims);
    Inc(i, CharLen);
  end;
end;

function CopyFileForceDir(const aSource, aDest: String): Boolean;
var
  APath: String = '';
begin
  Result := False;
  APath := ExtractFilePath(SafeExpandFilename(aDest));
  // ensure that Destination Path actually exists
  if not DirectoryExists(APath) then ForceDirectories(APath);
  Result := CopyFile(aSource, aDest, True, True);
end;

function CopyStreamWithProgress(aSource, aDest: TStream;
  AOnProgress: Zipper.TProgressEvent; ASender: TObject): int64;
const
  CHUNK_SIZE = 1024 * 1024;
var
  Buffer: TBytes;
  Chunk: LongInt;
  LastPct, Pct: Integer;
  Total: int64;
begin
  Result := 0;
  Total := aSource.Size - aSource.Position;
  if Total <= 0 then Exit;
  SetLength(Buffer, integer(Min(int64(CHUNK_SIZE), Total)));
  LastPct := -1;
  while Result < Total do
  begin
    Chunk := longint(Min(int64(Length(Buffer)), Total - Result));
    aSource.ReadBuffer(Buffer[0], Chunk);
    aDest.WriteBuffer(Buffer[0], Chunk);
    Inc(Result, Chunk);
    if not Assigned(AOnProgress) then Continue;
    Pct := integer((Result * 100) div Total);
    if Pct = LastPct then Continue;
    LastPct := Pct;
    AOnProgress(ASender, Pct);
  end;
end;

// Thin wrapper around LazLogger's DebugLn: adds a timestamp prefix (DebugLn
// doesn't supply one on its own) and otherwise defers to LazLogger's own
// file handling and buffering. LogLock makes it safe to call from worker
// threads (RunParallel jobs, RunEx threads): it keeps two threads from
// writing at once, and keeps each line in one piece on the console and in
// debug.log alike, without relying on how thread-safe a given LazLogger
// version happens to be.
procedure DebugLog(const Msg: String);
{$IFDEF DEBUG}
var
  FormattedMsg: String;
begin
  FormattedMsg := Format('[%s] %s',
    [FormatDateTime('YYYY-MM-DD hh:nn:ss', Now), Msg]);
  System.EnterCriticalSection(LogLock);
  try
    WriteLn(StdErr, FormattedMsg); // console echo, same as before
    // StdErr is per thread in FPC, each with its own buffer: flushed here,
    // inside the lock, so lines from different threads can't splice.
    Flush(StdErr);
    DebugLn(FormattedMsg);        // file logging, now owned by LazLogger
  finally
    System.LeaveCriticalSection(LogLock);
  end;
end;
{$ELSE}
begin
  // Compiles to nothing in Release mode
end;
{$ENDIF}

function DecodeHTMLEntity(const AEntity: String): String;
  // AEntity : the text between & and ;  e.g. 'amp', 'Auml', '#196', '#xC4'
  // Returns : the decoded UTF-8 string, or '' if unrecognised.
  //           Returning '' signals DecodeHTMLEntities to preserve the original &...;
var
  CodePoint: cardinal = 0;
  IntVal: Integer = 0;
  HexStr: String = '';
begin
  Result := '';
  if AEntity.IsEmpty then Exit;

  if AEntity[1] = '#' then
  begin
    if (Length(AEntity) > 2) and (UpCase(AEntity[2]) = 'X') then
    begin
      // Hex form: &#xC4;  &#x1D11E;
      HexStr := '$' + Copy(AEntity, 3, MaxInt);
      if not TryStrToInt(HexStr, IntVal) then Exit;
    end
    else
    begin
      // Decimal form: &#196;  &#8212;
      if not TryStrToInt(Copy(AEntity, 2, MaxInt), IntVal) then Exit;
    end;

    CodePoint := cardinal(IntVal);

    // Reject surrogates (U+D800-U+DFFF) and above U+10FFFF
    if (CodePoint > $10FFFF) or ((CodePoint >= $D800) and
      (CodePoint <= $DFFF)) then Exit;

    Result := UnicodeToUTF8(CodePoint);
  end
  else
    // Named entity: O(n) scan of const array
    Result := FindHTMLEntity(AEntity);
end;

function DecodeHTMLEntities(const s: String): String;
  // Decodes all HTML entities in S (named, decimal, and hex numeric forms).
  // Unknown entities such as &foo; are preserved verbatim.
var
  i: Integer = 1;
  EntityStart: Integer = 0;
  SemiPos: Integer = 0;
  Decoded: String = '';
begin
  if s.IsEmpty or (Pos('&', s) = 0) then Exit(s);
  Result := '';
  while i <= Length(s) do
  begin
    if s[i] <> '&' then
    begin
      Result := Result + s[i];
      Inc(i);
      Continue;
    end;

    // Ampersand found – scan ahead for closing semicolon.
    // Cap the scan at 12 chars to handle the longest named entity
    // ('thetasym' = 8 chars) while guarding against bare '&' in filenames.
    EntityStart := i;
    SemiPos := 0;
    i := EntityStart + 1;

    while (i <= Length(s)) and (i <= EntityStart + 12) and (s[i] <> ';') do
      Inc(i);

    if (i <= Length(s)) and (s[i] = ';') then SemiPos := i;

    if SemiPos > 0 then
    begin
      Decoded := DecodeHTMLEntity(
        Copy(s, EntityStart + 1, SemiPos - EntityStart - 1));

      if Decoded.IsNotEmpty then
      begin
        Result := Result + Decoded;
        i := SemiPos + 1;
        Continue;
      end;
    end;

    // No valid entity: emit literal '&' and resume after it
    Result := Result + '&';
    i := EntityStart + 1;
  end;
end;

function DeleteIfExists(const AFileName: String): Boolean;
begin
  Result := False;
  if FileExists(AFileName) then Result := DeleteFile(AFileName);
end;

function ExtractAfterStr(const sFind, s: String): String;
var
  k, StartPos: Integer;
  tmp: String;
begin
  Result := '';
  if (sFind = '') or (s = '') then Exit;
  k := UTF8Pos(sFind, s);
  if k = 0 then Exit;
  tmp := UTF8Copy(s, k + UTF8Length(sFind), MaxInt);
  StartPos := 1;
  Result := ExtractSubStr(tmp, StartPos, [#10, #13]);
end;

type

  // The in-memory buffer TZipStreamRelay hands TUnZipper for each entry.
  // Besides holding the decompressed bytes, it reports through FOnProgress
  // how far through the entry's own uncompressed size (from the zip's
  // central directory) decompression has got. Measured here rather than via
  // TUnZipper.OnProgress so the percentage means the same thing for stored
  // and deflated entries alike, whatever a given FPC release's unzipper
  // reports on its own. With no FOnProgress it is just a TMemoryStream that
  // allocates its full size up front.
  TProgressMemoryStream = class(TMemoryStream)
  private
    FExpectedSize: int64;
    FLastPct: Integer;
    FOnProgress: Zipper.TProgressEvent;
    FSender: TObject;
  public
    constructor Create(AExpectedSize: int64;
      AOnProgress: Zipper.TProgressEvent; ASender: TObject);
    function Write(const Buffer; Count: LongInt): LongInt; override;
  end;

  // TZipStreamRelay exists for exactly one reason: TUnZipper.OnCreateStream
  // / OnDoneStream are "of object" events, so they must be bound to a class
  // instance - they can't be the bare forward-declared procedures the rest
  // of this unit uses. This is an ordinary class with an ordinary
  // constructor/destructor (not an Initialize/Finalize RAII record), so it
  // doesn't run afoul of this unit's "no RAII types" rule; it's kept out of
  // the interface section entirely so it never becomes part of this unit's
  // public surface. One instance handles exactly one UnZipFiles call
  // (constructed, attached, used, freed by the ExtractFileFromZip overload
  // that owns it) and is not meant to be reused across calls.
  TZipStreamRelay = class
  private
    FCallback: TZipExtractCallback; // when assigned, takes priority over
    FDiskFileName: String; // used when FCallback is unassigned
    // FDiskFileName
    FOnProgress: Zipper.TProgressEvent; // optional; disk mode only
    procedure DoCreateStream(Sender: TObject; var AStream: TStream;
      AItem: TFullZipFileEntry);
    procedure DoDoneStream(Sender: TObject; var AStream: TStream;
      AItem: TFullZipFileEntry);

  public
    constructor CreateForDisk(const ADiskFileName: String;
      AOnProgress: Zipper.TProgressEvent = nil);
    constructor CreateForCallback(ACallback: TZipExtractCallback);
    procedure Attach(AUnZipper: TUnZipper);
  end;

constructor TZipStreamRelay.CreateForDisk(const ADiskFileName: String;
  AOnProgress: Zipper.TProgressEvent);
begin
  inherited Create;
  FDiskFileName := ADiskFileName;
  FCallback := nil;
  FOnProgress := AOnProgress;
end;

constructor TZipStreamRelay.CreateForCallback(ACallback: TZipExtractCallback);
begin
  inherited Create;
  FCallback := ACallback;
end;

procedure TZipStreamRelay.Attach(AUnZipper: TUnZipper);
begin
  AUnZipper.OnCreateStream := @DoCreateStream;
  AUnZipper.OnDoneStream := @DoDoneStream;
end;

// Always hands TUnZipper an in-memory buffer for the entry currently being
// decompressed. DoDoneStream is the matching teardown, and the only place
// this stream is ever freed - TUnZipper does not own or free it itself.
procedure TZipStreamRelay.DoCreateStream(Sender: TObject;
  var AStream: TStream; AItem: TFullZipFileEntry);
begin
  AStream := TProgressMemoryStream.Create(AItem.Size, FOnProgress, Sender);
end;

constructor TProgressMemoryStream.Create(AExpectedSize: int64;
  AOnProgress: Zipper.TProgressEvent; ASender: TObject);
begin
  inherited Create;
  FExpectedSize := AExpectedSize;
  FOnProgress := AOnProgress;
  FSender := ASender;
  FLastPct := -1;
  // One allocation up front instead of repeated grow-and-copy while a
  // multi-megabyte entry (ffprobe.exe, mkvmerge.exe) streams in.
  if (AExpectedSize > 0) and (AExpectedSize <= High(PtrInt)) then
    Capacity := PtrInt(AExpectedSize);
end;

function TProgressMemoryStream.Write(const Buffer; Count: LongInt): LongInt;
var Pct: Integer;
begin
  Result := inherited Write(Buffer, Count);
  if (not Assigned(FOnProgress)) or (FExpectedSize <= 0) then Exit;
  Pct := integer(Min(int64(100), (Position * 100) div FExpectedSize));
  if Pct = FLastPct then Exit;
  FLastPct := Pct;
  FOnProgress(FSender, Pct);
end;

procedure TZipStreamRelay.DoDoneStream(Sender: TObject;
  var AStream: TStream; AItem: TFullZipFileEntry);
begin
  try
    AStream.Position := 0;
    if Assigned(FCallback) then FCallback(AStream, AItem.ArchiveFileName)
    else
      with TFileStream.Create(FDiskFileName, fmCreate) do try
        CopyFrom(AStream, AStream.Size);
      finally
        Free;
      end;
    DebugLog('Unzipped OK: ' + AItem.ArchiveFileName);
  finally
    // AStream was created in DoCreateStream (TMemoryStream.Create) above;
    // TUnZipper does not own or free it, so we must free it here.
    AStream.Free;
  end;
end;

function efn(const fn: String): String;
begin
  Result := ExtractFileName(fn);
end;

function efnOnly(const fn: String): String;
begin
  Result := ExtractFileNameOnly(fn);
end;

function ExtractFileFromZip(const AZipFileName, AArchiveFileName,
  ADiskFileName: String; AOnProgress: Zipper.TProgressEvent): Boolean;
var
  Relay: TZipStreamRelay;
  SL: TSmartStrings;
  uz: TSmartUnZipper;
begin
  Relay := TZipStreamRelay.CreateForDisk(ADiskFileName, AOnProgress);
  try
    uz.Value.FileName := AZipFileName;
    Relay.Attach(uz.Value);
    SL.Value.Add(AArchiveFileName);
    uz.Value.UnZipFiles(SL.Value);
    Result := FileExists(ADiskFileName);
  finally
    Relay.Free;
  end;
end;

function ExtractFileFromZip(const AZipFileName, AArchiveFileName: String;
  ACallback: TZipExtractCallback): Boolean;
var
  Relay: TZipStreamRelay;
  SL: TSmartStrings;
  uz: TSmartUnZipper;
begin
  Result := False;
  if not Assigned(ACallback) then Exit;
  Relay := TZipStreamRelay.CreateForCallback(ACallback);
  try
    uz.Value.FileName := AZipFileName;
    Relay.Attach(uz.Value);
    SL.Value.Add(AArchiveFileName);
    uz.Value.UnZipFiles(SL.Value);
    Result := True;
  finally
    Relay.Free;
  end;
end;

function ExtractFromZipIfNotFound(
  const AZipFileName, AArchiveFileName, ADiskFileName: String;
  AOnProgress: Zipper.TProgressEvent): Boolean;
begin
  if FileExists(ADiskFileName) then Exit(True);
  try
    Result := ExtractFileFromZip(AZipFileName, AArchiveFileName,
      ADiskFileName, AOnProgress);
    if not Result then LogError(
        sb(['ExtractFromZipIfNotFound: ExtractFileFromZip returned ',
        'False for "', AArchiveFileName, '" from "',
        AZipFileName, '" to "', ADiskFileName, '"']));
  except
    on E: Exception do
    begin
      LogError(sb(['ExtractFromZipIfNotFound: failed to extract "',
        AArchiveFileName, '" from "', AZipFileName, '" to "',
        ADiskFileName, '"']), E);
      Result := False;
    end;
  end;
end;

function EnsureOpenSSLDllsPresent: Boolean;
var
  SourceZipFileName, DiskLibeay, DiskSsleay: String;
  ResStream: TSmartResourceStream;
  FileStream: TSmartFileStream;
begin
  {$IFNDEF WINDOWS}
  // Not needed/shipped on non-Windows platforms.
  Exit(True);
  {$ELSE}
  DiskLibeay := CombinePath(OpPath, LIBEAY_NAME);
  DiskSsleay := CombinePath(OpPath, SSLEAY_NAME);
  Result := FileExists(DiskLibeay) and FileExists(DiskSsleay);
  if Result then Exit;
  DebugLog('EnsureOpenSSLDllsPresent: one or both of "' +
    DiskLibeay + '"/"' + DiskSsleay + '" missing, attempting extraction');
  try
    // Make sure the embedded source archive itself is on disk in OpPath
    // before trying to pull individual files out of it - mirrors
    // TForm1.ExtractZipResourceIfNotFound (RT_RCDATA resource -> disk),
    // duplicated here (rather than called) because that method lives on
    // TForm1, which this unit must not depend on.
    SourceZipFileName := lowercase(sb([Application.Title, '-src.zip']));
    // Direct FileExists against OpPath, not FileSearch: FileSearch's
    // sfoImplicitCurrentDir flag always checks the process's current
    // working directory first, regardless of the DirList passed in, so it
    // can report a false-positive match from CWD (e.g. a dev/build
    // directory that happens to contain this filename) without OpPath
    // ever actually having the file. See the matching fix (and its full
    // explanation) in TForm1.ExtractZipResourceIfNotFound in uMain.pas,
    // which this duplicates.
    if not FileExists(CombinePath(OpPath, SourceZipFileName)) then
    begin
      // The embedded RT_RCDATA resource is registered under
      // UpperCase(filename) - that's what filey.lpi's <Resources> block
      // ("FILEY-SRC.ZIP") compiles into filey.res, which {$R *.res} in
      // filey.lpr links in - not the lowercase on-disk filename. See the
      // matching fix (and its full explanation) in
      // TForm1.ExtractZipResourceIfNotFound in uMain.pas, which this
      // duplicates.
      ResStream.Setup(HInstance, UpperCase(SourceZipFileName),
        Windows.RT_RCDATA);
      FileStream.Setup(CombinePath(OpPath, SourceZipFileName), fmCreate);
      FileStream.Value.CopyFrom(ResStream.Value, ResStream.Value.Size);
    end;
    if not FileExists(DiskLibeay) then
      ExtractFromZipIfNotFound(CombinePath(OpPath, SourceZipFileName),
        LIBEAY_NAME, DiskLibeay);
    if not FileExists(DiskSsleay) then
      ExtractFromZipIfNotFound(CombinePath(OpPath, SourceZipFileName),
        SSLEAY_NAME, DiskSsleay);
  except
    on E: Exception do LogError(
        'EnsureOpenSSLDllsPresent: extraction attempt failed', E);
  end;
  // Re-check regardless of whether the try block above raised - a partial
  // extraction (e.g. libeay32.dll succeeded, ssleay32.dll didn't) should
  // still be reflected accurately.
  Result := FileExists(DiskLibeay) and FileExists(DiskSsleay);
  if not Result then LogError(
      'EnsureOpenSSLDllsPresent: still missing after extraction ' +
      'attempt - libeay32.dll exists=' + IfThen(FileExists(DiskLibeay)) +
      ', ssleay32.dll exists=' + IfThen(FileExists(DiskSsleay)));
  {$ENDIF}
end;

function FastRemovePunctuation(const s: String): String;
const
  AlphaNumeric: set of char = ['A'..'Z', 'a'..'z', '0'..'9'];
var
  i, ULen: Integer;
  CP: cardinal;
begin
  // Walks codepoints (like ASCIIFold does), not bytes: a byte-only version
  // of this filter would test each byte of a multi-byte character against
  // an ASCII-only set and silently drop every one of them, destroying any
  // accented or non-Latin letter instead of keeping it.
  Result := '';
  if s = '' then Exit;
  i := 1;
  while i <= Length(s) do
  begin
    ULen := UTF8CodepointSize(@s[i]);
    if ULen = 1 then
    begin
      if s[i] in AlphaNumeric then Result := Result + s[i];
    end
    else
    begin
      CP := UTF8CodepointToUnicode(@s[i], ULen);
      // TCharacter classifies the Basic Multilingual Plane (WideChar);
      // codepoints above it (rare - e.g. emoji) are dropped, same as
      // punctuation always was.
      if (CP <= $FFFF) and TCharacter.IsLetterOrDigit(widechar(CP)) then
        Result := Result + Copy(s, i, ULen);
    end;
    Inc(i, ULen);
  end;
end;

function ExpandPathName(const Dir: String): String;
begin
  Result := AppendPathDelim(SafeExpandFilename(Dir));
end;

function FileExists(const Path: String): Boolean;
var
  Info: TUnicodeSearchRec;
begin
  Result := False;
  Info := Default(TUnicodeSearchRec);
  FillChar(Info, SizeOf(Info), 0);
  if (SysUtils.FindFirst(UnicodeString(Path), faAnyFile, Info) = 0) and
    ((Info.Attr and faDirectory) <> faDirectory) then Result := True;
  SysUtils.FindClose(Info);
end;

function FileExistsStr(const aCaseSensitiveFileName: String): Boolean;
var
  sFixed, sPath: String;
  SearchRec: TSearchRec;
  FindResult: LongInt;
begin
  Result := False;
  sFixed := SafeExpandFilename(aCaseSensitiveFileName);
  sPath := ExtractFilePath(sFixed);
  FindResult := FindFirst(sFixed, faAnyFile, SearchRec);
  try
    while FindResult = 0 do
    begin
      if CompareStr(sFixed, CombinePath(sPath, SearchRec.Name)) = 0 then
        Exit(True);
      FindResult := FindNext(SearchRec);
    end;
  finally
    FindClose(SearchRec);
  end;
end;

function FindAllFilesThrottled(const APath: String; const AMask: String;
  ASearchSubDirs: Boolean): TStringList;
var
  Searcher: TSmartFileSearcher;
begin
  Result := Searcher.FindAllThrottled(APath, AMask, ASearchSubDirs);
end;

function FindBestFont(const PriorityList: array of String): String;
var
  FntName: String;
begin
  Result := 'Monospace';
  for FntName in PriorityList do
  begin
    if Screen.Fonts.IndexOf(FntName) >= 0 then
    begin
      Result := FntName;
      Break;
    end;
  end;
end;

procedure FindFilesWithMaskList(AList: TStrings; const APath: String;
  AMaskList: TMaskList);
var
  SR: TSearchRec;
  sDir: String;
begin
  sDir := AppendPathDelim(APath);
  if SysUtils.FindFirst(CombinePath(sDir, '*'), faAnyFile, SR) = 0 then try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      if (SR.Attr and faDirectory) <> 0 then
        FindFilesWithMaskList(AList, CombinePath(sDir, SR.Name), AMaskList)
      else
      if AMaskList.Matches(SR.Name) then AList.Add(CombinePath(sDir, SR.Name));
    until SysUtils.FindNext(SR) <> 0;
  finally
    SysUtils.FindClose(SR);
  end;
end;

function FindHTMLEntity(const AName: String): String;
var
  i: Integer = 0;
begin
  Result := '';
  for i := Low(HTML_ENTITIES) to High(HTML_ENTITIES) do
    if HTML_ENTITIES[i].Name = AName then
    begin
      Result := HTML_ENTITIES[i].Value;
      Exit;
    end;
end;

function FixWinFileName(const s: String): String;
const
  // Only real directory separators split off a path here. This used to be
  // Trim(ExtractFileName(s)), but in a Windows build ExtractFileName also
  // splits at ':' (AllowDriveSeparators), so a name built from a title
  // such as "Star Trek: Strange New Worlds.S04E01..." lost everything up to
  // and including the colon - Windows and Wine only, never Linux. Both
  // separators are ASCII, so the byte-wise LastDelimiter is UTF-8 safe.
  {$IFDEF WINDOWS}
  cPathDelims = '\/';
  {$ELSE}
  cPathDelims = '/';
  {$ENDIF}
var
  i: Integer;
begin
  Result := '';
  if s = '' then Exit('unnamed_file');
  try
    // Step 1 & 2: Isolate the name (path stripped, ':' kept for step 4)
    Result := Trim(Copy(s, LastDelimiter(cPathDelims, s) + 1, MaxInt));
    if Result = '' then Exit('unnamed_file');
    // Step 4: Single-pass character replacement
    // This is very fast because it modifies the string "in place"
    UniqueString(Result);
    // Ensures we aren't modifying a shared string reference
    for i := 1 to Length(Result) do if Result[i] in cInvalidFileNameChars then
        Result[i] := '_';
    // Step 5 & 6: Clean up underscores
    // Using TrimSet to remove leading/trailing underscores
    Result := TrimSet(Result, [' ', '_']);
    // Handle consecutive underscores efficiently
    // This is the only place where StringReplace is needed
    while Pos('__', Result) > 0 do Result := ReplAllCI(Result, '__', '_');
    // Step 7: Windows reserved device names (CON, NUL, COM1...), which
    // stay reserved whatever follows the FIRST dot: "Con.S01E01.mkv" is as
    // unusable as "CON". The list used to live here too, checked against
    // ChangeFileExt (which strips only the LAST extension), so names like
    // that got through. IsReservedFileName is the one list now, and is
    // already False on Linux, so no IFDEF is needed here.
    if IsReservedFileName(Result) then Result := 'safe_' + Result;
    // Step 8: FS Limit (250 characters, not bytes - LeftStr/Length here
    // would cut by byte count and could split a multi-byte character in
    // half, leaving malformed UTF-8 at the end of the saved filename)
    if UTF8Length(Result) > 250 then Result := UTF8Copy(Result, 1, 250);
    if Result = '' then Result := 'unnamed_file';
  except
    on E: Exception do
    begin
      LogError('Error in FixWinFileName', E);
      Result := 'error_file';
    end;
  end;
end;

procedure FreeAndNilIfAssigned(var Obj);
begin
  if Assigned(Pointer(Obj)) then FreeAndNil(TObject(Obj));
end;

function GetDeepestDir(const AFileName: String): String;
begin
  Result := ExtractFileName(ExtractFileDir(AFileName));
end;

function GetSubDirs(const APath: String): TStringList;
var
  SR: TSearchRec;
  SearchPath, FullPath: String;
  List, SubDirs: TSmartStrings;
begin
  SearchPath := CombinePath(APath, '*');
  if FindFirst(SearchPath, faDirectory, SR) <> 0 then
  begin
    // List.Value creates the (empty) list on first access. Without it,
    // TakeValue handed back nil for a folder that couldn't be searched,
    // where every other path returns a list the caller owns and frees.
    List.Value.Clear;
    Exit(List.TakeValue);
  end;
  try
    repeat
      if (SR.Attr and faDirectory <> 0) and (SR.Name <> '.') and
        (SR.Name <> '..') then
      begin
        FullPath := CombinePath(APath, SR.Name);
        List.Value.Add(FullPath);
        SubDirs.SetValue(GetSubDirs(FullPath));
        List.Value.AddStrings(SubDirs.Value);
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  Result := List.TakeValue;
end;

function GetToolVer(const AExecutable: String;
  const AVersionArg: String = '--version'): String;
var
  sOut: String;
  iExitCode: Integer;
  SL: TSmartStrings; // Managed record - no .Free required!
begin
  Result := ' [No Version Found]';
  sOut := RunEx(AExecutable, [AVersionArg], iExitCode);
  if iExitCode <> -1 then // -1 means RunEx couldn't even start the process
  begin
    SL.Value.Text := Trim(sOut);
    if SL.Value.Count > 0 then Result := SL.Value[0];
  end;
end;

function GetWineVersion: UnicodeString;
  {$IFDEF WINDOWS}
  // NOTE: Do not change AnsiString/PAnsiChar to UnicodeString/PWideChar in this
  // function. wine_get_version/wine_get_build_id are C functions (char* return),
  // not Windows API calls -- there is no wide-char variant. AnsiString is the
  // correct narrow-string receiver; the UnicodeString(...) cast at the end is
  // where codepage-aware conversion into Filey's normal string type happens.
type
  TWineGetVersion = function: pansichar; cdecl;
  TWineGetBuildId = function: pansichar; cdecl;
var
  NtDllHandle: HMODULE;
  WineGetVersion: TWineGetVersion;
  WineGetBuildId: TWineGetBuildId;
  VersionStr, BuildStr: ansistring;
  {$ENDIF}
begin
  Result := '';
  {$IFDEF WINDOWS}
  NtDllHandle := GetModuleHandleW('ntdll.dll');
  if NtDllHandle = 0 then Exit;
  Pointer(WineGetVersion) := GetProcAddress(NtDllHandle, 'wine_get_version');
  if not Assigned(WineGetVersion) then Exit;
  VersionStr := WineGetVersion();
  BuildStr := '';
  Pointer(WineGetBuildId) := GetProcAddress(NtDllHandle, 'wine_get_build_id');
  if Assigned(WineGetBuildId) then BuildStr := WineGetBuildId();
  Result := UnicodeString(IfThen(BuildStr <> '', BuildStr, VersionStr));
  {$ENDIF}
end;

function HasInternetConnection: Boolean;
begin
  Result := TSmartHTTP.Available;
end;

function HasValidFileNameChars(const s: String;
  AllowPathSeparators: Boolean): Boolean;
var
  c: char;
begin
  Result := False;
  if s = '' then Exit;
  for c in s do
  begin
    if AllowPathSeparators and (c in ['/', '\']) then Continue;
    if c in cInvalidFileNameChars then Exit;
  end;
  Result := True;
end;

function IfExists(const s: String): String; overload;
begin
  Result := IfThen(FileExists(s));
end;

function IfExists(const s: String; const v1, v2: variant): String; overload;
begin
  Result := IfThen(FileExists(s), VarToStr(v1), VarToStr(v2));
end;

function IfThen(const AValue: Boolean): String;
begin
  if AValue then Result := 'True'
  else Result := 'False';
end;

procedure IncreaseAllFonts(AForm: TCustomForm; AStatusBar: TStatusBar;
  AToolBar: TToolBar; const AAmount: Integer);
var
  k: Integer = 0;
  v: Integer = 0;
begin
  v := Max(AForm.Canvas.Font.Size + AAmount, 8);
  for k := 0 to AForm.ComponentCount - 1 do
  begin
    if AForm.Components[k] is TControl then
      TControl(AForm.Components[k]).Font.Size := v;
    if (AForm.Components[k] is TDBGrid) and
      TDBGrid(AForm.Components[k]).Showing then
      TDBGrid(AForm.Components[k]).AutoAdjustColumns;
  end;
  AStatusBar.Canvas.Font.Size := v - 1;
  AForm.Canvas.Font.Size := v;
  AForm.Width := ToolBarWidthSize(AToolBar);
end;

function IsDirectoryEmpty(const directory: String): Boolean;
var
  SearchPath: String;
  SearchRec: TSearchRec;
  FindResult: LongInt;
begin
  if not DirectoryExists(directory) then
    raise Exception.CreateFmt(
      'IsDirectoryEmpty: directory does not exist: "%s"', [directory]);
  SearchPath := CombinePath(directory, AllFilesMask);
  SearchRec := Default(TSearchRec);
  FindResult := SysUtils.FindFirst(SearchPath, faAnyFile, SearchRec);
  try
    if FindResult <> 0 then
      raise Exception.CreateFmt(
        'IsDirectoryEmpty: could not read directory (error %d): "%s"',
        [FindResult, directory]);
    Result := True;
    repeat
      if (SearchRec.Name <> '.') and (SearchRec.Name <> '..') then Exit(False);
    until SysUtils.FindNext(SearchRec) <> 0;
  finally
    SysUtils.FindClose(SearchRec);
  end;
end;

function IsEmptyRecord(const Fields: TStringList): Boolean;
var
  s: String;
begin
  Result := True;
  for s in Fields do if s.IsNotBlank then Exit(False);
end;

function IsGridEmpty(const AGrid: TDBGrid): Boolean;
begin
  Result := (AGrid = nil) or (AGrid.Columns.Count = 0);
end;

type
  // TLazLoggerFile.FileHandle is protected; a descendant declared here may
  // set it.
  TLazLoggerFileAccess = class(TLazLoggerFile);

procedure InitializeDebugLog(const FileName: String = 'debug.log');
begin
  {$IFDEF DEBUG}
    DeleteIfExists(CombinePath(OpPath, FileName));
    // First, since CloseLogFileBetweenWrites below is a setting of the
    // file handle: one that writes straight to the file from any thread,
    // under its own lock. LazLogger's default handle instead queues a
    // worker thread's lines for the main thread to write (TThread.Queue)
    // and drops whatever is still queued when the program ends - so lines
    // logged by RunParallel jobs and RunEx threads could go missing.
    TLazLoggerFileAccess(DebugLogger).FileHandle :=
      TLazLoggerFileHandleThreadSave.Create;
    // Hand this off to LazLogger's own logger instance rather than managing
    // a file handle ourselves - DebugLogger (from the LazLogger unit, already
    // in this unit's uses clause) owns the file, reopening/closing it as
    // needed and serializing access across threads.
    DebugLogger.LogName := CombinePath(OpPath, FileName);
    // Without this, LazLogger keeps the file handle open across writes and
    // only truly commits them to disk when the file eventually gets
    // closed (app shutdown, or LazLogger's own internal reasons to reopen
    // it). Reading debug.log while the app is still running - or after a
    // hard crash that never got to close it - previously could show the
    // file trailing off mid-line, with everything after the last flush
    // simply not there yet. Forcing a close (and reopen) after every
    // single write costs an extra file-open syscall per DebugLog call,
    // which is immaterial at this log's actual volume, in exchange for
    // every line being durably on disk the instant it's written.
    DebugLogger.CloseLogFileBetweenWrites := True;
  {$ELSE}
  // Release still has to give LazLogger somewhere to write. With LogName
  // empty it falls back to the std handles, and a -WG build has none, so it
  // allocates the console that ends up sitting behind the form.
  DebugLogger.LogName := {$IFDEF WINDOWS}'NUL'{$ELSE}'/dev/null'{$ENDIF};
  {$ENDIF}
end;

procedure InitializeErrorLog(const FileName: String = 'error.log');
begin
  // Deliberately not deleted on startup, unlike debug.log - errors should
  // accumulate across runs so a rare failure isn't lost the next time the
  // app happens to launch cleanly.
  ErrorLogger := TLazLoggerFile.Create;
  // Written straight from any thread - see InitializeDebugLog.
  TLazLoggerFileAccess(ErrorLogger).FileHandle :=
    TLazLoggerFileHandleThreadSave.Create;
  ErrorLogger.LogName := CombinePath(OpPath, FileName);
  // Same reasoning as DebugLogger above, and it matters even more here:
  // error.log is the one place a crash's last words are expected to
  // survive the crash itself, in both Debug and Release builds.
  ErrorLogger.CloseLogFileBetweenWrites := True;
end;

function IsNativeWin32Control(const ACtrl: TWinControl): Boolean;
begin
  {$IFDEF WINDOWS}
  Result := (ACtrl is TCustomButton) or (ACtrl is TToolBar) or
    (ACtrl is TCustomEdit) or (ACtrl is TCustomComboBox) or
    (ACtrl is TCustomListBox) or (ACtrl is TCustomCheckBox) or
    (ACtrl is TCustomTabControl) or (ACtrl is TCustomProgressBar) or
    (ACtrl is TStatusBar);
  {$ELSE}
Result := False;
  {$ENDIF}
end;

function IsReservedFileName(const AFileName: String): Boolean;
var
  UName: String;
  DotPos: Integer;
begin
  Result := False;
  {$IFDEF WINDOWS}
  { 1. Prepare the name: Trim and Uppercase} UName :=
    UTF8UpperCase(ChangeFileExt(Trim(AFileName), ''));
  { 2. Windows quirk: CON.txt or CON.long.extension are all reserved.}
  { We find the FIRST dot and treat everything before it as the filename.}
  DotPos :=
    Pos('.', UName);
  if DotPos > 0 then UName := Copy(UName, 1, DotPos - 1);
  { 3. Check 3-character reserved names}
  { Order: NUL first (most common), then CON, AUX, PRN}
  if (Length(UName) = 3) then
  begin
    if IndexStr(UName, ['NUL', 'CON', 'AUX', 'PRN']) > -1 then Exit(True);
  end;
  { 4. Check numbered devices: COM1-9 and LPT1-9}
  { These are 4 characters long (e.g., 'COM1')} if (Length(UName) = 4) then
  begin
    if (Copy(UName, 1, 3) = 'COM') or (Copy(UName, 1, 3) = 'LPT') then
      if UName[4] in ['1'..'9'] then Exit(True);
  end;
  {$ENDIF}
  {$IFNDEF WINDOWS}
  // Unix systems generally only reserve the full path to the null device.
  // Filenames like "CON" or "NUL" are perfectly legal in Linux/macOS.
    if AFileName = '/dev/null' then Exit(True);
  {$ENDIF}
end;

function IsStringAllUpper(const s: String): Boolean;
var
  i, ULen: Integer;
  CP: cardinal;
begin
  // Classifies decoded codepoints, not raw bytes: TCharacter.IsLetter/
  // IsUpper on a lone byte of a multi-byte UTF-8 character tests that
  // byte's ordinal value in isolation, not the actual letter it's part
  // of, and gives an unreliable answer for any accented input.
  if s.IsEmpty then Exit(False);
  Result := True;
  i := 1;
  while i <= Length(s) do
  begin
    ULen := UTF8CodepointSize(@s[i]);
    CP := UTF8CodepointToUnicode(@s[i], ULen);
    if (CP <= $FFFF) and TCharacter.IsLetter(widechar(CP)) and
      not TCharacter.IsUpper(widechar(CP)) then Exit(False);
    Inc(i, ULen);
  end;
end;

procedure LoadEnvironment(AList: TStringList);
var
  i: Integer;
begin
  AList.BeginUpdate;
  try
    AList.Clear;
    for i := 1 to GetEnvironmentVariableCount do
      AList.Add(GetEnvironmentString(i - 1));
  finally
    AList.EndUpdate;
  end;
end;

procedure LogError(const AMessage: String; AException: Exception = nil);
var
  LogMessage: String;
begin
  LogMessage := ' ERROR: ' + AMessage;
  if Assigned(AException) then
    LogMessage := LogMessage + ' Exception: ' + AException.Message;
  // error.log gets its own timestamp here since, unlike debug.log (written
  // via DebugLog below), ErrorLogger.DebugLn doesn't add one on its own -
  // and error.log is written in both Debug and Release builds, so it can't
  // rely on DebugLog's DEBUG-only formatting to supply it.
  // LogLock: see DebugLog. Critical sections are recursive, so DebugLog
  // taking it again inside is fine.
  System.EnterCriticalSection(LogLock);
  try
    ErrorLogger.DebugLn(Format('[%s]',
      [FormatDateTime('YYYY-MM-DD hh:nn:ss', Now)]) + LogMessage);
    DebugLog(LogMessage); // debug.log too (Debug builds only); timestamps itself
  finally
    System.LeaveCriticalSection(LogLock);
  end;
end;

function MessageDlgEx(const AMsg: String; ADlgType: TMsgDlgType;
  AButtons: TMsgDlgButtons; AParent: TForm = nil): TModalResult;
var
  MsgFrm: TSmartForm;
  WA: TRect;
begin
  if AParent = nil then AParent := Application.MainForm;
  MsgFrm.SetValue(CreateMessageDialog(AMsg, ADlgType, AButtons));
  MsgFrm.Value.Position := poDefaultSizeOnly;
  MsgFrm.Value.FormStyle := fsSystemStayOnTop;
  // Application.MainForm is nil during startup (anything TForm1.Create or
  // FormCreate runs happens before it exists),
  // during shutdown, and from any non-main-form context. Centring on it
  // there was a straight access violation. Fall back to the work area.
  if Assigned(AParent) then
  begin
    MsgFrm.Value.Left :=
      AParent.Left + (AParent.Width - MsgFrm.Value.Width) div 2;
    MsgFrm.Value.Top :=
      AParent.Top + (AParent.Height - MsgFrm.Value.Height) div 2;
  end
  else
  begin
    WA := Screen.WorkAreaRect;
    MsgFrm.Value.Left :=
      WA.Left + ((WA.Right - WA.Left) - MsgFrm.Value.Width) div 2;
    MsgFrm.Value.Top :=
      WA.Top + ((WA.Bottom - WA.Top) - MsgFrm.Value.Height) div 2;
  end;
  Result := MsgFrm.Value.ShowModal;
end;

procedure NoOp; /// eliminate JCF warnings about missing Else in case stmt
begin
  //asm NOP end; //No Assembly Language needed here, just: begin end
end;

function ns(const AValue: Integer): String; inline;
begin
  Result := IntToStr(AValue);
end;

function ns(const AValue: int64): String; inline;
begin
  Result := IntToStr(AValue);
end;

function ns(const AValue: double; const ADecimals: Integer = 2): String;
  inline;
begin
  Result := FormatFloat('0.' + StringOfChar('0', ADecimals), AValue);
end;

function PosInsensitive(const SubStr, s: String): Integer;
begin //a bit slower, but Unicode foreign language support
  if SubStr.IsEmpty then Exit(0);
  Result := UTF8Pos(UTF8LowerCase(SubStr), UTF8LowerCase(s));
end;

function PosInsensitiveASCII(const SubStr, s: String): Integer;
var
  FoundPtr: PChar;
begin //speedy, but only US ASCII chars, not Unicode
  if SubStr.IsEmpty then Exit(0);
  FoundPtr := SearchBuf(PChar(s), Length(s), 0, 0, SubStr, [soDown]);
  if FoundPtr <> nil then Result := FoundPtr - PChar(s) + 1
  else
    Result := 0;
end;

function ProcessCP1252CSV(CSVLines: TStrings;
  const AFileName: String): TStrings;
var
  SmartStream: TSmartMemoryStream;
  FileStream: TMemoryStream;
  Line: rawbytestring;
  CurrentPos, StartPos: int64;
  p: pbyte;
begin
  Result := Default(TStrings);
  Line := Default(rawbytestring);
  if not FileExists(AFileName) then Exit;
  CSVLines.Clear; // never accumulate onto a caller's existing lines
  FileStream := SmartStream.Value;
  FileStream.LoadFromFile(AFileName);
  p := FileStream.Memory;
  CurrentPos := 0;
  StartPos := 0;
  while CurrentPos < FileStream.Size do
  begin
    // Check for Line Feed (#10) or Carriage Return (#13)
    if (p[CurrentPos] = 10) or (p[CurrentPos] = 13) then
    begin
      if CurrentPos > StartPos then
      begin
        // Extract the segment
        SetLength(Line, CurrentPos - StartPos);
        Move(p[StartPos], Line[1], CurrentPos - StartPos);
        // Force the compiler to treat this as CP1252
        SetCodePage(Line, 1252, False);
        // Logic for processing the CSV line goes here}{WriteLn('Processed Line: ', Line);}
        CSVLines.Add(CP1252ToUTF8(Line));
      end;
      // Skip the CR/LF characters
      if (CurrentPos + 1 < FileStream.Size) and
        (p[CurrentPos] = 13) and (p[CurrentPos + 1] = 10) then Inc(CurrentPos);
      // Skip the second half of CRLF
      Inc(CurrentPos);
      StartPos := CurrentPos;
    end
    else
      Inc(CurrentPos);
  end;
  // Handle the last line if it doesn't end with a newline
  if StartPos < FileStream.Size then
  begin
    SetLength(Line, FileStream.Size - StartPos);
    Move(p[StartPos], Line[1], FileStream.Size - StartPos);
    SetCodePage(Line, 1252, False);
    //DebugLog('Last Line: ', Line);
    CSVLines.Add(CP1252ToUTF8(Line));
  end;
  Result := CSVLines;
end;

function RemoveAllSpacesAndDots(const s: String): String;
begin
  Result := ReplAllCI(ReplAllCI(s, '.', ''), ' ', '');
end;

function RemoveDiacritics(const s: String): String;
var
  F: Boolean = False;
  i: SizeInt = 0;
  PS: PChar = nil;
  PD: PChar = nil;
begin
  Result := '';
  SetLength(Result, Length(s));
  PS := PChar(s);
  PD := PChar(Result);
  i := 0;
  while PS^ <> #0 do
  begin
    F := PS^ = #195;
    if F then case PS[1] of
        #128..#134: PD^ := 'A';
        #135: PD^ := 'C';
        #136..#139: PD^ := 'E';
        #140..#143: PD^ := 'I';
        #144: PD^ := 'D';
        #145: PD^ := 'N';
        #146..#150,
        #152: PD^ := 'O';
        #151: PD^ := 'x';
        #153..#156: PD^ := 'U';
        #157: PD^ := 'Y';
        #158: PD^ := 'P';
        #159: PD^ := 's';
        #160..#166: PD^ := 'a';
        #167: PD^ := 'c';
        #168..#171: PD^ := 'e';
        #172..#175: PD^ := 'i';
        #176: PD^ := 'd';
        #177: PD^ := 'n';
        #178..#182,
        #184: PD^ := 'o';
        #183: PD^ := '-';
        #185..#188: PD^ := 'u';
        #190: PD^ := 'p';
        #189,
        #191: PD^ := 'y';
        else
          F := False;
      end;
    if F then Inc(PS)
    else PD^ := PS^;
    Inc(i);
    Inc(PD);
    Inc(PS);
  end;
  SetLength(Result, i);
end;

//Case Insensitive
function ReplAllCI(const s, OldVal: String; const NewVal: String = ''): String;
  inline;
begin
  Result := StringReplace(s, OldVal, NewVal, [rfReplaceAll, rfIgnoreCase]);
end;

function ReplAllCITrim(const s, OldVal: String;
  const NewVal: String = ''): String; inline;
begin
  Result := Trim(StringReplace(s, OldVal, NewVal,
    [rfReplaceAll, rfIgnoreCase]));
end;

procedure ResolveSmartInput(var AInput: String);
var
  URI: TURI;
  sExpanded: String;
begin
  AInput := Trim(AInput);
  if AInput = '' then Exit;
  // 1. Check if it's an existing local file
  sExpanded := SafeExpandFilename(AInput);
  if FileExists(sExpanded) then
  begin
    AInput := sExpanded;
    Exit;
  end;
  // 2. Parse and Fix Protocol
  URI := ParseURI(AInput);
  if (URI.Protocol = '') and (Pos('.', AInput) > 0) then
  begin
    AInput := 'https://' + AInput;
    URI := ParseURI(AInput);
  end;
  // 3. Re-assemble manually (The most compatible way)
  if URI.Protocol <> '' then
  begin
    URI.Path := ResolveDots(URI.Path);
    AInput := URI.Protocol + '://';
    if URI.Username <> '' then
    begin
      AInput := AInput + URI.Username;
      if URI.Password <> '' then AInput := AInput + ':' + URI.Password;
      AInput := AInput + '@';
    end;
    AInput := AInput + URI.Host;
    // FIX: Port is a Word (integer). Check if it's set and convert to string.}
    if URI.Port > 0 then AInput := AInput + ':' + IntToStr(URI.Port);
    if (URI.Path <> '') and (URI.Path[1] <> '/') then AInput := AInput + '/';
    AInput := AInput + URI.Path;
    if URI.Document <> '' then AInput := AInput + '?' + URI.Document;
  end;
end;

// Configures, launches and drains an already-populated process. Both RunEx
// forms funnel through here so options, error handling and pipe draining
// exist in exactly one place. ADescription is for the error log only.
// AStartError, when given (by a TRunExThread), receives the reason the
// process couldn't be started instead of it being logged here, since
// LogError must not be called from a worker thread.
function RunExDrain(var AProc: TSmartProcess; const ADescription: String;
  bRedirectErr: Boolean; out AExitCode: Integer;
  AStartError: PString = nil): String;
const
  READ_BYTES = 4096;
type
  TByteArray = array[0..READ_BYTES - 1] of byte;
var
  MS: TSmartMemoryStream;
  Buffer: TByteArray;
  ReadLen: Integer;
  bGotData: Boolean;
begin
  AExitCode := -1;
  Buffer := Default(TByteArray);
  AProc.Value.Options := [poNoConsole, poUsePipes];
  if bRedirectErr then AProc.Value.Options :=
      AProc.Value.Options + [poStderrToOutPut];
  // Windows only, ignored elsewhere. poNoConsole already suppresses the
  // console box for a console tool; this additionally stops a GUI child
  // flashing a window. Every current caller is a console tool.
  AProc.Value.ShowWindow := swoHIDE;
  try
    AProc.Value.Execute;
  except
    on E: Exception do
    begin
      if Assigned(AStartError) then
        AStartError^ := E.ClassName + ': ' + E.Message
      else
        LogError(sb(['RunEx could not start: ', ADescription]), E);
      Exit('');
    end;
  end;
  while AProc.Value.Running or (AProc.Value.Output.NumBytesAvailable > 0) or
    ((not bRedirectErr) and (AProc.Value.Stderr.NumBytesAvailable > 0)) do
  begin
    bGotData := False;
    if AProc.Value.Output.NumBytesAvailable > 0 then
    begin
      ReadLen := AProc.Value.Output.Read(Buffer[0], SizeOf(Buffer));
      if ReadLen > 0 then
      begin
        MS.Value.Write(Buffer[0], ReadLen);
        bGotData := True;end;
    end;
    if (not bRedirectErr) and (AProc.Value.Stderr.NumBytesAvailable > 0) then
    begin
      // Drained and DISCARDED - see the note in the string overload.
      ReadLen := AProc.Value.Stderr.Read(Buffer[0], SizeOf(Buffer));
      if ReadLen > 0 then bGotData := True;
    end;
    if not bGotData then Sleep(1);
  end;
  AExitCode := AProc.Value.ExitStatus;
  Result := MS.AsString;
end;

// AStartError: see RunExDrain. Given only by a TRunExThread, which is also
// why the command line isn't logged here then (its starter logs it).
// ACurrentDir: the process's working directory ('' for the program's own).
function RunExCore(const sCommandLine: String; bRedirectErr: Boolean;
  out AExitCode: Integer; AStartError: PString = nil;
  const ACurrentDir: String = ''): String;
var
  Proc: TSmartProcess;
begin
  if IsDebugBuild and not Assigned(AStartError) then
    DebugLog(sb(['RunEx: ', sCommandLine]));
  Proc.ParseCommandLine(sCommandLine);
  if ACurrentDir <> '' then Proc.Value.CurrentDirectory := ACurrentDir;
  Result := RunExDrain(Proc, sCommandLine, bRedirectErr, AExitCode,
    AStartError);
end;

// Main thread only: what RunExCore leaves unlogged on a TRunExThread.
procedure LogRunExStart(const sCommandLine: String);
begin
  if IsDebugBuild then DebugLog(sb(['RunEx (thread): ', sCommandLine]));
end;

procedure LogRunExStartError(const sCommandLine, AStartError: String);
begin
  if AStartError <> '' then
    LogError(sb(['RunEx could not start: ', sCommandLine, ' - ',
      AStartError]));
end;

type
  // Runs one RunExCore call on a background thread. Used standalone by
  // RunExAsync (FCallback assigned, OnTerminate wired to its own
  // DoSingleCallback), and pooled by TRunExBatchCoordinator (FCallback left
  // nil, OnTerminate re-pointed at the coordinator instead).
  TRunExThread = class(TThread)
  private
    FBatchIndex: Integer;
    FCallback: TRunExCallback;
    FCommandLine: String;
    FCurrentDir: String;
    FExitCode: Integer;
    FOutput: String;
    FRedirectErr: Boolean;
    // Why the process couldn't be started ('' if it was). Logged on the
    // main thread, once the thread is done (DoSingleCallback,
    // TRunExBatchCoordinator.ThreadTerminated).
    FStartError: String;
    procedure DoSingleCallback(Sender: TObject);

  protected
    procedure Execute; override;

  public
    constructor Create(const ACommandLine: String; ARedirectErr: Boolean;
      ACallback: TRunExCallback; ABatchIndex: Integer = -1;
      const ACurrentDir: String = '');
    property BatchIndex: Integer read FBatchIndex;
    property CommandLine: String read FCommandLine;
    property ExitCode: Integer read FExitCode;
    property Output: String read FOutput;
    property StartError: String read FStartError;
  end;

  // Keeps up to AMaxConcurrency TRunExThread instances in flight at once
  // for RunExBatch, topping the pool back up every time one finishes.
  // Self-owned: created on Start, frees itself once every command line has
  // completed, so callers never need to (and must not) free it manually.
  TRunExBatchCoordinator = class
  private
    FCommandLines: array of String;
    FCurrentDirs: array of String;
    FCompleteCallback: TRunExBatchCompleteCallback;
    FCompletedCount: Integer;
    FFailedCount: Integer;
    FItemCallback: TRunExBatchItemCallback;
    FMaxConcurrency: Integer;
    FNextIndex: Integer;
    FRedirectErr: Boolean;
    FSucceededCount: Integer;
    procedure LaunchNext;
    procedure ThreadTerminated(Sender: TObject);

  public
    constructor Create(const ACommandLines, ACurrentDirs: array of String;
      AItemCallback: TRunExBatchItemCallback;
      ACompleteCallback: TRunExBatchCompleteCallback;
      AMaxConcurrency: Integer; ARedirectErr: Boolean);
    procedure Start;
  end;

function RunEx(const sCommandLine: String;
  bRedirectErr: Boolean = False): String; overload;
var
  LExitCode: Integer;
begin
  Result := RunExCore(sCommandLine, bRedirectErr, LExitCode);
end;

function RunEx(const sCommandLine: String; out AExitCode: Integer;
  bRedirectErr: Boolean = False): String; overload;
begin
  Result := RunExCore(sCommandLine, bRedirectErr, AExitCode);
end;

function RunEx(const AExecutable: String; const AParams: array of String;
  out AExitCode: Integer; bRedirectErr: Boolean = False): String; overload;
var
  Proc: TSmartProcess;
  s: String;
begin
  Proc.Value.Executable := AExecutable;
  for s in AParams do Proc.Value.Parameters.Add(s);
  if IsDebugBuild then DebugLog(
      sb(['RunEx: ', AExecutable, ' ', string.Join(' ', AParams)]));
  Result := RunExDrain(Proc, AExecutable, bRedirectErr, AExitCode);
end;

constructor TRunExThread.Create(const ACommandLine: String;
  ARedirectErr: Boolean; ACallback: TRunExCallback; ABatchIndex: Integer;
  const ACurrentDir: String);
begin
  inherited Create(True); // create suspended; caller starts it explicitly
  FreeOnTerminate := True;
  FCommandLine := ACommandLine;
  FRedirectErr := ARedirectErr;
  FCallback := ACallback;
  FBatchIndex := ABatchIndex;
  FCurrentDir := ACurrentDir;
  FExitCode := -1;
  if Assigned(FCallback) then OnTerminate := @DoSingleCallback;
end;

procedure TRunExThread.Execute;
begin
  FOutput := RunExCore(FCommandLine, FRedirectErr, FExitCode, @FStartError,
    FCurrentDir);
end;

// TThread.OnTerminate is always dispatched via Synchronize, so this (like
// TRunExBatchCoordinator.ThreadTerminated below) always runs on the main
// thread and is safe to use for UI updates.
procedure TRunExThread.DoSingleCallback(Sender: TObject);
begin
  LogRunExStartError(FCommandLine, FStartError);
  if Assigned(FCallback) then FCallback(FOutput, FExitCode);
end;

procedure RunExAsync(const sCommandLine: String; ACallback: TRunExCallback;
  bRedirectErr: Boolean = False);
begin
  LogRunExStart(sCommandLine);
  TRunExThread.Create(sCommandLine, bRedirectErr, ACallback).Start;
end;

constructor TRunExBatchCoordinator.Create(
  const ACommandLines, ACurrentDirs: array of String;
  AItemCallback: TRunExBatchItemCallback;
  ACompleteCallback: TRunExBatchCompleteCallback; AMaxConcurrency: Integer;
  ARedirectErr: Boolean);
var
  i: Integer;
begin
  inherited Create;
  SetLength(FCommandLines, System.Length(ACommandLines));
  SetLength(FCurrentDirs, System.Length(ACommandLines));
  for i := 0 to High(ACommandLines) do
  begin
    FCommandLines[i] := ACommandLines[i];
    if i <= High(ACurrentDirs) then FCurrentDirs[i] := ACurrentDirs[i]
    else
      FCurrentDirs[i] := '';
  end;
  FItemCallback := AItemCallback;
  FCompleteCallback := ACompleteCallback;
  FMaxConcurrency := AMaxConcurrency;
  if FMaxConcurrency < 1 then FMaxConcurrency := 1;
  FRedirectErr := ARedirectErr;
  FNextIndex := 0;
  FCompletedCount := 0;
  FSucceededCount := 0;
  FFailedCount := 0;
end;

procedure TRunExBatchCoordinator.LaunchNext;
var
  LThread: TRunExThread;
begin
  // Keep the pipeline topped up: launch more until either the concurrency
  // cap is reached or every command line has been submitted.
  while ((FNextIndex - FCompletedCount) < FMaxConcurrency) and
    (FNextIndex < System.Length(FCommandLines)) do
  begin
    LThread := TRunExThread.Create(FCommandLines[FNextIndex],
      FRedirectErr, nil, FNextIndex, FCurrentDirs[FNextIndex]);
    LThread.OnTerminate := @ThreadTerminated;
    LogRunExStart(FCommandLines[FNextIndex]);
    Inc(FNextIndex);
    LThread.Start;
  end;
end;

procedure TRunExBatchCoordinator.ThreadTerminated(Sender: TObject);
var
  LThread: TRunExThread;
begin
  LThread := TRunExThread(Sender);
  LogRunExStartError(LThread.CommandLine, LThread.StartError);
  Inc(FCompletedCount);
  if LThread.ExitCode = 0 then Inc(FSucceededCount)
  else Inc(FFailedCount);
  if Assigned(FItemCallback) then
    FItemCallback(LThread.BatchIndex, LThread.CommandLine, LThread.Output,
      LThread.ExitCode);
  if FCompletedCount = System.Length(FCommandLines) then
  begin
    if Assigned(FCompleteCallback) then
      FCompleteCallback(FSucceededCount, FFailedCount);
    Free; // self-owned: nothing else references this coordinator
  end
  else
    LaunchNext;
end;

procedure TRunExBatchCoordinator.Start;
begin
  if System.Length(FCommandLines) = 0 then
  begin
    if Assigned(FCompleteCallback) then FCompleteCallback(0, 0);
    Free;
    Exit;
  end;
  LaunchNext;
end;

procedure RunExBatch(const ACommandLines: array of String;
  AItemCallback: TRunExBatchItemCallback;
  ACompleteCallback: TRunExBatchCompleteCallback; AMaxConcurrency: Integer;
  bRedirectErr: Boolean);
begin
  TRunExBatchCoordinator.Create(ACommandLines, [], AItemCallback,
    ACompleteCallback, AMaxConcurrency, bRedirectErr).Start;
end;

procedure RunExBatch(const ACommandLines, ACurrentDirs: array of String;
  AItemCallback: TRunExBatchItemCallback;
  ACompleteCallback: TRunExBatchCompleteCallback; AMaxConcurrency: Integer;
  bRedirectErr: Boolean);
begin
  TRunExBatchCoordinator.Create(ACommandLines, ACurrentDirs, AItemCallback,
    ACompleteCallback, AMaxConcurrency, bRedirectErr).Start;
end;

type
  // RunExBatchAndWait's side of a RunExBatch: collects the results. Lives
  // until the batch's completion callback, which normally comes before
  // RunExBatchAndWait returns; if it stopped waiting (a stall), the waiter
  // is Abandoned instead and frees itself when the batch does finish, so a
  // late callback never reaches freed memory.
  TRunExWaiter = class
  public
    Abandoned: Boolean;
    AllDone: Boolean;
    DoneCount: Integer;
    ExitCodes: TIntegerArray;
    Outputs: TStringArray;
    procedure ItemDone(AIndex: Integer; const {%H-}ACommandLine: String;
      const AOutput: String; AExitCode: Integer);
    procedure BatchDone({%H-}ASucceededCount, {%H-}AFailedCount: Integer);
  end;

procedure TRunExWaiter.ItemDone(AIndex: Integer; const ACommandLine: String;
  const AOutput: String; AExitCode: Integer);
begin
  Inc(DoneCount);
  if (AIndex < 0) or (AIndex > High(Outputs)) then Exit;
  Outputs[AIndex] := AOutput;
  ExitCodes[AIndex] := AExitCode;
end;

procedure TRunExWaiter.BatchDone(ASucceededCount, AFailedCount: Integer);
begin
  AllDone := True;
  if Abandoned then Free;
end;

function RunExBatchAndWait(const ACommandLines, ACurrentDirs: array of String;
  out AOutputs: TStringArray; out AExitCodes: TIntegerArray;
  AMaxConcurrency: Integer; bRedirectErr: Boolean;
  AOnProgress: TParallelProgress; AStallMs: QWord): Boolean;
var
  i, iCount, iLastDone: Integer;
  LastProgress: QWord;
  Waiter: TRunExWaiter;
begin
  Result := True;
  iCount := System.Length(ACommandLines);
  AOutputs := nil;
  AExitCodes := nil;
  SetLength(AOutputs, iCount);
  SetLength(AExitCodes, iCount);
  for i := 0 to iCount - 1 do AExitCodes[i] := -1;
  if iCount = 0 then Exit;
  Waiter := TRunExWaiter.Create;
  SetLength(Waiter.Outputs, iCount);
  SetLength(Waiter.ExitCodes, iCount);
  for i := 0 to iCount - 1 do Waiter.ExitCodes[i] := -1;
  try
    RunExBatch(ACommandLines, ACurrentDirs, @Waiter.ItemDone,
      @Waiter.BatchDone, AMaxConcurrency, bRedirectErr);
  except
    on E: Exception do
    begin
      // Not even started: nothing will call the waiter back, unless some
      // threads did start - then it must stay, and free itself.
      LogError('RunExBatchAndWait: could not start the batch', E);
      Waiter.Abandoned := True;
      Exit(False);
    end;
  end;
  // Results arrive through TThread.Synchronize, which ProcessMessages
  // services.
  iLastDone := -1;
  LastProgress := GetTickCount64;
  while not Waiter.AllDone do
  begin
    Application.ProcessMessages;
    if Waiter.DoneCount <> iLastDone then
    begin
      iLastDone := Waiter.DoneCount;
      LastProgress := GetTickCount64;
      if Assigned(AOnProgress) then AOnProgress(iLastDone, iCount);
    end
    else if (AStallMs > 0) and (GetTickCount64 - LastProgress >= AStallMs) then
    begin
      LogError(sb(['RunExBatchAndWait: nothing finished for ',
        AStallMs div 1000, ' seconds; stopped waiting after ',
        Waiter.DoneCount, ' of ', iCount, ' commands']));
      Result := False;
      Break;
    end;
    if not Waiter.AllDone then Sleep(10);
  end;
  for i := 0 to iCount - 1 do
  begin
    AOutputs[i] := Waiter.Outputs[i];
    AExitCodes[i] := Waiter.ExitCodes[i];
  end;
  if Waiter.AllDone then Waiter.Free
  else
  begin
    // Its outputs were just copied; whatever arrives from now on is
    // dropped, and BatchDone frees it.
    SetLength(Waiter.Outputs, 0);
    SetLength(Waiter.ExitCodes, 0);
    Waiter.Abandoned := True;
  end;
end;

function ParallelThreadCount(AMax: Integer): Integer;
begin
  Result := Max(2, Min(AMax, Integer(TThread.ProcessorCount)));
end;

type
  // What a RunParallel call's worker threads share. Only the main thread
  // creates and frees it, after every worker has finished.
  TParallelRun = class
  public
    Aborted: Boolean; // set by the main thread; read by the workers
    Count: Integer;
    Done: LongInt;    // InterLockedIncrement'ed by the workers
    Errors: TStringArray; // one per job; '' unless it raised
    Job: TParallelJob;
    Next: LongInt;    // InterLockedIncrement'ed by the workers
    // The job at the index handed out next, or -1 once there are none (or
    // the run was cancelled). Called on the worker threads.
    function TakeNext: Integer;
    // Runs one job, catching anything it raises.
    procedure RunJob(AIndex: Integer);
  end;

  TParallelWorker = class(TThread)
  private
    FRun: TParallelRun;
  protected
    procedure Execute; override;
  public
    constructor Create(ARun: TParallelRun);
  end;

function TParallelRun.TakeNext: Integer;
begin
  if Aborted then Exit(-1);
  Result := InterLockedIncrement(Next) - 1;
  if Result >= Count then Result := -1;
end;

procedure TParallelRun.RunJob(AIndex: Integer);
begin
  try
    Job(AIndex);
  except
    on E: Exception do Errors[AIndex] := E.ClassName + ': ' + E.Message;
  end;
  InterLockedIncrement(Done);
end;

constructor TParallelWorker.Create(ARun: TParallelRun);
begin
  inherited Create(True); // started by RunParallel
  FreeOnTerminate := False; // RunParallel waits for it and frees it
  FRun := ARun;
end;

procedure TParallelWorker.Execute;
var
  i: Integer;
begin
  i := FRun.TakeNext;
  while i >= 0 do
  begin
    FRun.RunJob(i);
    i := FRun.TakeNext;
  end;
end;

function RunParallel(ACount: Integer; AJob: TParallelJob;
  AMaxThreads: Integer; AOnProgress: TParallelProgress;
  ACancelCheck: TParallelCancelCheck): Integer;
var
  i, iLastDone, iThreads: Integer;
  Run: TParallelRun;
  Workers: array of TParallelWorker;

  function AllWorkersFinished: Boolean;
  var
    w: TParallelWorker;
  begin
    for w in Workers do
      if not w.Finished then Exit(False);
    Result := True;
  end;

begin
  Result := 0;
  if (ACount <= 0) or not Assigned(AJob) then Exit;
  Run := TParallelRun.Create;
  Workers := nil;
  try
    Run.Count := ACount;
    Run.Job := AJob;
    SetLength(Run.Errors, ACount);
    iThreads := Min(AMaxThreads, ACount);
    // Start the workers. One that can't be created (no thread support, out
    // of resources) just means fewer; with none at all, the loop below
    // does every job here.
    if iThreads > 1 then
      for i := 1 to iThreads do
      try
        SetLength(Workers, System.Length(Workers) + 1);
        Workers[High(Workers)] := TParallelWorker.Create(Run);
        Workers[High(Workers)].Start;
      except
        on E: Exception do
        begin
          SetLength(Workers, System.Length(Workers) - 1);
          DebugLog('RunParallel: could not start worker thread: ' +
            E.Message);
          Break;
        end;
      end;
    if System.Length(Workers) = 0 then
    begin
      // On this thread, one job at a time, keeping the window alive.
      i := Run.TakeNext;
      while i >= 0 do
      begin
        Run.RunJob(i);
        if Assigned(AOnProgress) then AOnProgress(Run.Done, ACount);
        Application.ProcessMessages;
        if Assigned(ACancelCheck) and ACancelCheck() then Run.Aborted := True;
        i := Run.TakeNext;
      end;
    end
    else
    begin
      iLastDone := -1;
      while not AllWorkersFinished do
      begin
        Application.ProcessMessages;
        if (not Run.Aborted) and Assigned(ACancelCheck) and ACancelCheck() then
          Run.Aborted := True;
        if Assigned(AOnProgress) and (Run.Done <> iLastDone) then
        begin
          iLastDone := Run.Done;
          AOnProgress(iLastDone, ACount);
        end;
        Sleep(5);
      end;
      for i := 0 to High(Workers) do
      begin
        Workers[i].WaitFor;
        FreeAndNil(Workers[i]);
      end;
      if Assigned(AOnProgress) and (Run.Done <> iLastDone) then
        AOnProgress(Run.Done, ACount);
    end;
    Result := Run.Done;
    for i := 0 to ACount - 1 do
      if Run.Errors[i] <> '' then
      begin
        Dec(Result);
        LogError(sb(['RunParallel: job ', i, ' failed - ', Run.Errors[i]]));
      end;
  finally
    // Workers are only ever left here if an exception escaped the loop
    // above; they still hold Run, so wait for them before freeing it.
    for i := 0 to High(Workers) do
      if Assigned(Workers[i]) then
      begin
        Run.Aborted := True;
        Workers[i].WaitFor;
        Workers[i].Free;
      end;
    Run.Free;
  end;
end;

procedure SafeClearGridColumns(Grid: TDBGrid);
begin
  if not Assigned(Grid) then Exit;
  // REALLY IMPORTANT: AutoFillColumns MUST be False here. With it True,
  // Clear's internal notify triggers the grid's own auto-column-generation
  // from DataSource's field list *synchronously* - producing columns that
  // are not yet fully font/handle-initialized - before the caller's own
  // explicit Add loop ever runs. On Wine this fed an under-initialized
  // TColumn into font inheritance and raised "Cannot assign a Nil to a
  // TFont" inside Grid.Columns.Add. Linux tolerated the same sequence
  // silently. If anyone (including future you) ever ticks AutoFillColumns
  // back on for any of these grids in the IDE, this centralizes the fix so
  // it only needs fixing once, not once per SetupDb* procedure.
  Grid.AutoFillColumns := False;
  Grid.Columns.Clear;
end;

function SafeCopy(const Source: String; StartPos, Length: Integer): String;
begin
  Result := '';
  try
    if (StartPos > 0) and (StartPos <= System.Length(Source)) and
      (Length > 0) then Result := Copy(Source, StartPos, Length);
  except
    on E: Exception do
    begin
      LogError(sb(['Error in SafeCopy: StartPos=', ns(StartPos),
        ', Length=', ns(Length), ', Source=', Copy(Source, 1, 50)]), E);
      Result := '';
    end;
  end;
end;

function SafeExpandFilename(const FileName: String): String;
begin
  Result := '';
  if Length(FileName) = 0 then Exit;
  try
    Result := CleanAndExpandFilename(FileName);
  except
    on E: Exception do
    begin
      LogError(sb(['Error expanding filename: ',
        Copy(FileName, 1, 50)]), E);
      Result := FileName; // Return original on error
    end;
  end;
end;

procedure SafeSetFocus(AControl: TControl);
begin
  // 1. Check if the control exists
  if AControl = nil then Exit;
  // 2. Must be a TWinControl (controls that can have a window handle)
  if not (AControl is TWinControl) then Exit;
  // 3. Control must have a real OS window handle before focus is meaningful
  if not TWinControl(AControl).HandleAllocated then Exit;
  // 4. Control must actually be on-screen, not just logically visible
  if not TWinControl(AControl).Showing then Exit;
  // 5. A control must be visible and enabled to receive focus
  if not TWinControl(AControl).CanFocus then Exit;
  TWinControl(AControl).SetFocus;
end;

procedure SetAllCursors(const CursorConstant: Integer);
begin
  // Screen.Cursor is the standard LCL/VCL mechanism: any control whose own
  // Cursor is left at crDefault transparently defers to it, so this single
  // assignment covers the whole app without walking every component's RTTI.
  // (It will NOT override a control that has an explicit, non-default
  // Cursor of its own - if that ever matters here, the old RTTI-walk
  // approach is what you'd need instead.)
  Screen.Cursor := TCursor(CursorConstant);
  Application.ProcessMessages; // Nudges the cursor to redraw immediately
end;

function ShowMessage(const AMessage: String; const bIsHidden: Boolean;
  const ADialogID: String = ''): Boolean; overload;
var
  bmp: TSmartBitmap;
  dlg: TSmartManagedDialog;
  MaxWidth, minWidth, dialogWidth: Integer;
begin
  Result := False;
  if bIsHidden then Exit;
  if ADialogID <> '' then
  begin
    dlg.Setup(ADialogID);
    if dlg.IsSilenced then Exit(True);
  end;
  MaxWidth := 800;
  minWidth := 250;
  bmp.Value.Canvas.Font.Assign(Screen.SystemFont);
  dialogWidth := bmp.Value.Canvas.TextWidth(AMessage) + 100;
  if dialogWidth < minWidth then dialogWidth := minWidth
  else if dialogWidth > MaxWidth then dialogWidth := MaxWidth;
  if ADialogID.IsEmpty then dlg.Setup('GlobalMessage');
  dlg.Value.Caption := 'Information';
  dlg.Value.Text := AMessage;
  dlg.Value.Width := dialogWidth;
  dlg.Value.CommonButtons := [tcbOK];
  dlg.Value.MainIcon := tdiInformation;
  Result := dlg.Execute;
end;

procedure SetReadOnly(AObject: TObject; AValue: Boolean);
var
  LField: TField;
begin
  if not Assigned(AObject) then Exit;
  if IsPublishedProp(AObject, 'ReadOnly') then
    SetPropValue(AObject, 'ReadOnly', AValue);
  if AObject is TDataSet then for LField in TDataSet(AObject).Fields do
      LField.ReadOnly := AValue;
end;

function StripNonAlphaNum(const s: String): String;
var
  i, ULen: Integer;
  CP: cardinal;
  Trimmed: String;
  sb: TStringBuilder;
begin
  // Walks codepoints, not bytes - same reasoning as FastRemovePunctuation
  // and NormalizeTitleAndYear, both of which were already converted. A byte
  // filter tests each byte of a multi-byte character against an ASCII-only
  // set and drops all of them, so a Cyrillic, Greek or CJK title reduced to
  // whatever ASCII it happened to contain. That matters more here than
  // elsewhere: this builds EPS.SORTORDER, which carries a UNIQUE index, so
  // two different non-Latin shows could collide on the same key.
  Result := '';
  Trimmed := Trim(s);
  if Trimmed = '' then Exit;
  sb := TStringBuilder.Create(Length(Trimmed));
  try
    i := 1;
    while i <= Length(Trimmed) do
    begin
      ULen := UTF8CodepointSize(@Trimmed[i]);
      if ULen = 1 then
      begin
        if Trimmed[i] in ['0'..'9', 'A'..'Z', 'a'..'z'] then
          sb.Append(Trimmed[i]);
      end
      else
      begin
        CP := UTF8CodepointToUnicode(@Trimmed[i], ULen);
        // TCharacter classifies the Basic Multilingual Plane (WideChar);
        // codepoints above it are dropped, same as punctuation always was.
        if (CP <= $FFFF) and TCharacter.IsLetterOrDigit(widechar(CP)) then
          sb.Append(Copy(Trimmed, i, ULen));
      end;
      Inc(i, ULen);
    end;
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

procedure SwapString(var a, b: String);
begin
  specialize GenericSwap<String>(a, b);
end;

procedure ToggleBoolean(AObject: TObject;
  const APropName: String = 'ReadOnly');
var
  TargetState: Boolean = False;
  IsDatasetLocked: Boolean = False;
begin
  if not Assigned(AObject) then Exit;

  if AObject is TDataSet then
    IsDatasetLocked := not TDataSet(AObject).CanModify
  else if AObject is TCustomDBGrid then
    if Assigned(TCustomDBGrid(AObject).DataSource) and
      Assigned(TCustomDBGrid(AObject).DataSource.DataSet) then
      IsDatasetLocked := not TCustomDBGrid(AObject).DataSource.DataSet.CanModify;

  // If the environment is locked, ReadOnly MUST be True; otherwise flip
  if IsDatasetLocked then TargetState := True
  else TargetState := not GetPropValue(AObject, APropName);

  if IsPublishedProp(AObject, APropName) then
  begin
    SetPropValue(AObject, APropName, TargetState);
    if (AObject is TCustomDBGrid) and SameText(APropName, 'ReadOnly') then
    begin
      if TargetState then TCustomDBGrid(AObject).Color := clBtnFace
      else TCustomDBGrid(AObject).Color := clWindow;
    end;
  end;
end;

function ToolBarWidthSize(const AToolBar: TToolBar): Integer;
var
  i: Integer;
  w: Integer = 0;
  LControl: TControl;
  Guard: TDataLayoutGuard;
begin
  Result := 0;
  if not Assigned(AToolBar) or (AToolBar.ControlCount = 0) then Exit;
  Guard := TDataLayoutGuard.CreateLayout(AToolBar);
  for i := 0 to AToolBar.ControlCount - 1 do
  begin
    LControl := AToolBar.Controls[i];
    LControl.Left := w;
    w := w + LControl.Width;
  end;
  Result := w + 13;
end;

//jcf:format=on
function ToolRunsOK(const AWinePrefix, AExePath: String;
  const AVersionArg: String = '--version'): Boolean;
var
  sOut: String;
  iExit: Integer;
begin
  // Mirrors the way every tool is actually launched elsewhere in the app
  // (see e.g. ProbeFile): the bundled Windows build
  // is run through Wine explicitly rather than relying on the OS having
  // Wine registered as a binfmt_misc handler for .exe files.

  // AVersionArg is per-tool: mkvpropedit/mkvmerge accept the GNU-style
  // double-dash "--version", but ffprobe's option parser only exits
  // cleanly (code 0) for the single-dash "-version" - "ffprobe --version"
  // still prints the banner but then fails with "Missing argument for
  // option '-version'" and returns a non-zero exit code, which would make
  // ToolRunsOK wrongly discard a perfectly working ffprobe.
  if AWinePrefix <> EmptyStr then
    sOut := RunEx('wine', [AExePath, AVersionArg], iExit)
  else
    sOut := RunEx(AExePath, [AVersionArg], iExit);
  Result := (iExit = 0);
end;

function TrimPeriod(const s: String): String;
begin
  Result := Trim(s);
  while (Length(Result) > 0) and (Result[1] = '.') do
    System.Delete(Result, 1, 1);
  while (Length(Result) > 0) and (Result[Length(Result)] = '.') do
    System.Delete(Result, Length(Result), 1);
  Result := Trim(Result);
end;

function UpPipe(const s: String): String;
begin
  Result := sb(['|', UTF8UpperCase(s), '|']);
end;

function ValidateFileName(const AFileName: String): Boolean;
const
  INVALID_CHARS: set of char =
    ['<', '>', ':', '"', '/', '\', '|', '?', '*'];
var
  i: Integer;
  TrimmedName: String;
begin
  Result := False;
  try
    TrimmedName := Trim(AFileName);
    // Check for empty or too long names.
    // UTF8Length, not Length: Length() on a String counts BYTES, so a CJK
    // filename (3 bytes/char in UTF-8) hit the old 255-byte ceiling at
    // around 85 real characters. UTF8Length counts codepoints instead.
    if (TrimmedName = '') or (UTF8Length(TrimmedName) >
      MAX_PATH_LENGTH) then
      Exit;
    // Check for invalid characters
    for i := 1 to Length(TrimmedName) do
    begin
      if (TrimmedName[i] in INVALID_CHARS) or
        (Ord(TrimmedName[i]) < 32) then Exit;
    end;
    // Check for reserved names (Windows)
    if IsReservedFileName(TrimmedName) then Exit;
    Result := True;
  except
    on E: Exception do
    begin
      LogError('Error validating filename: ' + AFileName, E);
      Result := False;
    end;
  end;
end;

function ValidatePath(const APath: String): Boolean;
var
  TrimmedPath: String = '';
begin
  Result := False;
  try
    TrimmedPath := Trim(APath);
    if TrimmedPath = '' then Exit;
    // See ValidateFileName: UTF8Length counts codepoints, not bytes.
    if UTF8Length(TrimmedPath) > MAX_PATH_LENGTH then Exit;
    // Additional path validation could go here
    Result := True;
  except
    on E: Exception do
    begin
      LogError('Error validating path: ' + APath, E);
      Result := False;
    end;
  end;
end;




function VarRecToVariant(const AVarRec: TVarRec): variant;
begin
  case AVarRec.VType of
    vtAnsiString: Result := ansistring(AVarRec.VAnsiString);
    vtBoolean: Result := AVarRec.VBoolean;
    vtChar: Result := AVarRec.VChar;
    vtCurrency: Result := AVarRec.VCurrency^;
    vtExtended: Result := AVarRec.VExtended^;
    vtInt64: Result := AVarRec.VInt64^;
    vtInteger: Result := AVarRec.VInteger;
    vtInterface: Result := IUnknown(AVarRec.VInterface);
    vtPChar: Result := AVarRec.VPChar;
    vtPWideChar: Result := AVarRec.VPWideChar;
    vtString: Result := AVarRec.VString^;
    vtUnicodeString: Result := UnicodeString(AVarRec.VUnicodeString);
    vtVariant: Result := AVarRec.VVariant^;
    vtWideChar: Result := AVarRec.VWideChar;
    vtWideString: Result := WideString(AVarRec.VWideString);
    else
      Result := Null;
  end;
end;

// Renders one array-of-const element as a String. Shared by both sb()
// overloads below. Pure function - no shared state, nothing to leak or
// alias, so unlike the old AppendVarRecToBuilder there is no thread or
// reentrancy story to worry about here at all.
function VarRecToStr(const Arg: TVarRec): String;
begin
  case Arg.VType of
    vtAnsiString: Result := string(Arg.VAnsiString);
    vtBoolean: Result := BoolToStr(Arg.VBoolean, True);
    vtChar: Result := Arg.VChar;
    vtInt64: Result := IntToStr(Arg.VInt64^);
    vtInteger: Result := IntToStr(Arg.VInteger);
    vtUnicodeString: Result := UnicodeString(Arg.VUnicodeString);
    else
      Result := VarToStr(VarRecToVariant(Arg));
  end;
end;

function sb(const s: String): String;
begin
  Result := s;
end;

// Callers pass a handful of pieces (single digits, occasionally low tens)
// per call - never an accumulation loop - so plain concatenation costs
// nothing measurable here and needs no builder, shared or local.
function sb(const Args: array of const): String;
var
  i: Integer;
begin
  Result := '';
  for i := Low(Args) to High(Args) do Result := Result + VarRecToStr(Args[i]);
end;

// Backing store for sbAppend/sbResult/sbClear. Plain UnicodeString, so it is
// reference-counted like any other string - clearing or reassigning it never
// leaks and never needs a matching Free. That was the whole problem with the
// RAII-TStringBuilder idea: ownership/lifetime to manage. A string has none.

// What a shared global *does* still risk is reentrancy, not leaks: if
// routine A is mid-accumulation (has called sbClear, made some sbAppend
// calls, hasn't read sbResult yet) and calls routine B, and B also does
// sbClear/sbAppend/sbResult, B's sbClear wipes A's partial buffer and A's
// own eventual sbAppend calls land after B's content. There's no compiler
// error, no exception, no leak - just silently wrong text. The discipline
// that avoids this: use the trio as a strict, non-nested unit local to one
// routine (sbClear; a run of sbAppend calls; one sbResult read straight into
// Result or a local var), and never call another sbAppend/sbClear/sbResult
// user while your own run is still open. It also means this trio is not
// safe to call from more than one thread concurrently - fine for this app's
// UI-thread-only call sites, but worth remembering if that ever changes.
var
  _sbBuffer: String = '';

procedure sbClear;
begin
  _sbBuffer := '';
end;

procedure sbAppend(const s: String);
begin
  _sbBuffer := _sbBuffer + s;
end;

procedure sbAppend(const Args: array of const);
var
  i: Integer;
begin
  for i := Low(Args) to High(Args) do
    _sbBuffer := _sbBuffer + VarRecToStr(Args[i]);
end;

function sbResult: String;
begin
  Result := _sbBuffer;
end;

// Local-accumulator overloads - append straight into the caller's own var,
// no shared/global state, so no clear/reset step and no reentrancy story.
procedure sb(var Accum: String; const s: String);
begin
  Accum := Accum + s;
end;

procedure sb(var Accum: String; const Args: array of const);
var
  i: Integer;
begin
  for i := Low(Args) to High(Args) do Accum := Accum + VarRecToStr(Args[i]);
end;

// Currently unused — kept as a reusable primitive for future contexts
// (e.g. non-interactive tools) where per-file logging to ALog isn't needed.
// See TForm1.actZipSourcesExecute / AddToZip for the interactive equivalent.
//procedure ZipFileList(AZipper: TZipper; const AZipFileName: String;
//  const AFiles: TStrings;
//  AOnProgress: Zipper.TProgressEvent = nil;
//  AOnStartFile: Zipper.TOnStartFileEvent = nil);
//var
//  i: Integer;
//  NewEntry: TFullZipFileEntry;
//begin
//  AZipper.FileName := AZipFileName;
//  AZipper.OnProgress := AOnProgress;
//  AZipper.OnStartFile := AOnStartFile;
//  for i := 0 to AFiles.Count - 1 do
//  begin
//    NewEntry := TFullZipFileEntry(AZipper.Entries.AddFileEntry(AFiles[i]));
//    NewEntry.ArchiveFileName := ExtractFileName(AFiles[i]);
//    NewEntry.CompressionLevel := clmax;
//  end;
//  AZipper.ZipAllFiles;
//end;

// =============================================================================
initialization
  InitCriticalSection(LogLock);
  InitCriticalSection(ManifestLock);
  OpPath := AppendPathDelim(GetAppConfigDir(False));
  // Both loggers below open files inside OpPath. On a first run that
  // directory does not exist yet, and TForm1.Create's ForceDirectories call
  // is far too late - this unit's initialization is guaranteed to run
  // first, which is the whole reason OpPath lives here.
  ForceDirectories(OpPath);
  // The folder filey was started in is the user's - ~/Downloads, $HOME,
  // wherever a file manager happened to be - not a place for filey to
  // write. OpPath is made the current directory instead, so anything that
  // writes a relative path (filey's own bugs, a library's scratch files)
  // ends up among filey's own files. Every path filey works with is
  // absolute: dropped files, dialog results, tools found on PATH, and
  // ParamStr(0). RenameListItem changes the directory for a moment and
  // puts back whatever it found.
  LaunchDir := GetCurrentDir;
  SetCurrentDir(UTF8Encode(OpPath));
  CnfgFilePath := AppendPathDelim(GetAppConfigDir(False));
  ForceDirectories(CnfgFilePath);

  InitializeDebugLog;
  InitializeErrorLog;
  // Startup banner, logged to BOTH debug.log and error.log, before any
  // other line either file receives. Exists because logs from Linux,
  // native Windows, and Wine (which itself further splits into Debug vs
  // Release builds, and can use either the legacy "Local Settings\
  // Application Data" path or the modern "AppData\Local" one depending on
  // the Wine version/config) are otherwise visually near-identical -
  // several rounds of cross-environment debugging were lost to
  // misidentifying which log came from which combination. Only the
  // compile-time-cheap facts are logged here (OS target and Debug/Release
  // are both {$IFDEF}s, resolved at compile time - no runtime OS/version
  // detection has run yet at this point in unit initialization order).
  // Uses ExtractFileName(Application.ExeName), NOT Application.Title -
  // uMain.pas's own initialization section is what sets Application.Title
  // to 'filey', and per uses-clause dependency order that unit's
  // initialization runs AFTER this one's, so Application.Title is not yet
  // set to anything meaningful here. Application.ExeName is populated by
  // the LCL itself before any unit initialization runs, so it is safe
  // this early, and identifies the exact binary (including version, if
  // that is embedded in the filename) regardless of Title timing.
  // TForm1.Create logs a second, fuller banner once GetPreciseOSInfo and
  // the app's own FileVersion are actually available (see uMain.pas) -
  // this early one exists purely so SOME identifying line is present even
  // if the app crashes before TForm1.Create's banner gets a chance to run,
  // which is exactly the scenario that motivated adding this at all.
  BannerString := sb(['=== STARTUP: ',
    ExtractFileName(Application.ExeName), ' ',
    {$IFDEF DEBUG}'[DEBUG build]'{$ELSE}'[RELEASE build]'{$ENDIF}, ' ',
    {$IFDEF WPO}'[WPO build] ',{$ENDIF}
    {$IFDEF WINDOWS}'[Windows target - Wine if run under Wine]'
    {$ELSE}{$IFDEF LINUX}'[Linux target]'{$ELSE}'[unknown target]'
  {$ENDIF}{$ENDIF}, ' PID=', System.GetProcessID.ToString, ' exe="', Application.ExeName, '" ===']);
  DebugLog(BannerString);
  LogError(BannerString);
  DebugLog(sb(['Started in "', LaunchDir, '"; working directory now "',
    GetCurrentDir, '"']));
  DebugLog('uUtil.pas initialization');

finalization
  // InitializeErrorLog constructs this; nothing was releasing it.
  FreeAndNil(ErrorLogger);
  DoneCriticalSection(ManifestLock);
  DoneCriticalSection(LogLock);

end.
