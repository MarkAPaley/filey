{ Filey - uDBF.pas

Copyright (C) 2026 Mark A Paley

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program; if not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>.

Report bugs and questions at <https://gitlab.com/MarkAPaley/filey/-/issues>.
}

{ ==============================================================================
   uDBF

   The DBF layer extracted from TForm1 (fileyfrm.pas): the TDbType/DBFs
   enumerations and TDBRecord bookkeeping record that describe the tables the
   program keeps, the SetupSchema* routines that define each table's field
   layout, and a handful of small helpers (GetDBFStatus, GetDBStatus, SafeGo,
   sAddHint) that report on or navigate a TDbf/TField using nothing but their
   own parameters.

   This unit deliberately stops at the table/field/record boundary. Creating
   the on-disk tables (TForm1.InitializeDBFs), wiring grids and event
   handlers to them (SetupDbShows/SetupDbEps/...), and anything that touches
   the status bar or the FDbf array stays on TForm1 - that orchestration
   knows about the UI and the form's global state, and doesn't belong here.
   Nothing in this unit references TForm1, Form1, or any UI control.

   ---------------------------------------------------------------------------
   READ-ONLY AND LOCKED TABLES (template support)
   ---------------------------------------------------------------------------
   Two very different things can stop a write, and this unit keeps them
   apart:

   1. Whole-table, discovered once at open (TAccessDbf.PhysicalReadOnly):
      optical media, a read-only mount or share, file permissions, the
      Windows read-only attribute, or another program holding the file in a
      way that denies writers. CheckDbfFileAccess finds this out BEFORE
      TDbf.Open (a read-write open of such a file simply fails), and
      uDBFManager.CreateAndOpenDBFs then opens the table with
      ReadOnly := True and records the reason. Nothing is allowed to
      override it: TAccessDbf refuses Edit/Insert/Delete itself (see the
      DoBefore* overrides), so the program's own "flip ReadOnly off, write,
      flip it back" helpers (PostRecord, SafeSetDbField, ...) fail cleanly
      with the reason instead of failing later at the file level.

      That is distinct from POLICY read-only - TDbf.ReadOnly set by the
      program or the user (TForm1.actReadOnlyExecute) on a perfectly
      writable file. Policy read-only may be bypassed deliberately by the
      program's own helpers; physical read-only may not.

   2. Single-record, transient, discovered only on attempt
      (TAccessDbf.LockedRecNo): another user or program holds the record
      lock. There is no cheap way to test for this in advance, so
      TAccessDbf.InternalEdit catches TDbf's own "Record locked." failure,
      remembers which record it was, raises EDbfRecordLocked with a
      friendly message, and fires OnAccessChange so the UI can show it.
      Before giving up it retries briefly (LockRetries/LockRetryDelayMS,
      default 3 x 200 ms), since most locks are another user's Post that
      clears within milliseconds. The mark clears itself on a successful
      edit or on moving to another record.

   A third state, a WORKING COPY (TAccessDbf.WorkingCopyDir), exists for
   programs that open read-only media with
   uDBFManager.TReadOnlyMediaPolicy = rmWorkingCopy: the table is copied to
   a private temp folder and opened from there, so indexes can be built and
   rows edited - but nothing is written back to the original.

   DbfStatusBadge/GetDBStatus/GetDBStatusHint turn all of this into a
   leading status-bar tag (one of the STATUS_*_TAG constants below) and a
   plain-language reason for the status bar's hint.
============================================================================== }

unit uDBF;

{$mode objfpc}
{$LONGSTRINGS ON}
{$H+}
interface

uses
  Classes, db, Dbf, SysUtils;

const
  // Lengths of DBF fields
  LEN_MAX = 254;
  LEN_TITLE = 100;
  LEN_PATH = LEN_MAX;
  LEN_DATE = 20;

  LE = LineEnding;

  // Leading status-bar tags. Exactly one (or none) is placed at the very
  // START of a status line by GetDBStatus (and by TForm1's own
  // non-DBF status lines), where TForm1.StatusBarDrawPanel recognises it
  // and paints it as a coloured badge. Leading rather than trailing so it
  // survives when a long status line is clipped at the right edge. All
  // pure ASCII, so byte-indexed Copy on them is UTF-8 safe. Shorten them
  // (e.g. 'RO') if status-bar space gets tighter - nothing else depends
  // on the literal text.
  STATUS_LOCKED_TAG = 'LOCKED';
  STATUS_READONLY_TAG = 'READ-ONLY';
  STATUS_WORKCOPY_TAG = 'COPY';

  // Name prefix for the private temp folders rmWorkingCopy creates. Also
  // used as a safety check: TAccessDbf only ever deletes a working-copy
  // folder whose name starts with this, so a bug elsewhere can never turn
  // the cleanup into "delete some arbitrary directory".
  WORKCOPY_DIR_PREFIX = 'dbfcopy-';

