{ Filey - uEpisodeMatching.pas

Copyright (C) 2026 Mark A Paley

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program; if not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>.

Report bugs and questions at <https://gitlab.com/MarkAPaley/filey/-/issues>.
}

{ ==============================================================================
   uEpisodeMatching

   Everything needed to recognise a season/episode marker (S01E01, 1x01,
   101, ...) inside a video file name, and to pull the show title, episode
   number, and episode name back out of it.

   This unit was extracted from TForm1 (fileyfrm.pas): TEpisodePattern,
   TEpPatterns, TEpisodeMatch, and every TForm1 method whose job was purely
   pattern-matching an episode out of a string (BuildEpisodeNumber,
   ExtractEpisodeName, ExtractTitleFromFilename, FormatEpStr, GetEpNumName,
   InitializeEpisodePatterns and ValidateEpisodeNumber) now live on
   TEpisodeMatcher below. Nothing here touches a TDbf, a grid, or any other
   UI/database state - the owning form is responsible for all of that.

   TForm1 still owns filename sanitisation (FixWinFileName), because that
   routine is a general-purpose helper used well outside of episode
   matching. TEpisodeMatcher calls back into it (or whatever sanitiser the
   owner prefers) through the OnSanitizeFileName event, so this unit stays
   fully self-contained and independently testable.
============================================================================== }

unit uEpisodeMatching;

{$mode objfpc}
{$LONGSTRINGS ON}
{$H+}

interface

uses
  Classes, Generics.Collections, LazFileUtils, LazLogger, LazUTF8, RegExpr,
  StrUtils, SysUtils, uManagedUtils, uUtils;

type
  // Lets the owning form (or a unit test) supply whatever filename
  // sanitisation it wants; TEpisodeMatcher never needs to know how a
  // "clean" filename is produced, only that one can be requested.
  TFileNameSanitizeFunc = function(const AFileName: String): String;

  { TEpisodePattern }
  TEpisodePattern = class
  private
    FRegEx: TSmartRegEx; // Owns and manages the TRegExpr lifetime

  public
    AddSeasonZero, AddEpisodeZero: Boolean;
    // True for patterns with no literal S/E letters to anchor on (the NxN
    // family and the bare \d{3}/\d{4} fallbacks). These are the only ones
    // that can be fooled by a resolution (1920x1080), a codec tag (x264),
    // or a bare release year (2019) - see AdvanceToUnambiguousMatch and
    // IsKnownNonEpisodeToken in TEpisodeMatcher, which guard them.
    NumericGuard: Boolean;
    PatternName: String;
    RegexPattern: String;
    SeasonPos, SeasonLen, EpisodePos, EpisodeLen: Integer;
    constructor Create(const R: String; const SP, SL, EP, EL: Integer;
      const ASZ, AEZ, ANG: Boolean; const n: String);
    function Engine: TRegExpr;
    destructor Destroy; override;
  end;

  //TObjectList calls Free on each element when the list is freed,
  //which triggers TEpisodePattern.Destroy,
  //which calls FRegEx.FreeInstance
  TEpPatterns = class(specialize TObjectList<TEpisodePattern>);

  TEpisodeMatch = record
    EpName: String;
    EpNum: String;
    Found: Boolean;
  end;

  { TEpisodeMatcher }
  TEpisodeMatcher = class
  private
    FOnSanitizeFileName: TFileNameSanitizeFunc;
    FPatterns: TEpPatterns;
    // Walks Pattern's current (already-Exec'd) match forward via ExecNext
    // past any occurrence that HasNumericNeighbourConflict or
    // IsKnownNonEpisodeToken rejects as a false positive, stopping at the
    // first clean one. Returns False once the pattern has no occurrences
    // left in AFileName to try. Only ever called for NumericGuard patterns.
    function AdvanceToUnambiguousMatch(Pattern: TEpisodePattern;
      const AFileName: String): Boolean;
    // True if the character immediately before or after the match (at the
    // given 1-based byte position/length, as returned by TRegExpr's
    // MatchPos[0]/MatchLen[0]) is a digit, 'x'/'X', or - trailing side only
    // - 'p'/'P'/'i'/'I'; i.e. the match is sitting directly against another
    // number or a resolution/scan-type suffix (1920x1080, 1080p, 1080i)
    // rather than being a standalone token.
    function HasNumericNeighbourConflict(const AFileName: String;
      MatchStart, MatchLength: Integer): Boolean;
    procedure InitializePatterns;
    // True if Digits (a bare 3- or 4-digit match with no S/E letters) is a
    // known resolution/codec tag, or - for 4 digits - looks like a release
    // year (1900-2099). Belt-and-braces alongside HasNumericNeighbourConflict
    // for tokens that no longer have a tell-tale neighbour (e.g. a bare
    // "264" left after other cleanup already stripped the "x").
    function IsKnownNonEpisodeToken(const Digits: String): Boolean;
    function SanitizeFileName(const AFileName: String): String;

  public
    constructor Create;
    function BuildEpisodeNumber(const Season, Episode: String;
      AddSeasonZero, AddEpisodeZero: Boolean): String;
    function ExtractEpisodeName(
      const FileName, EpisodeNumber: String): String;
    function ExtractTitleFromFilename(
      const FileName, EpisodeNumber: String): String;
    function FormatEpStr(s: String): String;
    function GetEpNumName(const curFile: String): TEpisodeMatch;
    function ValidateEpisodeNumber(const EpisodeNum: String): Boolean;
    destructor Destroy; override;
    // Assign this to a method (e.g. Form1.FixWinFileName) that turns a raw
    // filename into a safe, comparable string. If left unassigned, a
    // minimal Trim(ExtractFileName(...)) fallback is used instead.
    property OnSanitizeFileName: TFileNameSanitizeFunc
      read FOnSanitizeFileName write FOnSanitizeFileName;
  end;

