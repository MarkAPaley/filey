unit uBrowser;

{ Support for the Browser tab (TForm1.tsBrowser): what TIpHtmlPanel needs
  in order to show real web pages without freezing or crashing Filey.

  TIpHtmlPanel (TurboPower IPro) is an HTML 3.2-era viewer. Left to itself
  it downloads the page and every image on the main thread, and several
  things in today's pages send it into an endless loop or an access
  violation. So three things stand between it and the web:

  - TBrowserDownloadBatch downloads on background threads, so the window
    keeps responding while a page and its images arrive.
  - SimplifyHtmlForViewer takes out, before IPro sees the page, the parts
    that hang or crash it.
  - TFileyHttpDataProvider hands IPro the page and its images from memory,
    so IPro itself never waits on the network.

  TForm1.BrowseToURL puts these together. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Graphics, fphttpclient, IpFileBroker, IpHtml, IpMsg;

const
  BROWSER_USER_AGENT = 'Mozilla/5.0 (Lazarus; Ubuntu)';
  // Downloads run on background threads, so these only decide when to
  // give up on a server; nothing is frozen while they run.
  BROWSER_CONNECT_TIMEOUT_MS = 10000;
  // Longest wait for the next piece of a page or image.
  BROWSER_PAGE_TIMEOUT_MS = 20000;
  BROWSER_IMAGE_TIMEOUT_MS = 10000;
  // A page is shown once its images are in, or after this long; any still
  // on their way show as IPro's placeholder.
  BROWSER_IMAGES_TIME_LIMIT_MS = 8000;
  BROWSER_IMAGE_WORKERS = 4;
  BROWSER_MAX_IMAGES = 60;
  BROWSER_MAX_PAGE_BYTES = 8 * 1024 * 1024;
  BROWSER_MAX_IMAGE_BYTES = 2 * 1024 * 1024;
  // Images are kept for Back and Forward; past either limit the cache
  // starts over before the next page's images are fetched.
  BROWSER_IMAGE_CACHE_MAX_COUNT = 400;
  BROWSER_IMAGE_CACHE_MAX_BYTES = 48 * 1024 * 1024;
  // TFileyHttpDataProvider.CheckURL's own download (frames only) runs on
  // the main thread, so it gives up sooner. So does a build without
  // threads - see StartBrowserDownloads.
  BROWSER_FALLBACK_CONNECT_MS = 5000;
  BROWSER_FALLBACK_TIMEOUT_MS = 8000;

type
  TBrowserContentKind = (bckOther, bckHtml, bckText, bckImage);

  { TBrowserDownload
    One address to fetch, and what came back. Only the worker thread that
    takes it writes to it; the main thread reads it once Done is set (see
    TBrowserDownloadBatch.Finished). }
  TBrowserDownload = class
  public
    ContentType: String;
    Data: RawByteString;
    Done: Boolean;
    // Why it failed; '' if it didn't.
    ErrorText: String;
    // The address after any redirects.
    FinalURL: String;
    // Not something the Browser tab can show (a .zip, a PDF, ...). The
    // download stops as soon as the headers say so.
    NotViewable: Boolean;
    URL: String;
    function OK: Boolean;
  end;

  { TBrowserDownloadBatch
    A set of downloads shared by the main thread and the worker threads
    fetching them (StartBrowserDownloads). Reference counted: the main
    thread and each worker hold a reference, and the last Release frees it.
    That lets the main thread stop waiting (a time limit, a new address,
    the program closing) while a worker is still finishing a request that
    can't be interrupted, such as a connection attempt. }
  TBrowserDownloadBatch = class
  private
    FCancelled: Boolean;
    // Clients (TBrowserHTTPClient) in the middle of a request, for Cancel.
    FClients: TFPList;
    FDoneCount: Integer;
    FItems: array of TBrowserDownload;
    FLock: TRTLCriticalSection;
    FNext: Integer;
    FRefCount: LongInt;
    FWorkers: Integer;

  public
    // Settings. Change them only before StartBrowserDownloads.
    ConnectTimeoutMs: Integer;
    // GetTickCount64 after which no more addresses are handed out; 0 for
    // none.
    Deadline: QWord;
    IOTimeoutMs: Integer;
    // A page for the Browser tab: stop at the headers if it isn't one it
    // can show.
    IsPage: Boolean;
    MaxBytes: Int64;
    constructor Create(AURLs: TStrings; AIsPage: Boolean);
    procedure AddRef;
    // True once no worker is running any more: everything is done, or
    // what was left was cancelled.
    function AllDone: Boolean;
    // Stops handing out addresses and aborts the requests under way.
    procedure Cancel;
    function Cancelled: Boolean;
    // For TBrowserFetcher only.
    procedure ClientStarted(AClient: TObject);
    procedure ClientStopped(AClient: TObject);
    function Count: Integer;
    function DoneCount: Integer;
    // The download at AIndex if it has finished, else nil. The batch still
    // owns it.
    function Finished(AIndex: Integer): TBrowserDownload;
    procedure ItemDone(AItem: TBrowserDownload);
    procedure Release;
    // Like Finished, but the caller takes ownership and must free it.
    function TakeFinished(AIndex: Integer): TBrowserDownload;
    function TakeNext: TBrowserDownload;
    procedure WorkerStarted;
    procedure WorkerStopped;
    destructor Destroy; override;
  end;

  { TFileyHttpDataProvider
    What IpHtmlPanel1 gets pages and images from. TForm1.BrowseToURL
    downloads a page and its images first (on background threads) and
    hands them over with SetDocument and AddImage, so IPro finds them
    here instead of fetching each one while it paints. Compared with the
    stock TIpHttpDataProvider:

    - CanHandle is always False, so every link click reaches
      TForm1.IpHtmlPanel1HotClick instead of being opened by the panel. The
      stock CanHandle ignores the address and answers from the content type
      of whatever it downloaded last, so after any HTML page it said yes to
      mailto: links too.
    - CheckURL serves the page BrowseToURL downloaded. The panel calls it
      twice for every page and the stock version downloads the page both
      times.
    - GetImage serves images from memory and never downloads. The stock
      version downloaded each image during painting and let a failed one
      (a 404) raise an exception there.
    - It derives from TIpCustomHtmlDataProvider, not TIpHttpDataProvider,
      and keeps the page itself. TIpHttpDataProvider's page stream is
      spelled Documment in every Lazarus release up to 4.8 and Document
      in later trunk, so nothing here depends on it.
    - DoGetStream returns nil. The stock version returned the page itself
      for every stylesheet, which IPro then parsed as CSS.
    - BuildURL resolves addresses correctly (see ResolveWebAddress). The
      stock one, IpUtils.BuildURL, turns "//cdn.example.com/logo.png" into
      a path on the page's own server. }
  TFileyHttpDataProvider = class(TIpCustomHtmlDataProvider)
  private
    // What CheckURL last said yes to, for GetHtmlStream: IPro always asks
    // CheckURL about an address just before it asks for the page.
    FCheckedData: RawByteString;
    // The page SetDocument gave it.
    FDocContentType: String;
    FDocData: RawByteString;
    FDocURL: String;
    // The last frame CheckURL downloaded itself.
    FFrameData: RawByteString;
    FFrameURL: String;
    FImageBytes: Int64;
    // Address -> TBrowserImageData.
    FImages: TStringList;
    FLinkClicked: Boolean;

  public
    constructor Create(AOwner: TComponent); override;
    procedure AddImage(const AURL: String; const AData: RawByteString);
    function BuildURL(const OldURL, NewURL: string): string; override;
    function CanHandle(const {%H-}AUrl: string): Boolean; override;
    function CheckURL(const AUrl: string;
      var AContentType: string): Boolean; override;
    function DoGetStream(const {%H-}AUrl: string): TStream; override;
    function GetHtmlStream(const {%H-}AUrl: string;
      {%H-}APostData: TIpFormDataEntity): TStream; override;
    procedure GetImage(ASender: TIpHtmlNode; const AUrl: string;
      var APicture: TPicture); override;
    function HasImage(const AURL: String): Boolean;
    // The page CheckURL and GetHtmlStream serve for AURL.
    procedure SetDocument(const AURL, AContentType: String;
      const AData: RawByteString);
    // True if a link has been clicked since the last call - see CanHandle.
    function TakeLinkClicked: Boolean;
    // Empties the image cache if it has grown past its limits.
    procedure TrimImageCache;
    destructor Destroy; override;
  end;

// What kind of content AContentType ("text/html; charset=utf-8") is, as
// far as the Browser tab is concerned. With no content type, AData is
// checked for an HTML page.
function BrowserContentKind(const AContentType: String;
  const AData: RawByteString): TBrowserContentKind;
// True if this program can start threads. On Linux (and any Unix) that
// takes a thread driver, cthreads, as the first unit in the program's uses
// clause - see filey.lpr.
function BrowserThreadsAvailable: Boolean;
// A page showing just the image at AImageURL, which must not contain '"'.
// IPro's own version of this (BuildImagePage) writes the address without
// quotes, and its parser then misreads it.
function ImagePageHtml(const AImageURL: String): String;
// True for an address the Browser tab can load itself.
function IsWebAddress(const AURL: String): Boolean;
// What the user typed in edUrl, as an address the Browser tab can load:
// trimmed, with https:// added to a bare "epguides.com/Reacher/" and "/"
// to a bare "https://example.com". Returns '' for anything that isn't an
// http(s) address.
function NormalizeWebAddress(const AText: String): String;
// AText as an HTML page showing it as it is, for text/plain and the like.
function PlainTextAsHtml(const AText: String): String;
// Where AHRef, a link or image address as written in a page, points when
// seen from the page at ABase.
function ResolveWebAddress(const ABase, AHRef: String): String;
// AHtml with the parts IPro can't cope with taken out (see
// DROP_WITH_CONTENT and the constants after it). If AImageSources is
// given, the src of every <img> kept, and <body background>, is added to
// it as written in the page.
function SimplifyHtmlForViewer(const AHtml: String;
  AImageSources: TStrings = nil): String;
// Starts up to AWorkers threads fetching ABatch's addresses and returns at
// once; wait with ABatch.AllDone. Without threads (BrowserThreadsAvailable)
// it fetches them itself before returning, with shorter timeouts, and
// stops at ABatch.Deadline.
procedure StartBrowserDownloads(ABatch: TBrowserDownloadBatch;
  AWorkers: Integer);
// For shutdown: waits up to ATimeoutMs for download threads still
// finishing a request to end.
procedure WaitForBrowserThreads(ATimeoutMs: QWord);

implementation

uses
  base64, Math, sockets, ssockets, StrUtils, URIParser;

const
  HTML_NAME_CHARS = ['A'..'Z', 'a'..'z', '0'..'9', '-', ':', '_', '.'];
  HTML_SPACE_CHARS = [#9, #10, #12, #13, ' '];
  // Removed together with everything up to their end tag:
  // - script: IPro can't run it anyway, and its parser reads script as if
  //   it were HTML. A script that builds markup in a string ("<script
  //   ...>") sends TIpHtmlParser.ParseScript into a loop that never ends,
  //   which is what froze Filey on google.com.
  // - iframe, and embedded content IPro can't show (object, video, audio,
  //   canvas, inline svg and math, template). Each iframe is another page
  //   for IPro to download and lay out inside the first, and on news sites
  //   they nest deeply.
  // - Form controls (select, textarea, button, and input below). Each
  //   becomes a real LCL control on the panel, and Filey can't submit forms
  //   through it anyway.
  DROP_WITH_CONTENT: array[0..14] of String = ('audio', 'button', 'canvas',
    'iframe', 'math', 'noembed', 'noframes', 'object', 'script', 'select',
    'svg', 'template', 'textarea', 'video', 'xmp');
  // Their content is plain text that ends at the first </name, however
  // much it looks like markup - the HTML rule for these elements.
  RAW_TEXT: array[0..8] of String = ('iframe', 'noembed', 'noframes',
    'plaintext', 'script', 'style', 'textarea', 'title', 'xmp');
  // Removed on their own; they have no content. <link> is for stylesheets
  // (IPro would ask DoGetStream for each), preloads and the like.
  DROP_TAG_ONLY: array[0..5] of String = ('embed', 'input', 'link',
    'param', 'source', 'track');

type
  // An image in TFileyHttpDataProvider's cache.
  TBrowserImageData = class
  public
    Data: RawByteString;
  end;

  { TBrowserHTTPClient
    A TFPHTTPClient that another thread can stop in the middle of a read.
    Terminate only sets a flag the client checks between reads, so a server
    that stops sending would hold the thread for the whole IOTimeout - and
    at shutdown, past the moment Filey stops waiting for it. Abort also
    shuts the socket down, which ends a read that is waiting at once. That
    happens at the socket level, without touching OpenSSL's state, which
    only the thread reading may change. A connection attempt still can't
    be interrupted: FPC offers no hook between creating the socket and
    connecting it. }
  TBrowserHTTPClient = class(TFPHTTPClient)
  private
    // Abort was called since ResetAbort. HTTPMethod clears Terminated when
    // it starts, so an Abort that comes before the connection exists is
    // remembered here and applied once it does.
    FAborted: Boolean;
    // The handler of the connection being made. Used only by the thread
    // running requests.
    FHandler: TSocketHandler;
    // The open connection's socket, if there is one.
    FHasSocket: Boolean;
    // Guards the three fields after it, which Abort uses from another
    // thread.
    FLock: TRTLCriticalSection;
    FSocketHandle: THandle;

  protected
    procedure ConnectToServer(const AHost: String; APort: Integer;
      UseSSL: Boolean = False); override;
    procedure DisconnectFromServer; override;
    function GetSocketHandler(const UseSSL: Boolean): TSocketHandler; override;

  public
    constructor Create(AOwner: TComponent); override;
    // Safe from any thread.
    procedure Abort;
    // Before each request, on the thread running it.
    procedure ResetAbort;
    destructor Destroy; override;
  end;

  { TBrowserFetcher
    Fetches addresses from a TBrowserDownloadBatch, one after another,
    until there are none left. Touches nothing but the batch, its own HTTP
    client and plain data - no LCL - so it can run on a background thread
    (TBrowserDownloadThread), or directly when there are no threads (see
    StartBrowserDownloads). }
  TBrowserFetcher = class
  private
    FBatch: TBrowserDownloadBatch;
    FClient: TBrowserHTTPClient;
    // The download under way, for the client's events.
    FItem: TBrowserDownload;
    FRedirectedTo: String;
    procedure ClientData(Sender: TObject;
      const {%H-}ContentLength, CurrentPos: Int64);
    procedure ClientHeaders(Sender: TObject);
    procedure ClientRedirect(Sender: TObject; const ASrc: String;
      var ADest: String);
    procedure Fetch(AItem: TBrowserDownload);

  public
    constructor Create(ABatch: TBrowserDownloadBatch);
    procedure Run;
    destructor Destroy; override;
  end;

  { TBrowserDownloadThread
    A TBrowserFetcher on a thread of its own. FPC's openssl unit installs
    OpenSSL's locking callbacks when it loads the libraries, so several of
    these can use HTTPS at once, even with the 1.0.x DLLs on Windows. }
  TBrowserDownloadThread = class(TThread)
  private
    FBatch: TBrowserDownloadBatch;
  protected
    procedure Execute; override;
  public
    constructor Create(ABatch: TBrowserDownloadBatch);
  end;

var
  // Download threads still running, for WaitForBrowserThreads.
  GBrowserThreads: LongInt = 0;

// "text/html; charset=utf-8" -> "text/html".
function BareContentType(const AContentType: String): String;
var
  p: SizeInt;
begin
  Result := LowerCase(Trim(AContentType));
  p := Pos(';', Result);
  if p > 0 then Result := Trim(Copy(Result, 1, p - 1));
end;

// The bytes of a "data:image/png;base64,..." address; '' for anything
// else.
function DecodeDataImage(const AURL: String): RawByteString;
var
  p: SizeInt;
begin
  Result := '';
  if not StartsText('data:image/', AURL) then Exit;
  p := Pos(',', AURL);
  if (p = 0) or not EndsText(';base64', Copy(AURL, 1, p - 1)) then Exit;
  try
    Result := DecodeStringBase64(Copy(AURL, p + 1, MaxInt));
  except
    Result := '';
  end;
end;

// s with &, < and > written as entities, for text inside a page.
function EscapeHtmlText(const s: String): String;
begin
  Result := StringReplace(s, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
end;

// True if s starts with a scheme ("https:", "mailto:", "data:").
function HasUrlScheme(const s: String): Boolean;
var
  i: SizeInt;
begin
  Result := False;
  if (s = '') or not (s[1] in ['A'..'Z', 'a'..'z']) then Exit;
  for i := 2 to Length(s) do
    case s[i] of
      'A'..'Z', 'a'..'z', '0'..'9', '+', '-', '.': ;
      ':': Exit(True);
      else
        Exit;
    end;
end;

function ImagePageHtml(const AImageURL: String): String;
begin
  Result := '<html><body><img src="' + AImageURL + '"></body></html>';
end;

function InList(const AName: String; const AList: array of String): Boolean;
var
  k: Integer;
begin
  for k := Low(AList) to High(AList) do
    if AList[k] = AName then Exit(True);
  Result := False;
end;

// Whether a download with this content type is worth finishing. With no
// content type it is finished, and BrowserContentKind looks at the data.
function IsViewableContentType(const AContentType: String): Boolean;
begin
  Result := (BareContentType(AContentType) = '') or
    (BrowserContentKind(AContentType, '') <> bckOther);
end;

function IsWebAddress(const AURL: String): Boolean;
begin
  Result := StartsText('http://', AURL) or StartsText('https://', AURL);
end;

function LooksLikeHtml(const AData: RawByteString): Boolean;
var
  sStart: String;
begin
  sStart := LowerCase(Copy(AData, 1, 1024));
  Result := (Pos('<html', sStart) > 0) or (Pos('<!doctype html', sStart) > 0)
    or (Pos('<head', sStart) > 0) or (Pos('<body', sStart) > 0);
end;

function BrowserContentKind(const AContentType: String;
  const AData: RawByteString): TBrowserContentKind;
var
  sType: String;
begin
  sType := BareContentType(AContentType);
  if (sType = 'text/html') or (sType = 'application/xhtml+xml') then
    Result := bckHtml
  else if StartsText('image/', sType) then
    Result := bckImage
  else if StartsText('text/', sType) or (sType = 'application/json') or
    (sType = 'application/xml') or EndsText('+json', sType) or
    EndsText('+xml', sType) then
    Result := bckText
  else if (sType = '') and LooksLikeHtml(AData) then
    Result := bckHtml
  else
    Result := bckOther;
end;

function PlainTextAsHtml(const AText: String): String;
var
  i: SizeInt;
  SB: TStringBuilder;
begin
  // A fixed-width font, with line breaks and runs of spaces kept - but not
  // <pre>: IPro doesn't decode entities inside <pre>, so a '<' in the text
  // couldn't be shown there at all.
  SB := TStringBuilder.Create(Length(AText) + Length(AText) div 4 + 64);
  try
    SB.Append('<html><body><tt>');
    i := 1;
    while i <= Length(AText) do
    begin
      case AText[i] of
        '&': SB.Append('&amp;');
        '<': SB.Append('&lt;');
        '>': SB.Append('&gt;');
        ' ': SB.Append('&nbsp;');
        #9: SB.Append('&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;');
        #13:
          begin
            SB.Append('<br>'#10);
            if (i < Length(AText)) and (AText[i + 1] = #10) then Inc(i);
          end;
        #10: SB.Append('<br>'#10);
        else
          SB.Append(AText[i]);
      end;
      Inc(i);
    end;
    SB.Append('</tt></body></html>');
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

// AURL with "/" as its path if it has none: "https://example.com" and
// "https://example.com?q=1" become "https://example.com/" and
// "https://example.com/?q=1".
function WithRootPath(const AURL: String): String;
var
  k, p: SizeInt;
begin
  Result := AURL;
  p := Pos('://', Result);
  if p = 0 then Exit;
  k := p + 3;
  while (k <= Length(Result)) and not (Result[k] in ['/', '?', '#']) do Inc(k);
  if (k > Length(Result)) or (Result[k] <> '/') then Insert('/', Result, k);
end;

function NormalizeWebAddress(const AText: String): String;
begin
  Result := Trim(AText);
  if Result = '' then Exit;
  if (Pos('://', Result) = 0) and (Pos('.', Result) > 0) and
    (Pos(' ', Result) = 0) then Result := 'https://' + Result;
  if IsWebAddress(Result) then Result := WithRootPath(Result)
  else
    Result := '';
end;

// URIParser.ResolveRelativeURI, except that an address that is already
// complete comes back exactly as written (so the same address is always
// the same string - TFileyHttpDataProvider keys its caches by it), and
// that a base with no path works: ResolveRelativeURI joins "logo.png" onto
// "https://example.com" as "https://example.comlogo.png".
function ResolveWebAddress(const ABase, AHRef: String): String;
begin
  if (ABase = '') or HasUrlScheme(AHRef) then Exit(AHRef);
  if not ResolveRelativeURI(WithRootPath(ABase), AHRef, Result) then
    Result := AHRef;
end;

{ HTML scanning. Only ASCII bytes ('<', '>', quotes, tag and attribute
  names) are ever examined, and UTF-8 never uses those inside a multi-byte
  character, so text in any language passes through intact. }

// True if the tag name starting at APos is ALowerName, and not just
// begins with it. APos is the first character after '<' or '</'.
function HtmlNameAt(const AHtml: String; APos: SizeInt;
  const ALowerName: String): Boolean;
var
  k: SizeInt;
  c: Char;
begin
  if APos + Length(ALowerName) - 1 > Length(AHtml) then Exit(False);
  for k := 1 to Length(ALowerName) do
  begin
    c := AHtml[APos + k - 1];
    if c in ['A'..'Z'] then c := Chr(Ord(c) + 32);
    if c <> ALowerName[k] then Exit(False);
  end;
  k := APos + Length(ALowerName);
  Result := (k > Length(AHtml)) or not (AHtml[k] in HTML_NAME_CHARS);
end;

// Finds attribute ALowerName in ATag, the text of one start tag from '<'
// to '>'. AValue is its value as written (no entities decoded - IPro
// doesn't decode them either), and AFrom..ATo is where the attribute, name
// through value, sits in ATag. False if ATag doesn't have it.
function HtmlTagAttribute(const ATag, ALowerName: String; out AValue: String;
  out AFrom, ATo: SizeInt): Boolean;
var
  j, k, Len, NameEnd, NameStart, ValStart, ValEnd: SizeInt;
begin
  Result := False;
  AValue := '';
  AFrom := 0;
  ATo := 0;
  Len := Length(ATag);
  k := 2;
  while (k <= Len) and (ATag[k] in HTML_NAME_CHARS) do Inc(k); // tag name
  while k <= Len do
  begin
    while (k <= Len) and ((ATag[k] in HTML_SPACE_CHARS) or (ATag[k] = '/')) do
      Inc(k);
    if (k > Len) or (ATag[k] = '>') then Exit;
    NameStart := k;
    while (k <= Len) and not (ATag[k] in HTML_SPACE_CHARS + ['=', '>', '/'])
      do Inc(k);
    if k = NameStart then
    begin
      Inc(k); // a stray '='
      Continue;
    end;
    NameEnd := k;
    ValStart := 0;
    ValEnd := -1;
    j := k;
    while (j <= Len) and (ATag[j] in HTML_SPACE_CHARS) do Inc(j);
    if (j <= Len) and (ATag[j] = '=') then
    begin
      k := j + 1;
      while (k <= Len) and (ATag[k] in HTML_SPACE_CHARS) do Inc(k);
      if (k <= Len) and (ATag[k] in ['"', '''']) then
      begin
        ValStart := k + 1;
        j := PosEx(ATag[k], ATag, ValStart);
        if j = 0 then j := Len + 1;
        ValEnd := j - 1;
        k := Min(j + 1, Len + 1);
      end
      else
      begin
        ValStart := k;
        while (k <= Len) and not (ATag[k] in HTML_SPACE_CHARS + ['>']) do
          Inc(k);
        ValEnd := k - 1;
      end;
    end;
    if LowerCase(Copy(ATag, NameStart, NameEnd - NameStart)) = ALowerName then
    begin
      if ValStart > 0 then
        AValue := Copy(ATag, ValStart, ValEnd - ValStart + 1);
      AFrom := NameStart;
      ATo := k - 1;
      Exit(True);
    end;
  end;
end;

// Index of the '>' closing the tag whose name ends just before AFrom,
// skipping any '>' inside a quoted attribute value. Length(AHtml) if there
// is none, so an unfinished tag runs to the end of the page.
function HtmlTagEnd(const AHtml: String; AFrom: SizeInt): SizeInt;
var
  k, q, Len: SizeInt;
begin
  Len := Length(AHtml);
  k := AFrom;
  while k <= Len do
  begin
    case AHtml[k] of
      '>': Exit(k);
      '=':
        begin
          Inc(k);
          while (k <= Len) and (AHtml[k] in HTML_SPACE_CHARS) do Inc(k);
          if (k <= Len) and (AHtml[k] in ['"', '''']) then
          begin
            q := PosEx(AHtml[k], AHtml, k + 1);
            if q = 0 then Exit(Len);
            k := q + 1;
          end;
          Continue;
        end;
    end;
    Inc(k);
  end;
  Result := Len;
end;

// Just past the '>' of the first </ALowerName at or after AFrom. With no
// end tag the element runs to the end of the page, as in a browser.
function HtmlSkipRawText(const AHtml, ALowerName: String;
  AFrom: SizeInt): SizeInt;
var
  k: SizeInt;
begin
  k := AFrom;
  repeat
    k := PosEx('</', AHtml, k);
    if k = 0 then Exit(Length(AHtml) + 1);
    if HtmlNameAt(AHtml, k + 2, ALowerName) then
      Exit(HtmlTagEnd(AHtml, k + 2 + Length(ALowerName)) + 1);
    Inc(k, 2);
  until False;
end;

// Just past the end tag matching an open ALowerName whose start tag ends
// before AFrom, counting nested ones (<svg> in <svg>). Raw-text elements
// inside are skipped whole, so a "</svg>" in a script doesn't count. 0 if
// there is no matching end tag.
function HtmlSkipElement(const AHtml, ALowerName: String;
  AFrom: SizeInt): SizeInt;
var
  Depth, k, Len, NEnd, NStart, TEnd: SizeInt;
  bEnd: Boolean;
  sInner: String;
begin
  Len := Length(AHtml);
  Depth := 1;
  k := AFrom;
  while k <= Len do
  begin
    k := PosEx('<', AHtml, k);
    if k = 0 then Break;
    if (k + 3 <= Len) and (AHtml[k + 1] = '!') and (AHtml[k + 2] = '-') and
      (AHtml[k + 3] = '-') then
    begin
      k := PosEx('-->', AHtml, k + 4);
      if k = 0 then Break;
      Inc(k, 3);
      Continue;
    end;
    NStart := k + 1;
    bEnd := (NStart <= Len) and (AHtml[NStart] = '/');
    if bEnd then Inc(NStart);
    NEnd := NStart;
    while (NEnd <= Len) and (AHtml[NEnd] in HTML_NAME_CHARS) do Inc(NEnd);
    if (NEnd = NStart) or not (AHtml[NStart] in ['A'..'Z', 'a'..'z']) then
    begin
      Inc(k);
      Continue;
    end;
    sInner := LowerCase(Copy(AHtml, NStart, NEnd - NStart));
    TEnd := HtmlTagEnd(AHtml, NEnd);
    if sInner = ALowerName then
    begin
      if bEnd then Dec(Depth)
      else if AHtml[TEnd - 1] <> '/' then Inc(Depth);
      if Depth = 0 then Exit(TEnd + 1);
      k := TEnd + 1;
    end
    else if (not bEnd) and InList(sInner, RAW_TEXT) then
      k := HtmlSkipRawText(AHtml, sInner, TEnd + 1)
    else
      k := TEnd + 1;
  end;
  Result := 0;
end;

// "0", "1", "0px" or "1px".
function IsTinyLength(const AValue: String): Boolean;
var
  s: String;
begin
  s := LowerCase(Trim(AValue));
  Result := (s = '0') or (s = '1') or (s = '0px') or (s = '1px');
end;

// ATag, an <img> start tag, as SimplifyHtmlForViewer keeps it: '' for a
// tracking pixel (width or height 0 or 1 - nothing to see, just another
// download), otherwise without align="left" or align="right".
// TIpNodeBlockLayouter.DoQueueElemObject sets the element it is laying out
// to nil for an image floated left or right, and ContinueRow then reads it
// whenever there was text before the image on the same line: an access
// violation in the middle of painting. Without the align the image sits in
// line with the text instead.
function SimplifiedImgTag(const ATag: String): String;
var
  a, b: SizeInt;
  sValue: String;
begin
  Result := '';
  if HtmlTagAttribute(ATag, 'width', sValue, a, b) and IsTinyLength(sValue)
  then Exit;
  if HtmlTagAttribute(ATag, 'height', sValue, a, b) and IsTinyLength(sValue)
  then Exit;
  Result := ATag;
  if HtmlTagAttribute(ATag, 'align', sValue, a, b) then
  begin
    sValue := LowerCase(Trim(sValue));
    if (sValue = 'left') or (sValue = 'right') then
      Delete(Result, a, b - a + 1);
  end;
end;

function SimplifyHtmlForViewer(const AHtml: String;
  AImageSources: TStrings): String;
var
  Len, OutLen: SizeInt;
  a, b, i, j, NameStart, NameEnd, TagEnd: SizeInt;
  IsEndTag, IsSelfClosing: Boolean;
  sName, sTag, sValue: String;

  // Result is sized once up front and filled with Move - a single pass
  // with no string concatenation. It only grows past Length(AHtml) if many
  // stray '<' become "&lt;".
  procedure Emit(AFrom, ACount: SizeInt);
  begin
    if ACount <= 0 then Exit;
    if OutLen + ACount > Length(Result) then
      SetLength(Result, (OutLen + ACount) * 2);
    Move(AHtml[AFrom], Result[OutLen + 1], ACount);
    Inc(OutLen, ACount);
  end;

  procedure EmitText(const AText: String);
  begin
    if AText = '' then Exit;
    if OutLen + Length(AText) > Length(Result) then
      SetLength(Result, (OutLen + Length(AText)) * 2);
    Move(AText[1], Result[OutLen + 1], Length(AText));
    Inc(OutLen, Length(AText));
  end;

begin
  Len := Length(AHtml);
  Result := '';
  SetLength(Result, Len);
  OutLen := 0;
  i := 1;
  while i <= Len do
  begin
    // Text up to the next '<' is copied as it is.
    j := PosEx('<', AHtml, i);
    if j = 0 then j := Len + 1;
    Emit(i, j - i);
    if j > Len then Break;
    i := j;
    // Comments go.
    if (i + 3 <= Len) and (AHtml[i + 1] = '!') and (AHtml[i + 2] = '-') and
      (AHtml[i + 3] = '-') then
    begin
      j := PosEx('-->', AHtml, i + 4);
      if j = 0 then Break;
      i := j + 3;
      Continue;
    end;
    // <!DOCTYPE ...> and <?xml ...?> stay.
    if (i < Len) and (AHtml[i + 1] in ['!', '?']) then
    begin
      j := PosEx('>', AHtml, i + 2);
      if j = 0 then j := Len;
      Emit(i, j - i + 1);
      i := j + 1;
      Continue;
    end;
    NameStart := i + 1;
    IsEndTag := (NameStart <= Len) and (AHtml[NameStart] = '/');
    if IsEndTag then Inc(NameStart);
    NameEnd := NameStart;
    while (NameEnd <= Len) and (AHtml[NameEnd] in HTML_NAME_CHARS) do
      Inc(NameEnd);
    if (NameEnd = NameStart) or
      not (AHtml[NameStart] in ['A'..'Z', 'a'..'z']) then
    begin
      // Not a tag ("a < b", "<3"), but IPro's tokenizer would take it for
      // one.
      EmitText('&lt;');
      Inc(i);
      Continue;
    end;
    sName := LowerCase(Copy(AHtml, NameStart, NameEnd - NameStart));
    TagEnd := HtmlTagEnd(AHtml, NameEnd);
    IsSelfClosing := AHtml[TagEnd - 1] = '/';
    if IsEndTag then
    begin
      // End tags left over from removed elements go too.
      if not (InList(sName, DROP_WITH_CONTENT) or
        InList(sName, DROP_TAG_ONLY)) then Emit(i, TagEnd - i + 1);
      i := TagEnd + 1;
      Continue;
    end;
    if InList(sName, DROP_TAG_ONLY) then
    begin
      i := TagEnd + 1;
      Continue;
    end;
    if InList(sName, DROP_WITH_CONTENT) then
    begin
      if InList(sName, RAW_TEXT) then
        // "<script ... />" still has content, in HTML.
        i := HtmlSkipRawText(AHtml, sName, TagEnd + 1)
      else if IsSelfClosing then
        i := TagEnd + 1
      else
      begin
        j := HtmlSkipElement(AHtml, sName, TagEnd + 1);
        // No end tag: only the start tag goes, not the rest of the page.
        if j = 0 then i := TagEnd + 1
        else
          i := j;
      end;
      Continue;
    end;
    if sName = 'img' then
    begin
      sTag := SimplifiedImgTag(Copy(AHtml, i, TagEnd - i + 1));
      if Assigned(AImageSources) and (sTag <> '') and
        HtmlTagAttribute(sTag, 'src', sValue, a, b) and (sValue <> '') then
        AImageSources.Add(sValue);
      EmitText(sTag);
      i := TagEnd + 1;
      Continue;
    end;
    if (sName = 'body') and Assigned(AImageSources) and
      HtmlTagAttribute(Copy(AHtml, i, TagEnd - i + 1), 'background',
      sValue, a, b) and (sValue <> '') then AImageSources.Add(sValue);
    Emit(i, TagEnd - i + 1);
    i := TagEnd + 1;
    // A raw-text element that stays (<style>, <title>): its content is
    // copied as it is, '<' and all, up to and including the end tag.
    if InList(sName, RAW_TEXT) then
    begin
      j := HtmlSkipRawText(AHtml, sName, i);
      Emit(i, j - i);
      i := j;
    end;
  end;
  SetLength(Result, OutLen);
end;

{ TBrowserDownload }

function TBrowserDownload.OK: Boolean;
begin
  Result := Done and (ErrorText = '') and not NotViewable;
end;

{ TBrowserDownloadBatch }

constructor TBrowserDownloadBatch.Create(AURLs: TStrings; AIsPage: Boolean);
var
  i: Integer;
begin
  inherited Create;
  InitCriticalSection(FLock);
  FClients := TFPList.Create;
  SetLength(FItems, AURLs.Count);
  for i := 0 to AURLs.Count - 1 do
  begin
    FItems[i] := TBrowserDownload.Create;
    FItems[i].URL := AURLs[i];
  end;
  FRefCount := 1;
  IsPage := AIsPage;
  ConnectTimeoutMs := BROWSER_CONNECT_TIMEOUT_MS;
  if AIsPage then
  begin
    IOTimeoutMs := BROWSER_PAGE_TIMEOUT_MS;
    MaxBytes := BROWSER_MAX_PAGE_BYTES;
  end
  else
  begin
    IOTimeoutMs := BROWSER_IMAGE_TIMEOUT_MS;
    MaxBytes := BROWSER_MAX_IMAGE_BYTES;
  end;
end;

procedure TBrowserDownloadBatch.AddRef;
begin
  InterLockedIncrement(FRefCount);
end;

function TBrowserDownloadBatch.AllDone: Boolean;
begin
  EnterCriticalSection(FLock);
  try
    Result := FWorkers = 0;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TBrowserDownloadBatch.Cancel;
var
  i: Integer;
begin
  EnterCriticalSection(FLock);
  try
    FCancelled := True;
    for i := 0 to FClients.Count - 1 do
      TBrowserHTTPClient(FClients[i]).Abort;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TBrowserDownloadBatch.Cancelled: Boolean;
begin
  EnterCriticalSection(FLock);
  try
    Result := FCancelled;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TBrowserDownloadBatch.ClientStarted(AClient: TObject);
begin
  EnterCriticalSection(FLock);
  try
    FClients.Add(AClient);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TBrowserDownloadBatch.ClientStopped(AClient: TObject);
begin
  EnterCriticalSection(FLock);
  try
    FClients.Remove(AClient);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TBrowserDownloadBatch.Count: Integer;
begin
  Result := Length(FItems);
end;

function TBrowserDownloadBatch.DoneCount: Integer;
begin
  EnterCriticalSection(FLock);
  try
    Result := FDoneCount;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TBrowserDownloadBatch.Finished(AIndex: Integer): TBrowserDownload;
begin
  Result := nil;
  if (AIndex < 0) or (AIndex > High(FItems)) then Exit;
  EnterCriticalSection(FLock);
  try
    if Assigned(FItems[AIndex]) and FItems[AIndex].Done then
      Result := FItems[AIndex];
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TBrowserDownloadBatch.ItemDone(AItem: TBrowserDownload);
begin
  EnterCriticalSection(FLock);
  try
    AItem.Done := True;
    Inc(FDoneCount);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TBrowserDownloadBatch.Release;
begin
  if InterLockedDecrement(FRefCount) = 0 then Free;
end;

function TBrowserDownloadBatch.TakeFinished(AIndex: Integer): TBrowserDownload;
begin
  Result := nil;
  if (AIndex < 0) or (AIndex > High(FItems)) then Exit;
  EnterCriticalSection(FLock);
  try
    if Assigned(FItems[AIndex]) and FItems[AIndex].Done then
    begin
      Result := FItems[AIndex];
      FItems[AIndex] := nil;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TBrowserDownloadBatch.TakeNext: TBrowserDownload;
begin
  Result := nil;
  EnterCriticalSection(FLock);
  try
    if FCancelled or (FNext > High(FItems)) or
      ((Deadline > 0) and (GetTickCount64 >= Deadline)) then Exit;
    Result := FItems[FNext];
    Inc(FNext);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TBrowserDownloadBatch.WorkerStarted;
begin
  EnterCriticalSection(FLock);
  try
    Inc(FWorkers);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TBrowserDownloadBatch.WorkerStopped;
begin
  EnterCriticalSection(FLock);
  try
    Dec(FWorkers);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

destructor TBrowserDownloadBatch.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(FItems) do FItems[i].Free;
  FClients.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

{ TBrowserHTTPClient }

constructor TBrowserHTTPClient.Create(AOwner: TComponent);
begin
  InitCriticalSection(FLock);
  inherited Create(AOwner);
end;

procedure TBrowserHTTPClient.Abort;
begin
  Terminate;
  EnterCriticalSection(FLock);
  try
    FAborted := True;
    // The explicit cast: fpShutdown takes a cint, THandle is wider on
    // Win64, and socket handles always fit.
    if FHasSocket then fpShutdown(LongInt(FSocketHandle), SHUT_RDWR);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TBrowserHTTPClient.ConnectToServer(const AHost: String;
  APort: Integer; UseSSL: Boolean);
begin
  FHandler := nil;
  inherited ConnectToServer(AHost, APort, UseSSL);
  EnterCriticalSection(FLock);
  try
    FHasSocket := Assigned(FHandler) and Assigned(FHandler.Socket);
    if FHasSocket then
    begin
      FSocketHandle := FHandler.Socket.Handle;
      // Aborted while connecting: the first read ends at once.
      if FAborted then fpShutdown(LongInt(FSocketHandle), SHUT_RDWR);
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TBrowserHTTPClient.DisconnectFromServer;
begin
  // Forgotten before the socket is closed, so Abort can never shut down a
  // handle the system has since reused.
  EnterCriticalSection(FLock);
  try
    FHasSocket := False;
  finally
    LeaveCriticalSection(FLock);
  end;
  FHandler := nil;
  inherited DisconnectFromServer;
end;

function TBrowserHTTPClient.GetSocketHandler(
  const UseSSL: Boolean): TSocketHandler;
begin
  // The socket this handler gets is the one ConnectToServer remembers.
  Result := inherited GetSocketHandler(UseSSL);
  FHandler := Result;
end;

procedure TBrowserHTTPClient.ResetAbort;
begin
  EnterCriticalSection(FLock);
  try
    FAborted := False;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

destructor TBrowserHTTPClient.Destroy;
begin
  // The inherited Destroy disconnects, which needs FLock.
  inherited Destroy;
  DoneCriticalSection(FLock);
end;

{ TBrowserFetcher }

constructor TBrowserFetcher.Create(ABatch: TBrowserDownloadBatch);
begin
  inherited Create;
  FBatch := ABatch;
  FClient := TBrowserHTTPClient.Create(nil);
  FClient.AllowRedirect := True;
  FClient.MaxRedirects := 10;
  FClient.ConnectTimeout := FBatch.ConnectTimeoutMs;
  FClient.IOTimeout := FBatch.IOTimeoutMs;
  FClient.AddHeader('User-Agent', BROWSER_USER_AGENT);
  if FBatch.IsPage then
    FClient.AddHeader('Accept',
      'text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.8')
  else
    FClient.AddHeader('Accept', 'image/*,*/*;q=0.5');
  FClient.OnHeaders := @ClientHeaders;
  FClient.OnDataReceived := @ClientData;
  FClient.OnRedirect := @ClientRedirect;
end;

procedure TBrowserFetcher.ClientData(Sender: TObject;
  const ContentLength, CurrentPos: Int64);
begin
  if FBatch.Cancelled then
    FClient.Terminate
  else if (FItem <> nil) and (CurrentPos > FBatch.MaxBytes) then
  begin
    FItem.ErrorText := Format('Too large (over %d MB)',
      [FBatch.MaxBytes div (1024 * 1024)]);
    FClient.Terminate;
  end;
end;

procedure TBrowserFetcher.ClientHeaders(Sender: TObject);
var
  iLength: Int64;
begin
  if FItem = nil then Exit;
  // A redirect: the client follows it without reading its body. (It is
  // recognised by its Location header because FPC 3.2.2 only stores the
  // new status code once this event has returned.)
  if TFPHTTPClient.GetHeader(FClient.ResponseHeaders, 'Location') <> '' then
    Exit;
  if FBatch.IsPage and not IsViewableContentType(
    TFPHTTPClient.GetHeader(FClient.ResponseHeaders, 'Content-Type')) then
  begin
    FItem.NotViewable := True;
    FClient.Terminate;
    Exit;
  end;
  iLength := StrToInt64Def(Trim(TFPHTTPClient.GetHeader(
    FClient.ResponseHeaders, 'Content-Length')), -1);
  if iLength > FBatch.MaxBytes then
  begin
    FItem.ErrorText := Format('Too large (over %d MB)',
      [FBatch.MaxBytes div (1024 * 1024)]);
    FClient.Terminate;
  end;
end;

procedure TBrowserFetcher.ClientRedirect(Sender: TObject;
  const ASrc: String; var ADest: String);
begin
  // The client resolves a relative Location itself, but only after this
  // event, so it is resolved here to record the address really landed on.
  ADest := ResolveWebAddress(ASrc, ADest);
  FRedirectedTo := ADest;
end;

procedure TBrowserFetcher.Fetch(AItem: TBrowserDownload);
var
  Body: TMemoryStream;
  Code: Integer;
begin
  FItem := AItem;
  FRedirectedTo := '';
  // Replaced below if the server redirects; set now so a download that
  // fails part way still has an address.
  AItem.FinalURL := AItem.URL;
  Body := TMemoryStream.Create;
  try
    try
      FClient.ResetAbort;
      FBatch.ClientStarted(FClient);
      try
        // Registered first, so a Cancel from now on reaches this client.
        if FBatch.Cancelled then
        begin
          AItem.ErrorText := 'Stopped';
          Exit;
        end;
        // [] accepts any status; it is checked below.
        FClient.HTTPMethod('GET', AItem.URL, Body, []);
      finally
        FBatch.ClientStopped(FClient);
      end;
      if FRedirectedTo <> '' then AItem.FinalURL := FRedirectedTo;
      AItem.ContentType := Trim(TFPHTTPClient.GetHeader(
        FClient.ResponseHeaders, 'Content-Type'));
      // Set by ClientHeaders or ClientData, which stopped the download.
      if AItem.NotViewable or (AItem.ErrorText <> '') then Exit;
      if FBatch.Cancelled then
      begin
        AItem.ErrorText := 'Stopped';
        Exit;
      end;
      Code := FClient.ResponseStatusCode;
      if (Code < 200) or (Code > 299) then
      begin
        AItem.ErrorText := Trim(Format('The server answered %d %s',
          [Code, FClient.ResponseStatusText]));
        Exit;
      end;
      SetLength(AItem.Data, Body.Size);
      if Body.Size > 0 then Move(Body.Memory^, AItem.Data[1], Body.Size);
    except
      on E: Exception do
        if AItem.ErrorText = '' then AItem.ErrorText := E.Message;
    end;
  finally
    Body.Free;
    FItem := nil;
  end;
end;

procedure TBrowserFetcher.Run;
var
  Item: TBrowserDownload;
begin
  repeat
    Item := FBatch.TakeNext;
    if Item = nil then Break;
    Fetch(Item);
    FBatch.ItemDone(Item);
  until False;
end;

destructor TBrowserFetcher.Destroy;
begin
  FClient.Free;
  inherited Destroy;
end;

{ TBrowserDownloadThread }

constructor TBrowserDownloadThread.Create(ABatch: TBrowserDownloadBatch);
begin
  // Counted before the thread exists, so AllDone and WaitForBrowserThreads
  // can't see it as finished before it has started.
  FBatch := ABatch;
  FBatch.AddRef;
  FBatch.WorkerStarted;
  InterLockedIncrement(GBrowserThreads);
  inherited Create(True);
  FreeOnTerminate := True;
  Start;
end;

procedure TBrowserDownloadThread.Execute;
var
  Fetcher: TBrowserFetcher;
begin
  try
    Fetcher := TBrowserFetcher.Create(FBatch);
    try
      Fetcher.Run;
    finally
      Fetcher.Free;
    end;
  except
    // Fetch reports its own errors on the item; nothing else here should
    // raise, and nothing may escape a thread.
  end;
  FBatch.WorkerStopped;
  FBatch.Release;
  InterLockedDecrement(GBrowserThreads);
end;

function BrowserThreadsAvailable: Boolean;
{$IFDEF UNIX}
var
  TM: TThreadManager;
begin
  // Without a thread driver, starting a thread isn't an exception but
  // runtime error 232, which ends the program. The RTL's stand-in "no
  // threads" manager is the one with no InitManager; cthreads has one.
  TM := Default(TThreadManager);
  Result := GetThreadManager(TM) and Assigned(TM.InitManager);
end;
{$ELSE}
begin
  // Windows threads are part of the RTL.
  Result := True;
end;
{$ENDIF}

// Downloads AURL on the calling thread, with the short fallback timeouts,
// and returns the result for the caller to free (nil only if nothing ran).
// For TFileyHttpDataProvider.CheckURL, which IPro calls on the main thread.
function DownloadNow(const AURL: String): TBrowserDownload;
var
  Batch: TBrowserDownloadBatch;
  Fetcher: TBrowserFetcher;
  URLs: TStringList;
begin
  URLs := TStringList.Create;
  try
    URLs.Add(AURL);
    Batch := TBrowserDownloadBatch.Create(URLs, True);
  finally
    URLs.Free;
  end;
  try
    Batch.ConnectTimeoutMs := BROWSER_FALLBACK_CONNECT_MS;
    Batch.IOTimeoutMs := BROWSER_FALLBACK_TIMEOUT_MS;
    Fetcher := TBrowserFetcher.Create(Batch);
    try
      Fetcher.Run;
    finally
      Fetcher.Free;
    end;
    Result := Batch.TakeFinished(0);
  finally
    Batch.Release;
  end;
end;

procedure StartBrowserDownloads(ABatch: TBrowserDownloadBatch;
  AWorkers: Integer);
var
  Fetcher: TBrowserFetcher;
  i: Integer;
begin
  if not BrowserThreadsAvailable then
  begin
    // Fetched here and now while the caller waits, as the Browser tab
    // always did before, with shorter timeouts since nothing else can
    // happen meanwhile.
    ABatch.ConnectTimeoutMs := Min(ABatch.ConnectTimeoutMs,
      BROWSER_FALLBACK_CONNECT_MS);
    ABatch.IOTimeoutMs := Min(ABatch.IOTimeoutMs, BROWSER_FALLBACK_TIMEOUT_MS);
    Fetcher := TBrowserFetcher.Create(ABatch);
    try
      Fetcher.Run;
    finally
      Fetcher.Free;
    end;
    Exit;
  end;
  for i := 1 to Min(AWorkers, ABatch.Count) do
    TBrowserDownloadThread.Create(ABatch);
end;

procedure WaitForBrowserThreads(ATimeoutMs: QWord);
var
  Start: QWord;
begin
  Start := GetTickCount64;
  while (InterLockedExchangeAdd(GBrowserThreads, 0) > 0) and
    (GetTickCount64 - Start < ATimeoutMs) do
    Sleep(10);
end;

{ TFileyHttpDataProvider }

constructor TFileyHttpDataProvider.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FImages := TStringList.Create;
  FImages.CaseSensitive := True;
  FImages.Sorted := True;
  FImages.Duplicates := dupIgnore;
  FImages.OwnsObjects := True;
end;

procedure TFileyHttpDataProvider.AddImage(const AURL: String;
  const AData: RawByteString);
var
  i: Integer;
  Item: TBrowserImageData;
begin
  if (AURL = '') or (AData = '') or FImages.Find(AURL, i) then Exit;
  Item := TBrowserImageData.Create;
  Item.Data := AData;
  FImages.AddObject(AURL, Item);
  Inc(FImageBytes, Length(AData));
end;

function TFileyHttpDataProvider.BuildURL(const OldURL, NewURL: string): string;
begin
  Result := ResolveWebAddress(OldURL, NewURL);
end;

function TFileyHttpDataProvider.CanHandle(const AUrl: string): Boolean;
begin
  // The panel asks this only when a link is clicked, just before it calls
  // OnHotClick. That is how TForm1.IpHtmlPanel1HotClick tells a click apart
  // from the panel handing over a page it can't show, which skips this.
  FLinkClicked := True;
  Result := False;
end;

function TFileyHttpDataProvider.CheckURL(const AUrl: string;
  var AContentType: string): Boolean;
var
  Frame: TBrowserDownload;
  sImageURL: String;
begin
  Result := False;
  AContentType := '';
  if (FDocURL <> '') and (AUrl = FDocURL) then
  begin
    FCheckedData := FDocData;
    AContentType := FDocContentType;
    Exit(True);
  end;
  if (FFrameURL <> '') and (AUrl = FFrameURL) then
  begin
    FCheckedData := FFrameData;
    AContentType := 'text/html';
    Exit(True);
  end;
  // Anything else is a frame of a <frameset> page, which IPro opens by
  // itself while it lays the page out. That download has to happen here,
  // on the main thread, hence the short timeouts. The frame is shown the
  // way BrowseToURL shows a page.
  Frame := DownloadNow(AUrl);
  try
    if Frame = nil then Exit;
    if Frame.NotViewable then
      // A link to it instead, for the system to open if clicked.
      FFrameData := '<html><body><p><a href="' +
        StringReplace(AUrl, '"', '%22', [rfReplaceAll]) + '">' +
        EscapeHtmlText(AUrl) + '</a></p></body></html>'
    else if not Frame.OK then
      Exit
    else
      case BrowserContentKind(Frame.ContentType, Frame.Data) of
        bckHtml: FFrameData := SimplifyHtmlForViewer(Frame.Data);
        bckText: FFrameData := PlainTextAsHtml(Frame.Data);
        bckImage:
          begin
            sImageURL := StringReplace(AUrl, '"', '%22', [rfReplaceAll]);
            AddImage(sImageURL, Frame.Data);
            FFrameData := ImagePageHtml(sImageURL);
          end;
        else
          Exit;
      end;
  finally
    Frame.Free;
  end;
  FFrameURL := AUrl;
  FCheckedData := FFrameData;
  AContentType := 'text/html';
  Result := True;
end;

function TFileyHttpDataProvider.DoGetStream(const AUrl: string): TStream;
begin
  // Only ever asked for a <link rel="stylesheet">, and SimplifyHtmlForViewer
  // takes those out. The stock provider returned the page itself here.
  Result := nil;
end;

function TFileyHttpDataProvider.GetHtmlStream(const AUrl: string;
  APostData: TIpFormDataEntity): TStream;
begin
  // IPro frees the stream once it has read it.
  Result := TMemoryStream.Create;
  if FCheckedData <> '' then
    Result.WriteBuffer(FCheckedData[1], Length(FCheckedData));
  Result.Position := 0;
end;

procedure TFileyHttpDataProvider.GetImage(ASender: TIpHtmlNode;
  const AUrl: string; var APicture: TPicture);
var
  i: Integer;
  sData: RawByteString;
  Stream: TMemoryStream;
begin
  APicture := nil;
  if StartsText('data:', AUrl) then sData := DecodeDataImage(AUrl)
  else if FImages.Find(AUrl, i) then
    sData := TBrowserImageData(FImages.Objects[i]).Data
  else
    // Not fetched in time, or it failed: IPro shows its placeholder.
    Exit;
  if sData = '' then Exit;
  Stream := TMemoryStream.Create;
  try
    Stream.WriteBuffer(sData[1], Length(sData));
    Stream.Position := 0;
    APicture := TPicture.Create;
    try
      APicture.LoadFromStream(Stream);
    except
      // A format the LCL can't read (WebP, SVG, ...) or a damaged file.
      FreeAndNil(APicture);
    end;
  finally
    Stream.Free;
  end;
end;

function TFileyHttpDataProvider.HasImage(const AURL: String): Boolean;
var
  i: Integer;
begin
  Result := FImages.Find(AURL, i);
end;

procedure TFileyHttpDataProvider.SetDocument(const AURL, AContentType: String;
  const AData: RawByteString);
begin
  FDocURL := AURL;
  FDocContentType := AContentType;
  FDocData := AData;
end;

function TFileyHttpDataProvider.TakeLinkClicked: Boolean;
begin
  Result := FLinkClicked;
  FLinkClicked := False;
end;

procedure TFileyHttpDataProvider.TrimImageCache;
begin
  if (FImages.Count < BROWSER_IMAGE_CACHE_MAX_COUNT) and
    (FImageBytes < BROWSER_IMAGE_CACHE_MAX_BYTES) then Exit;
  FImages.Clear;
  FImageBytes := 0;
end;

destructor TFileyHttpDataProvider.Destroy;
begin
  FImages.Free;
  inherited Destroy;
end;

end.