type
  // Enumeration for database types
  TDbType = (dbAbout = 0, dbEps = 1, dbList = 2, dbLog = 3,
    dbShows = 4, dbTempEps = 5);

  // Enumerating makes it easy to add/remove DBFs to the program. Must stay
  // in the same order as TDbType above - TForm1.InitializeDBFs relies on
  // GetEnumName(TypeInfo(DBFs), Ord(aTDbTypeValue)) lining the two enums up
  // positionally - and every name must be UPPERCASE (see the note in
  // InitializeDBFs about why a re-lowercased name here silently breaks
  // table creation on case-sensitive filesystems).
  //jcf:format=off
  DBFs = (ABOUT, EPS, LIST, LOG, SHOWS, TEMPEPS); {must be UPPERCASE}
  //jcf:format=on

  { Database record with improved management }
  TDBRecord = record
    // Physical record number saved by a caller that's about to do something
    // disruptive to aDB's cursor (currently: TForm1.tsInfoHide, before the
    // About tab's Zap-and-rebuild) and restored afterward. Deliberately a
    // plain record number rather than a TBookmark: aDB.Close/aDB.Open (as
    // done by ZapPackTable's rebuild) is not guaranteed to preserve
    // bookmarks captured before the cycle - and doesn't, in practice, for a
    // table that gets closed/reopened as part of every rebuild - so a
    // TBookmark taken beforehand is the wrong tool here. 0 means "nothing
    // saved yet"; see uDBF.SafeGo for the bounds-checked way to use this.
    aSavedRecNo: Integer;
    // Last value GetDBStatus computed for aDB.ExactRecordCount. Only
    // meaningful when aRecCountDirty is False.
    aCachedRecCount: Integer;
    aDataSource: TDataSource;
    aDB: TDbf;
    aFilterDescription: String;
    aFilterText: String;
    aIsInitialized: Boolean;
    // True until GetDBStatus next recomputes aCachedRecCount. Set True by
    // whatever could change how many rows ExactRecordCount would report:
    // TForm1.DBFRecordCountChanged (wired to every table's AfterPost/
    // AfterDelete in CreateAndOpenDBFs, so ordinary row Post/Delete/Append
    // is covered automatically regardless of which call site triggered
    // it), plus the filter-toggle and Zap/Pack call sites in fileyfrm.pas
    // that change which rows match without going through Post/Delete.
    aRecCountDirty: Boolean;
    aTabIndex: Integer;
  end;

  // Named (not anonymous) so uDBFManager's var parameters and TForm1.FDbf
  // can share the identical type - Object Pascal's var-parameter checking
  // is by declared type identity, not just structural shape, so two
  // separately-written "array[TDbType] of TDBRecord" declarations would
  // NOT be interchangeable here even though they look the same.
  TDBFArray = array[TDbType] of TDBRecord;

  // Result of probing a table file BEFORE handing it to TDbf.Open.
  TDbfFileAccess = (
    dfaWritable,    // read-write open succeeded
    dfaReadOnly,    // readable, but writes are refused (reason says why)
    dfaUnopenable); // cannot even be read (e.g. held exclusively elsewhere)

  // What uDBFManager.CreateAndOpenDBFs does with a table it finds to be
  // physically read-only. Declared here (not in uDBFManager) so TAccessDbf
  // and the status helpers below can talk about working copies too.
  TReadOnlyMediaPolicy = (
    // Open the original, read-only. Browsing works; anything that writes
    // (edits, index rebuilds, Zap/Pack, imports) is refused with a reason.
    rmOpenInPlace,
    // Copy the table (and its .MDX/.DBT companions) to a private temp
    // folder and open that instead. Everything works, including building
    // indexes the original lacks, but changes are NOT saved back to the
    // original and the copy is deleted when the table is freed.
    rmWorkingCopy);

  // Raised when anything tries to modify a physically read-only table.
  // Descends from EDatabaseError so every existing "on E: EDatabaseError"
  // handler (e.g. TForm1.actZapExecute) already catches it.
  EDbfReadOnly = class(EDatabaseError);

  // Raised when TDbf could not lock the current record because another
  // user or program holds it. Also an EDatabaseError, so
  // TDataSet.OnEditError/OnDeleteError see it and may return daRetry.
  EDbfRecordLocked = class(EDatabaseError);

  { TAccessDbf
    A TDbf that knows WHY it can't be written to. uDBFManager creates every
    table as one of these; everything else in the program keeps using
    plain TDbf variables (the free functions below accept any TDbf and
    simply report "writable, no reason" for a plain one). }
  TAccessDbf = class(TDbf)
  private
    FLockedRecNo: Integer;
    FLockReason: String;
    FLockRetries: Integer;
    FLockRetryDelayMS: Cardinal;
    FOnAccessChange: TNotifyEvent;
    FPhysicalReadOnly: Boolean;
    FReadOnlyReason: String;
    FSourcePath: String;
    FWorkingCopyDir: String;
    procedure DoAccessChange;
    procedure ForgetRecordLock;

  protected
    procedure DoAfterEdit; override;
    procedure DoAfterScroll; override;
    procedure DoBeforeDelete; override;
    procedure DoBeforeEdit; override;
    procedure DoBeforeInsert; override;
    // TDbf.InternalEdit is where the record lock is taken (TDbf's own
    // InternalDelete calls it too), so this is the one place a lock
    // failure can be recognised for both Edit and Delete.
    procedure InternalEdit; override;

  public
    constructor Create(AOwner: TComponent); override;
    // Clears the "record is locked" mark and notifies OnAccessChange.
    procedure ClearRecordLock;
    // True when the CURRENT record is the one that last failed to lock.
    function IsRecordLocked: Boolean;
    // Called by uDBFManager before Open, once CheckDbfFileAccess has found
    // the file cannot be written. AReason is a plain-language phrase such
    // as 'the disc or drive is read-only'.
    procedure MarkPhysicalReadOnly(const AReason: String);
    // Called by uDBFManager when rmWorkingCopy redirected this table to a
    // temp copy. AReason is why the original could not be used directly.
    procedure MarkWorkingCopy(const ASourcePath, ACopyDir,
      AReason: String);
    // Raises EDbfReadOnly (naming AOperation and the reason) if this table
    // is physically read-only; does nothing otherwise.
    procedure RequireWritable(const AOperation: String);
    destructor Destroy; override;
    property LockedRecNo: Integer read FLockedRecNo;
    property LockReason: String read FLockReason;
    // How many extra attempts InternalEdit makes to lock a record another
    // user holds, and how long it waits before each one. Locks held by
    // another user's quick Post usually last milliseconds, so a short
    // retry avoids reporting a lock that would have cleared on its own.
    // The wait blocks the calling thread, so keep
    // LockRetries * LockRetryDelayMS small (default 3 x 200 ms = 0.6 s).
    // Set LockRetries := 0 to report a lock immediately.
    property LockRetries: Integer read FLockRetries write FLockRetries;
    property LockRetryDelayMS: Cardinal
      read FLockRetryDelayMS write FLockRetryDelayMS;
    // Fired when the lock mark is set or cleared outside of a scroll (a
    // failed edit, a successful retry), so a status bar can refresh.
    property OnAccessChange: TNotifyEvent
      read FOnAccessChange write FOnAccessChange;
    property PhysicalReadOnly: Boolean read FPhysicalReadOnly;
    property ReadOnlyReason: String read FReadOnlyReason;
    // For a working copy: the folder the ORIGINAL table lives in.
    property SourcePath: String read FSourcePath;
    // For a working copy: the private temp folder it was copied to.
    property WorkingCopyDir: String read FWorkingCopyDir;
  end;

// ===== Schema definitions =====
// Each of these defines the field layout for one table. Call once, right
// before CreateTable, on a freshly-created TDbf.
procedure SetupSchemaAbout(aDbf: TDbf);
procedure SetupSchemaEps(aDbf: TDbf);
procedure SetupSchemaList(aDbf: TDbf);
procedure SetupSchemaLog(aDbf: TDbf);
procedure SetupSchemaShows(aDbf: TDbf);
procedure SetupSchemaTempEps(aDbf: TDbf); // mirrors SetupSchemaEps

// ===== Status / diagnostics =====
// Multi-line diagnostic dump of a table's current properties (used by
// TForm1.ShowDBFStatus for the "Show DBF status" debug view).
function GetDBFStatus(aDB: TDbf): String;

