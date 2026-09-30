{ Filey - uReleaseGroup.pas

Copyright (C) 2026 Mark A Paley

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program; if not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>.

Report bugs and questions at <https://gitlab.com/MarkAPaley/filey/-/issues>..
}

{ ==============================================================================
   uReleaseGroup

   A guessit-style (https://github.com/guessit-io/guessit) release-group
   guesser: given a video (or subtitle) file name, work out which scene / P2P
   / fansub group produced it, if any. Plus the small amount of Matroska
   plumbing needed to embed the result as a global tag via mkvpropedit.

   Conventions recognised, tried in this order:

     1. Trailing, dash-glued group      Show.S01E01.720p.HDTV.x264-LOL.mkv
                                        Movie.2019.1080p.WEB.H264-NTb[TGx].mkv
                                        Show.S01E01.WEB.h264-GRP-xpost.mkv
     2. Leading [bracket] (fansubs)     [SubsPlease] Show - 01 (1080p) [A1B2C3D4].mkv
     3. Trailing [bracket] / (paren)    Movie (2019) [1080p] [BluRay] [YTS.MX].mp4
        including the QxR-style         Movie (2019) (1080p BluRay x265 10bit Tigole).mkv
        "last word of a technical
        parenthesis" form

   Before any of that, the tail of the name is cleaned: known media/subtitle
   extensions, subtitle language suffixes (.en.srt), indexer/site tags
   ([eztv.re], [rarbg], [TGx], ...), repost/obfuscation suffixes (-xpost,
   -Obfuscated, ...), and browser duplicate markers ("(1)").

   Strict mode (the default) only accepts a dash-glued group when the token
   right before the dash is itself something technical - a codec, source,
   resolution, audio format, year/number, episode marker or release flag
   (x264-LOL, 1080p-GRP, HDTV-LOL, H.264-NTb, 2019-GRP). This is what stops
   hyphenated titles such as "Show.S01E01.Spider-Man.mkv" from reporting a
   group called "Man". Turn it off only for collections where groups
   routinely follow plain words.

   Unicode: every delimiter this unit splits or tests on is plain ASCII, and
   no byte of a multi-byte UTF-8 sequence can equal an ASCII byte, so
   byte-wise scanning never splits a character. Lengths are measured in
   codepoints (UTF8Length), and any non-ASCII byte counts as a "letter" when
   deciding whether a candidate is a name rather than a number, so groups
   such as "Группа" are accepted.

   Standard objfpc mode only - no Delphi-mode constructs. The regex is
   plain TRegExpr syntax (no lookaround, no (?:...)), which the RegExpr unit
   shipped with stock FPC 3.2.x supports.

   Not thread-safe: a TReleaseGroupGuesser owns a single TRegExpr. Use one
   instance per thread, or the GuessReleaseGroup convenience function from
   the main thread only.
============================================================================== }

unit uReleaseGroup;

{$mode objfpc}
{$H+}

interface

uses
  Classes, LazUTF8, RegExpr, SysUtils;

const
  // Matroska tag used by default when embedding the group. ENCODED_BY is an
  // official Matroska tag ("the person or organisation that encoded the
  // item") that MediaInfo, ffprobe, mpv, VLC, etc. all display. Pass a
  // custom name (e.g. 'RELEASE_GROUP') to the tag routines below if you'd
  // rather keep it separate from ENCODED_BY.
  RELEASE_GROUP_DEFAULT_TAG = 'ENCODED_BY';

type
  { TReleaseGroupGuesser }
  TReleaseGroupGuesser = class
  private
    FStrict: Boolean;
    FTechRegEx: TRegExpr; // numeric/pattern-shaped technical tokens
    function BracketFallback(ABrackets: TStrings): String;
    function IsTechnicalToken(const AToken: String): Boolean;
    function IsValidGroup(const ACandidate: String;
      AAllowSpaces: Boolean): Boolean;
    function LastWordOfTechnicalPhrase(const APhrase: String): String;
    function StripTail(const AName: String; ABrackets: TStrings): String;
    function TryDashGroup(const ACore: String): String;
    function TryLeadingBracket(const ACore: String): String;

  public
    constructor Create;
    // Returns the release group guessed from AFileName (a bare file name or
    // a full path in either / or \ form), or '' if none could be found. The
    // group is returned exactly as written in the name (case preserved).
    function Guess(const AFileName: String): String;
    destructor Destroy; override;
    property Strict: Boolean read FStrict write FStrict;
  end;

// Convenience wrapper around a lazily-created, unit-owned
// TReleaseGroupGuesser. Main thread only (see the banner above).
function GuessReleaseGroup(const AFileName: String;
  AStrict: Boolean = True): String;

// Escapes &, <, >, " and ' for use inside XML text. UTF-8 in, UTF-8 out.
function XmlEscape(const s: String): String;

// Builds a Matroska tags XML document (the format mkvpropedit's --tags and
// mkvmerge's --global-tags accept) holding one global SimpleTag, ATagName =
// AGroup, targeted at TargetTypeValue 50 (movie / episode level). Returns
// '' if AGroup or ATagName is empty.
function BuildReleaseGroupTagsXml(const AGroup: String;
  const ATagName: String = RELEASE_GROUP_DEFAULT_TAG): String;

// Writes BuildReleaseGroupTagsXml's output to AXmlFileName as UTF-8 (no
// BOM). Returns True on success, False on empty input or any I/O error;
// never raises.
function WriteReleaseGroupTagsFile(const AGroup, AXmlFileName: String;
  const ATagName: String = RELEASE_GROUP_DEFAULT_TAG): Boolean;

implementation

const
  // Separators between tokens in a release name.
  TOKEN_DELIMS: TSysCharSet = [' ', '.', '_', '-', '[', ']', '(', ')',
    '{', '}', '+', ',', '~'];
  // What gets trimmed off the right-hand end while cleaning the tail.
  TAIL_TRIM: TSysCharSet = [' ', '.', '_', '-', #9];

  MIN_GROUP_CODEPOINTS = 2;
  MAX_GROUP_CODEPOINTS = 40;

  // Extensions stripped before parsing. Only these - a blind
  // ChangeFileExt would eat the ".MX" of an extension-less "...[YTS.MX]".
  MEDIA_EXTS: array[0..22] of String = (
    '.mkv', '.mp4', '.m4v', '.avi', '.mov', '.wmv', '.webm', '.ts', '.m2ts',
    '.mts', '.mpg', '.mpeg', '.flv', '.ogm', '.divx', '.vob', '.3gp',
    '.rmvb', '.nfo', '.part', '.!qb', '.crdownload', '.tmp');
  SUBTITLE_EXTS: array[0..6] of String = (
    '.srt', '.ass', '.ssa', '.sub', '.idx', '.vtt', '.sup');
  // Language / flavour suffixes that sit between a subtitle's release name
  // and its extension: Show.S01E01.720p.HDTV.x264-LOL.en.forced.srt
  SUBTITLE_SUFFIXES: array[0..27] of String = (
    'en', 'eng', 'english', 'fr', 'fre', 'fra', 'de', 'ger', 'deu', 'es',
    'spa', 'it', 'ita', 'nl', 'dut', 'nld', 'pt', 'por', 'ja', 'jpn', 'ru',
    'rus', 'forced', 'sdh', 'hi', 'cc', 'default', 'full');

  // Indexer / tracker / re-poster tags. Never a release group themselves;
  // stripped from the tail and ignored as bracket candidates. (RARBG is
  // deliberately NOT here: "-RARBG" is also a group name on their own
  // encodes.)
  KNOWN_SITES: array[0..16] of String = (
    'eztv', 'eztv.re', 'eztv.io', 'eztv.ag', 'eztv.it', 'ettv', 'tgx',
    'torrentgalaxy', 'torrentgalaxy.to', 'rartv', '1337x', '1337x.to',
    'publichd', 'vtv', 'xpost', 'rarbg.to', 'www');

  // Repost / obfuscation / indexer junk that follows the real group:
  // ...x264-KILLERS-xpost, ...H264-NTb-Obfuscated, ...-GRP-AsRequested
  JUNK_SUFFIXES: array[0..12] of String = (
    'xpost', 'postbot', 'obfuscated', 'scrambled', 'asrequested', 'repost',
    'rp', 'sample', 'whiterev', 'buymore', 'rakuten', 'converted', 'dirfix');

  // Word-shaped technical tokens: sources, codecs, containers, streaming
  // services, audio, HDR, editions, release flags. Anything numeric or
  // pattern-shaped (1080p, x264, DDP5.1, S01E01, 10bit, ...) is covered by
  // TECH_PATTERN instead.
  TECH_WORDS: array[0..133] of String = (
    // sources
    'web', 'webrip', 'webdl', 'web-dl', 'dl', 'rip', 'hdtv', 'pdtv', 'sdtv',
    'dsr', 'dsrip', 'tvrip', 'hdrip', 'dvd', 'dvdrip', 'dvdr', 'dvd5',
    'dvd9', 'bluray', 'blu', 'ray', 'bdrip', 'brrip', 'bd', 'bdremux',
    'remux', 'uhd', 'hd', 'fhd', 'sd', 'cam', 'hdcam', 'telesync', 'tc',
    'scr', 'screener', 'dvdscr', 'r5', 'vhs', 'vhsrip', 'laserdisc', 'hddvd',
    // streaming services
    'amzn', 'nf', 'dsnp', 'hmax', 'atvp', 'hulu', 'pcok', 'pmtp', 'max',
    'itunes', 'stan', 'crav', 'cr', 'funi', 'vrv',
    // video codecs / containers
    'hevc', 'avc', 'xvid', 'divx', 'av1', 'vp9', 'mpeg2', 'vc1', 'mp4',
    'mkv', 'hdr', 'hdr10', 'hdr10plus', 'dv', 'dovi', 'sdr', 'hlg',
    // audio
    'aac', 'ac3', 'eac3', 'dd', 'ddp', 'dts', 'ma', 'hra', 'truehd',
    'atmos', 'flac', 'mp3', 'opus', 'lpcm', 'pcm', 'dual', 'multi', 'audio',
    'dubbed', 'subbed', 'dub', 'sub', 'subs', 'hardsub', 'hc',
    // editions / release flags
    'proper', 'repack', 'rerip', 'real', 'internal', 'limited', 'extended',
    'unrated', 'uncut', 'uncensored', 'remastered', 'directors', 'cut',
    'theatrical', 'imax', 'criterion', 'hybrid', 'custom', 'complete',
    'readnfo', 'nfofix', 'ws', 'fs', 'ntsc', 'pal', '3d', 'sbs', 'hsbs',
    'ou', 'hou', 'open', 'matte', 'season', 'part', 'episode');

  // Country / region codes that appear in trailing parentheses of show
  // names - "The Office (US)" - and so must never be read as a group.
  COUNTRY_CODES: array[0..11] of String = (
    'us', 'uk', 'gb', 'au', 'ca', 'nz', 'ie', 'fr', 'de', 'jp', 'kr', 'es');

  // Pattern-shaped technical tokens, matched whole and case-insensitively:
  //   123 / 2019          all digits (years, episode numbers, "264" of H.264)
  //   1080p 720i          resolutions            4k 8k
  //   S01 S01E01E02       season / episode       E01 EP01
  //   1x01 01x02          NxN episode            v2 v3 (fansub versions)
  //   10bit 8bits 6ch     depth / channels       x264 h265 h.264
  //   DDP5.1 AAC2.0 5.1   audio + channel layout
  TECH_PATTERN =
    '^(\d+|\d{3,4}[pi]|\d{1,2}k|s\d{1,2}(e\d{1,4})*|ep?\d{1,4}|' +
    '\d{1,2}x\d{1,4}|v\d{1,2}|\d{1,2}bits?|\d{1,2}ch|[hx]\.?26[2345]|' +
    '(dd|ddp|aac|dts|eac3|ac3|truehd|flac|opus|atmos|lpcm|pcm)?\d{1,2}' +
    '(\.\d)?)$';

  // CRC32 checksums fansubbers append: [A1B2C3D4]
  CRC32_LENGTH = 8;

var
  _Guesser: TReleaseGroupGuesser = nil;

{$REGION 'Local helpers'}

function CountChar(const s: String; ACh: Char): Integer;
var
  c: Char;
begin
  Result := 0;
  for c in s do if c = ACh then Inc(Result);
end;

function EndsText(const ASuffix, s: String): Boolean;
begin
  Result := (Length(s) >= Length(ASuffix)) and
    SameText(Copy(s, Length(s) - Length(ASuffix) + 1, Length(ASuffix)),
    ASuffix);
end;

// True if s contains an ASCII letter, or any non-ASCII byte (i.e. a UTF-8
// encoded character, which for group-name purposes counts as a letter).
function HasLetter(const s: String): Boolean;
var
  c: Char;
begin
  for c in s do
    if (c in ['A'..'Z', 'a'..'z']) or (Ord(c) >= $80) then Exit(True);
  Result := False;
end;

function InList(const s: String; const AList: array of String): Boolean;
var
  i: Integer;
begin
  // SameText is ASCII case-insensitive, which is exactly right here: every
  // list entry is ASCII, and a non-ASCII candidate simply never matches.
  for i := Low(AList) to High(AList) do
    if SameText(s, AList[i]) then Exit(True);
  Result := False;
end;

function IsCRC32(const s: String): Boolean;
var
  c: Char;
begin
  Result := Length(s) = CRC32_LENGTH;
  if Result then
    for c in s do
      if not (c in ['0'..'9', 'A'..'F', 'a'..'f']) then Exit(False);
end;

// Last token of s, splitting on ADelims. '' if s ends with a delimiter.
function LastToken(const s: String; const ADelims: TSysCharSet): String;
var
  p: Integer;
begin
  p := Length(s);
  while (p > 0) and not (s[p] in ADelims) do Dec(p);
  Result := Copy(s, p + 1, MaxInt);
end;

function SplitWords(const s: String): TStringList;
begin
  Result := TStringList.Create;
  Result.Delimiter := ' ';
  Result.StrictDelimiter := True;
  Result.DelimitedText := s;
end;

function TrimRightSet(const s: String; const ASet: TSysCharSet): String;
var
  p: Integer;
begin
  p := Length(s);
  while (p > 0) and (s[p] in ASet) do Dec(p);
  Result := Copy(s, 1, p);
end;

{$ENDREGION}

{$REGION 'TReleaseGroupGuesser'}

constructor TReleaseGroupGuesser.Create;
begin
  inherited Create;
  FStrict := True;
  FTechRegEx := TRegExpr.Create;
  FTechRegEx.ModifierI := True;
  FTechRegEx.Expression := TECH_PATTERN;
  FTechRegEx.Compile;
end;

function TReleaseGroupGuesser.BracketFallback(ABrackets: TStrings): String;
var
  Cand: String;
  HasTechBracket: Boolean;
  i: Integer;
begin
  Result := '';
  // Is there at least one purely technical trailing bracket ([1080p],
  // (2019), [BluRay], [A1B2C3D4])? In strict mode a lone single-word
  // bracket needs that company - otherwise "Some Show (Revival).mkv" would
  // report a group called "Revival".
  HasTechBracket := False;
  for i := 0 to ABrackets.Count - 1 do
    if IsTechnicalToken(ABrackets[i]) or IsCRC32(ABrackets[i]) then
    begin
      HasTechBracket := True;
      Break;
    end;

  for i := 0 to ABrackets.Count - 1 do
  begin
    Cand := ABrackets[i];
    if Pos(' ', Cand) > 0 then
    begin
      Result := LastWordOfTechnicalPhrase(Cand);
      if Result <> '' then Exit;
      Continue;
    end;
    if IsCRC32(Cand) or not IsValidGroup(Cand, False) then Continue;
    if FStrict and not HasTechBracket and (Pos('.', Cand) = 0) then Continue;
    Exit(Cand);
  end;
end;

function TReleaseGroupGuesser.Guess(const AFileName: String): String;
var
  Brackets: TStringList;
  Core, Name: String;
begin
  Result := '';
  // ExtractFileName honours both / and \ (AllowDirectorySeparators), so a
  // Windows path handed over from a Wine-side dialog still works on Linux.
  Name := ExtractFileName(AFileName);
  if Trim(Name) = '' then Exit;
  Brackets := TStringList.Create;
  try
    Core := StripTail(Name, Brackets);
    if Core = '' then
    begin
      Result := BracketFallback(Brackets);
      Exit;
    end;
    Result := TryDashGroup(Core);
    if Result <> '' then Exit;
    Result := TryLeadingBracket(Core);
    if Result <> '' then Exit;
    Result := BracketFallback(Brackets);
  finally
    Brackets.Free;
  end;
end;

function TReleaseGroupGuesser.IsTechnicalToken(const AToken: String): Boolean;
begin
  if AToken = '' then Exit(False);
  Result := InList(AToken, TECH_WORDS) or FTechRegEx.Exec(AToken);
end;

function TReleaseGroupGuesser.IsValidGroup(const ACandidate: String;
  AAllowSpaces: Boolean): Boolean;
var
  Cand, Left, Right: String;
  DotPos, Len, i: Integer;
  Words: TStringList;
begin
  Result := False;
  Cand := Trim(ACandidate);
  Len := UTF8Length(Cand);
  if (Len < MIN_GROUP_CODEPOINTS) or (Len > MAX_GROUP_CODEPOINTS) then Exit;
  if LastDelimiter('[](){}', Cand) > 0 then Exit;
  if not HasLetter(Cand) then Exit;
  if InList(Cand, KNOWN_SITES) or InList(Cand, COUNTRY_CODES) or
    InList(Cand, JUNK_SUFFIXES) then Exit;

  if Pos(' ', Cand) > 0 then
  begin
    if not AAllowSpaces then Exit;
    // A multi-word bracket such as "[Anime Time]" is fine, but one made
    // purely of technical words ("[Multi Subs]", "[1080p HEVC]") is not.
    Words := SplitWords(Cand);
    try
      for i := 0 to Words.Count - 1 do
        if (Words[i] <> '') and not IsTechnicalToken(Words[i]) then
          Exit(True);
    finally
      Words.Free;
    end;
    Exit(False);
  end;

  if IsTechnicalToken(Cand) then Exit;

  // Dotted candidates are only accepted when shaped like a domain-style
  // group name (YTS.MX, YTS.AM): exactly one dot, a non-technical name
  // before it and a 2-3 letter suffix after it. Anything else with a dot
  // is a run of tokens the dash didn't really terminate - "DL.1080p" from
  // "WEB-DL.1080p", "HD.MA.5.1" from "DTS-HD.MA.5.1".
  DotPos := Pos('.', Cand);
  if DotPos > 0 then
  begin
    if CountChar(Cand, '.') <> 1 then Exit;
    Left := Copy(Cand, 1, DotPos - 1);
    Right := Copy(Cand, DotPos + 1, MaxInt);
    if (Length(Left) < 2) or IsTechnicalToken(Left) then Exit;
    if not (Length(Right) in [2..3]) or IsTechnicalToken(Right) or
      InList(Right, SUBTITLE_SUFFIXES) then Exit;
    for i := 1 to Length(Right) do
      if not (Right[i] in ['A'..'Z', 'a'..'z']) then Exit;
  end;
  Result := True;
end;

function TReleaseGroupGuesser.LastWordOfTechnicalPhrase(
  const APhrase: String): String;
var
  i, Last: Integer;
  Words: TStringList;
begin
  // "(1080p BluRay x265 HEVC 10bit AAC 5.1 Tigole)" -> "Tigole": the last
  // word is a plausible group and every word before it is technical.
  Result := '';
  Words := SplitWords(APhrase);
  try
    for i := Words.Count - 1 downto 0 do
      if Trim(Words[i]) = '' then Words.Delete(i);
    if Words.Count < 2 then Exit;
    Last := Words.Count - 1;
    for i := 0 to Last - 1 do
      if not IsTechnicalToken(Words[i]) then Exit;
    if IsValidGroup(Words[Last], False) and not IsCRC32(Words[Last]) then
      Result := Words[Last];
  finally
    Words.Free;
  end;
end;

function TReleaseGroupGuesser.StripTail(const AName: String;
  ABrackets: TStrings): String;
var
  Changed, IsSubtitle: Boolean;
  Closer, Opener: Char;
  Depth, i, p: Integer;
  Ext, Tok: String;
begin
  Result := Trim(AName);

  // 1. Known extension (plus, for subtitles, any language/flavour suffixes).
  IsSubtitle := False;
  Ext := ExtractFileExt(Result);
  if (Ext <> '') and (InList(Ext, MEDIA_EXTS) or InList(Ext, SUBTITLE_EXTS)) then
  begin
    IsSubtitle := InList(Ext, SUBTITLE_EXTS);
    SetLength(Result, Length(Result) - Length(Ext));
  end;
  if IsSubtitle then
    repeat
      Tok := LastToken(Result, ['.']);
      Changed := (Tok <> Result) and InList(Tok, SUBTITLE_SUFFIXES);
      if Changed then SetLength(Result, Length(Result) - Length(Tok) - 1);
    until not Changed;

  // 2. Peel bracket blocks and junk suffixes off the end until neither is
  //    left. Bracket contents are kept (innermost-last order = rightmost
  //    first) for BracketFallback.
  repeat
    Changed := False;
    Result := TrimRightSet(Result, TAIL_TRIM);
    if Result = '' then Break;

    Closer := Result[Length(Result)];
    if Closer in [']', ')', '}'] then
    begin
      case Closer of
        ']': Opener := '[';
        ')': Opener := '(';
        else Opener := '{';
      end;
      Depth := 0;
      p := Length(Result);
      while p > 0 do
      begin
        if Result[p] = Closer then Inc(Depth)
        else if Result[p] = Opener then
        begin
          Dec(Depth);
          if Depth = 0 then Break;
        end;
        Dec(p);
      end;
      if p > 0 then
      begin
        ABrackets.Add(Trim(Copy(Result, p + 1, Length(Result) - p - 1)));
        SetLength(Result, p - 1);
        Changed := True;
        Continue;
      end;
      Break; // unbalanced - leave it alone
    end;

    Tok := LastToken(Result, TOKEN_DELIMS);
    if (Tok <> '') and (Length(Tok) < Length(Result)) and
      (InList(Tok, JUNK_SUFFIXES) or InList(Tok, KNOWN_SITES)) then
    begin
      SetLength(Result, Length(Result) - Length(Tok));
      Changed := True;
    end;
  until not Changed;

  // Site tags glued on as ".eztv.re"-style dotted suffixes.
  for i := Low(KNOWN_SITES) to High(KNOWN_SITES) do
    if (Pos('.', KNOWN_SITES[i]) > 0) and
      EndsText('.' + KNOWN_SITES[i], Result) then
    begin
      SetLength(Result, Length(Result) - Length(KNOWN_SITES[i]) - 1);
      Result := TrimRightSet(Result, TAIL_TRIM);
      Break;
    end;
end;

function TReleaseGroupGuesser.TryDashGroup(const ACore: String): String;
var
  Cand: String;
  p: Integer;
begin
  Result := '';
  p := LastDelimiter('-', ACore);
  if (p <= 1) or (p >= Length(ACore)) then Exit;
  // Must be glued on both sides: "x264-LOL", not "Show - 01".
  if (ACore[p - 1] in [' ', #9]) or (ACore[p + 1] in [' ', #9]) then Exit;
  Cand := Copy(ACore, p + 1, MaxInt);
  if Pos(' ', Cand) > 0 then Exit;
  if not IsValidGroup(Cand, False) then Exit;
  if FStrict and not IsTechnicalToken(
    LastToken(Copy(ACore, 1, p - 1), TOKEN_DELIMS)) then Exit;
  Result := Cand;
end;

function TReleaseGroupGuesser.TryLeadingBracket(const ACore: String): String;
var
  Cand: String;
  p: Integer;
begin
  Result := '';
  if (ACore = '') or (ACore[1] <> '[') then Exit;
  p := Pos(']', ACore);
  if p < 3 then Exit;
  Cand := Trim(Copy(ACore, 2, p - 2));
  if IsCRC32(Cand) then Exit;
  if IsValidGroup(Cand, True) then Result := Cand;
end;

destructor TReleaseGroupGuesser.Destroy;
begin
  FreeAndNil(FTechRegEx);
  inherited Destroy;
end;

{$ENDREGION}

{$REGION 'Public routines'}

function BuildReleaseGroupTagsXml(const AGroup: String;
  const ATagName: String): String;
var
  Builder: TStringBuilder;
begin
  Result := '';
  if (Trim(AGroup) = '') or (Trim(ATagName) = '') then Exit;
  Builder := TStringBuilder.Create(512);
  try
    Builder.Append('<?xml version="1.0" encoding="UTF-8"?>').Append(#10);
    Builder.Append('<!DOCTYPE Tags SYSTEM "matroskatags.dtd">').Append(#10);
    Builder.Append('<Tags>').Append(#10);
    Builder.Append('  <Tag>').Append(#10);
    Builder.Append('    <Targets>').Append(#10);
    Builder.Append('      <TargetTypeValue>50</TargetTypeValue>').Append(#10);
    Builder.Append('    </Targets>').Append(#10);
    Builder.Append('    <Simple>').Append(#10);
    Builder.Append('      <Name>').Append(XmlEscape(Trim(ATagName)))
      .Append('</Name>').Append(#10);
    Builder.Append('      <String>').Append(XmlEscape(Trim(AGroup)))
      .Append('</String>').Append(#10);
    Builder.Append('    </Simple>').Append(#10);
    Builder.Append('  </Tag>').Append(#10);
    Builder.Append('</Tags>').Append(#10);
    Result := Builder.ToString;
  finally
    Builder.Free;
  end;
end;

function GuessReleaseGroup(const AFileName: String; AStrict: Boolean): String;
begin
  if _Guesser = nil then _Guesser := TReleaseGroupGuesser.Create;
  _Guesser.Strict := AStrict;
  Result := _Guesser.Guess(AFileName);
end;

function WriteReleaseGroupTagsFile(const AGroup, AXmlFileName: String;
  const ATagName: String): Boolean;
var
  Stream: TFileStream;
  Xml: String;
begin
  Result := False;
  Xml := BuildReleaseGroupTagsXml(AGroup, ATagName);
  if (Xml = '') or (AXmlFileName = '') then Exit;
  try
    Stream := TFileStream.Create(AXmlFileName, fmCreate);
    try
      // String is UTF-8 throughout a Lazarus app, so its bytes are the file.
      Stream.WriteBuffer(Pointer(Xml)^, Length(Xml));
    finally
      Stream.Free;
    end;
    Result := True;
  except
    on E: Exception do Result := False;
  end;
end;

function XmlEscape(const s: String): String;
var
  c: Char;
  Builder: TStringBuilder;
begin
  if LastDelimiter('&<>"''', s) = 0 then Exit(s);
  Builder := TStringBuilder.Create(Length(s) + 16);
  try
    // Byte-wise is UTF-8 safe: none of the five escaped characters can
    // appear inside a multi-byte sequence, and the rest pass through in
    // order and reassemble exactly.
    for c in s do
      case c of
        '&': Builder.Append('&amp;');
        '<': Builder.Append('&lt;');
        '>': Builder.Append('&gt;');
        '"': Builder.Append('&quot;');
        '''': Builder.Append('&apos;');
        else Builder.Append(c);
      end;
    Result := Builder.ToString;
  finally
    Builder.Free;
  end;
end;

{$ENDREGION}

finalization
  FreeAndNil(_Guesser);

end.