implementation

{$REGION 'TEpisodePattern'}
constructor TEpisodePattern.Create(const R: String;
  const SP, SL, EP, EL: Integer; const ASZ, AEZ, ANG: Boolean;
  const n: String);
begin
  RegexPattern := R;
  SeasonPos := SP;
  SeasonLen := SL;
  EpisodePos := EP;
  EpisodeLen := EL;
  AddSeasonZero := ASZ;
  AddEpisodeZero := AEZ;
  NumericGuard := ANG;
  PatternName := n;
  FRegEx.Value.Expression := R;
  FRegEx.Value.Compile;
end;

function TEpisodePattern.Engine: TRegExpr;
begin
  Result := FRegEx.Value;
end;

destructor TEpisodePattern.Destroy;
begin
  FRegEx.FreeInstance;   // explicit, deterministic, sequenced correctly
  inherited Destroy;
end;
{$ENDREGION}

{$REGION 'TEpisodeMatcher'}
constructor TEpisodeMatcher.Create;
begin
  inherited Create;
  FPatterns := TEpPatterns.Create;
  FPatterns.Capacity := 17; // Pre-allocates the memory in one shot
  InitializePatterns;
end;

function TEpisodeMatcher.AdvanceToUnambiguousMatch(Pattern: TEpisodePattern;
  const AFileName: String): Boolean;
begin
  // Only ever called right after Pattern.Engine.Exec(AFileName) succeeded,
  // so there's always a current match to test first.
  Result := True;
  while HasNumericNeighbourConflict(AFileName, Pattern.Engine.MatchPos[0],
      Pattern.Engine.MatchLen[0]) or IsKnownNonEpisodeToken(
      Pattern.Engine.Match[0]) do
  begin
    if not Pattern.Engine.ExecNext then Exit(False);
  end;
end;

function TEpisodeMatcher.BuildEpisodeNumber(const Season, Episode: String;
  AddSeasonZero, AddEpisodeZero: Boolean): String;
var
  SeasonFormatted: String = '';
  EpisodeFormatted: String = '';
begin
  Result := '';
  try
    // Format season part
    if AddSeasonZero and (Length(Season) = 1) then
      SeasonFormatted := sb(['0', Season])
    else
      SeasonFormatted := Season;
    // Format episode part
    if AddEpisodeZero and (Length(Episode) = 1) then
      EpisodeFormatted := sb(['0', Episode])
    else
      EpisodeFormatted := Episode;
    // Build final result
    Result :=
      sb(['S', SeasonFormatted, 'E', EpisodeFormatted]);
  except
    on E: Exception do
    begin
      LogError(sb(['Error building episode number for Season=',
        Season, ', Episode=', Episode]), E);
      Result := '';
    end;
  end;