// One-line status-bar summary: [badge] table name, record position, sort,
// filter. The optional leading badge is one of the STATUS_*_TAG constants
// (see DbfStatusBadge). Recomputing ExactRecordCount is a full table walk
// (there's no query engine to cache it for us), so
// AEntry.aCachedRecCount/aRecCountDirty let repeated calls between actual
// row-count changes skip that walk - see the comment on aRecCountDirty in
// TDBRecord for what's responsible for setting it True again.
function GetDBStatus(var AEntry: TDBRecord): String;

// The plain-language explanation that belongs in the status bar's HINT
// for aDB's current badge: why it is read-only, which record is locked,
// or where a working copy lives. '' when there is nothing to explain.
function GetDBStatusHint(aDB: TDbf): String;

// The leading status-bar tag for aDB right now, or '' for a normal
// writable table. Priority: LOCKED (current record) > READ-ONLY (physical
// or policy) > COPY (working copy).
function DbfStatusBadge(aDB: TDbf): String;

// ===== Access / read-only helpers =====
// Probes AFileName WITHOUT involving TDbf: can it be opened read-write,
// only read-only, or not at all? AReason is a plain-language phrase for
// the two failure cases ('' when writable). Never raises.
function CheckDbfFileAccess(const AFileName: String;
  out AReason: String): TDbfFileAccess;

// True if aDB was opened read-only because the FILE can't be written
// (never True for a plain TDbf, or for policy read-only).
function IsPhysicallyReadOnly(aDB: TDbf): Boolean;

// True if aDB is a rmWorkingCopy temp copy of a read-only original.
function IsWorkingCopy(aDB: TDbf): Boolean;

// The reason recorded for aDB being physically read-only, or ''.
function DbfReadOnlyReason(aDB: TDbf): String;

// Raises EDbfReadOnly if aDB is physically read-only. Safe to call with
// a plain TDbf (does nothing). AOperation reads naturally after
// "Cannot ...", e.g. 'rebuild index TITLE'.
procedure RequireWritable(aDB: TDbf; const AOperation: String);

// True if aDB currently defines an index called AIndexName (case-
// insensitive, same as the rest of this program's index handling).
function DbfHasIndex(aDB: TDbf; const AIndexName: String): Boolean;

// ===== Navigation / field helpers =====
// Moves to physical record N if it exists; leaves the dataset untouched and
// returns False otherwise.
function SafeGo(const aDB: TDbf; n: LongInt): Boolean;

// "FieldName= Value" plus a line ending, or '' if the field's display text
// is blank. Used to build multi-field hint/tooltip strings.
function sAddHint(const LField: TField): String;

// ===== On-disk schema validation =====
// Reads AFileName's raw dBase header/field-descriptor bytes - no TDbf
// involved - and reports whether its field layout (name, type char, length,
// in order) matches what ADbType's SetupSchemaXxx would create today.
// Deliberately does NOT open the file via TDbf: a handful of onDisk field
// layouts (stale schema, or a handful of corrupt bytes) make the Dbf
// package's own field-construction code raise a hard access violation
// instead of a catchable Pascal exception - undetectable and uncatchable
// from here once TDbf.Open has been called. Reading the header ourselves,
// first, with nothing but bounds-checked byte access, is what lets a
// mismatch be caught safely and handled (see CreateAndOpenDBFs) before
// the file is ever handed to TDbf. Returns False (mismatch/unreadable) on
// anything it can't positively confirm as a match, including a
// missing/empty file, a truncated header, or a read error - deliberately
// fails toward "treat it as needing to be recreated" rather than toward
// "assume it's fine".
function DbfMatchesSchema(const AFileName: String; ADbType: TDbType): Boolean;

// True if AFileName is a scratch copy TDbf left behind while packing one of
// filey's in-memory tables (ABOUT, LIST, TEMPEPS): TDbf names that copy
// after the table's file name plus "_1", "_2", ..., and an in-memory table
// has no file name, so the copies were called just "_1", "_2", ... in the
// current directory. Only the header is read, as by DbfMatchesSchema, and
// the field NAMES must be exactly those of one of those tables, in order;
// field lengths are not compared, so copies made under older layouts
// (ABOUT's VALUE was once 100 characters) are recognised too.
function IsFileyTableLeftover(const AFileName: String): Boolean;

implementation

uses
  dbf_common, dbf_str, FileUtil, LazFileUtils, LazUTF8, StrUtils,
  uManagedUtils, uUtils;

function GetDBFStatus(aDB: TDbf): String;
var
  i: Integer = 0;
begin
  Result :=
    'Name= ' + aDB.Name + LE + 'FilePathFull= ' + aDB.FilePathFull +
    LE + 'TableName= ' + aDB.TableName + LE + 'Active= ' +
    IfThen(aDB.Active) + LE + 'ReadOnly= ' + IfThen(aDB.ReadOnly) +
    LE + 'Exclusive= ' + IfThen(aDB.Exclusive) + LE +
    'ControlsDisabled= ' + IfThen(aDB.ControlsDisabled) + LE;
  if IsPhysicallyReadOnly(aDB) then
    Result := Result + 'PhysicalReadOnly= True (' +
      DbfReadOnlyReason(aDB) + ')' + LE;
  if IsWorkingCopy(aDB) then
    Result := Result + 'WorkingCopyOf= ' +
      TAccessDbf(aDB).SourcePath + LE;
  if aDB.IndexFieldNames.IsNotEmpty then
    Result := Result + 'IndexFieldNames= ' + aDB.IndexFieldNames + LE;
  aDB.IndexDefs.Update;
  if aDB.IndexDefs.Count > 0 then for i := 0 to aDB.IndexDefs.Count - 1 do
    begin
      Result := Result + 'Index[' + ns(i) + '].Name= ' +
        aDB.IndexDefs.Items[i].Name + IfThen(ixunique in
        aDB.Indexes[i].Options, ' [UNIQUE]', '') + LE;
      Result := Result + 'Index[' + ns(i) + '].Expression= ' +
        aDB.IndexDefs.Items[i].Expression + LE;
    end;
  if aDB.Filter.IsNotEmpty then
    Result := Result + 'Filter= ' + aDB.Filter + LE;
  Result := Result + 'PhysicalRecCount= ' + ns(aDB.PhysicalRecordCount);
end;

function GetDBStatus(var AEntry: TDBRecord): String;
var
  aDB: TDbf;
  Badge: String;
  IsUnique: Boolean = False;
