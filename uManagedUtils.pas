unit uManagedUtils;

{$mode objfpc}{$H+}
{$MODESWITCH TYPEHELPERS}
{$MODESWITCH ADVANCEDRECORDS}
{$MODESWITCH ImplicitFunctionSpecialization}
{$COPERATORS ON}
{$INLINE ON}
{$J-}// Constants are truly read-only
{$WARN 6058 off : Call to subroutine "$1" marked as inline is not inlined}
{$WARN 5024 off : Parameter "$1" not used}
interface

uses
  {$IFDEF UNIX}baseunix,{$ENDIF}
  {$IFDEF WINDOWS}Registry, winsock2, Windows,{$ENDIF}
  Buttons, Classes, ComCtrls, Controls, db, DBGrids,
  Dialogs, DOS, EditBtn, ExtCtrls, FileInfo, FileUtil,
  Forms, FPHTTPClient, Graphics, Grids, HtmlGlobals,
  HtmlView, HTTPDefs, IniFiles, IpHtml, LCLType, {Masks,}
  Process, RegExpr, StdCtrls, StrUtils, SynEdit, SysUtils,
  TypInfo, Zipper, fpjson, opensslsockets; {do not remove opensslsockets!}

  // =============================================================================
  //  TYPE DECLARATIONS
  // =============================================================================