end;

function TEpisodeMatcher.ExtractEpisodeName(
  const FileName, EpisodeNumber: String): String;
var
  CleanFileName: String;
  EpisodePos: Integer;
  NamePart: String;
  p: PChar;
begin
  Result := '';
  if (FileName = '') or (EpisodeNumber = '') then Exit;
  try
    // Step 1: Clean and isolate filename
    CleanFileName := SanitizeFileName(ExtractFileNameOnly(
      SafeExpandFilename(FileName)));
    // Step 2: Search case-insensitively first (soMatchCase omitted),
    // so that any capitalisation of the episode code (S01E01 / s01e01)
    // is found reliably.  Fall back to a case-sensitive search only if
    // the case-insensitive pass somehow returns nil (should not happen).
    p := SearchBuf(PChar(CleanFileName), Length(CleanFileName),
      0, 0, EpisodeNumber, []);
    if p = nil then p :=
        SearchBuf(PChar(CleanFileName), Length(CleanFileName),
        0, 0, EpisodeNumber, [soMatchCase]);
    if p <> nil then
    begin
      EpisodePos := p - PChar(CleanFileName) + 1;
      // Step 3: Extract everything after the episode number
      NamePart := Copy(CleanFileName, EpisodePos +
        Length(EpisodeNumber), MaxInt);
      // Step 4: Remove leading separators ('.', '-', '_', ' ')
      // TrimLeftSet is very fast and cleaner than a while loop
      NamePart := TrimLeftSet(NamePart, ['.', '-', '_', ' ']);
      // Step 5: Handle extensions more efficiently
      // Instead of 5 StringReplaces, we just check if it ends with a common video ext
      // You can keep this list or use an array with IndexText
      Result := Trim(NamePart);
    end;
  except
    on E: Exception do
    begin
      LogError(sb(['Error extracting episode name from: ',
        Copy(FileName, 1, 50)]), E);
      Result := '';
    end;
  end;
end;

function TEpisodeMatcher.ExtractTitleFromFilename(
  const FileName, EpisodeNumber: String): String;
var
  CleanFileName: String = '';
  EpisodePos: Integer = 0;
  TitlePart: String = '';
begin
  Result := 'Unknown_Series';
  if Length(FileName) = 0 then Exit;
  if Length(EpisodeNumber) = 0 then
  begin
    // Fallback to cleaned filename if no episode number
    Result := SanitizeFileName(ExtractFileNameOnly(FileName));
    if Length(Result) = 0 then Result := 'Unknown_Series';
    Exit;
  end;
  try
    // Clean filename using actual Lazarus functions, then the sanitizer
    CleanFileName := ExtractFileName(SafeExpandFilename(FileName));
    CleanFileName := SanitizeFileName(ExtractFileNameOnly(CleanFileName));
    // Find position of episode number in filename
    EpisodePos := PosInsensitive(EpisodeNumber, CleanFileName);
    if EpisodePos > 1 then
    begin
      // Extract everything before the episode number.
      // EpisodePos is a CHARACTER position (from PosInsensitive, which is
      // UTF8-based) so the cut must be UTF8Copy - a plain Copy here would
      // use EpisodePos-1 as a BYTE count and truncate short on any title
      // with multi-byte characters before the episode marker.
      TitlePart := UTF8Copy(CleanFileName, 1, EpisodePos - 1);
      // Clean up the title part
      TitlePart := Trim(TitlePart);
      // Remove common separators from end
      while (Length(TitlePart) > 0) and
        (TitlePart[Length(TitlePart)] in ['.', '-', '_', ' ']) do
        Delete(TitlePart, Length(TitlePart), 1);
      Result := Trim(TitlePart);
    end
    else
    begin
      // If episode number not found or at beginning, use whole filename
      Result := CleanFileName;
    end;
    // Ensure we have something
    if Length(Result) = 0 then Result := 'Unknown_Series';
  except
    on E: Exception do
    begin
      LogError(sb(['Error extracting title from: ',
        Copy(FileName, 1, 50)]), E);
      Result := 'Error_Series';
    end;
  end;