begin
  aDB := AEntry.aDB;
  if (aDB.Indexes.Count > 0) then
    IsUnique := (ixunique in aDB.Indexes[0].Options) and
      aDB.IndexName.IsNotEmpty;
  if AEntry.aRecCountDirty then
  begin
    AEntry.aCachedRecCount := aDB.ExactRecordCount;
    AEntry.aRecCountDirty := False;
  end;
  // Badge goes FIRST - see the STATUS_*_TAG constants for why.
  Badge := DbfStatusBadge(aDB);
  Result := sb([IfThen(Badge <> '', Badge + ' ', ''),
    aDB.TableName, ' RecNo:', PadLeft(ns(aDB.PhysicalRecNo), 5),
    '/', aDB.PhysicalRecordCount,
    IfThen(aDB.IndexName.IsNotEmpty, ' Sort:' + aDB.IndexName, ''),
    IfThen(AEntry.aFilterDescription.IsNotEmpty, ' Filter:' +
    AEntry.aFilterDescription, ''), IfThen(IsUnique, ' Unique', ' '),
    'Recs:', AEntry.aCachedRecCount, IfThen(aDB.TableName <>
    'LOG.DBF', '', '     Select All (Ctrl+A), Select None (Ctrl+Z)')]);
end;

function sAddHint(const LField: TField): String;
var
  LText: String;
begin
  Result := '';
  // No index check needed! The caller guarantees LField exists.
  LText := LField.DisplayText;
  if LText.IsNotBlank then Result := LField.FieldName + '= ' + LText + LE;
end;

function SafeGo(const aDB: TDbf; n: LongInt): Boolean;
begin
  Result := True;
  if (0 < n) and (n <= aDB.PhysicalRecordCount) then aDB.PhysicalRecNo := n
  else
    Result := False;
end;

procedure SetupSchemaAbout(aDbf: TDbf);
begin
  aDbf.FieldDefs.Clear;
  aDbf.FieldDefs.Add('Info', ftString, LEN_TITLE, True);
  // LEN_MAX, not LEN_TITLE: values such as PATH, the platform line and the
  // "Install with: ...  (double-click to copy ...)" hints run past 100
  // characters. ABOUT is a memory table rebuilt on every run, so there is
  // no file on disk whose layout this could break.
  aDbf.FieldDefs.Add('Value', ftString, LEN_MAX, True);
end;

procedure SetupSchemaEps(aDbf: TDbf);
begin
  aDbf.FieldDefs.Clear;
  aDbf.FieldDefs.Add('Title', ftString, LEN_TITLE, True);
  aDbf.FieldDefs.Add('EpNum', ftString, 10, True);
  aDbf.FieldDefs.Add('EpName', ftString, LEN_TITLE, True);
  aDbf.FieldDefs.Add('SortOrder', ftString, LEN_TITLE, True);
end;

procedure SetupSchemaList(aDbf: TDbf);
begin
  aDbf.FieldDefs.Clear;
  aDbf.FieldDefs.Add('DIRECTORY', ftString, LEN_TITLE, True);
  aDbf.FieldDefs.Add('TITLE', ftString, LEN_TITLE, True);
  aDbf.FieldDefs.Add('FROM', ftString, LEN_PATH, True);
  aDbf.FieldDefs.Add('FROMNAME', ftString, LEN_TITLE, True);
  aDbf.FieldDefs.Add('FROMPATH', ftString, LEN_PATH, True);
  aDbf.FieldDefs.Add('NAMENPATH', ftString, LEN_PATH, True);
  aDbf.FieldDefs.Add('EPNUM', ftString, 10, True);
  aDbf.FieldDefs.Add('EPNAME', ftString, LEN_TITLE, True);
  aDbf.FieldDefs.Add('HEIGHT', ftString, 10, True);
  aDbf.FieldDefs.Add('AUDIOCHAN', ftString, 10, True);
  aDbf.FieldDefs.Add('CODEC', ftString, 10, True);
  aDbf.FieldDefs.Add('GROUP', ftString, 30, True);
  aDbf.FieldDefs.Add('EXTENSION', ftString, 20, True);
  aDbf.FieldDefs.Add('SUBTITLES', ftString, 10, True);
  aDbf.FieldDefs.Add('TO', ftString, LEN_PATH, True);
  aDbf.FieldDefs.Add('TOPATH', ftString, LEN_PATH, True);
  aDbf.FieldDefs.Add('TREELEVEL', ftString, 1, True);
end;

procedure SetupSchemaLog(aDbf: TDbf);
begin
  aDbf.FieldDefs.Clear;
  aDbf.FieldDefs.Add('DATETIME', ftString, LEN_DATE, True);
  aDbf.FieldDefs.Add('FROM', ftString, LEN_PATH, True);
  aDbf.FieldDefs.Add('FROMPATH', ftString, LEN_PATH, True);
  aDbf.FieldDefs.Add('TO', ftString, LEN_PATH, True);
  aDbf.FieldDefs.Add('TOPATH', ftString, LEN_PATH, True);
  aDbf.FieldDefs.Add('UNDO', ftBoolean);
end;

procedure SetupSchemaShows(aDbf: TDbf);
begin
  aDbf.FieldDefs.Clear;
  aDbf.FieldDefs.Add('TITLE', ftString, LEN_TITLE, True);
  aDbf.FieldDefs.Add('DIRECTORY', ftString, LEN_TITLE, True);
  aDbf.FieldDefs.Add('SEARCHTHIS', ftString, LEN_MAX, True);
  aDbf.FieldDefs.Add('LOOKUPDATE', ftString, LEN_DATE, True);
  aDbf.FieldDefs.Add('HIDDEN', ftBoolean);
end;

procedure SetupSchemaTempEps(aDbf: TDbf);
begin
  // This typically mimics SetupSchemaEps exactly
  // so you can move records between them easily.
  SetupSchemaEps(aDbf);
end;

{ TAccessDbf }

constructor TAccessDbf.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FLockRetries := 3;
  FLockRetryDelayMS := 200;
end;

procedure TAccessDbf.ClearRecordLock;
begin
  if FLockedRecNo = 0 then Exit;
  ForgetRecordLock;
  DoAccessChange;
end;

procedure TAccessDbf.DoAccessChange;
begin
  if Assigned(FOnAccessChange) then FOnAccessChange(Self);
end;

procedure TAccessDbf.DoAfterEdit;
begin
  // The lock was obtained this time (e.g. a retry succeeded).
  if FLockedRecNo <> 0 then ClearRecordLock;
  inherited DoAfterEdit;
end;