type

  { --- Callbacks & Events --- }
  TErrorEvent = procedure(const Msg: String; E: Exception) of object;
  ThtLinkClickEvent = procedure(Sender: TObject; const SRC: ThtString;
    var Handled: Boolean) of object;
  TLookupFunc = function: String of object;
  TRunnerNotify = procedure of object;

  // =============================================================================
  //  SUPPORT CLASSES
  // =============================================================================

  { TManagedDialogForm }
  TManagedDialogForm = class(TForm)
  public
    BitBtnOK: TBitBtn;
    DialogMemo: TMemo;
    PanelBottom, PanelClient, PanelTop: TPanel;
    // CRITICAL: Ensure this signature matches LCL exactly!
    constructor CreateNew(AOwner: TComponent; Num: Integer = 0); override;
    procedure Resize; override;
  end;

  { TThrottledUI }//out of alphabetic order, forward-declared
  TThrottledUI = record
  private
    FInterval: cardinal;
    FIsBreak: Boolean;
    FLastCheck: QWord;
    class operator Finalize(var aRecord: TThrottledUI);
    class operator Initialize(var aRecord: TThrottledUI);
    procedure SetBreak(AValue: Boolean);

  public
    class function Create(AInterval: cardinal = 100): TThrottledUI; static;
    procedure Check;
    function IsReady: Boolean;
    procedure Reset;
    function TryProceed: Boolean;
    property IsBreak: Boolean read FIsBreak write SetBreak;
  end;

  { TSearchHandler }
  TSearchHandler = class
  private
    FList: TStringList;
    FThrottle: TThrottledUI; // forward-declared above

  public
    constructor Create(AThrottleIntervalMS: cardinal = 100);
    function ExtractList: TStringList;
    procedure OnFound(FileIterator: TFileIterator);
    destructor Destroy; override;
  end;

  { TVersion }
  TVersion = class
    Version, Major, Minor, Build: String;
  end;

  { TViewerBridge }
  // Routes a TSmartHtmlViewer's link clicks. The handler set through
  // TSmartHtmlViewer.OnClick (FUserClick) sees every link first; whatever
  // it leaves unhandled that is a web or mail address opens in the system's
  // default program, and anything else (#anchors, relative files) falls
  // through to THtmlViewer itself.
  TViewerBridge = class
  private
    FUserClick: ThtLinkClickEvent;
  public
    procedure LinkClick(Sender: TObject; const SRC: ThtString;
      var Handled: Boolean);
    procedure TargetClick(Sender: TObject; const {%H-}Target,
      URL: ThtString; var Handled: Boolean);
    property UserClick: ThtLinkClickEvent read FUserClick write FUserClick;
  end;

  { TZipToStreamBridge }
  TZipToStreamBridge = class
  public
    FOutStream: TMemoryStream;
    FTargetFile: String;
    FZipSourceStream: TStream;
    constructor Create(AZipSourceStream: TStream; const ATarget: String);
    procedure DoCloseInput({%H-}Sender: TObject; var AStream: TStream);
    procedure DoCreateStream({%H-}Sender: TObject; var AStream: TStream;
      AItem: TFullZipFileEntry);
    procedure DoDoneStream({%H-}Sender: TObject; var AStream: TStream;
    {%H-}AItem: TFullZipFileEntry);
    procedure DoOpenInput({%H-}Sender: TObject; var AStream: TStream);
    procedure ReleaseOwnership;
    destructor Destroy; override;
    property MemoryStream: TMemoryStream read FOutStream;
  end;

  // =============================================================================
  //  VALUE RECORDS  (non-RAII)
  // =============================================================================

  { TConfigPair }
  TConfigPair = record
    Key, Value: String;
  end;

  { TEventSuspender }
  TEventSuspender = record
  private
    FActive: Boolean;
    FPropName: String;
    FSaved: TMethod;
    FTarget: TObject;

  public
    class operator Finalize(var aRecord: TEventSuspender);
    class operator Initialize(var aRecord: TEventSuspender);
    class function Start(ATarget: TObject;
      const APropName: String): TEventSuspender; static;
  end;

  { TFilePath }
  TFilePath = record
    Value: String;
    // Concatenation & Comparison
    class operator +(a, b: TFilePath): TFilePath;
    // Assignment Operators
    class operator := (const s: String): TFilePath;
    class operator := (const f: TFilePath): String;
    class operator =(a: TFilePath; b: String): Boolean;
    class function Combine(const APath, AFileName: String): TFilePath; static;
    // Methods
    function Backup: Boolean;
    function CopyFile(const Dest: TFilePath;
      Overwrite: Boolean = True): Boolean;
    function Delete: Boolean;
    function DirExists: Boolean;
    function Exists: Boolean;
    function Rename(const NewName: TFilePath): Boolean;
    function WithDefaultExtension: TFilePath;
  end;

  { TLookupRunner }
  TLookupRunner = record
  private
    FFoundValue: String;
    FIsFound: Boolean;
    FOnError: TErrorEvent;

  public
    class function Start: TLookupRunner; static;
    function ElseExec(ACallback: TLookupFunc): TLookupRunner;
    function OnError(AHandler: TErrorEvent): TLookupRunner;
    function TryMethod(AFunc: TLookupFunc): TLookupRunner;
    function TryValue(const AValue: String): TLookupRunner;
    property FoundValue: String read FFoundValue;
    property IsFound: Boolean read FIsFound;
  end;

  { TManagedSearch  –  Boyer-Moore-Horspool fast search }
  TManagedSearch = record
  private
    FJumpTable: array[0..255] of Integer;
    FPattern: String;
    procedure Precompute(const P: String);

  public
    class operator := (const s: String): TManagedSearch;
    function FindIn(const Source: String): Integer;
  end;

  // =============================================================================
  //  RAII RECORDS  (sorted alphabetically)
  // =============================================================================

  { TDataLayoutGuard }
  TDataLayoutGuard = record
  private
    FControl: TWinControl;
    FDataSet: TDataSet;
    FDataSource: TDataSource;
    FDBControl: TPersistent;
    procedure EnforceAccessRules;
    procedure RestoreLink;
    procedure SetUpdateState(ALock: Boolean);
    procedure SeverLink;

  public
    // Dataset only: DisableControls / EnableControls.
    class function Create(ADataSet: TDataSet): TDataLayoutGuard;
      static; overload;
    // Dataset + temporarily detach a data-aware control's DataSource,
    // optionally with a layout lock. All three arguments are required, so a
    // TWinControl can never be silently taken as the layout control.
    class function Create(ADataSet: TDataSet; ADBControl: TPersistent;
      ALayoutControl: TWinControl): TDataLayoutGuard; static; overload;
    // Layout lock. DisableAutoSizing propagates to every parent up to the
    // form, so the whole form's layout is deferred until release.
    class function CreateLayout(ALayoutControl: TWinControl):
      TDataLayoutGuard; static; overload;
    class function CreateLayout(ADataSet: TDataSet;
      ALayoutControl: TWinControl): TDataLayoutGuard; static; overload;
    class operator Finalize(var aRecord: TDataLayoutGuard);
    class operator Initialize(var aRecord: TDataLayoutGuard);
  end;

  { TEnabledScope }
  // Temporarily re-enables specific controls - plus every parent up to (not
  // including) the form - and/or non-visual components with a published
  // Boolean Enabled property (TAction), inside a region where something
  // further up the call stack, typically TSmartBusyState with
  // ADisableUI=True, has disabled the whole form. Only the items this scope
  // actually flipped from disabled to enabled are remembered, and exactly
  // those are disabled again when the scope ends, so the outer owner's own
  // restore still works unchanged. Items that were already enabled are left
  // alone, which makes the scope a no-op when nothing had disabled them.
  // Listed controls also get ACursor for the scope's lifetime.
  // Use Enable on a declared local; don't return or copy a populated
  // instance (same rule as TSmart<T>).
  TEnabledScope = record
  private
    FCursorControls: array of TControl;
    FCursors: array of TCursor;
    FEnabled: array of TComponent;
    procedure EnableOne(AComp: TComponent);

  public
    class operator Finalize(var aRecord: TEnabledScope);
    class operator Initialize(var aRecord: TEnabledScope);
    procedure Enable(const AComponents: array of TComponent;
      ACursor: TCursor = crDefault);
    procedure Restore;
  end;

  { TManagedDisabledControls }
  TManagedDisabledControls = record
  private
    FDataSet: TDataSet;

  public
    class function Create(ADataSet: TDataSet): TManagedDisabledControls;
      static;
    class operator Finalize(var aRecord: TManagedDisabledControls);
  end;

  { TSmartBitBtn }
  TSmartBitBtn = record
  private
    FInstance: TBitBtn;
    procedure Free;
    function GetValue: TBitBtn;

  public
    class operator Finalize(var aRecord: TSmartBitBtn);
    class operator Initialize(var aRecord: TSmartBitBtn);
    procedure Setup(AParent: TWinControl; const ACaption: String;
      AKind: TBitBtnKind = bkOK);
    property Value: TBitBtn read GetValue;
  end;

  { TSmartBitmap }
  TSmartBitmap = record
  private
    FInstance: TBitmap;
    function GetValue: TBitmap;

  public
    class operator Finalize(var aRecord: TSmartBitmap);
    class operator Initialize(var aRecord: TSmartBitmap);
    // Optional: for callers that need a real drawing surface of a given size.
    procedure SetSize(AWidth, AHeight: Integer);
    property Value: TBitmap read GetValue;
  end;

  { TSmartBusyState }
  TSmartBusyState = record
  private
    FCleanup: TRunnerNotify;
    FDisabledComponents: TList;
    FForm: TForm;
    FOriginalStatus: String;
    FStatusControl: TControl;
    FThrottle: TThrottledUI;
    class operator Initialize(var aRecord: TSmartBusyState);
    function GetCurrentStatusText: String;
    procedure SetState(const ACursor: TCursor; const DisableUI: Boolean);
    procedure UpdateStatusText(const AText: String);

  public
    class operator Finalize(var aRecord: TSmartBusyState);
    class function Start(AForm: TForm; ACleanup: TRunnerNotify;
      AStatusControl: TControl; ADisableUI: Boolean): TSmartBusyState; static;
    procedure Heartbeat(const AStatusMsg: String = '');
  end;

  { TSmartDialogForm }
  TSmartDialogForm = record
  private
    FInstance: TManagedDialogForm;
    function GetValue: TManagedDialogForm;

  public
    class operator Finalize(var aRecord: TSmartDialogForm);
    class operator Initialize(var aRecord: TSmartDialogForm);
    procedure AdjustWidthToContent(Padding: Integer = 180;
      MaxWidth: Integer = 1000);
    // FIX: Changed from function to procedure to avoid "Temporary Copy" AV
    procedure Setup(const ACaption: String = ''; AFont: TFont = nil);
    function ShowModal: TModalResult;
    property Value: TManagedDialogForm read GetValue;
  end;

  { TSmartEditButton }
  TSmartEditButton = record
  private
    FInstance: TEditButton;
    procedure Free;
    function GetValue: TEditButton;

  public
    class operator Finalize(var aRecord: TSmartEditButton);
    class operator Initialize(var aRecord: TSmartEditButton);
    procedure Setup(AParent: TWinControl; const AText: String = '';
      AAlign: TAlign = alNone);
    property Value: TEditButton read GetValue;
  end;

  { TSmartFileSearcher }
  TSmartFileSearcher = record
  private
    FHandler: TSearchHandler;
    FInstance: TFileSearcher;
    function GetValue: TFileSearcher;

  public
    class operator Finalize(var aRecord: TSmartFileSearcher);
    class operator Initialize(var aRecord: TSmartFileSearcher);
    function FindAllThrottled(const APath: String; const AMask: String;
      ASearchSubDirs: Boolean;
      AThrottleIntervalMS: cardinal = 100): TStringList;
    property Value: TFileSearcher read GetValue;
  end;

  { TSmartFileStream }
  TSmartFileStream = record
  private
    FFileName: String;
    FInstance: TFileStream;
    FMode: word;
    function GetExists: Boolean;
    function GetValue: TFileStream;

  public
    class operator Finalize(var aRecord: TSmartFileStream);
    class operator Initialize(var aRecord: TSmartFileStream);
    procedure Open(const AFileName: String; Mode: word);
    procedure Setup(const AFileName: String; Mode: word);
    property Exists: Boolean read GetExists;
    property Value: TFileStream read GetValue;
  end;

  { TSmartForm }
  TSmartForm = record
  private
    FInstance: TForm;
    function GetValue: TForm;

  public
    class operator Finalize(var aRecord: TSmartForm);
    class operator Initialize(var aRecord: TSmartForm);
    // NOTE: unlike TSmart<T>, TForm's real constructor takes an AOwner
    // parameter (TComponent.Create(AOwner) is virtual), so it is called
    // directly here as a concretely-typed TForm.CreateNew(AOwner) call.
    // This dispatches correctly and runs TForm's full initialisation chain -
    // the same reason the generic TSmart<T> cannot safely handle TComponent
    // descendants via an untyped TClass metaclass call.
    procedure Setup(AOwner: TComponent);
    procedure SetValue(AValue: TForm);
    property Value: TForm read GetValue;
  end;

  { TSmartHTTP }
  TSmartHTTP = record
  private
    FClient: TFPHTTPClient;
    FLastError: String;
    FResponseCode: Integer;
    class function CanReachDNS(const AAddr: String): Boolean; static;
    function ToRFC1123(ADate: TDateTime): String;

  public
    class function Available: Boolean; static;
    class operator Finalize(var aSmart: TSmartHTTP);
    class operator Initialize(var aSmart: TSmartHTTP);
    function Get(const AURL: String; out AContent: String): Boolean;
    function GetClient: TFPHTTPClient;
    function GetIfNewer(const AURL: String; ALocalLastMod: TDateTime;
      out AContent: String): Boolean;
    function Heal: Boolean;
    property ResponseCode: Integer read FResponseCode;
  end;

  { TSmartHtmlViewer }
  TSmartHtmlViewer = record
  private
    FBridge: TViewerBridge;
    FInstance: TWinControl;
    function GetValue: THtmlViewer;
    procedure SetOnClick(AValue: ThtLinkClickEvent);

  public
    class operator Finalize(var aRecord: TSmartHtmlViewer);
    class operator Initialize(var aRecord: TSmartHtmlViewer);
    procedure FreeInstance;
    procedure LoadFromFile(const AFileName: String);
    procedure LoadFromString(const AHtml: String;
      const ABasePath: String = '');
    procedure Setup(AParent: TWinControl; AAlign: TAlign = alClient);
    // Gets first look at every link clicked (set Handled to keep it);
    // unhandled web/mail links still open in the default browser. Kept on
    // the bridge, so it may be set before Setup and survives later Setups.
    property OnClick: ThtLinkClickEvent write SetOnClick;
    property Value: THtmlViewer read GetValue;
  end;

  { TSmartIni }
  TSmartIni = record
  private
    FFileName: String;
    FInstance: TIniFile;
    // FFileName, or the default when Setup hasn't named a file.
    function EffectiveFileName: String;
    function GetExists: Boolean;
    function GetValue: TIniFile;
    procedure SetFileName(const Value: String);

  public
    class operator Finalize(var aRecord: TSmartIni);
    class operator Initialize(var aRecord: TSmartIni);
    procedure CleanDuplicateKeys(const ASection, AKey: String);
    // Deletes every key in ASection whose name matches one of AMasks,
    // ignoring case: '*' stands for any run of characters, '?' for any one
    // ('TabSheetSourceCode*', 'SomeOldKey'). A section left with no keys
    // is removed too. The file is written once, at the end, and only if
    // something was deleted. Returns how many keys were deleted.
    function DeleteKeys(const ASection: String;
      const AMasks: array of String): Integer;
    procedure HardRemoveSection(const ASection: String);
    // Deletes the ini file and forgets what was read from it, so nothing
    // this program still holds in memory writes it back. The next read or
    // write starts from an empty file. True if the file is gone afterwards.
    function RemoveFile: Boolean;
    procedure Setup(const AFileName: String);
    procedure WriteClean(const ASection, AKey, AValue: String);
    procedure WritePairs(const ASection: String;
      const APairs: array of TConfigPair);
    property Exists: Boolean read GetExists;
    property FileName: String read FFileName write SetFileName;
    property Value: TIniFile read GetValue;
  end;

  { TSmartIpHtmlPanel }
  TSmartIpHtmlPanel = record
  private
    FInstance: TIpHtmlPanel;
    function GetValue: TIpHtmlPanel;

  public
    class operator Finalize(var aRecord: TSmartIpHtmlPanel);
    class operator Initialize(var aRecord: TSmartIpHtmlPanel);
    procedure LoadFromStream(AStream: TStream);
    procedure Release;
    procedure Setup(AParent: TWinControl; AAlign: TAlign = alClient);
    property Value: TIpHtmlPanel read GetValue;
  end;

  { TSmartManagedDialog }
  TSmartManagedDialog = record
  private
    FDialogID: String;
    FInstance: TTaskDialog;
    function GetIsSilenced: Boolean;
    function GetValue: TTaskDialog;
    procedure HandleHyperlink(Sender: TObject);
    procedure SetSilenced(AValue: Boolean);

  public
    class operator Finalize(var aRecord: TSmartManagedDialog);
    class operator Initialize(var aRecord: TSmartManagedDialog);
    function Execute: Boolean;
    procedure SetTexts(const ATitle, AInstruction, AContent: String);
    procedure Setup(const ADialogID: String; AOwner: TComponent = nil);
    property IsSilenced: Boolean read GetIsSilenced;
    property Value: TTaskDialog read GetValue;
  end;

  { TSmartMemoryStream }
  TSmartMemoryStream = record
  private
    FStream: TMemoryStream; //instance field
  class var
    FActiveCount: Integer; //shared, genuinely intended
  private
    procedure Clear;
    function GetValue: TMemoryStream;
    procedure LoadFromFile(const AFileName: String);
    procedure SetValue(AValue: TMemoryStream);
  public
    class operator Initialize(var aRecord: TSmartMemoryStream);
    class operator Finalize(var aRecord: TSmartMemoryStream);
    class function ActiveCount: Integer; static;
    function AsString: String;
    property Value: TMemoryStream read GetValue write SetValue;
  end;

  { TSmartPanel }
  TSmartPanel = record
  private
    FInstance: TPanel;
    procedure Free;
    function GetValue: TPanel;

  public
    class operator Finalize(var aRecord: TSmartPanel);
    class operator Initialize(var aRecord: TSmartPanel);
    procedure Setup(AParent: TWinControl; AAlign: TAlign = alNone);
    property Value: TPanel read GetValue;
  end;

  { TSmartProcess }
  TSmartProcess = record
  private
    FInstance: TProcess;
    function GetValue: TProcess;

  public
    class operator Finalize(var aRecord: TSmartProcess);
    class operator Initialize(var aRecord: TSmartProcess);
    procedure ParseCommandLine(const AValue: String);
    procedure QuickRun(const AExecutable: String;
      const AArgs: array of String; AWait: Boolean = True);
    property Value: TProcess read GetValue;
  end;

  { TSmartRegEx }
  TSmartRegEx = record
  private
    FEngine: TRegExpr;

  public
    class operator Finalize(var aRecord: TSmartRegEx);
    class operator Initialize(var aRecord: TSmartRegEx);
    procedure FreeInstance;
    function GetValue: TRegExpr;
    procedure SetValue(AValue: TRegExpr);
    property Value: TRegExpr read GetValue write SetValue;
  end;

  {$IFDEF WINDOWS}
  { TSmartRegistry }
  TSmartRegistry = record
  private
    FInstance: TRegistry;
    function GetValue: TRegistry;

  public
    class operator Finalize(var aRecord: TSmartRegistry);
    class operator Initialize(var aRecord: TSmartRegistry);
    function ReadStringDefault(const Name, Default: String): String;
    function TryOpenKey(const Key: String;
      CanCreate: Boolean = False): Boolean;
    property Value: TRegistry read GetValue;
  end;
  {$ENDIF}

  { TSmartResourceStream }
  TSmartResourceStream = record
  private
    FStream: TResourceStream;

  public
    class operator Finalize(var aRecord: TSmartResourceStream);
    class operator Initialize(var aRecord: TSmartResourceStream);
    function GetValue: TResourceStream;
    procedure Setup(AInstance: TLCLHandle; const AResName: String;
      AResType: PChar);
    property Value: TResourceStream read FStream;
  end;

  { TSmartStringStream }
  TSmartStringStream = record
  private
    FInitialContent: String;
    FInstance: TStringStream;
    function GetValue: TStringStream;

  public
    class operator Finalize(var aRecord: TSmartStringStream);
    class operator Initialize(var aRecord: TSmartStringStream);
    procedure Setup(const AContent: String);
    property Value: TStringStream read GetValue;
  end;

  { TSmartSynEdit }
  TSmartSynEdit = record
  private
    FInstance: TCustomControl;
    procedure Free;
    function GetValue: TCustomControl;

  public
    class operator Finalize(var aRecord: TSmartSynEdit);
    class operator Initialize(var aRecord: TSmartSynEdit);
    procedure Setup(AParent: TWinControl; AAlign: TAlign = alClient);
    property Value: TCustomControl read GetValue;
  end;

  { TSmartTabSheet }
  TSmartTabSheet = record
  private
    FInstance: TTabSheet;
    procedure Free;
    function GetValue: TTabSheet;
    procedure Setup(APageControl: TPageControl; const ACaption: String);

  public
    class operator Finalize(var aRecord: TSmartTabSheet);
    class operator Initialize(var aRecord: TSmartTabSheet);
    property Value: TTabSheet read GetValue;
  end;

  { TSmartUnzipper }
  TSmartUnzipper = record
  private
    FInstance: TUnZipper;
    FOwner: TComponent;
    function GetValue: TUnZipper;

  public
    class operator Finalize(var aRecord: TSmartUnzipper);
    class operator Initialize(var aRecord: TSmartUnzipper);
    procedure QuickExtract(const AZipFile, ADestDir: String);
    function QuickExtractToStream(AZipSourceStream: TStream;
      const AZipName, AInternalFile: String): TMemoryStream;
    procedure Setup(AOwner: TComponent = nil);
    property Value: TUnZipper read GetValue;
  end;

  { TSmartVersion }
  TSmartVersion = record
  private
    FInstance: TVersion;

  public
    class operator Finalize(var aRecord: TSmartVersion);
    class operator Initialize(var aRecord: TSmartVersion);
    property Value: TVersion read FInstance;
  end;

  { TSmartVersionInfo }
  TSmartVersionInfo = record
  private
    FInfo: TFileVersionInfo;
    FLoaded: Boolean;
    function GetVersionString: String;

  public
    class operator Finalize(var Dest: TSmartVersionInfo);
    class operator Initialize(var Dest: TSmartVersionInfo);
    function LoadLocalFileInfo: Boolean;
    property Loaded: Boolean read FLoaded;
    property Value: TFileVersionInfo read FInfo;
    property VersionString: String read GetVersionString;
  end;

  { TSmartZipper }
  TSmartZipper = record
  private
    FInstance: TZipper;
    FOwner: TComponent;
    function GetValue: TZipper;

  public
    class operator Finalize(var aRecord: TSmartZipper);
    class operator Initialize(var aRecord: TSmartZipper);
    procedure Setup(AOwner: TComponent);
    property Value: TZipper read GetValue;
  end;

  // =============================================================================
  //  GENERIC RAII RECORD
  // =============================================================================

  { TSmart<T> }
  // NOTE: FPC does not implement the Delphi-style "constructor" generic
  // constraint (declaring it is a parse error: "Illegal expression"). It
  // isn't needed here anyway: FPC type-checks a generic's body at
  // specialization time rather than declaration time, so "T.Create" below
  // is checked, and resolved, against the real concrete type for each
  // specialization (e.g. literally as TBitmap.Create) - it correctly runs
  // that class's full constructor chain with no extra constraint required.
  // This is exactly why TForm cannot be a TSmart<T> specialization: its
  // real constructor requires an AOwner argument, so "T.Create" (no args)
  // would fail to specialize for it. See the dedicated TSmartForm above
  // instead.
  generic TSmart<T: class> = record
  private
    FInstance: T;
    FOwner: TComponent;
    FName: String;
    function GetValue: T;

  public
    // DO NOT REASSIGN a populated TSmart<T> variable - "L := Make(a);
    // L := Make(b);" produces a double-free/access violation plus a leak
    // of the first instance. The compiler bitwise-copies the record on
    // assignment and then finalizes BOTH the old and new copies, so the
    // first instance is freed twice (once via the overwritten source
    // reference, once via L's own Finalize) and leaked once (nothing ever
    // freed the object the first Make(a) allocated).

    // Fresh assignment into an empty/newly-declared variable IS safe and
    // is the normal pattern used throughout this codebase - e.g.
    // "L := SomeFunctionReturningTSmart(...)" as a function result (RVO
    // writes directly into L, verified on FPC 3.2.2) or
    // "Busy := TSmartBusyState.Start(...)" as the first assignment to Busy
    // in that scope. The danger is specifically a SECOND assignment into a
    // variable that already holds an instance.

    // A guarding class operator Copy was tried and reverted: FPC enforces
    // constref on Copy's source parameter at the compiler level (it is not
    // a Delphi-style convention that can be cast around), so there is no
    // way to null out the source's FInstance from inside Copy to prevent
    // the double free. Every documented FPC Copy operator, including
    // FPC's own management-operators feature announcement, is written to
    // never mutate its source - a shared-ownership/refcounting redesign
    // is the correct fix if this is ever needed, not a workaround here.
    class operator Finalize(var aRecord: TSmart);
    class operator Initialize(var aRecord: TSmart);
    // A scan of this codebase (see git history) found no existing call
    // site that reassigns a populated TSmart<T> variable - this comment
    // exists so the first one that ever does gets written correctly.
    procedure FreeInstance;
    procedure Setup(AOwner: TComponent);
    procedure SetValue(AValue: T);
    function TakeValue: T;
    property Name: String read FName write FName;
    property Value: T read GetValue;
  end;

  // =============================================================================
  //  COMPOSITE RAII RECORDS  (depend on simpler types above)
  // =============================================================================

  { TSourceViewManager }
  TSourceViewManager = record
  private
    FBitBtnNexts: array of TSmartBitBtn;
    FBitBtnPrevs: array of TSmartBitBtn;
    FEditButtons: array of TSmartEditButton;
    FPanels: array of TSmartPanel;
    FSynEdits: array of TSmartSynEdit;
    FTabSheets: array of TSmartTabSheet;

  public
    class operator Finalize(var aRecord: TSourceViewManager);
    class operator Initialize(var {%H-}aRecord: TSourceViewManager);
    procedure AddSourceView(APageControl: TPageControl;
      const ATitle, APath: String);
    procedure Clear;
    function GetBitBtnNext(Index: Integer): TBitBtn;
    function GetBitBtnPrev(Index: Integer): TBitBtn;
    function GetCount: Integer;
    function GetEditButton(Index: Integer): TEditButton;
    function GetPanel(Index: Integer): TPanel;
    function GetSynEdit(Index: Integer): TSynEdit;
    function GetTabSheet(Index: Integer): TTabSheet;
  end;

  // =============================================================================
  //  TYPE ALIASES  (specialisations of TSmart<T>)
  // =============================================================================
  TSmartStrings = specialize TSmart<TStringList>;

  // =============================================================================
  //  CLASS HELPERS
  // =============================================================================

  { TProgressBarHelper }
  TProgressBarHelper = class helper for TProgressBar
    procedure SmartUpdate(var aUI: TThrottledUI; aCurrent: Integer;
      aStep: Integer = 10);
  end;

  { TMyStringHelper }
  TMyStringHelper = type helper(TStringHelper) for string
  public
    function Clean: String;
    function IsBlank: Boolean; inline;      // Fast Trim='', no temp string
    function IsNotBlank: Boolean; inline;   // Fast Trim<>'', no temp string
    function IsNotEmpty: Boolean; inline;   // Fastest <> ''
    function Key: String;
    function PipeMe: String;
    function ProperCase: String; overload;  // Initial capital
    function ProperCase(const WordDelims: TSysCharSet): String;
      overload;                         // Initial capital, custom delimiters
    function Quote: String;                 // Wrap in double-quote '"'
    function UTF8ToUpper: String;
  end;

  { TStringsHelper }
  TStringsHelper = class helper for TStrings

  public
    function AddAsDir(const s: String): Integer;
    function AddAsPath(const s: String): Integer;
    function AddAsPathIfExists(const s: String): Integer;
    function AddCleanPath(const s: String): Integer;
    function AddIfEmpty(const s: String): Integer;
    function AddIfNotEmpty(const s: String): Integer;
    function AddUnique(const s: String): Integer;
    procedure Shuffle;
  end;