end;

function TEpisodeMatcher.FormatEpStr(s: String): String;
const
  Delims: TSysCharSet = ['-', 'x', 'X', 'e', 'E'];
var
  SeasonNumber, EpisodeNumber: Integer;
begin
  Result := '';
  if s.IsEmpty then Exit;
  // 'S' is deliberately NOT in Delims - adding it there would make a
  // LEADING delimiter split field 1 as empty, breaking plain "1x01" input.
  // Instead, strip a leading S/s once, up front, so this function's own
  // output ("S01E01") is accepted back as input without the season field
  // failing to parse.
  if (s <> '') and (UpCase(s[1]) = 'S') then Delete(s, 1, 1);
  if not TryStrToInt(ExtractDelimited(1, s, Delims), SeasonNumber) then
  begin
    LogError(sb(['FormatEpStr: could not parse season from: ', s]));
    Exit;
  end;
  if not TryStrToInt(ExtractDelimited(2, s, Delims), EpisodeNumber) then
  begin
    LogError(sb(['FormatEpStr: could not parse episode from: ', s]));
    Exit;
  end;
  Result := 'S' + Format('%.*d', [2, SeasonNumber]) + 'E' +
    Format('%.*d', [2, EpisodeNumber]);
end;

function TEpisodeMatcher.GetEpNumName(const curFile: String): TEpisodeMatch;
var
  EpisodePart, EpNameCandidate, MatchedText, SeasonPart: String;
  Pattern: TEpisodePattern;
begin
  Result := Default(TEpisodeMatch); // Zeros out strings, booleans, and objects
  if curFile.IsEmpty then Exit;
  for Pattern in FPatterns do
  begin
    // HUGE SPEED BOOST: No compilation happens here anymore.
    // We just reuse the engine that was built at startup!
    if not Pattern.Engine.Exec(curFile) then Continue;
    // Bare numeric patterns (NxN and the \d{3}/\d{4} fallbacks) have no S/E
    // letters to anchor on, so their first match in the file might be a
    // resolution, codec tag, or year rather than a real episode marker.
    // Walk forward to the first clean occurrence, or give up on this
    // pattern entirely if none exists. Patterns with real S/E letters
    // can't be confused this way, so they skip this check completely.
    if Pattern.NumericGuard and not
      AdvanceToUnambiguousMatch(Pattern, curFile) then Continue;
    // TRegExpr stores the match results inside the engine instance itself
    MatchedText := Pattern.Engine.Match[0];
    if MatchedText.IsEmpty then Continue;
    SeasonPart := SafeCopy(MatchedText, Pattern.SeasonPos, Pattern.SeasonLen);
    EpisodePart := SafeCopy(MatchedText, Pattern.EpisodePos,
      Pattern.EpisodeLen);
    if SeasonPart.IsEmpty or EpisodePart.IsEmpty then Continue;
    Result.EpNum := BuildEpisodeNumber(SeasonPart, EpisodePart,
      Pattern.AddSeasonZero, Pattern.AddEpisodeZero);
    if Result.EpNum.IsEmpty then Continue;
    // --- SUCCESS PATH ---
    // Fixed issue with out-of-order resolution/codec occurring before
    // Season/Episode info.  Now uses Copy, rather than RegEx split.
    EpNameCandidate := Copy(curFile, Pattern.Engine.MatchPos[0] +
      Pattern.Engine.MatchLen[0], MaxInt);
    if EpNameCandidate.IsNotEmpty then Result.EpName := EpNameCandidate;
    Result.Found := True;
    Break;
  end;
  if IsDebugBuild and not Result.Found then
    DebugLog(sb(['No episode pattern found in file: ', Copy(curFile, 1, 100)]));
end;

function TEpisodeMatcher.HasNumericNeighbourConflict(const AFileName: String;
  MatchStart, MatchLength: Integer): Boolean;
const
  BeforeSet: TSysCharSet = ['0'..'9', 'x', 'X'];
  AfterSet: TSysCharSet = ['0'..'9', 'x', 'X', 'p', 'P', 'i', 'I'];