procedure TAccessDbf.DoAfterScroll;
begin
  // Moving off the locked record retires the mark. Cleared BEFORE
  // inherited so the AfterScroll handler (which refreshes the status
  // bar) already sees it gone; no OnAccessChange needed for the same
  // reason. Cheap enough for bulk loops: an integer compare.
  if (FLockedRecNo <> 0) and (PhysicalRecNo <> FLockedRecNo) then
    ForgetRecordLock;
  inherited DoAfterScroll;
end;

procedure TAccessDbf.DoBeforeDelete;
begin
  RequireWritable('delete this record');
  inherited DoBeforeDelete;
end;

procedure TAccessDbf.DoBeforeEdit;
begin
  // Runs even when a caller has just set ReadOnly := False to force a
  // write (PostRecord, SafeSetDbField) - that trick is fine for POLICY
  // read-only, but the file itself was opened read-only here and the
  // write would only fail later, deep inside TDbf, with a vaguer error.
  RequireWritable('edit this record');
  inherited DoBeforeEdit;
end;

procedure TAccessDbf.DoBeforeInsert;
begin
  RequireWritable('add a record');
  inherited DoBeforeInsert;
end;

procedure TAccessDbf.ForgetRecordLock;
begin
  FLockedRecNo := 0;
  FLockReason := '';
end;

procedure TAccessDbf.InternalEdit;
var
  Attempt: Integer;
  LRecNo: Integer;
begin
  LRecNo := PhysicalRecNo;
  Attempt := 0;
  repeat
    try
      inherited InternalEdit;
      Exit; // locked it
    except
      // TDbfFile.LockRecord raises EDbfError(STRING_RECORD_LOCKED) - and
      // that is the only thing TDbf.InternalEdit does that can fail - but
      // compare the message anyway so nothing else is ever misreported as
      // a lock. STRING_RECORD_LOCKED is a variable in dbf_str (localised),
      // so this stays correct whichever language TDbf is built with.
      on E: EDbfError do
      begin
        if E.Message <> STRING_RECORD_LOCKED then raise;
        if Attempt >= FLockRetries then
        begin
          FLockedRecNo := LRecNo;
          FLockReason := Format('Record %d of %s is locked by another ' +
            'user or program. Try again in a moment.', [LRecNo, TableName]);
          DoAccessChange;
          raise EDbfRecordLocked.Create(FLockReason);
        end;
      end;
    end;
    // Retried here, inside InternalEdit, rather than through
    // OnEditError/daRetry: no event to wire up per table, no retry counter
    // to keep and reset on the form, and it covers Delete too (TDbf's
    // InternalDelete calls InternalEdit). A successful LockRecord re-reads
    // the record, so a retry sees the other user's committed values.
    Inc(Attempt);
    Sleep(FLockRetryDelayMS);
  until False;
end;

function TAccessDbf.IsRecordLocked: Boolean;
begin
  Result := (FLockedRecNo <> 0) and Active and
    (PhysicalRecNo = FLockedRecNo);
end;

procedure TAccessDbf.MarkPhysicalReadOnly(const AReason: String);
begin
  FPhysicalReadOnly := True;
  FReadOnlyReason := AReason;
end;

procedure TAccessDbf.MarkWorkingCopy(const ASourcePath, ACopyDir,
  AReason: String);
begin
  FSourcePath := ASourcePath;
  FWorkingCopyDir := ACopyDir;
  // Kept for the hint: the copy exists BECAUSE the original was read-only.
  FReadOnlyReason := AReason;
end;

procedure TAccessDbf.RequireWritable(const AOperation: String);
begin
  if FPhysicalReadOnly then
    raise EDbfReadOnly.CreateFmt('Cannot %s: %s is read-only because %s.',
      [AOperation, TableName, FReadOnlyReason]);
end;

destructor TAccessDbf.Destroy;
var
  LDir: String;
begin
  // Captured before inherited Destroy, which closes the table (releasing
  // its file handles, so the folder CAN be deleted afterwards) and frees
  // this object's fields.
  LDir := FWorkingCopyDir;
  inherited Destroy;
  // Only ever delete a folder this unit's own naming scheme produced.
  if (LDir <> '') and (Pos(WORKCOPY_DIR_PREFIX,
    ExtractFileName(ExcludeTrailingPathDelimiter(LDir))) = 1) and
    DirectoryExists(LDir) then
    DeleteDirectory(LDir, False);
end;

{ Free functions }

function CheckDbfFileAccess(const AFileName: String;
  out AReason: String): TDbfFileAccess;
const
  {$IFDEF WINDOWS}
  ERR_ACCESS_DENIED = 5;
  ERR_WRITE_PROTECT = 19;
  ERR_NOT_READY = 21;
  ERR_SHARING_VIOLATION = 32;
  ERR_LOCK_VIOLATION = 33;
  {$ELSE}
  ERR_EPERM = 1;
  ERR_EACCES = 13;
  ERR_EBUSY = 16;
  ERR_EROFS = 30;
  {$ENDIF}
var
  {$IFDEF WINDOWS}
  Attr: LongInt;
  {$ENDIF}
  Dir: String;
  H: THandle;
  ReadErr, WriteErr: Integer;