type
  // One character Windows forbids in file names, and the look-alike filey
  // writes in its place (UTF-8) when new names use look-alikes.
  TReservedLookalike = record
    Reserved: Char;
    Lookalike: String;
  end;

const
  // The look-alikes filey writes, one per forbidden character. '"' isn't
  // here: it becomes an opening or a closing curly quote depending on where
  // it stands (QUOTE_OPEN_LOOKALIKE / QUOTE_CLOSE_LOOKALIKE). Chosen to
  // look like the original at the same width where Unicode has such a
  // character; '?' has none, so it gets the fullwidth form yt-dlp uses.
  RESERVED_LOOKALIKES: array[0..7] of TReservedLookalike = (
    (Reserved: ':'; Lookalike: #$EA#$9E#$89),  // U+A789 MODIFIER LETTER COLON
    (Reserved: '?'; Lookalike: #$EF#$BC#$9F),  // U+FF1F FULLWIDTH QUESTION MARK
    (Reserved: '*'; Lookalike: #$E2#$88#$97),  // U+2217 ASTERISK OPERATOR
    (Reserved: '/'; Lookalike: #$E2#$88#$95),  // U+2215 DIVISION SLASH
    (Reserved: '\'; Lookalike: #$E2#$88#$96), // U+2216 SET MINUS
    (Reserved: '|'; Lookalike: #$C7#$80),      // U+01C0 LATIN LETTER DENTAL CLICK
    (Reserved: '<'; Lookalike: #$E2#$80#$B9),  // U+2039 SINGLE LEFT-POINTING ANGLE QUOTATION MARK
    (Reserved: '>'; Lookalike: #$E2#$80#$BA)); // U+203A SINGLE RIGHT-POINTING ANGLE QUOTATION MARK
  QUOTE_OPEN_LOOKALIKE = #$E2#$80#$9C;  // U+201C LEFT DOUBLE QUOTATION MARK
  QUOTE_CLOSE_LOOKALIKE = #$E2#$80#$9D; // U+201D RIGHT DOUBLE QUOTATION MARK
  // What other programs write in place of those characters (yt-dlp and
  // rclone use the fullwidth forms). Key treats these, the look-alikes
  // above and the curly quotes all as word breaks, like the characters
  // they stand for, so a file named with any of them still matches its
  // show.
  OTHER_LOOKALIKES: array[0..14] of String = (
    #$EF#$BC#$9A,  // U+FF1A FULLWIDTH COLON
    #$E2#$88#$B6,  // U+2236 RATIO
    #$EF#$B9#$95,  // U+FE55 SMALL COLON
    #$EF#$B8#$93,  // U+FE13 PRESENTATION FORM FOR VERTICAL COLON
    #$EF#$B9#$96,  // U+FE56 SMALL QUESTION MARK
    #$EF#$BC#$8A,  // U+FF0A FULLWIDTH ASTERISK
    #$EF#$BC#$82,  // U+FF02 FULLWIDTH QUOTATION MARK
    #$E2#$A7#$B8,  // U+29F8 BIG SOLIDUS
    #$E2#$A7#$B9,  // U+29F9 BIG REVERSE SOLIDUS
    #$EF#$BC#$8F,  // U+FF0F FULLWIDTH SOLIDUS
    #$EF#$BC#$BC,  // U+FF3C FULLWIDTH REVERSE SOLIDUS
    #$E2#$81#$84,  // U+2044 FRACTION SLASH
    #$EF#$BD#$9C,  // U+FF5C FULLWIDTH VERTICAL LINE
    #$EF#$BC#$9C,  // U+FF1C FULLWIDTH LESS-THAN SIGN
    #$EF#$BC#$9E); // U+FF1E FULLWIDTH GREATER-THAN SIGN

var
  // The program's one settings file. Every part of the program reads and
  // writes settings through this instance - TForm1 after AppIni.Setup,
  // TSmartManagedDialog's "Don't show this again" - never through a
  // TSmartIni of its own on the same file. TIniFile reads the file once,
  // when it is opened, and every write saves its whole in-memory copy, so
  // two instances on one file each erase whatever the other wrote since
  // it opened (the main form's save on exit used to wipe [DialogSilence]
  // this way). Opened on first use, under the name given to Setup, or
  // <executable name>.ini in OpPath when Setup hasn't been called.
  AppIni: TSmartIni;

  // =============================================================================
  //  HTML ENTITY TABLE, OS-DETECTION CONSTANTS, and the STAND-ALONE
  //  (non-RAII) FORWARD-DECLARED UTILITY FUNCTIONS have all moved to
  //  uUtils.pas. See that unit for ASCIIFold, sb/sbAppend/sbClear/sbResult,
  //  ns, IfThen, FileExists, ToggleBoolean, etc.
  // =============================================================================

  // =============================================================================
implementation

// =============================================================================

uses
  {Character,} DateUtils, fpHTML,
  Generics.Collections, LazFileUtils, LazUTF8, LCLIntf, Math,
  Menus, openssl, sockets,
  Variants, uUtils;

  // =============================================================================
  //  LOCAL HELPERS
  // =============================================================================

{ InternalSetLinkClick – bypasses record scope to wire up link events }
procedure InternalSetLinkClick(AControl: TWinControl;
  AEvent: ThtLinkClickEvent);
var
  M: TMethod;
  PropInfo: PPropInfo;
begin
  if not Assigned(AControl) then Exit;
  M := TMethod(AEvent);
  PropInfo := GetPropInfo(AControl.ClassInfo, 'OnLinkClick');
  if PropInfo = nil then PropInfo :=
      GetPropInfo(AControl.ClassInfo, 'OnHotSpotClick');
  if PropInfo <> nil then SetMethodProp(AControl, PropInfo, M);
end;

{ InternalSetTargetClick – wires OnHotSpotTargetClick, which TFrameViewer
  fires INSTEAD of OnHotSpotClick for links that carry a target="..."
  attribute (e.g. target="_blank"). A plain THtmlViewer never fires it (it
  sends every link, target or not, to OnHotSpotClick) and doesn't publish
  it, so for THtmlViewer this finds no property and does nothing. }
procedure InternalSetTargetClick(AControl: TWinControl; AEvent: TMethod);
var
  PropInfo: PPropInfo;
begin
  if not Assigned(AControl) then Exit;
  PropInfo := GetPropInfo(AControl.ClassInfo, 'OnHotSpotTargetClick');
  if PropInfo <> nil then SetMethodProp(AControl, PropInfo, AEvent);
end;

// True (and opened in the system's default program) if ALink is a web or
// mail address. Anything else (#anchors, relative files) returns False so
// the viewer handles it itself.
function OpenExternalLink(const ALink: String): Boolean;
var
  sLink, sLower: String;
begin
  sLink := Trim(ALink);
  sLower := UTF8LowerCase(sLink);
  Result := (Pos('http://', sLower) = 1) or (Pos('https://', sLower) = 1) or
    (Pos('ftp://', sLower) = 1) or (Pos('mailto:', sLower) = 1);
  if Result then LCLIntf.OpenURL(sLink);
end;

// =============================================================================
//  SUPPORT CLASSES  (alphabetical)
// =============================================================================

constructor TManagedDialogForm.CreateNew(AOwner: TComponent; Num: Integer);
begin
  inherited CreateNew(AOwner, Num);

  Self.Caption := 'Information';
  Self.SetBounds(0, 0, 600, 450);
  Self.Position := poMainFormCenter;

  PanelBottom := TPanel.Create(Self);
  PanelBottom.Parent := Self;
  PanelBottom.Align := alBottom;
  PanelBottom.Height := 60;
  PanelBottom.BevelOuter := bvNone;

  PanelClient := TPanel.Create(Self);
  PanelClient.Parent := Self;
  PanelClient.Align := alClient;
  PanelClient.BevelOuter := bvNone;
  PanelClient.BorderWidth := 10;

  DialogMemo := TMemo.Create(Self);
  DialogMemo.Parent := PanelClient;
  DialogMemo.Align := alClient;
  DialogMemo.ReadOnly := True;
  DialogMemo.ScrollBars := ssBoth;

  BitBtnOK := TBitBtn.Create(Self);
  BitBtnOK.Parent := PanelBottom;
  BitBtnOK.Kind := bkOK;
  BitBtnOK.ModalResult := mrOk;
  BitBtnOK.Caption := '&OK';
  BitBtnOK.AutoSize := True;
  BitBtnOK.Cancel := True;  { Enables Escape Key }
end;

procedure TManagedDialogForm.Resize;
begin
  inherited Resize;
  if Assigned(BitBtnOK) and Assigned(PanelBottom) then
  begin
    BitBtnOK.Left := (PanelBottom.Width - BitBtnOK.Width) div 2;
    BitBtnOK.Top := (PanelBottom.Height - BitBtnOK.Height) div 2;
  end;
end;

constructor TSearchHandler.Create(AThrottleIntervalMS: cardinal);
begin
  inherited Create;
  FList := TStringList.Create;
  FThrottle := TThrottledUI.Create(AThrottleIntervalMS);
end;

destructor TSearchHandler.Destroy;
begin
  FList.Free; // no-op if already handed off via ExtractList
  inherited Destroy;
end;

function TSearchHandler.ExtractList: TStringList;
begin
  // Transfers ownership to the caller; Destroy will no longer free it.
  Result := FList;
  FList := nil;
end;

procedure TSearchHandler.OnFound(FileIterator: TFileIterator);
begin
  FList.Add(FileIterator.FileName);
  FThrottle.Check;
end;

procedure TViewerBridge.LinkClick(Sender: TObject; const SRC: ThtString;
  var Handled: Boolean);
begin
  Handled := False;
  if Assigned(FUserClick) then FUserClick(Sender, SRC, Handled);
  if not Handled then Handled := OpenExternalLink(UTF8Encode(SRC));
end;

// Links carrying a target="..." (e.g. target="_blank") arrive here, NOT in
// LinkClick - in a TFrameViewer (see InternalSetTargetClick). Without this
// handler such links silently do nothing.
procedure TViewerBridge.TargetClick(Sender: TObject;
  const Target, URL: ThtString; var Handled: Boolean);
begin
  Handled := False;
  if Assigned(FUserClick) then FUserClick(Sender, URL, Handled);
  if not Handled then Handled := OpenExternalLink(UTF8Encode(URL));
end;

constructor TZipToStreamBridge.Create(AZipSourceStream: TStream;
  const ATarget: String);
begin
  inherited Create;
  FZipSourceStream := AZipSourceStream;
  FTargetFile := ATarget;
  FOutStream := nil;
end;

destructor TZipToStreamBridge.Destroy;
begin
  if Assigned(FOutStream) then FOutStream.Free;
  inherited Destroy;
end;

procedure TZipToStreamBridge.DoCloseInput(Sender: TObject;
  var AStream: TStream);
begin
  // DO NOT free FZipSourceStream here.
  // Setting nil prevents TUnZipper from destroying the resource stream.
  AStream := nil;
end;

procedure TZipToStreamBridge.DoCreateStream(Sender: TObject;
  var AStream: TStream; AItem: TFullZipFileEntry);
begin
  AStream := nil; // CRITICAL: default nil tells TUnZipper to skip this entry
  if SameText(AItem.ArchiveFileName, FTargetFile) then
  begin
    if Assigned(FOutStream) then FreeAndNil(FOutStream); // guard dup entries
    FOutStream := TMemoryStream.Create;
    AStream := FOutStream;
  end;
end;

procedure TZipToStreamBridge.DoDoneStream(Sender: TObject;
  var AStream: TStream; AItem: TFullZipFileEntry);
begin
  // DO NOT free FOutStream here – QuickExtractToStream needs it alive.
  AStream := nil;
end;

procedure TZipToStreamBridge.DoOpenInput(Sender: TObject;
  var AStream: TStream);
begin
  AStream := FZipSourceStream;
end;

procedure TZipToStreamBridge.ReleaseOwnership;
begin
  FOutStream := nil; // Bridge no longer owns the stream; caller is responsible
end;

class operator TEventSuspender.Initialize(var aRecord: TEventSuspender);
begin
  aRecord.FTarget := nil;
  aRecord.FPropName := '';
  aRecord.FSaved := Default(TMethod);
  aRecord.FActive := False;
end;

class function TEventSuspender.Start(ATarget: TObject;
  const APropName: String): TEventSuspender;
var
  PropInfo: PPropInfo;
begin
  Result.FTarget := ATarget;
  Result.FPropName := APropName;
  if not Assigned(ATarget) then Exit;
  PropInfo := GetPropInfo(ATarget, APropName);
  if (PropInfo = nil) or (PropInfo^.PropType^.Kind <> tkMethod) then Exit;
  Result.FSaved := GetMethodProp(ATarget, PropInfo);
  SetMethodProp(ATarget, PropInfo, Default(TMethod)); // suspend it
  Result.FActive := True;
end;

class operator TEventSuspender.Finalize(var aRecord: TEventSuspender);
var
  PropInfo: PPropInfo;
begin
  if not aRecord.FActive then Exit;
  if not Assigned(aRecord.FTarget) then Exit;
  PropInfo := GetPropInfo(aRecord.FTarget, aRecord.FPropName);
  if PropInfo <> nil then SetMethodProp(aRecord.FTarget, PropInfo,
      aRecord.FSaved);
end;

// =============================================================================
//  VALUE RECORDS  (alphabetical)
// =============================================================================

class operator TFilePath.:=(const s: String): TFilePath;
begin
  Result.Value := s;
end;

class operator TFilePath.:=(const f: TFilePath): String;
begin
  Result := f.Value;
end;

class operator TFilePath.+(a, b: TFilePath): TFilePath;
begin
  Result.Value := AppendPathDelim(a.Value) + b.Value;
end;

class operator TFilePath.=(a: TFilePath; b: String): Boolean;
begin
  Result := a.Value = b;
end;

function TFilePath.Backup: Boolean;
var
  i: Integer = 0;
  Dest: TFilePath;
begin
  Result := False;
  if not Exists then Exit;
  i := 1;
  repeat
    Dest := Value + '.' + IntToStr(i).PadLeft(3, '0');
    Inc(i);
  until not Dest.Exists;
  Result := Self.CopyFile(Dest, False);
end;

// Joins a directory and a filename into a single delimiter-correct
// TFilePath. Takes plain Strings so callers building a path from two
// raw string values (e.g. a directory + a filename property) don't
// need to explicit-cast either argument to TFilePath first.
class function TFilePath.Combine(const APath, AFileName: String): TFilePath;
begin
  Result.Value := AppendPathDelim(APath) + AFileName;
end;

function TFilePath.CopyFile(const Dest: TFilePath;
  Overwrite: Boolean): Boolean;
var
  Flags: TCopyFileFlags;
begin
  Result := False;
  if not Exists then Exit;
  if not ForceDirectories(ExtractFilePath(Dest.Value)) then Exit;
  if Overwrite then Flags := [cffOverwriteFile]
  else Flags := [];
  Result := FileUtil.CopyFile(Value, Dest.Value, Flags);
end;

function TFilePath.Delete: Boolean;
begin
  Result := False;
  if Exists then Result := SysUtils.DeleteFile(Value);
end;

function TFilePath.DirExists: Boolean;
begin
  Result := SysUtils.DirectoryExists(Value);
end;

function TFilePath.Exists: Boolean;
begin
  Result := SysUtils.FileExists(Value);
end;

function TFilePath.Rename(const NewName: TFilePath): Boolean;
var
  Target: TFilePath;
begin
  Result := False;
  // SysUtils.FileExists is NOT consistent across platforms for directories.
  // On Unix it goes through fpAccess(..., F_OK), which succeeds for a
  // folder. On Windows it explicitly masks out FILE_ATTRIBUTE_DIRECTORY and
  // returns False. Testing Exists alone therefore made renaming a FOLDER
  // work on Linux and silently fail on Windows - see
  // TForm1.OfferRenameDeepestDir, which is the only caller and only ever
  // passes directories.
  if not (Exists or DirExists) then Exit;
  if ExtractFilePath(NewName.Value) = '' then
    Target := TFilePath(ExtractFilePath(Value)) + NewName
  else
    Target := NewName;
  if not ForceDirectories(ExtractFilePath(Target.Value)) then Exit;
  Result := RenameFile(Value, Target.Value);
  if Result then Value := Target.Value;
end;

function TFilePath.WithDefaultExtension: TFilePath;
begin
  Result := Self;
  {$IFDEF WINDOWS}
  if ExtractFileExt(Result.Value) = '' then
    Result.Value := Result.Value + '.exe';
  {$ENDIF}
end;

function TLookupRunner.ElseExec(ACallback: TLookupFunc): TLookupRunner;
begin
  if FIsFound then Exit(Self);
  if Assigned(ACallback) then try
    FFoundValue := ACallback();
    FIsFound := FFoundValue.IsNotEmpty;
  except
    on E: Exception do
    begin
      if Assigned(FOnError) then FOnError('Pipeline fallback failed', E);
      FIsFound := False;
    end;
  end;
  Result := Self;
end;

function TLookupRunner.OnError(AHandler: TErrorEvent): TLookupRunner;
begin
  FOnError := AHandler;
  Result := Self;
end;

class function TLookupRunner.Start: TLookupRunner;
begin
  Result.FFoundValue := '';
  Result.FIsFound := False;
end;

function TLookupRunner.TryMethod(AFunc: TLookupFunc): TLookupRunner;
begin
  if FIsFound then Exit(Self);
  if Assigned(AFunc) then try
    FFoundValue := AFunc();
    FIsFound := FFoundValue.IsNotEmpty;
  except
    on E: Exception do
    begin
      if Assigned(FOnError) then FOnError('Pipeline step failed', E);
      FIsFound := False;
    end;
  end;
  Result := Self;
end;

function TLookupRunner.TryValue(const AValue: String): TLookupRunner;
begin
  if FIsFound then Exit(Self);
  FFoundValue := AValue;
  FIsFound := FFoundValue.IsNotEmpty;
  Result := Self;
end;

function TManagedSearch.FindIn(const Source: String): Integer;
var
  Skip, i, PatLen: Integer;
begin
  Result := -1;
  PatLen := Length(FPattern);
  if PatLen = 0 then Exit;
  Skip := 0;
  while Skip <= (Length(Source) - PatLen) do
  begin
    i := PatLen;
    while (i > 0) and (FPattern[i] = Source[Skip + i]) do Dec(i);
    if i = 0 then Exit(Skip + 1);
    Inc(Skip, FJumpTable[Ord(Source[Skip + PatLen])]);
  end;
end;

procedure TManagedSearch.Precompute(const P: String);
var
  i: Integer = 0;
begin
  for i := 0 to 255 do FJumpTable[i] := Length(P);
  for i := 1 to Length(P) - 1 do FJumpTable[Ord(P[i])] := Length(P) - i;
end;

class operator TManagedSearch.:=(const s: String): TManagedSearch;
begin
  Result.FPattern := s;
  Result.Precompute(s);
end;

class function TDataLayoutGuard.Create(ADataSet: TDataSet): TDataLayoutGuard;
begin
  Result := TDataLayoutGuard.Create(ADataSet, nil, nil);
end;

class function TDataLayoutGuard.CreateLayout(ALayoutControl: TWinControl):
TDataLayoutGuard;
begin
  Result := TDataLayoutGuard.Create(nil, nil, ALayoutControl);
end;

class function TDataLayoutGuard.CreateLayout(ADataSet: TDataSet;
  ALayoutControl: TWinControl): TDataLayoutGuard;
begin
  Result := TDataLayoutGuard.Create(ADataSet, nil, ALayoutControl);
end;

class function TDataLayoutGuard.Create(ADataSet: TDataSet;
  ADBControl: TPersistent; ALayoutControl: TWinControl): TDataLayoutGuard;
begin
  Result := Default(TDataLayoutGuard);
  Result.FDataSet := ADataSet;
  Result.FDBControl := ADBControl;
  Result.FControl := ALayoutControl;
  if Assigned(Result.FDataSet) then Result.FDataSet.DisableControls;
  Result.SetUpdateState(True);
  Result.SeverLink;
end;

class operator TDataLayoutGuard.Initialize(var aRecord: TDataLayoutGuard);
begin
  FillChar(aRecord, SizeOf(aRecord), 0);
end;

class operator TDataLayoutGuard.Finalize(var aRecord: TDataLayoutGuard);
begin
  aRecord.RestoreLink;
  aRecord.SetUpdateState(False);
  if Assigned(aRecord.FDataSet) then aRecord.FDataSet.EnableControls;
end;

procedure TDataLayoutGuard.EnforceAccessRules;
begin
  if not Assigned(FDataSet) then Exit;
  if FDataSet.CanModify then Exit;
  if Assigned(FDBControl) then ToggleBoolean(FDBControl, 'ReadOnly');
end;

procedure TDataLayoutGuard.RestoreLink;
begin
  if Assigned(FDBControl) and Assigned(FDataSource) then
    if IsPublishedProp(FDBControl, 'DataSource') then
      SetObjectProp(FDBControl, 'DataSource', FDataSource);
end;

procedure TDataLayoutGuard.SetUpdateState(ALock: Boolean);
begin
  if not Assigned(FControl) then Exit;
  if ALock then
  begin
    FControl.DisableAutoSizing;
    FControl.DisableAlign;
    FControl.BeginUpdateBounds;
    if FControl is TCustomGrid then TCustomGrid(FControl).BeginUpdate
    else if FControl is TCustomListView then
      TCustomListView(FControl).Items.BeginUpdate
    else if FControl is TCustomTreeView then
      TCustomTreeView(FControl).BeginUpdate
    else if FControl is TCustomMemo then
      TCustomMemo(FControl).Lines.BeginUpdate
    else if FControl is TCustomListBox then
      TCustomListBox(FControl).Items.BeginUpdate
    else if FControl is TCustomComboBox then
      TCustomComboBox(FControl).Items.BeginUpdate;
  end
  else
  begin
    if FControl is TCustomGrid then TCustomGrid(FControl).EndUpdate(True)
    else if FControl is TCustomListView then
      TCustomListView(FControl).Items.EndUpdate
    else if FControl is TCustomTreeView then
      TCustomTreeView(FControl).EndUpdate
    else if FControl is TCustomMemo then TCustomMemo(FControl).Lines.EndUpdate
    else if FControl is TCustomListBox then
      TCustomListBox(FControl).Items.EndUpdate
    else if FControl is TCustomComboBox then
      TCustomComboBox(FControl).Items.EndUpdate;
    FControl.EndUpdateBounds;
    FControl.EnableAlign;
    FControl.EnableAutoSizing;
    FControl.Invalidate;
  end;
end;

procedure TDataLayoutGuard.SeverLink;
begin
  if not Assigned(FDBControl) then Exit;
  if FDBControl is TCustomDBGrid then
    TCustomDBGrid(FDBControl).AutoSize := False;
  if IsPublishedProp(FDBControl, 'DataSource') then
  begin
    FDataSource := TDataSource(GetObjectProp(FDBControl, 'DataSource'));
    SetObjectProp(FDBControl, 'DataSource', nil);
  end;
end;

class operator TEnabledScope.Initialize(var aRecord: TEnabledScope);
begin
  aRecord.FCursorControls := nil;
  aRecord.FCursors := nil;
  aRecord.FEnabled := nil;
end;

class operator TEnabledScope.Finalize(var aRecord: TEnabledScope);
begin
  aRecord.Restore;
end;

procedure TEnabledScope.Enable(const AComponents: array of TComponent;
  ACursor: TCursor);
var
  Chain: array of TControl;
  Ctl: TControl;
  i: Integer = 0;
  n: Integer = 0;
begin
  Chain := nil;
  for i := Low(AComponents) to High(AComponents) do
  begin
    if not Assigned(AComponents[i]) then Continue;
    if not (AComponents[i] is TControl) then
    begin
      EnableOne(AComponents[i]); // e.g. a TAction
      Continue;
    end;
    Ctl := TControl(AComponents[i]);
    // Cursor: remember the current one (the busy state's hourglass) so
    // Restore can hand it back.
    n := Length(FCursorControls);
    SetLength(FCursorControls, n + 1);
    SetLength(FCursors, n + 1);
    FCursorControls[n] := Ctl;
    FCursors[n] := Ctl.Cursor;
    Ctl.Cursor := ACursor;
    // A child of a disabled parent stays unusable (GTK2/Qt propagate
    // insensitivity down the widget tree), so the whole chain up to the
    // form has to be enabled too. The form itself is never touched.
    SetLength(Chain, 0);
    while Assigned(Ctl) and not (Ctl is TCustomForm) do
    begin
      SetLength(Chain, Length(Chain) + 1);
      Chain[High(Chain)] := Ctl;
      Ctl := Ctl.Parent;
    end;
    for n := High(Chain) downto 0 do EnableOne(Chain[n]); // outermost first
  end;
end;

procedure TEnabledScope.EnableOne(AComp: TComponent);
var
  PropInfo: PPropInfo;
begin
  if not Assigned(AComp) then Exit;
  if AComp is TControl then
  begin
    if TControl(AComp).Enabled then Exit; // already usable, or seen before
    TControl(AComp).Enabled := True;
  end
  else
  begin
    PropInfo := GetPropInfo(AComp, 'Enabled');
    if (PropInfo = nil) or (PropInfo^.PropType^.Kind <> tkBool) then Exit;
    if GetOrdProp(AComp, PropInfo) <> 0 then Exit;
    SetOrdProp(AComp, PropInfo, 1);
  end;
  SetLength(FEnabled, Length(FEnabled) + 1);
  FEnabled[High(FEnabled)] := AComp;
end;

procedure TEnabledScope.Restore;
var
  i: Integer = 0;
  PropInfo: PPropInfo;
begin
  // Reverse order: children/actions go back to disabled before their
  // parents, the mirror image of Enable.
  for i := High(FEnabled) downto 0 do
  begin
    if FEnabled[i] is TControl then TControl(FEnabled[i]).Enabled := False
    else
    begin
      PropInfo := GetPropInfo(FEnabled[i], 'Enabled');
      if PropInfo <> nil then SetOrdProp(FEnabled[i], PropInfo, 0);
    end;
  end;
  // Reverse order also makes a control listed twice end up with its true
  // original cursor rather than ACursor.
  for i := High(FCursorControls) downto 0 do
    FCursorControls[i].Cursor := FCursors[i];
  SetLength(FEnabled, 0);
  SetLength(FCursorControls, 0);
  SetLength(FCursors, 0);
end;

class function TManagedDisabledControls.Create(
  ADataSet: TDataSet): TManagedDisabledControls;
begin
  Result.FDataSet := ADataSet;
  if Assigned(Result.FDataSet) then Result.FDataSet.DisableControls;
end;

class operator TManagedDisabledControls.Finalize(
  var aRecord: TManagedDisabledControls);
begin
  if Assigned(aRecord.FDataSet) then aRecord.FDataSet.EnableControls;
end;

class operator TSmartBitmap.Initialize(var aRecord: TSmartBitmap);
begin
  aRecord.FInstance := nil;
end;

class operator TSmartBitmap.Finalize(var aRecord: TSmartBitmap);
begin
  FreeAndNil(aRecord.FInstance);
end;

function TSmartBitmap.GetValue: TBitmap;
begin
  if not Assigned(FInstance) then
  begin
    FInstance := TBitmap.Create;
    // A 0x0 bitmap has no usable backing surface on win32, so metric
    // calls like TextHeight can fail or return garbage there while GTK/Qt
    // quietly cope. 1x1 gives every widgetset a real DC to measure against.
    FInstance.SetSize(1, 1);
  end;
  Result := FInstance;
end;

procedure TSmartBitmap.SetSize(AWidth, AHeight: Integer);
begin
  Value.SetSize(AWidth, AHeight);
end;

class operator TThrottledUI.Initialize(var aRecord: TThrottledUI);
begin
  aRecord.FInterval := 100;
  aRecord.FLastCheck := 0;
  aRecord.FIsBreak := False;
end;

class operator TThrottledUI.Finalize(var {%H-}aRecord: TThrottledUI);
begin
  // FInstance removed: it was only ever set to nil and freed - dead weight
  // on a record that is copied/reassigned frequently (see UI, FShowsColumnsThrottle).
end;

procedure TThrottledUI.Check;
begin
  if not IsReady then Exit;
  Application.ProcessMessages;
  {$IFDEF WINDOWS}
  if GetAsyncKeyState(27) <> 0 then FIsBreak := True;
  {$ENDIF}
  if Application.Terminated then FIsBreak := True;
  FLastCheck := GetTickCount64;
end;

class function TThrottledUI.Create(AInterval: cardinal): TThrottledUI;
begin
  Result.FInterval := AInterval;
  Result.FLastCheck := GetTickCount64;
end;

function TThrottledUI.IsReady: Boolean;
begin
  Result := (GetTickCount64 - FLastCheck) >= FInterval;
end;

procedure TThrottledUI.Reset;
begin
  FIsBreak := False;
  FLastCheck := GetTickCount64;
end;

// A plain gate for debouncing UI event handlers that can fire several
// times in quick succession (e.g. KeyPress/KeyUp/Change all reacting to
// one keystroke). Returns True and advances the clock if at least
// FInterval ms have passed since the last successful call; otherwise
// returns False and leaves the clock untouched, so a burst of calls
// within the interval only lets the first one through. Distinct from
// Check, which is built for message-pumping inside a tight loop (it
// also calls Application.ProcessMessages and watches for Escape/
// termination) - TryProceed has no side effects beyond the interval
// bookkeeping.
function TThrottledUI.TryProceed: Boolean;
begin
  Result := IsReady;
  if Result then FLastCheck := GetTickCount64;
end;

procedure TThrottledUI.SetBreak(AValue: Boolean);
begin
  FIsBreak := AValue;
end;

class operator TSmartBitBtn.Initialize(var aRecord: TSmartBitBtn);
begin
  aRecord.FInstance := nil;
end;

class operator TSmartBitBtn.Finalize(var aRecord: TSmartBitBtn);
begin
  FreeAndNil(aRecord.FInstance);
end;

function TSmartBitBtn.GetValue: TBitBtn;
begin
  if not Assigned(FInstance) then
    raise Exception.Create('TSmartBitBtn not initialized. Call Setup first.');
  Result := FInstance;
end;

procedure TSmartBitBtn.Setup(AParent: TWinControl;
  const ACaption: String; AKind: TBitBtnKind);
begin
  if Assigned(FInstance) then FInstance.Free;
  FInstance := TBitBtn.Create(AParent);
  FInstance.Parent := AParent;
  FInstance.Caption := ACaption;
  FInstance.Kind := AKind;
end;

procedure TSmartBitBtn.Free;
begin
  if Assigned(FInstance) then FreeAndNil(FInstance);
end;

class function TSmartBusyState.Start(AForm: TForm; ACleanup: TRunnerNotify;
  AStatusControl: TControl; ADisableUI: Boolean): TSmartBusyState;
begin
  Result.FForm := AForm;
  Result.FCleanup := ACleanup;
  Result.FDisabledComponents := TList.Create;
  Result.FThrottle := TThrottledUI.Create(100);
  Result.FStatusControl := AStatusControl;
  Result.FOriginalStatus := Result.GetCurrentStatusText;
  Result.SetState(crHourGlass, ADisableUI);
end;

class operator TSmartBusyState.Finalize(var aRecord: TSmartBusyState);
var
  i: Integer = 0;
  PropInfo: PPropInfo;
begin
  if Assigned(aRecord.FForm) then
  begin
    aRecord.SetState(crDefault, False);
    if Assigned(aRecord.FStatusControl) then
      aRecord.UpdateStatusText(aRecord.FOriginalStatus);
    if Assigned(aRecord.FDisabledComponents) then
      for i := 0 to aRecord.FDisabledComponents.Count - 1 do
      begin
        PropInfo := GetPropInfo(
          TComponent(aRecord.FDisabledComponents[i]), 'Enabled');
        if PropInfo <> nil then
          SetOrdProp(TComponent(aRecord.FDisabledComponents[i]), PropInfo, 1);
      end;
    if Assigned(aRecord.FCleanup) then aRecord.FCleanup();
  end;
  // Deliberately NO UpdateStatusText('') here. It used to run
  // unconditionally, immediately undoing the FOriginalStatus restore six
  // lines above - so the status bar ended up blank after every AddFiles,
  // every RenameThisList and every DownLoadEps.
  FreeAndNil(aRecord.FDisabledComponents);
end;

function TSmartBusyState.GetCurrentStatusText: String;
var
  PropInfo: PPropInfo;
begin
  Result := '';
  if not Assigned(FStatusControl) then Exit;
  if FStatusControl is TStatusBar then
  begin
    if TStatusBar(FStatusControl).Panels.Count > 0 then
      Result := TStatusBar(FStatusControl).Panels[0].Text
    else
      Result := TStatusBar(FStatusControl).SimpleText;
  end
  else
  begin
    PropInfo := GetPropInfo(FStatusControl, 'Caption');
    if PropInfo = nil then PropInfo := GetPropInfo(FStatusControl, 'Text');
    if PropInfo <> nil then Result := GetStrProp(FStatusControl, PropInfo);
  end;
end;

procedure TSmartBusyState.Heartbeat(const AStatusMsg: String);
begin
  if not FThrottle.IsReady then Exit;
  if AStatusMsg <> '' then UpdateStatusText(AStatusMsg);
  FThrottle.Check;
  Sleep(1);
end;

class operator TSmartBusyState.Initialize(var aRecord: TSmartBusyState);
begin
  aRecord.FForm := nil;
  aRecord.FCleanup := nil;
  aRecord.FDisabledComponents := nil;
  aRecord.FStatusControl := nil;
  aRecord.FOriginalStatus := '';
end;

procedure TSmartBusyState.SetState(const ACursor: TCursor;
  const DisableUI: Boolean);
var
  i: Integer = 0;
  comp: TComponent;
  PropInfo: PPropInfo;
begin
  if not Assigned(FForm) then Exit;
  for i := 0 to FForm.ComponentCount - 1 do
  begin
    comp := FForm.Components[i];
    PropInfo := GetPropInfo(comp, 'Cursor');
    if PropInfo <> nil then SetOrdProp(comp, PropInfo, ACursor);
    if DisableUI then
    begin
      PropInfo := GetPropInfo(comp, 'Enabled');
      if (PropInfo <> nil) and (GetOrdProp(comp, PropInfo) <> 0) then
      begin
        SetOrdProp(comp, PropInfo, 0);
        FDisabledComponents.Add(comp);
      end;
    end;
  end;
end;

procedure TSmartBusyState.UpdateStatusText(const AText: String);
begin
  if not Assigned(FStatusControl) then Exit;
  if FStatusControl is TStatusBar then
  begin
    with TStatusBar(FStatusControl) do if Panels.Count > 0 then
        Panels[0].Text := AText
      else SimpleText := AText;
  end
  else if IsPublishedProp(FStatusControl, 'Caption') then
    SetPropValue(FStatusControl, 'Caption', AText)
  else if IsPublishedProp(FStatusControl, 'Text') then
    SetPropValue(FStatusControl, 'Text', AText);
end;

procedure TSmartDialogForm.AdjustWidthToContent(Padding: Integer;
  MaxWidth: Integer);
var
  Line: String = '';
  Widest: Integer = 0;
begin
  Value.Canvas.Font.Assign(Value.DialogMemo.Font);
  for Line in Value.DialogMemo.Lines do
    Widest := Max(Widest, Value.Canvas.TextWidth(Line));
  Widest := Widest + Padding;
  if Widest > MaxWidth then Widest := MaxWidth;
  if Widest < 450 then Widest := 450;
  Value.Width := Widest;
end;

class operator TSmartDialogForm.Initialize(var aRecord: TSmartDialogForm);
begin
  aRecord.FInstance := nil;
end;

class operator TSmartDialogForm.Finalize(var aRecord: TSmartDialogForm);
begin
  // RAII ensures the form is freed when the record goes out of scope.
  // Note: We do NOT set CloseAction := caFree because the record handles memory.
  FreeAndNil(aRecord.FInstance);
end;

function TSmartDialogForm.GetValue: TManagedDialogForm;
begin
  if not Assigned(FInstance) then
    FInstance := TManagedDialogForm.CreateNew(nil);
  Result := FInstance;
end;

procedure TSmartDialogForm.Setup(const ACaption: String; AFont: TFont);
begin
  if ACaption.IsNotEmpty then Value.Caption := ACaption;
  if Assigned(AFont) then Value.DialogMemo.Font.Assign(AFont);
end;

function TSmartDialogForm.ShowModal: TModalResult;
begin
  Result := Value.ShowModal;
end;

class operator TSmartEditButton.Initialize(var aRecord: TSmartEditButton);
begin
  aRecord.FInstance := nil;
end;

class operator TSmartEditButton.Finalize(var aRecord: TSmartEditButton);
begin
  FreeAndNil(aRecord.FInstance);
end;

function TSmartEditButton.GetValue: TEditButton;
begin
  if not Assigned(FInstance) then
    raise Exception.Create(
      'TSmartEditButton not initialized. Call Setup first.');
  Result := FInstance;
end;

procedure TSmartEditButton.Setup(AParent: TWinControl;
  const AText: String; AAlign: TAlign);
begin
  if Assigned(FInstance) then FInstance.Free;
  FInstance := TEditButton.Create(AParent);
  FInstance.Parent := AParent;
  FInstance.Text := AText;
  FInstance.Align := AAlign;
  FInstance.ButtonCaption := '...';
  FInstance.ButtonWidth := 23;
end;

procedure TSmartEditButton.Free;
begin
  if Assigned(FInstance) then FreeAndNil(FInstance);
end;

class operator TSmartFileSearcher.Initialize(var aRecord: TSmartFileSearcher);
begin
  aRecord.FHandler := nil;
  aRecord.FInstance := nil;
end;

class operator TSmartFileSearcher.Finalize(var aRecord: TSmartFileSearcher);
begin
  FreeAndNil(aRecord.FHandler);
  FreeAndNil(aRecord.FInstance);
end;

function TSmartFileSearcher.GetValue: TFileSearcher;
begin
  if not Assigned(FInstance) then FInstance := TFileSearcher.Create;
  Result := FInstance;
end;

function TSmartFileSearcher.FindAllThrottled(const APath: String;
  const AMask: String; ASearchSubDirs: Boolean;
  AThrottleIntervalMS: cardinal): TStringList;
begin
  FreeAndNil(FHandler); // guard against re-entrant reuse of the same record
  FHandler := TSearchHandler.Create(AThrottleIntervalMS);
  Value.OnFileFound := @FHandler.OnFound;
  Value.Search(APath, AMask, ASearchSubDirs);
  Result := FHandler.ExtractList;
end;

class operator TSmartFileStream.Initialize(var aRecord: TSmartFileStream);
begin
  aRecord.FInstance := nil;
end;

class operator TSmartFileStream.Finalize(var aRecord: TSmartFileStream);
begin
  FreeAndNil(aRecord.FInstance);
end;

function TSmartFileStream.GetExists: Boolean;
begin
  Result := FileExists(FFileName);
end;

function TSmartFileStream.GetValue: TFileStream;
begin
  if not Assigned(FInstance) then
  begin
    if (FMode <> fmCreate) and not Exists then
      raise EFOpenError.Create('Missing: ' + FFileName);
    FInstance := TFileStream.Create(FFileName, FMode);
  end;
  Result := FInstance;
end;

procedure TSmartFileStream.Open(const AFileName: String; Mode: word);
begin
  if FInstance <> nil then FreeAndNil(FInstance);
  FInstance := TFileStream.Create(AFileName, Mode);
end;

procedure TSmartFileStream.Setup(const AFileName: String; Mode: word);
begin
  FFileName := AFileName;
  FMode := Mode;
  if Assigned(FInstance) then FreeAndNil(FInstance);
end;

class operator TSmartForm.Initialize(var aRecord: TSmartForm);
begin
  aRecord.FInstance := nil;
end;

class operator TSmartForm.Finalize(var aRecord: TSmartForm);
begin
  FreeAndNil(aRecord.FInstance);
end;

function TSmartForm.GetValue: TForm;
begin
  if not Assigned(FInstance) then
    raise Exception.Create(
      'TSmartForm not initialized. Call Setup or SetValue first.');
  Result := FInstance;
end;

procedure TSmartForm.SetValue(AValue: TForm);
begin
  if Assigned(FInstance) and (FInstance <> AValue) then FInstance.Free;
  FInstance := AValue;
end;

procedure TSmartForm.Setup(AOwner: TComponent);
begin
  if Assigned(FInstance) then FreeAndNil(FInstance);
  // TForm.CreateNew is called directly against the concrete class, so it
  // dispatches correctly and runs TCustomForm/TForm's full construction
  // chain - unlike a generic metaclass-based Create, which would not.
  FInstance := TForm.CreateNew(AOwner);
end;

class function TSmartHTTP.CanReachDNS(const AAddr: String): Boolean;
var
  s: LongInt = 0;
  {$IFDEF UNIX}
  Addr: TInetSockAddr;
  Timeout: timeval;
  {$ENDIF}
  {$IFDEF WINDOWS}
  Addr: sockaddr_in;
  Timeout: Integer;
  {$ENDIF}
begin
  Result := False;
  s := fpSocket(AF_INET, SOCK_STREAM, 0);
  if s <> -1 then try
    {$IFDEF UNIX}
    Addr.sin_family := AF_INET;
    Addr.sin_port := htons(53);
    Addr.sin_addr := StrToNetAddr(AAddr);
    Timeout.tv_sec := 0;
    Timeout.tv_usec := 500000;
    fpSetSockOpt(s, SOL_SOCKET, SO_SNDTIMEO, @Timeout, SizeOf(Timeout));
    {$ENDIF}
    {$IFDEF WINDOWS}
    Addr.sin_family := AF_INET;
    Addr.sin_port := htons(53);
    Addr.sin_addr.s_addr := inet_addr(PChar(AAddr));
    Timeout := 500; // 500 ms
    fpSetSockOpt(s, SOL_SOCKET, SO_SNDTIMEO, @Timeout, SizeOf(Timeout));
    {$ENDIF}
    if fpConnect(s, @Addr, SizeOf(Addr)) = 0 then Result := True;
  finally
    {$IFDEF WINDOWS}CloseSocket(s);{$ELSE}fpClose(S);{$ENDIF}
  end;
end;

class function TSmartHTTP.Available: Boolean;
begin
  // 1.1.1.1 (Cloudflare) first, as before. A single blocked/unreachable
  // resolver shouldn't read as "no internet" - some networks block or
  // hijack specific well-known DNS IPs (policy, captive portals, a
  // transient outage at one provider) while the internet is otherwise
  // fine, so 8.8.8.8 (Google) is tried as a fallback before giving up.
  // Note this doesn't cover networks that block public DNS IPs as a
  // category, since both addresses are well-known targets for that kind
  // of blocking - it only helps when the *specific* address is the
  // problem, not the concept of reaching a public resolver at all.
  Result := CanReachDNS('1.1.1.1') or CanReachDNS('8.8.8.8');
end;

class operator TSmartHTTP.Initialize(var aSmart: TSmartHTTP);
begin
  aSmart.FClient := nil;
  aSmart.FResponseCode := 0;
end;

class operator TSmartHTTP.Finalize(var aSmart: TSmartHTTP);
begin
  FreeAndNil(aSmart.FClient);
end;

function TSmartHTTP.Get(const AURL: String; out AContent: String): Boolean;
begin
  Result := False;
  FLastError := '';
  if not Heal then
  begin
    AContent := FLastError;
    Exit(False);
  end;
  try
    AContent := GetClient.Get(AURL);
    FResponseCode := FClient.ResponseStatusCode;
    Result := (FResponseCode = 200) or (FResponseCode = 202);
    if not Result then FLastError :=
        'Unexpected Status: ' + IntToStr(FResponseCode);
  except
    on E: Exception do
    begin
      AContent := E.Message;
      FLastError := E.Message;
      FResponseCode := 500;
    end;
  end;
end;

function TSmartHTTP.GetClient: TFPHTTPClient;
begin
  if not Assigned(FClient) then
  begin
    FClient := TFPHTTPClient.Create(nil);
    FClient.AllowRedirect := True;
    FClient.IOTimeout := 5000;
    FClient.AddHeader('User-Agent', 'Mozilla/5.0 (Lazarus; Ubuntu)');
  end;
  Result := FClient;
end;

function TSmartHTTP.GetIfNewer(const AURL: String; ALocalLastMod: TDateTime;
  out AContent: String): Boolean;
var
  Client: TFPHTTPClient;
begin
  Result := False;
  if not Available then Exit;
  if not Heal then Exit;
  Client := GetClient;
  Client.RequestHeaders.Clear;
  Client.AddHeader('User-Agent', 'Mozilla/5.0 (Lazarus; Ubuntu)');
  if ALocalLastMod > 1.0 then
    Client.AddHeader('If-Modified-Since', ToRFC1123(ALocalLastMod));
  try
    AContent := Client.Get(AURL);
    FResponseCode := Client.ResponseStatusCode;
    Result := (FResponseCode = 200) or (FResponseCode = 202);
  except
    on E: Exception do
    begin
      AContent := E.Message;
      FResponseCode := 500;
    end;
  end;
end;

function TSmartHTTP.Heal: Boolean;
begin
  Result := True;
  uUtils.EnsureOpenSSLDllsPresent;
  try
    InitSSLInterface;
  except
    on E: Exception do
    begin
      // Mirrors the retry pattern in uMain.pas's InitSSLInterface call
      // sites: on "Could not initialize OpenSSL", attempt to (re-)extract
      // libeay32.dll/ssleay32.dll and try exactly once more before giving
      // up. EnsureOpenSSLDllsPresent lives in uUtils.pas (not TForm1)
      // specifically so this unit - which cannot see TForm1's methods -
      // can share the same extraction logic instead of duplicating it.
      if UTF8ContainsText(E.Message, 'Could not initialize OpenSSL') and
        uUtils.EnsureOpenSSLDllsPresent then
      begin
        try
          InitSSLInterface;
        except
          on E2: Exception do Result := False;
        end;
      end
      else
        Result := False;
    end;
  end;
end;

function TSmartHTTP.ToRFC1123(ADate: TDateTime): String;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.ShortMonthNames[1] := 'Jan'; FS.ShortMonthNames[2] := 'Feb';
  FS.ShortMonthNames[3] := 'Mar'; FS.ShortMonthNames[4] := 'Apr';
  FS.ShortMonthNames[5] := 'May'; FS.ShortMonthNames[6] := 'Jun';
  FS.ShortMonthNames[7] := 'Jul'; FS.ShortMonthNames[8] := 'Aug';
  FS.ShortMonthNames[9] := 'Sep'; FS.ShortMonthNames[10] := 'Oct';
  FS.ShortMonthNames[11] := 'Nov'; FS.ShortMonthNames[12] := 'Dec';
  FS.ShortDayNames[1] := 'Sun'; FS.ShortDayNames[2] := 'Mon';
  FS.ShortDayNames[3] := 'Tue'; FS.ShortDayNames[4] := 'Wed';
  FS.ShortDayNames[5] := 'Thu'; FS.ShortDayNames[6] := 'Fri';
  FS.ShortDayNames[7] := 'Sat';
  Result := FormatDateTime(HTTPDefs.HTTPDateFmt, ADate, FS);
end;

class operator TSmartHtmlViewer.Initialize(var aRecord: TSmartHtmlViewer);
begin
  aRecord.FBridge := TViewerBridge.Create;
  aRecord.FInstance := nil;
end;

class operator TSmartHtmlViewer.Finalize(var aRecord: TSmartHtmlViewer);
begin
  FreeAndNil(aRecord.FBridge);
end;

procedure TSmartHtmlViewer.FreeInstance;
begin
  if Assigned(FInstance) then
  begin
    THtmlViewer(FInstance).Clear;
    FreeAndNil(FInstance);
  end;
end;

function TSmartHtmlViewer.GetValue: THtmlViewer;
begin
  Result := THtmlViewer(FInstance);
end;

procedure TSmartHtmlViewer.LoadFromFile(const AFileName: String);
begin
  if Assigned(FInstance) then
    THtmlViewer(FInstance).LoadFromFile(UnicodeString(AFileName));
end;

procedure TSmartHtmlViewer.LoadFromString(const AHtml: String;
  const ABasePath: String);
begin
  if Assigned(FInstance) then
  begin
    if ABasePath <> '' then THtmlViewer(FInstance).LoadFromString(
        UnicodeString(AHtml), UnicodeString(ABasePath))
    else
      THtmlViewer(FInstance).LoadFromString(
        UnicodeString(AHtml),
        ExtractFilePath(UnicodeString(ParamStr(0))));
  end;
end;

// Stored on the bridge rather than wired straight onto the viewer: wiring
// it directly replaced the bridge (so unhandled web links stopped opening),
// did nothing at all before Setup had created the viewer, and was quietly
// undone by the next Setup, which re-wires the bridge.
procedure TSmartHtmlViewer.SetOnClick(AValue: ThtLinkClickEvent);
begin
  FBridge.UserClick := AValue;
end;

procedure TSmartHtmlViewer.Setup(AParent: TWinControl; AAlign: TAlign);
var
  M: TMethod;
begin
  if not Assigned(FInstance) then FInstance := THtmlViewer.Create(AParent);
  FInstance.Parent := AParent;
  FInstance.Align := AAlign;
  InternalSetLinkClick(FInstance, @FBridge.LinkClick);
  M.Code := @TViewerBridge.TargetClick;
  M.Data := FBridge;
  InternalSetTargetClick(FInstance, M);
end;

class operator TSmartIni.Initialize(var aRecord: TSmartIni);
begin
  aRecord.FInstance := nil;
end;

class operator TSmartIni.Finalize(var aRecord: TSmartIni);
begin
  // No UpdateFile here. With TIniFile's default CacheUpdates = False every
  // write has already reached the disk, and with CacheUpdates = True,
  // TIniFile.Destroy saves what is still pending by itself. An
  // unconditional UpdateFile wrote the whole in-memory copy back no matter
  // what - re-creating an ini the user had just deleted ("Delete filey.ini
  // File"), and erasing anything another instance had written since this
  // one opened the file.
  try
    FreeAndNil(aRecord.FInstance);
  except
    // swallow: Finalize must not raise during scope teardown
    aRecord.FInstance := nil;
  end;
end;

procedure TSmartIni.CleanDuplicateKeys(const ASection, AKey: String);
var
  SL: TSmartStrings;
  i: Integer = 0;
begin
  Value.ReadSectionValues(ASection, SL.Value);
  for i := SL.Value.Count - 1 downto 0 do
    if SameText(SL.Value.Names[i], AKey) then Value.DeleteKey(ASection, AKey);
end;

// True if AText matches AMask, where '*' stands for any run of characters
// (none included) and '?' for exactly one. Both are expected already
// upper-cased. Works on UTF-16 code units, which is exact for everything
// outside the rare characters beyond the Basic Multilingual Plane.
function IniKeyMatches(const AText, AMask: UnicodeString): Boolean;
var
  iMask, iMaskStar, iText, iTextStar: Integer;
begin
  iText := 1;
  iMask := 1;
  iMaskStar := 0;
  iTextStar := 0;
  while iText <= Length(AText) do
  begin
    if (iMask <= Length(AMask)) and (AMask[iMask] = '*') then
    begin
      // Remember the star; first try matching it to nothing.
      iMaskStar := iMask;
      iTextStar := iText;
      Inc(iMask);
    end
    else if (iMask <= Length(AMask)) and
      ((AMask[iMask] = '?') or (AMask[iMask] = AText[iText])) then
    begin
      Inc(iText);
      Inc(iMask);
    end
    else if iMaskStar > 0 then
    begin
      // Mismatch after a star: let the star swallow one more character.
      iMask := iMaskStar + 1;
      Inc(iTextStar);
      iText := iTextStar;
    end
    else
      Exit(False);
  end;
  while (iMask <= Length(AMask)) and (AMask[iMask] = '*') do Inc(iMask);
  Result := iMask > Length(AMask);
end;

function TSmartIni.DeleteKeys(const ASection: String;
  const AMasks: array of String): Integer;
var
  bWasCaching: Boolean;
  i: Integer;
  Keys, Remaining: TSmartStrings;
  Masks: array of UnicodeString;
  sKey: String;
  uKey: UnicodeString;
begin
  Result := 0;
  if (Length(AMasks) = 0) or not Exists then Exit;
  // Upper-cased once, here, rather than once per key.
  SetLength(Masks, Length(AMasks));
  for i := 0 to High(AMasks) do
    Masks[i] := UTF8Decode(UTF8UpperCase(AMasks[i]));
  Value.ReadSection(ASection, Keys.Value);
  if Keys.Value.Count = 0 then Exit;
  // Each DeleteKey would otherwise rewrite the whole file.
  bWasCaching := Value.CacheUpdates;
  Value.CacheUpdates := True;
  try
    for sKey in Keys.Value do
    begin
      uKey := UTF8Decode(UTF8UpperCase(sKey));
      for i := 0 to High(Masks) do
        if IniKeyMatches(uKey, Masks[i]) then
        begin
          Value.DeleteKey(ASection, sKey);
          Inc(Result);
          Break;
        end;
    end;
    if Result > 0 then
    begin
      Value.ReadSection(ASection, Remaining.Value);
      if Remaining.Value.Count = 0 then Value.EraseSection(ASection);
    end;
  finally
    // Back to how it was; turning caching off writes the file now if
    // anything was deleted.
    Value.CacheUpdates := bWasCaching;
  end;
end;

function TSmartIni.EffectiveFileName: String;
begin
  // The default was ChangeFileExt(ParamStr(0), '.ini') alone - next to the
  // executable, which may not be writable (e.g. /usr/bin on Linux, or a
  // locked-down Program Files on Windows). OpPath (uUtils.pas) is the
  // same writable, guaranteed-to-exist config directory every other
  // un-Setup path in this app already uses. The filename itself is still
  // derived generically from the executable's own name, not hardcoded.
  // GetExists used to keep the old next-to-the-executable default, so it
  // could report on a different file from the one Value opened.
  if FFileName.IsEmpty then
    FFileName := CombinePath(OpPath, efn(ChangeFileExt(ParamStr(0), '.ini')));
  Result := FFileName;
end;

function TSmartIni.GetExists: Boolean;
begin
  Result := FileExists(EffectiveFileName);
end;

function TSmartIni.GetValue: TIniFile;
begin
  if not Assigned(FInstance) then
    FInstance := TIniFile.Create(EffectiveFileName);
  Result := FInstance;
end;

procedure TSmartIni.HardRemoveSection(const ASection: String);
var
  SL: TSmartStrings;
  i: Integer = 0;
  InTarget: Boolean = False;
  Header: String = '';
begin
  if not Exists then Exit;
  if Assigned(FInstance) then FreeAndNil(FInstance);
  Header := '[' + UTF8LowerCase(Trim(ASection)) + ']';
  SL.Value.LoadFromFile(FFileName);
  InTarget := False;
  for i := SL.Value.Count - 1 downto 0 do
  begin
    if Pos('[', SL.Value[i]) = 1 then
      InTarget := (UTF8LowerCase(Trim(SL.Value[i])) = Header);
    if InTarget then SL.Value.Delete(i);
  end;
  SL.Value.SaveToFile(FFileName);
end;

function TSmartIni.RemoveFile: Boolean;
begin
  // Forget the in-memory copy first, without saving it: CacheUpdates is
  // turned off so TIniFile.Destroy has nothing pending to write.
  if Assigned(FInstance) then
  begin
    FInstance.CacheUpdates := False;
    FreeAndNil(FInstance);
  end;
  if FileExists(EffectiveFileName) then SysUtils.DeleteFile(FFileName);
  Result := not FileExists(FFileName);
end;

procedure TSmartIni.SetFileName(const Value: String);
begin
  if FFileName <> Value then
  begin
    FFileName := Value;
    FreeAndNil(FInstance); // Next call to GetValue will reopen with new path
    DebugLog('FFileName= ' + FFileName);
  end;
end;

procedure TSmartIni.Setup(const AFileName: String);
begin
  if AFileName.IsEmpty then Exit;
  Self.FileName := AFileName;
end;

procedure TSmartIni.WriteClean(const ASection, AKey, AValue: String);
var
  SL: TSmartStrings;
begin
  Self.CleanDuplicateKeys(ASection, AKey);
  Value.ReadSection(ASection, SL.Value);
  if SL.Value.Count = 0 then Value.EraseSection(ASection);
  Value.WriteString(ASection, AKey, AValue);
end;

procedure TSmartIni.WritePairs(const ASection: String;
  const APairs: array of TConfigPair);
var
  Pair: TConfigPair;
begin
  Pair := Default(TConfigPair);
  for Pair in APairs do Self.WriteClean(ASection, Pair.Key, Pair.Value);
  Value.UpdateFile;
end;

class operator TSmartIpHtmlPanel.Initialize(var aRecord: TSmartIpHtmlPanel);
begin
  aRecord.FInstance := nil;
end;

class operator TSmartIpHtmlPanel.Finalize(var aRecord: TSmartIpHtmlPanel);
begin
  FreeAndNil(aRecord.FInstance);
end;

function TSmartIpHtmlPanel.GetValue: TIpHtmlPanel;
begin
  if not Assigned(FInstance) then FInstance := TIpHtmlPanel.Create(nil);
  Result := FInstance;
end;

procedure TSmartIpHtmlPanel.LoadFromStream(AStream: TStream);
begin
  if not Assigned(AStream) then Exit;
  AStream.Position := 0;
  Value.SetHtmlFromStream(AStream);
end;

procedure TSmartIpHtmlPanel.Release;
begin
  // Nil the pointer; the record no longer owns it, so Finalize won't free it
  FInstance := nil;
end;

procedure TSmartIpHtmlPanel.Setup(AParent: TWinControl; AAlign: TAlign);
begin
  Value.Parent := AParent;
  Value.Align := AAlign;
end;

class operator TSmartManagedDialog.Initialize(
  var aRecord: TSmartManagedDialog);
begin
  aRecord.FInstance := nil;
  aRecord.FDialogID := '';
end;

class operator TSmartManagedDialog.Finalize(
  var aRecord: TSmartManagedDialog);
begin
  FreeAndNil(aRecord.FInstance);
end;

function TSmartManagedDialog.Execute: Boolean;
begin
  Result := False;
  if IsSilenced then Exit(True);
  if Value.Execute then
  begin
    Result := True;
    if tfVerificationFlagChecked in Value.Flags then SetSilenced(True);
  end;
end;

function TSmartManagedDialog.GetIsSilenced: Boolean;
begin
  if FDialogID.IsEmpty then Exit(False);
  // AppIni, not a TSmartIni of its own: see AppIni's declaration.
  Result := AppIni.Value.ReadBool('DialogSilence', FDialogID, False);
end;

function TSmartManagedDialog.GetValue: TTaskDialog;
begin
  if not Assigned(FInstance) then FInstance := TTaskDialog.Create(nil);
  Result := FInstance;
end;

procedure TSmartManagedDialog.HandleHyperlink(Sender: TObject);
begin
  if Assigned(Sender) and (Sender is TTaskDialog) then
    OpenURL(TTaskDialog(Sender).URL);
end;

procedure TSmartManagedDialog.SetSilenced(AValue: Boolean);
begin
  if FDialogID <> '' then
    AppIni.Value.WriteBool('DialogSilence', FDialogID, AValue);
end;

procedure TSmartManagedDialog.Setup(const ADialogID: String;
  AOwner: TComponent);
begin
  FDialogID := ADialogID;
  if Assigned(FInstance) then FreeAndNil(FInstance);
  FInstance := TTaskDialog.Create(AOwner);
  FInstance.Flags := FInstance.Flags + [tfEnableHyperlinks];
  FInstance.VerificationText := 'Don''t show this message again';
  Value.OnHyperlinkClicked := @HandleHyperlink;
end;

procedure TSmartManagedDialog.SetTexts(
  const ATitle, AInstruction, AContent: String);
begin
  Value.Caption := ATitle;
  Value.Text := '<big>' + AInstruction + '</big>';
  Value.Title := AContent;
end;

class operator TSmartMemoryStream.Initialize(var aRecord: TSmartMemoryStream);
begin
  aRecord.FStream := nil;
end;

class operator TSmartMemoryStream.Finalize(var aRecord: TSmartMemoryStream);
begin
  if aRecord.FStream <> nil then
  begin
    FreeAndNil(aRecord.FStream);
    // FActiveCount is a class var shared by every instance across every
    // thread (RunEx's async/batch modes now create/free these concurrently
    // on background threads), so it must be updated atomically rather than
    // with a plain Dec.
    InterlockedDecrement(FActiveCount);
  end;
end;

class function TSmartMemoryStream.ActiveCount: Integer;
begin
  Result := FActiveCount;
end;

function TSmartMemoryStream.AsString: String;
begin
  if (not Assigned(FStream)) or (FStream.Size = 0) then Exit('');
  SetLength(Result, FStream.Size);
  FStream.Position := 0;
  FStream.Read(Result[1], FStream.Size);
  // Process output (e.g. from RunEx) is UTF-8 on every platform we target.
  // Tag the buffer explicitly rather than leaving it to inherit whatever
  // the system default codepage happens to be (which is not guaranteed to
  // be UTF-8 on Windows). This only relabels the bytes already read above;
  // it does not re-encode or copy them.
  SetCodePage(rawbytestring(Result), CP_UTF8, False);
end;

procedure TSmartMemoryStream.Clear;
begin
  if Assigned(FStream) then FStream.Clear;
end;

function TSmartMemoryStream.GetValue: TMemoryStream;
begin
  if FStream = nil then
  begin
    FStream := TMemoryStream.Create;
    InterlockedIncrement(FActiveCount);
  end;
  Result := FStream;
end;

procedure TSmartMemoryStream.LoadFromFile(const AFileName: String);
var
  LFile: TSmartFileStream;
begin
  if FileExists(AFileName) then
  begin
    LFile.Open(AFileName, fmOpenRead or fmShareDenyNone);
    Value.Clear;
    Value.CopyFrom(LFile.Value, LFile.Value.Size);
    Value.Position := 0;
  end;
end;

procedure TSmartMemoryStream.SetValue(AValue: TMemoryStream);
begin
  if (FStream <> nil) and (FStream <> AValue) then
  begin
    FStream.Free;
    InterlockedDecrement(FActiveCount);
  end;
  if (FStream = nil) and (AValue <> nil) then
    InterlockedIncrement(FActiveCount);
  FStream := AValue;
end;

class operator TSmartPanel.Initialize(var aRecord: TSmartPanel);
begin
  aRecord.FInstance := nil;
end;

class operator TSmartPanel.Finalize(var aRecord: TSmartPanel);
begin
  FreeAndNil(aRecord.FInstance);
end;

procedure TSmartPanel.Free;
begin
  if Assigned(FInstance) then FreeAndNil(FInstance);
end;

function TSmartPanel.GetValue: TPanel;
begin
  if not Assigned(FInstance) then
    raise Exception.Create('TSmartPanel not initialized. Call Setup first.');
  Result := FInstance;
end;

procedure TSmartPanel.Setup(AParent: TWinControl; AAlign: TAlign);
begin
  if Assigned(FInstance) then FInstance.Free;
  FInstance := TPanel.Create(AParent);
  FInstance.Parent := AParent;
  FInstance.Align := AAlign;
  FInstance.BevelOuter := bvNone;
  FInstance.Caption := '';
end;

class operator TSmartProcess.Initialize(var aRecord: TSmartProcess);
begin
  aRecord.FInstance := nil;
end;

class operator TSmartProcess.Finalize(var aRecord: TSmartProcess);
begin
  if Assigned(aRecord.FInstance) then
  begin
    if aRecord.FInstance.Running then aRecord.FInstance.Terminate(0);
    FreeAndNil(aRecord.FInstance);
  end;
end;

function TSmartProcess.GetValue: TProcess;
begin
  if not Assigned(FInstance) then FInstance := TProcess.Create(nil);
  Result := FInstance;
end;

procedure TSmartProcess.ParseCommandLine(const AValue: String);
begin
  {$PUSH}{$WARNINGS OFF}
  Value.Options := Value.Options + [poUsePipes, poNoConsole];
  Value.CommandLine := AValue;
  {$POP}
end;

procedure TSmartProcess.QuickRun(const AExecutable: String;
  const AArgs: array of String; AWait: Boolean);
var
  s: String = '';
begin
  GetValue.Executable := AExecutable;
  GetValue.Parameters.Clear;
  for s in AArgs do GetValue.Parameters.Add(s);
  if AWait then GetValue.Options := GetValue.Options + [poWaitOnExit]
  else GetValue.Options := GetValue.Options - [poWaitOnExit];
  GetValue.Execute;
end;

class operator TSmartRegEx.Initialize(var aRecord: TSmartRegEx);
begin
  aRecord.FEngine := nil;
end;

class operator TSmartRegEx.Finalize(var aRecord: TSmartRegEx);
begin
  FreeAndNil(aRecord.FEngine);
end;

procedure TSmartRegEx.FreeInstance;
begin
  FreeAndNil(FEngine);
end;

function TSmartRegEx.GetValue: TRegExpr;
begin
  if not Assigned(FEngine) then FEngine := TRegExpr.Create;
  Result := FEngine;
end;

procedure TSmartRegEx.SetValue(AValue: TRegExpr);
begin
  FEngine := AValue;
end;

{$IFDEF WINDOWS}
class operator TSmartRegistry.Initialize(var aRecord: TSmartRegistry);
begin
  aRecord.FInstance := nil;
end;

class operator TSmartRegistry.Finalize(var aRecord: TSmartRegistry);
begin
  FreeAndNil(aRecord.FInstance);
end;

function TSmartRegistry.GetValue: TRegistry;
begin
  if not Assigned(FInstance) then FInstance := TRegistry.Create(KEY_READ);
  Result := FInstance;
end;

function TSmartRegistry.ReadStringDefault(
  const Name, Default: String): String;
begin
  try
    if Value.ValueExists(Name) then Result := Value.ReadString(Name)
    else Result := Default;
  except
    Result := Default;
  end;
end;

function TSmartRegistry.TryOpenKey(const Key: String;
  CanCreate: Boolean): Boolean;
begin
  try
    Result := Value.OpenKey(Key, CanCreate);
  except
    Result := False;
  end;
end;
{$ENDIF}

class operator TSmartResourceStream.Initialize(
  var aRecord: TSmartResourceStream);
begin
  aRecord.FStream := nil;
end;

class operator TSmartResourceStream.Finalize(
  var aRecord: TSmartResourceStream);
begin
  if aRecord.FStream <> nil then FreeAndNil(aRecord.FStream);
end;

function TSmartResourceStream.GetValue: TResourceStream;
begin
  if not Assigned(FStream) then
    raise Exception.Create(
      'TSmartResourceStream not initialized. Call Setup first.');
  Result := FStream;
end;

procedure TSmartResourceStream.Setup(AInstance: TLCLHandle;
  const AResName: String; AResType: PChar);
begin
  if FStream <> nil then FreeAndNil(FStream);
  FStream := TResourceStream.Create(AInstance, AResName, AResType);
end;

class operator TSmartStringStream.Initialize(
  var aRecord: TSmartStringStream);
begin
  aRecord.FInstance := nil;
  aRecord.FInitialContent := '';
end;

class operator TSmartStringStream.Finalize(var aRecord: TSmartStringStream);
begin
  FreeAndNil(aRecord.FInstance);
end;

function TSmartStringStream.GetValue: TStringStream;
begin
  if not Assigned(FInstance) then
    FInstance := TStringStream.Create(FInitialContent);
  Result := FInstance;
end;

procedure TSmartStringStream.Setup(const AContent: String);
begin
  FInitialContent := AContent;
  if Assigned(FInstance) then
  begin
    FInstance.Size := 0;
    FInstance.WriteString(AContent);
    FInstance.Position := 0;
  end;
end;

class operator TSmartSynEdit.Initialize(var aRecord: TSmartSynEdit);
begin
  aRecord.FInstance := nil;
end;

class operator TSmartSynEdit.Finalize(var aRecord: TSmartSynEdit);
begin
  FreeAndNil(aRecord.FInstance);
end;

procedure TSmartSynEdit.Free;
begin
  if Assigned(FInstance) then FreeAndNil(FInstance);
end;

function TSmartSynEdit.GetValue: TCustomControl;
begin
  if not Assigned(FInstance) then
    raise Exception.Create('TSmartSynEdit not initialized. Call Setup first.');
  Result := FInstance;
end;

procedure TSmartSynEdit.Setup(AParent: TWinControl; AAlign: TAlign);
begin
  if Assigned(FInstance) then FInstance.Free;
  FInstance := TSynEdit.Create(AParent);
  FInstance.Parent := AParent;
  FInstance.Align := AAlign;
end;

// Turns a caption like 'uUtils.pas' into a valid, stable component Name
// ('tsSrc_uUtils_pas') so dynamically-created source-code tab sheets can be
// identified by SaveSettings/LoadConfiguration across sessions, rather than
// by page position (which shifts if files are added/removed/reordered).
// Falls back to a numeric suffix in the rare case of a collision, since
// component Names must be unique within their Owner.
function MakeUniqueTabSheetName(AOwner: TComponent;
  const ACaption: String): String;
var
  i: Integer;
  Sanitized: String;
  Ch: char;
  Candidate: String;
  Suffix: Integer;
begin
  Sanitized := '';
  for i := 1 to Length(ACaption) do
  begin
    Ch := ACaption[i];
    if (Ch in ['A'..'Z', 'a'..'z', '0'..'9', '_']) then
      Sanitized := Sanitized + Ch
    else
      Sanitized := Sanitized + '_';
  end;
  if (Sanitized <> '') and (Sanitized[1] in ['0'..'9']) then
    Sanitized := '_' + Sanitized;
  Candidate := 'tsSrc_' + Sanitized;
  Suffix := 1;
  while Assigned(AOwner) and Assigned(AOwner.FindComponent(Candidate)) do
  begin
    Inc(Suffix);
    Candidate := 'tsSrc_' + Sanitized + '_' + IntToStr(Suffix);
  end;
  Result := Candidate;
end;

class operator TSmartTabSheet.Initialize(var aRecord: TSmartTabSheet);
begin
  aRecord.FInstance := nil;
end;

class operator TSmartTabSheet.Finalize(var aRecord: TSmartTabSheet);
begin
  if Assigned(aRecord.FInstance) then
  begin
    // LCL's Free on a TabSheet automatically removes it from its PageControl
    aRecord.FInstance.Free;
    aRecord.FInstance := nil;
  end;
end;

procedure TSmartTabSheet.Free;
begin
  FreeAndNil(FInstance);
end;

function TSmartTabSheet.GetValue: TTabSheet;
begin
  if not Assigned(FInstance) then
    raise Exception.Create(
      'TSmartTabSheet not initialized. Call Setup first.');
  Result := FInstance;
end;

procedure TSmartTabSheet.Setup(APageControl: TPageControl;
  const ACaption: String);
begin
  if Assigned(FInstance) then FInstance.Free;
  FInstance := TTabSheet.Create(APageControl);
  FInstance.PageControl := APageControl;
  if ACaption <> '' then
  begin
    FInstance.Caption := ACaption;
    FInstance.Name := MakeUniqueTabSheetName(APageControl, ACaption);
  end;
end;

class operator TSmartUnzipper.Initialize(var aRecord: TSmartUnzipper);
begin
  aRecord.FInstance := nil;
  aRecord.FOwner := nil;
end;

class operator TSmartUnzipper.Finalize(var aRecord: TSmartUnzipper);
begin
  FreeAndNil(aRecord.FInstance);
end;

function TSmartUnzipper.GetValue: TUnZipper;
begin
  if not Assigned(FInstance) then FInstance := TUnZipper.Create;
  Result := FInstance;
end;

procedure TSmartUnzipper.QuickExtract(const AZipFile, ADestDir: String);
begin
  GetValue.FileName := AZipFile;
  GetValue.OutputPath := ADestDir;
  GetValue.UnZipAllFiles;
end;

function TSmartUnzipper.QuickExtractToStream(AZipSourceStream: TStream;
  const AZipName, AInternalFile: String): TMemoryStream;
var
  Unzipper: TUnZipper;
  Bridge: TZipToStreamBridge;
  FileList: TStringList;
begin
  Result := nil;
  Bridge := TZipToStreamBridge.Create(AZipSourceStream, AInternalFile);
  Unzipper := TUnZipper.Create;
  FileList := TStringList.Create;
  try
    AZipSourceStream.Position := 0;
    Unzipper.FileName := AZipName;
    Unzipper.OnOpenInputStream := @Bridge.DoOpenInput;
    Unzipper.OnCloseInputStream := @Bridge.DoCloseInput;
    Unzipper.OnCreateStream := @Bridge.DoCreateStream;
    Unzipper.OnDoneStream := @Bridge.DoDoneStream;
    AZipSourceStream.Position := 0;
    Unzipper.Examine;
    FileList.Add(AInternalFile);
    Unzipper.UnZipFiles(FileList);
    if Assigned(Bridge.MemoryStream) then
    begin
      Result := Bridge.MemoryStream;
      Result.Position := 0;
      Bridge.ReleaseOwnership;
    end;
  finally
    FileList.Free;
    Unzipper.Free;
    Bridge.Free;
  end;
end;

procedure TSmartUnzipper.Setup(AOwner: TComponent);
begin
  FOwner := AOwner;
  if Assigned(FInstance) then FreeAndNil(FInstance);
end;

class operator TSmartVersion.Initialize(var aRecord: TSmartVersion);
begin
  aRecord.FInstance := TVersion.Create;
end;

class operator TSmartVersion.Finalize(var aRecord: TSmartVersion);
begin
  FreeAndNil(aRecord.FInstance);
end;

class operator TSmartVersionInfo.Initialize(var Dest: TSmartVersionInfo);
begin
  Dest.FInfo := TFileVersionInfo.Create(nil);
  Dest.FLoaded := False;
end;

class operator TSmartVersionInfo.Finalize(var Dest: TSmartVersionInfo);
begin
  FreeAndNil(Dest.FInfo);
end;

function TSmartVersionInfo.GetVersionString: String;
begin
  if not FLoaded then Exit('0.0.0.0');
  Result := FInfo.VersionStrings.Values['FileVersion'];
  if Result = '' then Result := FInfo.VersionStrings.Values['ProductVersion'];
end;

function TSmartVersionInfo.LoadLocalFileInfo: Boolean;
begin
  try
    FInfo.FileName := ParamStr(0);
    FInfo.ReadFileInfo;
    FLoaded := True;
  except
    FLoaded := False;
  end;
  Result := FLoaded;
end;

class operator TSmartZipper.Initialize(var aRecord: TSmartZipper);
begin
  aRecord.FInstance := nil;
  aRecord.FOwner := nil;
end;

class operator TSmartZipper.Finalize(var aRecord: TSmartZipper);
begin
  FreeAndNil(aRecord.FInstance);
end;

function TSmartZipper.GetValue: TZipper;
begin
  if not Assigned(FInstance) then FInstance := TZipper.Create;
  Result := FInstance;
end;

procedure TSmartZipper.Setup(AOwner: TComponent);
begin
  FOwner := AOwner;
  if Assigned(FInstance) then FreeAndNil(FInstance);
end;

class operator TSmart.Initialize(var aRecord: TSmart);
begin
  aRecord.FInstance := nil;
  aRecord.FOwner := nil;
end;

class operator TSmart.Finalize(var aRecord: TSmart);
begin
  if Assigned(aRecord.FInstance) then
  begin
    aRecord.FInstance.Free;
    aRecord.FInstance := nil;
  end;
end;

procedure TSmart.FreeInstance;
begin
  if Assigned(FInstance) then
  begin
    if Assigned(FInstance) then
    begin
      FInstance.Free;
      FInstance := nil;
    end;
  end;
end;

function TSmart.GetValue: T;
begin
  if not Assigned(FInstance) then
    // Call through the generic type T itself (not an untyped TClass
    // variable): T.Create specialises to the real, concrete constructor
    // (e.g. TBitmap.Create) for each instantiation and runs its full
    // initialisation chain. Calling "TClass(T).Create" instead is a
    // classic FPC/Delphi trap: TObject.Create is not virtual, so a call
    // through a plain TClass variable resolves statically to
    // TObject.Create alone. NewInstance still allocates a correctly
    // sized block (it *is* virtual), but none of TGraphic/TCustomBitmap's
    // own constructor code runs, leaving fields such as FSharedImage nil
    // and causing a GPF the moment something like Canvas is touched.
    FInstance := T.Create;
  Result := FInstance;
end;

procedure TSmart.SetValue(AValue: T);
begin
  if Assigned(FInstance) and (FInstance <> AValue) then FInstance.Free;
  FInstance := AValue;
end;

procedure TSmart.Setup(AOwner: TComponent);
begin
  FOwner := AOwner;
  if Assigned(FInstance) then FreeAndNil(FInstance);
end;

function TSmart.TakeValue: T;
begin
  Result := FInstance;
  FInstance := nil;
end;

class operator TSourceViewManager.Initialize(
  var {%H-}aRecord: TSourceViewManager);
begin
  // Dynamic arrays initialise to length 0 – no extra work needed
end;

class operator TSourceViewManager.Finalize(var aRecord: TSourceViewManager);
begin
  aRecord.Clear;
end;

procedure TSourceViewManager.AddSourceView(APageControl: TPageControl;
  const ATitle, APath: String);
var
  NewIdx: Integer = 0;
begin
  NewIdx := Length(FTabSheets);
  SetLength(FTabSheets, NewIdx + 1);
  SetLength(FBitBtnNexts, NewIdx + 1);
  SetLength(FBitBtnPrevs, NewIdx + 1);
  SetLength(FEditButtons, NewIdx + 1);
  SetLength(FPanels, NewIdx + 1);
  SetLength(FSynEdits, NewIdx + 1);

  FTabSheets[NewIdx].Setup(APageControl, ATitle);
  FBitBtnNexts[NewIdx].Setup(FTabSheets[NewIdx].Value, ATitle, bkCustom);
  FBitBtnPrevs[NewIdx].Setup(FTabSheets[NewIdx].Value, ATitle, bkCustom);
  FEditButtons[NewIdx].Setup(FTabSheets[NewIdx].Value, ATitle, alClient);
  FPanels[NewIdx].Setup(FTabSheets[NewIdx].Value, alTop);
  FSynEdits[NewIdx].Setup(FTabSheets[NewIdx].Value, alClient);
  FPanels[NewIdx].Value.Caption := ' ' + APath; // Little padding for the path
end;

procedure TSourceViewManager.Clear;
var
  i: Integer = 0;
begin
  if Length(FTabSheets) = 0 then Exit;
  // Free in reverse order; tab last since it is parent of the others
  for i := High(FTabSheets) downto 0 do
  begin
    FBitBtnNexts[i].Free;
    FBitBtnPrevs[i].Free;
    FEditButtons[i].Free;
    FPanels[i].Free;
    FSynEdits[i].Free;
    FTabSheets[i].Free;
  end;
  SetLength(FTabSheets, 0);
  SetLength(FBitBtnNexts, 0);
  SetLength(FBitBtnPrevs, 0);
  SetLength(FEditButtons, 0);
  SetLength(FPanels, 0);
  SetLength(FSynEdits, 0);
end;

function TSourceViewManager.GetBitBtnNext(Index: Integer): TBitBtn;
begin
  Result := TBitBtn(FBitBtnNexts[Index].Value);
end;

function TSourceViewManager.GetBitBtnPrev(Index: Integer): TBitBtn;
begin
  Result := TBitBtn(FBitBtnPrevs[Index].Value);
end;

function TSourceViewManager.GetCount: Integer;
begin
  Result := Length(FTabSheets);
end;

function TSourceViewManager.GetEditButton(Index: Integer): TEditButton;
begin
  Result := TEditButton(FEditButtons[Index].Value);
end;

function TSourceViewManager.GetPanel(Index: Integer): TPanel;
begin
  Result := TPanel(FPanels[Index].Value);
end;

function TSourceViewManager.GetSynEdit(Index: Integer): TSynEdit;
begin
  Result := TSynEdit(FSynEdits[Index].Value);
end;

function TSourceViewManager.GetTabSheet(Index: Integer): TTabSheet;
begin
  Result := TTabSheet(FTabSheets[Index].Value);
end;

procedure TProgressBarHelper.SmartUpdate(var aUI: TThrottledUI;
  aCurrent: Integer; aStep: Integer);
begin
  Self.Position := aCurrent;
  if (aCurrent mod aStep = 0) or (aCurrent >= Self.Max) then
  begin
    Self.Repaint; // Direct widget paint for Linux/GTK responsiveness
    aUI.Check;   // Throttled message processing
  end;
end;

function TMyStringHelper.IsBlank: Boolean;
var
  c: char;
begin
  // Faster than Self.Trim.IsEmpty because no temp string is created
  for c in Self do if c > #32 then Exit(False);
  Result := True;
end;

function TMyStringHelper.IsNotBlank: Boolean;
begin
  Result := not Self.IsBlank;
end;

function TMyStringHelper.IsNotEmpty: Boolean;
begin
  Result := not Self.IsEmpty;
end;

function TMyStringHelper.PipeMe: String;
begin
  Result := '|' + Self + '|'; // UTF8-safe
end;

function TMyStringHelper.ProperCase: String;
begin
  Result := Self.ProperCase(StdWordDelims);
end;

function TMyStringHelper.ProperCase(const WordDelims: TSysCharSet): String;
begin
  // UTF8ProperCase (LazUtils/LazUTF8) decodes multi-byte UTF-8 codepoints
  // correctly, unlike AnsiProperCase which walks raw bytes and AVs on
  // UnicodeString/UTF-8 input under an ansi/codepage conversion mismatch.
  Result := UTF8ProperCase(Self, WordDelims);
end;

function TMyStringHelper.Quote: String;
begin
  // UTF8-safe: quote char '"' is ASCII and UTF8 continuation bytes never
  // collide with ASCII byte values, so byte-level AnsiQuotedStr is safe here.
  Result := AnsiQuotedStr(Self, '"');
end;

function TMyStringHelper.UTF8ToUpper: String;
begin
  Result := UTF8UpperCase(Self);
end;

function TStringsHelper.AddAsDir(const s: String): Integer;
begin
  Result := -1;
  if s.IsNotBlank then Result :=
      Self.Add(ExcludeTrailingPathDelimiter(SetDirSeparators(s)));
end;

function TStringsHelper.AddAsPath(const s: String): Integer;
begin
  Result := -1;
  if s.IsNotBlank then Result :=
      Self.Add(AppendPathDelim(SetDirSeparators(s)));
end;

function TStringsHelper.AddAsPathIfExists(const s: String): Integer;
var
  ls: String = '';
begin
  Result := -1;
  ls := SetDirSeparators(s.Trim);
  if (not ls.IsEmpty) and DirectoryExists(ls) then
    Result := Self.Add(AppendPathDelim(ls));
end;

function TStringsHelper.AddCleanPath(const s: String): Integer;
var
  Cleaned: String = '';
begin
  Result := -1;
  Cleaned := SetDirSeparators(s);
  Cleaned := SafeExpandFileName(Cleaned);
  Cleaned := ExcludeTrailingPathDelimiter(Cleaned);
  if DirectoryExists(Cleaned) then Result := Self.Add(Cleaned);
end;

function TStringsHelper.AddIfEmpty(const s: String): Integer;
begin
  Result := -1;
  if s.Trim.IsEmpty then Result := Self.Add(s);
end;

function TStringsHelper.AddIfNotEmpty(const s: String): Integer;
begin
  Result := -1;
  if s.IsNotBlank then Result := Self.Add(s);
end;

function TStringsHelper.AddUnique(const s: String): Integer;
begin
  Result := -1;
  if Self.IndexOf(s) = -1 then Result := Self.Add(s);
end;

procedure TStringsHelper.Shuffle;
var
  i: Integer = 0;
begin
  if Self.Count < 2 then Exit;
  Self.BeginUpdate;
  try
    // Fisher-Yates Shuffle
    for i := Self.Count - 1 downto 1 do Self.Exchange(i, Random(i + 1));
  finally
    Self.EndUpdate;
  end;
end;

// Tidy only: trims, turns Unicode spaces/controls into a single ASCII space,
// drops invisible characters. Never changes case or visible content.
// The output is never longer than the input, so it's written straight into a
// preallocated buffer (cheaper than a TStringBuilder for this).
function TMyStringHelper.Clean: String;
var
  P: PChar;
  i: Integer = 1;
  n: Integer = 0;
  Len: Integer = 0;
  SrcLen: Integer = 0;
  CP: cardinal = 0;
  PendingSpace: Boolean = False;
begin
  Result := '';
  if Self = '' then Exit;
  SrcLen := System.Length(Self);
  P := PChar(Self); // PChar() rather than @Self[i]: avoids a copy-on-write
  SetLength(Result, SrcLen);
  while i <= SrcLen do
  begin
    CP := UTF8CodepointToUnicode(P + i - 1, Len);
    if Len < 1 then Len := 1;
    if i + Len - 1 > SrcLen then Len := SrcLen - i + 1;
    case CP of
      0..32, $7F, $A0, $1680, $2000..$200A, $2028, $2029, $202F, $205F, $3000:
        PendingSpace := n > 0;  // leading whitespace dropped, runs collapsed
      $AD, $200B..$200D, $2060, $FEFF:
        ;                       // soft hyphen, zero-width chars, BOM: dropped
      else
      begin
        if PendingSpace then
        begin
          Inc(n);
          Result[n] := ' ';
          PendingSpace := False;
        end;
        Move(P[i - 1], Result[n + 1], Len);
        Inc(n, Len);
      end;
    end;
    Inc(i, Len);
  end;
  SetLength(Result, n); // a pending trailing space is never written: trimmed
end;

// Comparison key ONLY - never store in a displayed field or show to the user.
// Both sides of any comparison must go through Key.
function TMyStringHelper.Key: String;
var
  bNonASCII: Boolean = False;
  s: String = '';
  sLookalike: String = '';
  i: Integer = 0;
  n: Integer = 0;
begin
  s := UTF8UpperCase(ASCIIFold(Self.Clean));
  s := StringReplace(s, '&', ' AND ', [rfReplaceAll]);
  for i := 1 to System.Length(s) do
    if s[i] >= #$80 then
    begin
      bNonASCII := True;
      Break;
    end;
  // Only text with non-ASCII characters can hold any of these, and most
  // titles are plain ASCII, so they skip all the replacing.
  if bNonASCII then
  begin
    // Curly apostrophes vanish, like ''' below: GREY’S = GREYS.
    s := StringReplace(s, #$E2#$80#$99, '', [rfReplaceAll]); // U+2019 ’
    s := StringReplace(s, #$E2#$80#$98, '', [rfReplaceAll]); // U+2018 ‘
    // Look-alikes for the characters Windows forbids in file names break
    // words, as the characters themselves do. Otherwise the loop below
    // keeps their UTF-8 bytes as letters - "TREK꞉" glued together - and a
    // file named with them no longer matched its show.
    for i := Low(RESERVED_LOOKALIKES) to High(RESERVED_LOOKALIKES) do
      s := StringReplace(s, RESERVED_LOOKALIKES[i].Lookalike, ' ',
        [rfReplaceAll]);
    s := StringReplace(s, QUOTE_OPEN_LOOKALIKE, ' ', [rfReplaceAll]);
    s := StringReplace(s, QUOTE_CLOSE_LOOKALIKE, ' ', [rfReplaceAll]);
    for sLookalike in OTHER_LOOKALIKES do
      s := StringReplace(s, sLookalike, ' ', [rfReplaceAll]);
  end;
  SetLength(Result, System.Length(s));
  for i := 1 to System.Length(s) do case s[i] of
      'A'..'Z', '0'..'9', #$80..#$FF: // letters, digits, untouched UTF-8
      begin
        Inc(n);
        Result[n] := s[i];
      end;
      '''', '`':
        ; // apostrophes vanish: GREY'S = GREYS
      else
      begin
        Inc(n);
        Result[n] := ' ';
      end;
    end;
  SetLength(Result, n);
  Result := Result.Clean; // collapse the spaces punctuation left behind
end;

// =============================================================================
initialization
  Randomize;
  // InitSSLInterface deliberately is NOT called here. It used to be, but
  // that made it the very first substantial thing this program did on
  // every launch - before Form1 exists, before any exception handler is
  // in place, and (on Windows) before uUtils's own initialization had
  // necessarily run either, since unit initialization order depends on
  // the dependency graph, not source order.

  // Two things made that a real problem rather than just an odd choice:
  // 1. FPC's InitSSLInterface, via _RandScreen, actually takes a
  //    screenshot of the desktop on every successful call on Windows -
  //    a real, still-open FPC issue (freepascal.org/fpc/source#36045),
  //    not a misreading of this code. That's a multi-second, GDI-heavy
  //    operation to run unconditionally at the earliest possible moment
  //    of every launch, whether or not this session ever touches a
  //    network feature.
  // 2. Under Wine specifically, screen-capture GDI calls are only
  //    partially implemented, which is a very plausible reason that same
  //    call sequence can hard-fault instead of just running slowly - an
  //    access violation this early, before Form1 exists, has nowhere to
  //    be caught and takes the whole process down. try/except cannot
  //    catch a real AV originating inside a system DLL call like this
  //    one.

  // InitSSLInterface is idempotent (see its own SSLLoaded early-exit) and
  // is already called lazily, safely, exactly when SSL is actually about
  // to be used: TSmartHTTP.Heal (this unit) and fileyfrm.pas's own call
  // right before its first HTTPS use. Removing the eager call here costs
  // nothing - by the time any code path actually needs SSL, one of those
  // two call sites will have already initialized it - and it means a
  // user who never touches a network feature this session never pays the
  // RandScreen cost, or risks it, at all.

end.