begin
  // MatchStart/MatchLength come straight from TRegExpr's MatchPos[0] /
  // MatchLen[0], which - like AFileName itself - are byte offsets into the
  // (UTF-8) AnsiString, not UTF8 character offsets (see TRegExpr's own
  // RegExprString = AnsiString definition). Plain byte indexing below is
  // still safe on a filename holding multi-byte characters: every char
  // tested for here is plain ASCII, and a UTF-8 continuation byte (always
  // >= $80) can never equal any of them, so it always, correctly, reads as
  // "not a conflicting neighbour".
  Result :=
    ((MatchStart > 1) and (AFileName[MatchStart - 1] in BeforeSet)) or
    ((MatchStart + MatchLength <= Length(AFileName)) and
    (AFileName[MatchStart + MatchLength] in AfterSet));
end;

//jcf:format=off
procedure TEpisodeMatcher.InitializePatterns;
const F = False; T = True;
begin
  FPatterns.Clear;
  // Regex Pattern                SP SL EP EL ASZ AEZ  NG  Pattern Name
  //
  // --- explicit S..E.. markers: unambiguous (NG always False) ---
  // Each 3-digit-episode pattern is listed *before* its 2-digit sibling in
  // the same season-width group. \d{2} right after E is perfectly happy
  // matching just the first two digits of a 3-digit episode number
  // (S01E100 -> match "S01E10", dropping the trailing "0"), so whichever
  // pattern is tried first wins, and the longer one has to go first.
  FPatterns.Add(TEpisodePattern.Create('[Ss]\d{2}[Ee]\d{3}',   2, 2, 5, 3, F, F, F, 'S01E100'));
  FPatterns.Add(TEpisodePattern.Create('[Ss]\d{2}\.[Ee]\d{3}', 2, 2, 6, 3, F, F, F, 'S01.E100'));
  FPatterns.Add(TEpisodePattern.Create('[Ss]\d{2}[Ee]\d{2}',   2, 2, 5, 2, F, F, F, 'S01E01'));
  FPatterns.Add(TEpisodePattern.Create('[Ss]\d{2}\.[Ee]\d{2}', 2, 2, 6, 2, F, F, F, 'S01.E01'));
  FPatterns.Add(TEpisodePattern.Create('[Ss]\d{2}[Ee]\d{1}',   2, 2, 5, 1, F, T, F, 'S01E1'));
  FPatterns.Add(TEpisodePattern.Create('[Ss]\d{2}\.[Ee]\d{1}', 2, 2, 6, 1, F, T, F, 'S01.E1'));
  FPatterns.Add(TEpisodePattern.Create('[Ss]\d{1}[Ee]\d{3}',   2, 1, 4, 3, T, F, F, 'S1E100'));
  FPatterns.Add(TEpisodePattern.Create('[Ss]\d{1}\.[Ee]\d{3}', 2, 1, 5, 3, T, F, F, 'S1.E100'));
  FPatterns.Add(TEpisodePattern.Create('[Ss]\d{1}[Ee]\d{2}',   2, 1, 4, 2, T, F, F, 'S1E01'));
  FPatterns.Add(TEpisodePattern.Create('[Ss]\d{1}\.[Ee]\d{2}', 2, 1, 5, 2, T, F, F, 'S1.E01'));
  FPatterns.Add(TEpisodePattern.Create('[Ss]\d{1}[Ee]\d{1}',   2, 1, 4, 1, T, T, F, 'S1E1'));
  // --- NxN and bare-digit fallbacks: no S/E letters at all, so these are
  // the ones a resolution (1920x1080), a codec tag (x264/x265), or a bare
  // year (2019) can be mistaken for. NG=True routes them through
  // AdvanceToUnambiguousMatch / IsKnownNonEpisodeToken in GetEpNumName
  // instead of regex lookaround: the RegExpr unit as shipped with stock
  // FPC/Lazarus does not implement (?=..)/(?!..)/(?<=..)/(?<!..) at all -
  // confirmed against FPC 3.2.2's bundled regexpr.pas, where every one of
  // those raises "TRegExpr compile: unrecognized modifier" at runtime. The
  // updated Sorokin/Torgashin engine that does support them isn't what FPC
  // packages by default (see fpc-pascal list, "TRegExpr in FPC 3.2.4 is
  // still old", Jan 2025) - so this stays plain, portable regex plus a
  // small amount of Pascal either side of Exec/ExecNext.
  FPatterns.Add(TEpisodePattern.Create('\d{2}[Xx]\d{2}',       1, 2, 4, 2, F, F, T, '01x01'));
  FPatterns.Add(TEpisodePattern.Create('\d{1}[Xx]\d{2}',       1, 1, 3, 2, T, F, T, '1x01'));
  FPatterns.Add(TEpisodePattern.Create('\d{2}[Xx]\d{1}',       1, 2, 4, 1, F, T, T, '01x1'));
  FPatterns.Add(TEpisodePattern.Create('\d{1}[Xx]\d{1}',       1, 1, 3, 1, T, T, T, '1x1'));
  FPatterns.Add(TEpisodePattern.Create('\d{4}',                1, 2, 3, 2, F, F, T, '1001'));
  FPatterns.Add(TEpisodePattern.Create('\d{3}',                1, 1, 2, 2, T, F, T, '101'));