begin
  AReason := '';
  Dir := ExtractFileDir(AFileName);

  // 1. Writable? FileOpen (not TFileStream) so the OS error code is read
  //    straight after the failed call, before anything can reset it.
  H := FileOpen(AFileName, fmOpenReadWrite or fmShareDenyNone);
  if H <> feInvalidHandle then
  begin
    FileClose(H);
    Exit(dfaWritable);
  end;
  WriteErr := GetLastOSError;

  // 2. Readable at all?
  H := FileOpen(AFileName, fmOpenRead or fmShareDenyNone);
  if H = feInvalidHandle then
  begin
    ReadErr := GetLastOSError;
    {$IFDEF WINDOWS}
    if (ReadErr = ERR_SHARING_VIOLATION) or (ReadErr = ERR_LOCK_VIOLATION)
    then
      AReason := 'another program has it open exclusively'
    else if ReadErr = ERR_NOT_READY then
      AReason := 'the drive is not ready (no disc, or the media was removed)'
    else
    {$ENDIF}
      AReason := 'it cannot be read (' + SysErrorMessage(ReadErr) + ')';
    Exit(dfaUnopenable);
  end;
  FileClose(H);

  // 3. Readable but not writable - say why, as precisely as the OS lets
  //    us. The attribute and media checks come first because on Windows
  //    both of them surface as a plain "access denied".
  Result := dfaReadOnly;
  {$IFDEF WINDOWS}
  Attr := FileGetAttr(AFileName);
  if WriteErr = ERR_WRITE_PROTECT then
    AReason := 'the disc or drive is write-protected'
  else if (WriteErr = ERR_SHARING_VIOLATION) or
    (WriteErr = ERR_LOCK_VIOLATION) then
    AReason := 'another program has it open and is preventing changes'
  else if not DirectoryIsWritable(Dir) then
    // CD/DVD files carry the read-only attribute too, so test the folder
    // BEFORE the attribute - "the media is read-only" is the useful
    // answer there, not "untick Read-only in Properties".
    AReason := 'its folder cannot be written to (optical disc, ' +
      'read-only share, or folder permissions)'
  else if (Attr <> -1) and ((Attr and faReadOnly) <> 0) then
    AReason := 'the file is marked read-only (Properties > Read-only)'
  else if WriteErr = ERR_ACCESS_DENIED then
    AReason := 'you do not have permission to change it'
  else
    AReason := 'it cannot be opened for writing (' +
      SysErrorMessage(WriteErr) + ')';
  {$ELSE}
  if WriteErr = ERR_EROFS then
    AReason := 'the disc or drive is mounted read-only'
  else if WriteErr = ERR_EBUSY then
    AReason := 'the file is busy'
  else if (WriteErr = ERR_EACCES) or (WriteErr = ERR_EPERM) then
  begin
    if DirectoryIsWritable(Dir) then
      AReason := 'you do not have permission to change it'
    else
      AReason := 'its folder cannot be written to (read-only share or ' +
        'folder permissions)';
  end
  else
    AReason := 'it cannot be opened for writing (' +
      SysErrorMessage(WriteErr) + ')';
  {$ENDIF}
end;

function DbfHasIndex(aDB: TDbf; const AIndexName: String): Boolean;
var
  i: Integer;
begin
  Result := False;
  if not Assigned(aDB) then Exit;
  aDB.IndexDefs.Update;
  for i := 0 to aDB.IndexDefs.Count - 1 do
    if SameText(aDB.IndexDefs[i].Name, AIndexName) then Exit(True);
end;

function DbfReadOnlyReason(aDB: TDbf): String;
begin
  if IsPhysicallyReadOnly(aDB) then
    Result := TAccessDbf(aDB).ReadOnlyReason
  else
    Result := '';
end;

function DbfStatusBadge(aDB: TDbf): String;
begin
  Result := '';
  if not (Assigned(aDB) and aDB.Active) then Exit;
  if (aDB is TAccessDbf) and TAccessDbf(aDB).IsRecordLocked then
    Result := STATUS_LOCKED_TAG
  else if IsPhysicallyReadOnly(aDB) or not aDB.CanModify then
    Result := STATUS_READONLY_TAG
  else if IsWorkingCopy(aDB) then
    Result := STATUS_WORKCOPY_TAG;
end;

function GetDBStatusHint(aDB: TDbf): String;
var
  Badge: String;
begin
  Result := '';
  Badge := DbfStatusBadge(aDB);
  if Badge = STATUS_LOCKED_TAG then
    Result := TAccessDbf(aDB).LockReason
  else if Badge = STATUS_READONLY_TAG then
  begin
    if IsPhysicallyReadOnly(aDB) then
      Result := sb(['Read-only: ', aDB.TableName, ' cannot be changed ',
        'because ', DbfReadOnlyReason(aDB), '.'])
    else if aDB.ReadOnly then
      Result := sb(['Read-only: ', aDB.TableName,
        ' has been set read-only by the program.'])
    else
      // TDbf.GetCanModify's other reason: no codepage translation is
      // available for the table's language driver.
      Result := sb(['Read-only: ', aDB.TableName, ' uses a language ',
        'driver (codepage) that is not available, so it can only be read.']);
  end
  else if Badge = STATUS_WORKCOPY_TAG then
    Result := sb(['Working copy: the original ', aDB.TableName, ' in "',
      TAccessDbf(aDB).SourcePath, '" is read-only (',
      TAccessDbf(aDB).ReadOnlyReason, '), so it was copied to "',
      TAccessDbf(aDB).WorkingCopyDir, '". Changes are NOT saved back ',
      'to the original.']);
end;

function IsPhysicallyReadOnly(aDB: TDbf): Boolean;
begin
  Result := (aDB is TAccessDbf) and TAccessDbf(aDB).PhysicalReadOnly;
end;

function IsWorkingCopy(aDB: TDbf): Boolean;
begin
  Result := (aDB is TAccessDbf) and (TAccessDbf(aDB).WorkingCopyDir <> '');
end;

procedure RequireWritable(aDB: TDbf; const AOperation: String);
begin
  if aDB is TAccessDbf then TAccessDbf(aDB).RequireWritable(AOperation);
end;

type
  // One expected field, in the dBase header's own terms - name, type
  // char ('C'/'L'/etc, matching the field-type byte at descriptor offset
  // 11), and length (descriptor offset 16). Deliberately NOT expressed in
  // terms of TFieldType/ftString - the whole point of this table is to
  // check the raw on-disk bytes without going through the db/Dbf units'
  // own field-type mapping, which is the code path that's unsafe to run
  // against a stale or corrupt file in the first place.
  TExpectedDbfField = record
    Name: String[10]; // dBase field names are stored in 10 bytes + NUL
    TypeChar: Char;
    Length: Byte;
  end;

const
  // Mirrors SetupSchemaAbout/Eps/List/Log/Shows exactly - ftString maps to
  // 'C' (character) and ftBoolean maps to 'L' (logical) in every dBase
  // variant TDbf supports here. TEMPEPS isn't listed separately: it mirrors
  // EPS's layout (SetupSchemaTempEps just calls SetupSchemaEps), so
  // DbfMatchesSchema's dbEps, dbTempEps: branch reuses EXPECTED_EPS for
  // both.
  EXPECTED_ABOUT: array[0..1] of TExpectedDbfField = (
    (Name: 'INFO'; TypeChar: 'C'; Length: LEN_TITLE),
    (Name: 'VALUE'; TypeChar: 'C'; Length: LEN_MAX)
  );
  EXPECTED_EPS: array[0..3] of TExpectedDbfField = (
    (Name: 'TITLE'; TypeChar: 'C'; Length: LEN_TITLE),
    (Name: 'EPNUM'; TypeChar: 'C'; Length: 10),
    (Name: 'EPNAME'; TypeChar: 'C'; Length: LEN_TITLE),
    (Name: 'SORTORDER'; TypeChar: 'C'; Length: LEN_TITLE)
  );
  EXPECTED_LIST: array[0..15] of TExpectedDbfField = (
    (Name: 'DIRECTORY'; TypeChar: 'C'; Length: LEN_TITLE),
    (Name: 'TITLE'; TypeChar: 'C'; Length: LEN_TITLE),
    (Name: 'FROM'; TypeChar: 'C'; Length: LEN_PATH),
    (Name: 'FROMNAME'; TypeChar: 'C'; Length: LEN_TITLE),
    (Name: 'FROMPATH'; TypeChar: 'C'; Length: LEN_PATH),
    (Name: 'NAMENPATH'; TypeChar: 'C'; Length: LEN_PATH),
    (Name: 'EPNUM'; TypeChar: 'C'; Length: 10),
    (Name: 'EPNAME'; TypeChar: 'C'; Length: LEN_TITLE),
    (Name: 'HEIGHT'; TypeChar: 'C'; Length: 10),
    (Name: 'AUDIOCHAN'; TypeChar: 'C'; Length: 10),
    (Name: 'CODEC'; TypeChar: 'C'; Length: 10),
    (Name: 'GROUP'; TypeChar: 'C'; Length: 30),
    (Name: 'EXTENSION'; TypeChar: 'C'; Length: 20),
    (Name: 'SUBTITLES'; TypeChar: 'C'; Length: 10),
    (Name: 'TO'; TypeChar: 'C'; Length: LEN_PATH),
    (Name: 'TOPATH'; TypeChar: 'C'; Length: LEN_PATH)
    // TREELEVEL (LIST's 17th and last field) isn't listed here - see
    // EXPECTED_LIST_TREELEVEL below, and the dbList branch in
    // DbfMatchesSchema's field-comparison loop, for why it's handled
    // separately instead of just being a 17th entry in this array.
  );
  EXPECTED_LIST_TREELEVEL: TExpectedDbfField =
    (Name: 'TREELEVEL'; TypeChar: 'C'; Length: 1);
  EXPECTED_LOG: array[0..5] of TExpectedDbfField = (
    (Name: 'DATETIME'; TypeChar: 'C'; Length: LEN_DATE),
    (Name: 'FROM'; TypeChar: 'C'; Length: LEN_PATH),
    (Name: 'FROMPATH'; TypeChar: 'C'; Length: LEN_PATH),
    (Name: 'TO'; TypeChar: 'C'; Length: LEN_PATH),
    (Name: 'TOPATH'; TypeChar: 'C'; Length: LEN_PATH),
    (Name: 'UNDO'; TypeChar: 'L'; Length: 1)
  );
  EXPECTED_SHOWS: array[0..4] of TExpectedDbfField = (
    (Name: 'TITLE'; TypeChar: 'C'; Length: LEN_TITLE),
    (Name: 'DIRECTORY'; TypeChar: 'C'; Length: LEN_TITLE),
    (Name: 'SEARCHTHIS'; TypeChar: 'C'; Length: LEN_MAX),
    (Name: 'LOOKUPDATE'; TypeChar: 'C'; Length: LEN_DATE),
    (Name: 'HIDDEN'; TypeChar: 'L'; Length: 1)
  );

// Raw dBase field descriptor, as laid out on disk. Classic dBase III/IV
// uses a 32-byte descriptor (name at +0, type char at +11, length at
// +16). dBase Level 7 (Visual FoxPro-style, version byte 0x04 - see
// DbfMatchesSchema) uses a 48-byte descriptor instead, with the name
// still at +0 but type char at +32 and length at +33 - confirmed against
// a real SHOWS.DBF header (TITLE/C/100 etc. only decode correctly at
// those offsets; the 32-byte classic offsets read back a name-block
// padding byte instead of the real type/length). Each descriptor array
// is terminated by a $0D byte in place of the next descriptor's first
// byte. Only the pieces DbfMatchesSchema actually compares (name, type
// char, length) are kept; the remaining bytes (field data address,
// decimal count, work-area ID, etc.) are read as part of the fixed-size
// Buf but never examined.
type
  TRawFieldDescriptor = record
    Name: String; // trimmed, uppercased, from the 11-byte zero-padded name
    TypeChar: Char;
    Length: Byte;
  end;

// Size, in bytes, of one on-disk field descriptor for a given dBase
// version byte - 48 for Level 7 (0x04), 32 for classic dBase III/IV
// (0x03/0x83). See TRawFieldDescriptor's banner comment.
function FieldDescriptorSize(AVersionByte: Byte): Integer;
begin
  if AVersionByte = $04 then Result := 48
  else Result := 32;
end;

// Reads one field descriptor starting at the stream's current position;
// ASize must be the correct on-disk descriptor size for this file's
// version byte (see FieldDescriptorSize) since the type char and length
// live at different offsets in a 48-byte Level 7 descriptor than in a
// 32-byte classic one. Returns False if the stream doesn't have ASize
// bytes left, or if what it read isn't a plausible field descriptor
// (unprintable name), so a truncated/corrupt file fails safely instead
// of returning garbage.
function ReadFieldDescriptor(AStream: TStream; ASize: Integer;
  out ADescriptor: TRawFieldDescriptor): Boolean;
type
  TBufArray = array[0..47] of Byte; // sized for the larger (Level 7) case
var
  Buf: TBufArray;
  i, TypeOffset, LengthOffset: Integer;
  NameStr: String;
begin
  Result := False;
  if (ASize <> 32) and (ASize <> 48) then Exit;
  Buf := Default(TBufArray);
  if AStream.Read(Buf, ASize) <> ASize then Exit;
  NameStr := '';
  for i := 0 to 10 do
  begin
    if Buf[i] = 0 then Break;
    // Field names are ASCII in every dBase variant TDbf targets here - a
    // byte outside printable ASCII means this isn't a real field
    // descriptor (most likely we've drifted out of alignment reading a
    // corrupt file), so fail rather than fabricate a name from garbage.
    if (Buf[i] < 32) or (Buf[i] > 126) then Exit;
    NameStr := NameStr + Chr(Buf[i]);
  end;
  if NameStr.IsBlank then Exit;
  if ASize = 48 then
  begin
    TypeOffset := 32;
    LengthOffset := 33;
  end
  else
  begin
    TypeOffset := 11;
    LengthOffset := 16;
  end;
  ADescriptor.Name := UTF8UpperCase(NameStr);
  ADescriptor.TypeChar := Chr(Buf[TypeOffset]);
  ADescriptor.Length := Buf[LengthOffset];
  Result := True;
end;

// DbfMatchesSchema, and with ANamesOnly the looser check
// IsFileyTableLeftover needs: same field names in the same order, any
// type and length.
function DbfHeaderMatches(const AFileName: String; ADbType: TDbType;
  ANamesOnly: Boolean): Boolean;