end;

function TEpisodeMatcher.IsKnownNonEpisodeToken(const Digits: String): Boolean;
const
  // 3-digit resolution/codec tags. Mostly belt-and-braces on top of
  // HasNumericNeighbourConflict, for a bare token that lost its tell-tale
  // neighbour to earlier cleanup (e.g. a lone "264" with the "x" gone).
  ExcludedTriples: array[0..3] of String = ('720', '480', '264', '265');
  // 4-digit resolution tags, same reasoning. Deliberately no 19xx/20xx
  // "looks like a year" check here - a bare 4-digit fallback match is
  // allowed to stand as SxxExx even for season 19/20, since a false
  // negative on a genuine year is judged the lesser cost for this
  // collection than mis-parsing a real season-19+ dailies show.
  ExcludedQuads: array[0..1] of String = ('1080', '2160');
var
  i: Integer;
begin
  Result := False;
  case Length(Digits) of
    3:
      for i := Low(ExcludedTriples) to High(ExcludedTriples) do
        if Digits = ExcludedTriples[i] then Exit(True);
    4:
      for i := Low(ExcludedQuads) to High(ExcludedQuads) do
        if Digits = ExcludedQuads[i] then Exit(True);
  end;
end;

function TEpisodeMatcher.SanitizeFileName(const AFileName: String): String;
begin
  if Assigned(FOnSanitizeFileName) then
    Result := FOnSanitizeFileName(AFileName)
  else
    Result := Trim(ExtractFileName(AFileName));
  if Result.IsEmpty then Result := 'unnamed_file';
end;

function TEpisodeMatcher.ValidateEpisodeNumber(
  const EpisodeNum: String): Boolean;
var
  L: Integer;
begin
  Result := False;
  L := Length(EpisodeNum);
  // Minimum possible length is 4: "S1E1"
  if L < 4 then Exit;
  // Must start with 'S'
  if (EpisodeNum[1] <> 'S') and (EpisodeNum[1] <> 's') then Exit;
  // The logic: Find the 'E', ensure digits exist between S and E, and after E.
  // This mimics your '^S\d{1,2}E\d{1,2}' pattern exactly.
  // Check S digits (position 2 and maybe 3)
  if not (EpisodeNum[2] in ['0'..'9']) then Exit;
  if EpisodeNum[3] in ['0'..'9'] then
  begin
    if L < 5 then Exit; //prevent Range check error
    // Format is SxxE...
    if UpCase(EpisodeNum[4]) <> 'E' then Exit;
    // Check E digits
    if not (EpisodeNum[5] in ['0'..'9']) then Exit;
  end
  else
  begin
    // Format is SxE...
    if UpCase(EpisodeNum[3]) <> 'E' then Exit;
    // Check E digits
    if not (EpisodeNum[4] in ['0'..'9']) then Exit;
  end;
  Result := True;
end;

destructor TEpisodeMatcher.Destroy;
begin
  FreeAndNil(FPatterns);
  //TObjectList frees each TEpisodePattern, which frees its FRegEx
  inherited Destroy;
end;
//jcf:format=on

{$ENDREGION}

initialization
  DebugLog('uEpisodeMatching.pas initialization');

end.