var
  Descriptor: TRawFieldDescriptor;
  ExpectedCount, FieldDescSize, FieldDescStart, i: Integer;
  HeaderLen: Word;
  Stream: TFileStream;
  VersionByte: Byte;

  // Compares Descriptor against the Nth entry of whichever EXPECTED_*
  // array applies, returning False on any mismatch. TREELEVEL (LIST's
  // 17th field) is handled as a special case since fixed arrays can't
  // vary in length per call - if a future schema adds more
  // variable-tail fields, extend this the same way rather than trying to
  // make the EXPECTED_* arrays themselves variable-length.
  function Matches(const AExpected: TExpectedDbfField): Boolean;
  begin
    Result := (Descriptor.Name = UTF8UpperCase(AExpected.Name)) and
      (ANamesOnly or ((Descriptor.TypeChar = AExpected.TypeChar) and
      (Descriptor.Length = AExpected.Length)));
  end;

begin
  Result := False;
  if not FileExists(AFileName) then Exit;
  case ADbType of
    dbAbout: ExpectedCount := Length(EXPECTED_ABOUT);
    dbEps, dbTempEps: ExpectedCount := Length(EXPECTED_EPS);
    dbList: ExpectedCount := Length(EXPECTED_LIST) + 1; // + TREELEVEL
    dbLog: ExpectedCount := Length(EXPECTED_LOG);
    dbShows: ExpectedCount := Length(EXPECTED_SHOWS);
    else
      Exit; // Unknown ADbType - fail safe rather than guess.
  end;
  // fmOpenRead (not ReadWrite) - this also has to work on read-only
  // media, and it's only ever reading anyway.
  Stream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
  try
    try
      // Header is at least 68 bytes before the field descriptor array even
      // starts for a Level 7 file (see below) - anything shorter can't be
      // a valid file in the format this app actually writes.
      if Stream.Size < 69 then Exit;
      VersionByte := Stream.ReadByte;
      // 0x03 = dBase III/IV, no memo; 0x83 = dBase III + .DBT memo; 0x04 =
      // dBase Level 7 (Visual FoxPro-style), no memo. TDbf is configured
      // for Version:='7.0'/TableLevel:=7 (see ConfigureDbfDefaults), which
      // is what actually gets written to disk - confirmed against a real
      // SHOWS.DBF header: version byte 0x04, a 36-byte language-driver-ID
      // block ("DBWINWE0"/"DB850US0" etc, e.g. codepage) at offset 32-67,
      // and field descriptors starting at offset 68, not 32. The previous
      // 0x03/0x83-only check rejected every file this app itself writes -
      // on every platform, not just Wine - triggering a needless
      // quarantine-and-recreate on every launch. A byte outside all three
      // values means this file wasn't written by this program's current
      // schema.
      if not (VersionByte in [$03, $83, $04]) then Exit;
      // Classic dBase III/IV puts field descriptors right after the
      // 32-byte fixed header, in 32-byte descriptors; Level 7 (0x04)
      // inserts a 36-byte language-driver-ID block first and uses
      // 48-byte descriptors instead (see TRawFieldDescriptor's banner
      // comment) - confirmed against a real header, where "TITLE" (the
      // first field name) starts at byte 68, and "DIRECTORY" (the
      // second) at byte 116, i.e. 48 bytes later.
      FieldDescSize := FieldDescriptorSize(VersionByte);
      if VersionByte = $04 then FieldDescStart := 68
      else FieldDescStart := 32;
      Stream.Position := 8;
      // Bytes 8-9: 16-bit header length, little-endian - TStream.ReadWord
      // matches the FPC RTL's default (LE) which is correct for dBase's
      // on-disk byte order on every platform this app targets.
      HeaderLen := Stream.ReadWord;
      // Header length must be big enough for the fixed header up to
      // FieldDescStart plus at least one field descriptor of the right
      // size plus the 0x0D terminator, and must fit inside the file
      // itself.
      if (HeaderLen < FieldDescStart + FieldDescSize + 1) or
        (HeaderLen > Stream.Size) then Exit;
      Stream.Position := FieldDescStart;
      for i := 0 to ExpectedCount - 1 do
      begin
        if not ReadFieldDescriptor(Stream, FieldDescSize, Descriptor) then
          Exit;
        case ADbType of
          dbAbout: if not Matches(EXPECTED_ABOUT[i]) then Exit;
          dbEps, dbTempEps: if not Matches(EXPECTED_EPS[i]) then Exit;
          dbList:
            if i < Length(EXPECTED_LIST) then
            begin
              if not Matches(EXPECTED_LIST[i]) then Exit;
            end
            else if not Matches(EXPECTED_LIST_TREELEVEL) then Exit;
          dbLog: if not Matches(EXPECTED_LOG[i]) then Exit;
          dbShows: if not Matches(EXPECTED_SHOWS[i]) then Exit;
        end;
      end;
      // Field descriptor array must end exactly here - a $0D terminator
      // immediately after the last expected field. An extra field (from
      // an old schema that added a column since removed, for example)
      // would otherwise pass every check above while still being a
      // mismatch.
      Result := Stream.ReadByte = $0D;
    except
      // Belt-and-braces: every path above is bounds-checked before it
      // reads, so this should be unreachable, but DbfMatchesSchema's
      // whole contract is "never raises, fails toward False" - if a
      // bounds check here is ever wrong, a caught EStreamError and a
      // False result is what that contract requires, not a propagated
      // exception three callers away from this file.
      Result := False;
    end;
  finally
    Stream.Free;
  end;
end;

function DbfMatchesSchema(const AFileName: String; ADbType: TDbType):
  Boolean;
begin
  Result := DbfHeaderMatches(AFileName, ADbType, False);
end;

function IsFileyTableLeftover(const AFileName: String): Boolean;
const
  // TEMPEPS has EPS's layout (SetupSchemaTempEps), so dbEps covers both.
  MEMORY_TABLES: array[0..2] of TDbType = (dbAbout, dbList, dbEps);
var
  i: Integer;
  sName: String;
begin
  Result := False;
  sName := ExtractFileName(AFileName);
  // "_" and at least one digit, nothing else.
  if (Length(sName) < 2) or (sName[1] <> '_') then Exit;
  for i := 2 to Length(sName) do
    if not (sName[i] in ['0'..'9']) then Exit;
  for i := Low(MEMORY_TABLES) to High(MEMORY_TABLES) do
    if DbfHeaderMatches(AFileName, MEMORY_TABLES[i], True) then Exit(True);
end;

initialization
   DebugLog('uDBF.pas initializaiton');

end.
