{ Filey - uDBFManager.pas

Copyright (C) 2026 Mark A Paley

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program; if not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>.

Report bugs and questions at <https://gitlab.com/MarkAPaley/filey/-/issues>.
}

{ ==============================================================================
   uDBFManager

   The DBF *orchestration* extracted from TForm1: creating and opening the
   full set of tables (formerly TForm1.InitializeDBFs), and the two table
   maintenance operations that don't need a grid or a dialog to do their job
   (formerly TForm1.PackThisTable and TForm1.ZapPackTable).

   This is deliberately a separate unit from uDBF.pas, not an addition to
   it. uDBF.pas's only dependencies are DB/Dbf/SysUtils, which is what makes
   it trivial to reason about and test. The routines here need a component
   owner (to create TDbf/TDataSource instances against) and, in ZapPackTable's
   case, a way to report what it did - neither of which uDBF.pas should have
   to know about.

   Two callback types carry that: TDBFConfigureDataSourceEvent is "of
   object" because it exists to let the owning form bind real instance
   methods (e.g. TForm1.DBEpsStateChange) to a freshly-created TDataSource -
   there's no way around needing Self there. TDBFStatusEvent is deliberately
   NOT "of object": its only job is reporting a line of text, and the
   obvious thing to bind it to (uUtils.DebugLog) is itself a plain,
   stateless procedure. Making the callback type match keeps @DebugLog
   assignable directly, with no forwarding method required.

   TForm1 still owns everything that reads as UI: cursor changes
   (SetAllCursors), grid setup (SetupDbShows/SetupDbEps/SetupDbList/
   SetupDbLog), the confirmation dialog and grid-state guards around Zap
   (ConfirmThenZapPackTable), and the routine status-bar refresh that used
   to follow a pack (that call was dropped outright, not moved - see
   PackThisTable below).

   READ-ONLY MEDIA (see uDBF's banner for the full model): every table is
   created as a uDBF.TAccessDbf. Before a file-backed table is opened, its
   file is probed (uDBF.CheckDbfFileAccess). A table that can't be written
   is either opened read-only with its reason recorded (rmOpenInPlace), or
   copied to a private temp folder and opened from there (rmWorkingCopy).
   Every operation in this unit that rewrites a table - index add/drop,
   Pack, Zap - refuses a physically read-only table up front with
   uDBF.EDbfReadOnly, which is an EDatabaseError, instead of failing midway.
============================================================================== }

unit uDBFManager;

{$mode objfpc}
{$LONGSTRINGS ON}
{$H+}
{$INLINE ON}
{$WARN 6058 off : Call to subroutine "$1" marked as inline is not inlined}
interface

uses
  Classes, db, Dbf, SysUtils, uDBF;

type
  // Reports a single line of status text. Deliberately a plain procedure,
  // not "of object" - see the unit banner above for why.
  TDBFStatusEvent = procedure(const Msg: String);

  // Lets the owning form wire up whatever a freshly-created TDataSource
  // needs (e.g. an OnStateChange handler) without this unit having to know
  // TDbType-specific details like "dbEps needs DBEpsStateChange".
  TDBFConfigureDataSourceEvent = procedure(ADbType: TDbType;
    ADataSource: TDataSource) of object;

// Creates a TDataSource for aDB if one doesn't already exist, and (re)binds
// its AutoEdit/DataSet/Name/Enabled properties. AOwner is the component that
// will own a newly-created TDataSource.
procedure AssignDBFDataSource(var aDB: TDbf; var ADataSource: TDataSource;
  AOwner: TComponent);

// Creates and opens every not-yet-assigned entry in ADbfArray: builds the
// TAccessDbf/TDataSource pair, creates the on-disk table from the matching
// SetupSchema* routine if it doesn't exist yet, then opens it. AOwner owns
// every component created. ATablePath is the directory tables are read
// from/written to (ABOUT/LIST/TEMPEPS are memory-only tables regardless).
// ADefaultAfterScroll/ADefaultBeforeScroll are applied to every table;
// ADefaultRecordCountChanged is applied to every table's AfterPost and
// AfterDelete, so the status-bar record-count cache (aCachedRecCount/
// aRecCountDirty) gets invalidated automatically no matter which of the
// many Post/Delete call sites on that table actually fired - a handler
// that overrides AfterPost afterwards (SetupDbLog's LogAfterPost) is
// responsible for still invalidating the cache itself.
// AOnConfigureDataSource (if assigned) runs once per table right after its
// TDataSource is created, before anything else touches it.
// AOnAccessChange (if assigned) becomes every table's
// TAccessDbf.OnAccessChange - fired when a record lock is detected or
// cleared, so the owner can refresh its status display.
// AReadOnlyMediaPolicy decides what happens to a file-backed table whose
// file turns out to be read-only - see uDBF.TReadOnlyMediaPolicy.
procedure CreateAndOpenDBFs(var ADbfArray: TDBFArray;
  AOwner: TComponent; const ATablePath: String;
  const ADefaultAfterScroll, ADefaultBeforeScroll,
  ADefaultRecordCountChanged: TDataSetNotifyEvent;
  AOnConfigureDataSource: TDBFConfigureDataSourceEvent = nil;
  AOnAccessChange: TNotifyEvent = nil;
  AReadOnlyMediaPolicy: TReadOnlyMediaPolicy = rmOpenInPlace);

// Packs a table in place: exclusive access, PackTable if there's anything
// to pack, then repositions to the first record. Does nothing for an
// in-memory (stoMemory) table, which TDbf can only pack through a scratch
// file in the current directory. Uses PhysicalRecordCount
// (not RecordCount) for the guard, since the whole point of packing is
// reclaiming space from records already marked deleted - those are exactly
// the ones RecordCount excludes. No status is reported - whatever a caller
// last wrote to a status bar for this is almost always overwritten by the
// next thing that runs anyway, so there's nothing meaningful lost by not
// reporting it here. Raises uDBF.EDbfReadOnly on a physically read-only
// table.
procedure PackThisTable(var aDB: TDbf);

// Adds an index to an already-open aDB. Index creation/rebuild requires
// exclusive access (TDbf raises EDbfError from deep inside AddIndex if it
// doesn't have it), so this acquires exclusive access first and always
// releases it again afterward - callers don't need to set aDB.Exclusive
// themselves, and the table isn't left locked beyond the index operation
// itself. Uses the same escalate-in-place mechanism as PackThisTable/
// ZapPackTable: no Close/Open cycle needed since aDB is expected to
// already be open. Raises uDBF.EDbfReadOnly on a physically read-only
// table - check uDBF.IsPhysicallyReadOnly first where an index is merely
// nice to have.
procedure AddIndexExclusive(var aDB: TDbf; const AIndexName, AFields: String;
  AOptions: TIndexOptions);

// Drops an index from an already-open aDB, if it exists. A no-op if
// AIndexName isn't currently defined - so callers can call this
// unconditionally before a bulk load without first checking IndexDefs
// themselves. Bulk-inserting into a table with a live unique index means
// every single Append/Post pays for a B-tree lookup+insert to enforce
// that uniqueness; dropping the index first and rebuilding it once at the
// end (with AddIndexExclusive) does the same uniqueness check just once,
// in bulk, instead of per-row. Same exclusive-access dance as
// AddIndexExclusive, for the same reason (TDbf.DeleteIndex also requires
// exclusive access). Raises uDBF.EDbfReadOnly on a physically read-only
// table, even if the index doesn't exist (the caller is about to write
// to the table anyway).
procedure DeleteIndexIfPresentExclusive(var aDB: TDbf;
  const AIndexName: String);

// Deletes every record in aDB (irreversible) and packs the file. Unlike
// PackThisTable, this DOES report via AOnStatus (if assigned) - Zap is
// destructive, so "it happened and it finished" is worth keeping somewhere,
// even if it's no longer the status bar. Pass @DebugLog, for example.
// Raises uDBF.EDbfReadOnly on a physically read-only table.
procedure ZapPackTable(var aDB: TDbf; AOnStatus: TDBFStatusEvent = nil);

implementation

uses
  FileUtil, LazFileUtils, LazUTF8, StrUtils, TypInfo, uManagedUtils, uUtils;

// Escalates aDB (already open) to exclusive access in place - no
// Close/Open cycle needed. TryExclusive attempts the lock without raising;
// if another running instance (or anything else) already has the table
// open, aDB.Exclusive comes back False here, and we must refuse rather
// than push ahead. Shared by PackThisTable, ZapPackTable,
// AddIndexExclusive and DeleteIndexIfPresentExclusive so all of them fail
// the same way when the lock can't be had.
//
// Returns aDB.ReadOnly as it was on entry; pass it to ReleaseExclusive.
// TDbf.TryExclusive and TDbf.EndExclusive both overwrite ReadOnly from the
// file's actual open mode (dbf.pas: "FReadOnly := FDbfFile.Mode =
// pfReadOnly"), which silently discarded a POLICY read-only setting
// (TForm1.actReadOnlyExecute) every time a table was packed, zapped or
// re-indexed.
function AcquireExclusive(var aDB: TDbf; const AOperation: String): Boolean;
begin
  // Refuse before touching the lock at all: a physically read-only table
  // can never be escalated, and the reason is more useful than
  // "Could not get exclusive access".
  RequireWritable(aDB, AOperation);
  Result := aDB.ReadOnly;
  aDB.TryExclusive;
  if not aDB.Exclusive then
  begin
    aDB.ReadOnly := Result;
    raise EDatabaseError.CreateFmt(
      'Could not get exclusive access to "%s" to %s. Close any other ' +
      'running program that has this table open, then try again.',
      [aDB.TableName, AOperation]);
  end;
end;

procedure AssignDBFDataSource(var aDB: TDbf; var ADataSource: TDataSource;
  AOwner: TComponent);
begin
  if (not Assigned(ADataSource)) then
    ADataSource := TDataSource.Create(AOwner);
  ADataSource.AutoEdit := True;
  ADataSource.DataSet := aDB;
  ADataSource.Name := ExtractFileNameOnly('DataSource' + aDB.TableName);
  ADataSource.Enabled := True;
  {enabled MUST come last in this set, or mem leaks}
end;

// Resets db's operational properties to a known-good state. Runs on
// EVERY call for a freshly-created db object -- not only the first time
// the table is created on disk. Previously this whole block lived
// inside "if not FileExists(...)", which meant it only ever executed
// the very first time a table was created; on every subsequent app
// launch the .DBF already exists, so Filter/ReadOnly/Storage/StoreDefs/
// TableLevel/Tag/Version/OpenMode were silently left at whatever
// TDbf.Create defaulted them to. Pulling this out fixes that.
procedure ConfigureDbfDefaults(aDB: TDbf; ADbIndex: TDbType);
begin
  aDB.Active := False;
  aDB.DisableControls;
  aDB.Filter := '';
  aDB.Filtered := False;
  aDB.FilterOptions := [];
  aDB.OpenMode := omAutoCreate; // omNormal;
  // Default only - PrepareFileAccess below turns this back on, BEFORE
  // Open, for a file that can't be written (a read-write open of such a
  // file would simply fail).
  aDB.ReadOnly := False;
  aDB.ShowDeleted := False;
  // stoMemory requires backingstream:=TMemoryStream.Create; UserStream:=backingstream;
  // stoMemory requires CLOSE dbf before closing program, to prevent memory leak
  if IndexStr(aDB.Name, ['ABOUT', 'LIST', 'TEMPEPS']) > -1 then
  begin
    aDB.Storage := stoMemory;
    aDB.FilePath := '';
    aDB.FilePathFull := '';
  end
  else
    aDB.Storage := stoFile;
  aDB.StoreDefs := True;
  aDB.TableLevel := 7;
  aDB.Tag := Ord(ADbIndex);
  aDB.Version := '7.0';
end;

// Copies ATableName and every companion file sharing its base name
// (.MDX index, .DBT memo, ...) from ASourceDir into a new private temp
// folder, returned in ACopyDir. Returns False - having removed any
// partial copy - if the .DBF itself wasn't found or any copy failed.
function MakeWorkingCopy(const ASourceDir, ATableName: String;
  out ACopyDir: String): Boolean;
var
  BaseName, Dest: String;
  FoundTable: Boolean = False;
  SR: TSearchRec;
begin
  Result := False;
  BaseName := ExtractFileNameOnly(ATableName);
  ACopyDir := TFilePath.Combine(GetTempDir(False),
    sb([WORKCOPY_DIR_PREFIX, ExtractFileNameOnly(ParamStr(0)), '-',
    BaseName, '-', IntToStr(GetProcessID), '-',
    IntToStr(GetTickCount64)])).Value;
  if not ForceDirectories(ACopyDir) then
  begin
    LogError('MakeWorkingCopy: could not create "' + ACopyDir + '"');
    ACopyDir := '';
    Exit;
  end;
  try
    // Walk the folder rather than guessing extensions, and match the base
    // name case-insensitively: files burned to optical media often come
    // back with a different letter case than they were written with.
    if FindFirst(TFilePath.Combine(ASourceDir, '*').Value, faAnyFile,
      SR) = 0 then
    try
      repeat
        if (SR.Attr and faDirectory) <> 0 then Continue;
        if not SameText(ExtractFileNameOnly(SR.Name), BaseName) then Continue;
        // Copied under the TableName's own spelling for the .DBF itself
        // (TDbf opens TableName exactly), and under the source's spelling
        // for companions.
        if SameText(SR.Name, ATableName) then
        begin
          Dest := TFilePath.Combine(ACopyDir, ATableName).Value;
          FoundTable := True;
        end
        else
          Dest := TFilePath.Combine(ACopyDir, SR.Name).Value;
        if not FileUtil.CopyFile(
          TFilePath.Combine(ASourceDir, SR.Name).Value, Dest,
          [cffOverwriteFile]) then
        begin
          LogError('MakeWorkingCopy: could not copy "' + SR.Name +
            '" to "' + ACopyDir + '"');
          Exit;
        end;
        {$IFDEF WINDOWS}
        // Files copied off CD/DVD keep the read-only attribute on some
        // Windows versions, which would make the copy read-only too.
        FileSetAttr(Dest, FileGetAttr(Dest) and not faReadOnly);
        {$ENDIF}
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
    Result := FoundTable;
    if not Result then
      LogError('MakeWorkingCopy: "' + ATableName + '" not found in "' +
        ASourceDir + '"');
  finally
    if not Result then
    begin
      DeleteDirectory(ACopyDir, False);
      ACopyDir := '';
    end;
  end;
end;

// Probes a file-backed table BEFORE TDbf.Open and configures aDB to
// match: writable files are left alone; read-only ones are either opened
// read-only with their reason recorded, or redirected to a working copy
// (ATableFile is updated to point at it). Returns False if the table
// can't be used at all this run, having logged why.
function PrepareFileAccess(aDB: TAccessDbf; const ATablePath: String;
  var ATableFile: TFilePath; APolicy: TReadOnlyMediaPolicy): Boolean;
var
  CopyDir, Reason: String;
begin
  Result := True;
  if not ATableFile.Exists then
  begin
    // About to be created, so the folder itself must accept new files.
    // Checked here because CreateTable's own failure on read-only media
    // is an unhelpful low-level stream error.
    if not DirectoryIsWritable(ATablePath) then
    begin
      LogError('CreateAndOpenDBFs: cannot create ' + aDB.TableName +
        ' because "' + ATablePath + '" cannot be written to - skipping ' +
        'it for this run.');
      Exit(False);
    end;
    Exit;
  end;
  case CheckDbfFileAccess(ATableFile, Reason) of
    dfaWritable: Exit;
    dfaUnopenable:
    begin
      LogError('CreateAndOpenDBFs: cannot open "' + ATableFile.Value +
        '" because ' + Reason + ' - skipping ' + aDB.TableName +
        ' for this run.');
      Exit(False);
    end;
    dfaReadOnly:
      if (APolicy = rmWorkingCopy) and
        MakeWorkingCopy(ATablePath, aDB.TableName, CopyDir) then
      begin
        aDB.FilePathFull := CopyDir;
        aDB.FilePath := CopyDir;
        aDB.MarkWorkingCopy(ATablePath, CopyDir, Reason);
        ATableFile := TFilePath.Combine(CopyDir, aDB.TableName);
        DebugLog('CreateAndOpenDBFs: ' + aDB.TableName + ' is read-only (' +
          Reason + '); opened a working copy in "' + CopyDir + '"');
      end
      else
      begin
        // Must precede Open: TDbf picks its file mode from ReadOnly.
        aDB.ReadOnly := True;
        aDB.MarkPhysicalReadOnly(Reason);
        DebugLog('CreateAndOpenDBFs: ' + aDB.TableName +
          ' opened read-only because ' + Reason);
      end;
  end;
end;

// Deletes rmWorkingCopy folders left behind by earlier runs that didn't
// exit cleanly (a crash skips TAccessDbf.Destroy's cleanup). Only folders
// whose name starts with this program's own prefix, and only ones more
// than a day old - so a second copy of the program running right now
// never has its working copy pulled out from under it.
procedure PurgeStaleWorkingCopies;
var
  Prefix, TempDir: String;
  SR: TSearchRec;
begin
  TempDir := GetTempDir(False);
  Prefix := sb([WORKCOPY_DIR_PREFIX, ExtractFileNameOnly(ParamStr(0)), '-']);
  if FindFirst(TFilePath.Combine(TempDir, Prefix + '*').Value, faDirectory,
    SR) <> 0 then
  begin
    FindClose(SR);
    Exit;
  end;
  try
    repeat
      if ((SR.Attr and faDirectory) <> 0) and
        (Pos(Prefix, SR.Name) = 1) and
        (FileDateToDateTime(SR.Time) < Now - 1) then
        if not DeleteDirectory(TFilePath.Combine(TempDir, SR.Name).Value,
          False) then
          DebugLog('PurgeStaleWorkingCopies: could not delete "' +
            SR.Name + '"');
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

procedure CreateAndOpenDBFs(var ADbfArray: TDBFArray;
  AOwner: TComponent; const ATablePath: String;
  const ADefaultAfterScroll, ADefaultBeforeScroll,
  ADefaultRecordCountChanged: TDataSetNotifyEvent;
  AOnConfigureDataSource: TDBFConfigureDataSourceEvent;
  AOnAccessChange: TNotifyEvent;
  AReadOnlyMediaPolicy: TReadOnlyMediaPolicy);
var
  DbIndex: TDbType;
  db: TDbf;
  TableFile: TFilePath;
begin
  if AReadOnlyMediaPolicy = rmWorkingCopy then PurgeStaleWorkingCopies;
  // array D of DBFs allows easy/consistent DBF creation/iteration
  for DbIndex := Low(TDbType) to High(TDbType) do
  begin
    db := ADbfArray[DbIndex].aDB;
    if Assigned(db) then Continue;
    // TAccessDbf, not plain TDbf: carries the read-only reason and the
    // record-lock state, and refuses writes to read-only media itself.
    // Everything else keeps treating it as an ordinary TDbf.
    db := TAccessDbf.Create(AOwner);
    ADbfArray[DbIndex].aDB := db;
    // write the new reference back into the array
    // UPPERCASING enumerated type DBFs name is cross-platform IMPORTANT.
    // Changing 'EPS' to 'Eps' silently skips SetupSchema* and
    // CreateTable says "Invalid DBF file. Invalid field definition."
    db.Name := UTF8UpperCase(GetEnumName(TypeInfo(DBFs), Ord(DbIndex)));
    ADbfArray[DbIndex].ADataSource := TDataSource.Create(AOwner);
    if Assigned(AOnConfigureDataSource) then
      AOnConfigureDataSource(DbIndex, ADbfArray[DbIndex].ADataSource);
    ADbfArray[DbIndex].aFilterDescription := '';
    // aSavedRecNo needs no explicit reset: 0 (an Integer field's default on
    // a freshly-created record) already means "nothing saved yet" to
    // SafeGo/its callers.
    // Starts dirty so the first status-bar display computes a real
    // ExactRecordCount instead of trusting the zero-value default.
    ADbfArray[DbIndex].aRecCountDirty := True;
    db.FilePathFull := ATablePath;
    db.FilePath := ATablePath;
    db.TableName := db.Name + '.DBF';
    // Cross-platform, delimiter-correct path join (directory + filename)
    // instead of raw string concatenation.
    TableFile := TFilePath.Combine(ATablePath, db.TableName);

    // Reset db to a known state on every run, not just the first time
    // this table is created (see ConfigureDbfDefaults comment above).
    ConfigureDbfDefaults(db, DbIndex);
    TAccessDbf(db).OnAccessChange := AOnAccessChange;

    // Probe the file BEFORE anything else opens it for writing. May mark
    // db read-only, or redirect it (and TableFile) to a working copy.
    if (db.Storage = stoFile) and not PrepareFileAccess(TAccessDbf(db),
      ATablePath, TableFile, AReadOnlyMediaPolicy) then
    begin
      db.EnableControls; // balance ConfigureDbfDefaults' DisableControls
      Continue;
    end;

    // Validate the on-disk file's actual field layout against what
    // SetupSchemaXxx expects TODAY, before TDbf ever touches it. Only
    // meaningful for db.Storage = stoFile tables (EPS/LOG/SHOWS) -
    // ABOUT/LIST/TEMPEPS are stoMemory (see ConfigureDbfDefaults) and
    // never persist across runs regardless of what TableFile.Exists
    // reports, so there's nothing on disk for a mismatch to mean here.
    //
    // This exists because a stale or corrupted .DBF's field layout can
    // make the Dbf package's OWN field-construction code raise a hard
    // access violation from inside db.Open below - not a catchable
    // Pascal exception, so the except block a few lines down (which DOES
    // correctly catch ordinary open failures) never gets a chance to run
    // and the whole process dies instead. Reading the header ourselves
    // first, with nothing but bounds-checked byte access
    // (DbfMatchesSchema), is what lets a bad file be caught and handled
    // here instead.
    if (db.Storage = stoFile) and TableFile.Exists and
      not DbfMatchesSchema(TableFile, DbIndex) then
    begin
      // A read-only original can't be quarantined, and quarantining a
      // working copy would just replace it with a new EMPTY table that
      // looks like the real data - so neither is "repaired"; the table
      // sits out the run with a clear log line instead.
      if IsPhysicallyReadOnly(db) or IsWorkingCopy(db) then
      begin
        LogError('CreateAndOpenDBFs: "' + TableFile.Value +
          '" does not match the current schema and is on read-only ' +
          'media, so it cannot be repaired - skipping ' + db.TableName +
          ' for this run.');
        db.EnableControls;
        Continue;
      end;
      LogError('CreateAndOpenDBFs: "' + TableFile.Value +
        '" does not match the current schema (or could not be read) - ' +
        'quarantining it so a fresh copy can be created.');
      if not QuarantineFile(TableFile) then
      begin
        // Couldn't even get the bad file out of the way - opening it
        // would still risk the AV this check exists to prevent, so this
        // table has to sit out the run rather than gamble on db.Open.
        LogError('CreateAndOpenDBFs: could not quarantine "' + TableFile.Value +
          '" - skipping ' + db.TableName + ' for this run.');
        db.EnableControls;
        Continue;
      end;
    end;

    if not TableFile.Exists then
    begin
      case db.Name of
        'ABOUT': SetupSchemaAbout(db);
        'EPS', 'TEMPEPS': SetupSchemaEps(db);
        'LIST': SetupSchemaList(db);
        'LOG': SetupSchemaLog(db);
        'SHOWS': SetupSchemaShows(db);
        else
          NoOp
      end;
      try
        db.CreateTable;
      except
        on E: Exception do
        begin
          // NOTE: This used to be where a case-mismatch in aDB.Name
          // (e.g. 'Eps' instead of 'EPS', from JCF relowercasing the
          // DBFs enum) would surface as "Invalid DBF file. Invalid
          // field definition." - fixed at the source above via
          // UpperCase(GetEnumName(...)) instead of a retry-on-failure
          // workaround here, so this except block should now only
          // catch genuine table-creation failures.
          LogError('Error creating table ' + db.TableName, E);
          db.EnableControls;
          Continue; // Skip to next database
        end;
      end;
    end; { Open the database}
    // ConfigureDbfDefaults called DisableControls unconditionally, so the
    // matching EnableControls has to be in a finally. Previously it sat
    // inside the try after db.Open - if Open threw, the except block logged
    // and moved on, and THAT dataset's controls stayed disabled for the
    // entire life of the process, with no way to notice.
    try
      try
        AssignDBFDataSource(db, ADbfArray[DbIndex].ADataSource, AOwner);
        db.AfterScroll := ADefaultAfterScroll;
        db.BeforeScroll := ADefaultBeforeScroll;
        db.AfterPost := ADefaultRecordCountChanged;
        db.AfterDelete := ADefaultRecordCountChanged;
        // Deliberately NOT setting db.Exclusive here: this opens all DBFs in
        // normal shared mode, matching AcquireExclusive/EndExclusive's model
        // where exclusive access is a temporary escalation (see PackThisTable /
        // ZapPackTable), not a standing state. Setting Exclusive := True with
        // no matching EndExclusive would lock the dataset for every subsequent
        // caller in this session (see the same issue noted at fileyfrm.pas:2869).
        db.Open;
        // Set the aIsInitialized flag to True after successful opening
        ADbfArray[DbIndex].aIsInitialized := True;
        ADbfArray[DbIndex].ADataSource.DataSet := db;
      except
        on E: Exception do
        begin
          LogError('Error opening database ' + db.TableName, E);
          ADbfArray[DbIndex].aIsInitialized := False;
          // Ensure flag is set to False on failure
        end;
      end;
    finally
      db.EnableControls;
    end;
  end;
end;

// Counterpart to AcquireExclusive: drops back to shared access and
// restores the policy ReadOnly flag AcquireExclusive saved.
procedure ReleaseExclusive(var aDB: TDbf; AWasReadOnly: Boolean);
begin
  aDB.EndExclusive;
  aDB.ReadOnly := AWasReadOnly;
end;

procedure AddIndexExclusive(var aDB: TDbf; const AIndexName, AFields: String;
  AOptions: TIndexOptions);
var
  WasReadOnly: Boolean;
begin
  WasReadOnly := AcquireExclusive(aDB, 'create index ' + AIndexName);
  try
    aDB.AddIndex(AIndexName, AFields, AOptions);
  finally
    ReleaseExclusive(aDB, WasReadOnly);
  end;
end;

procedure DeleteIndexIfPresentExclusive(var aDB: TDbf;
  const AIndexName: String);
var
  WasReadOnly: Boolean;
begin
  // Before anything else - including clearing IndexName below, which
  // would otherwise leave a read-only table unsorted for nothing.
  RequireWritable(aDB, 'drop index ' + AIndexName);
  if not DbfHasIndex(aDB, AIndexName) then Exit;
  // aDB.IndexName can't still point at the index we're about to drop -
  // clearing it first also means we're not left navigating by a
  // now-nonexistent index afterward.
  if SameText(aDB.IndexName, AIndexName) then aDB.IndexName := '';
  WasReadOnly := AcquireExclusive(aDB, 'drop index ' + AIndexName);
  try
    aDB.DeleteIndex(AIndexName);
  finally
    ReleaseExclusive(aDB, WasReadOnly);
  end;
end;

procedure PackThisTable(var aDB: TDbf);
var
  WasReadOnly: Boolean;
begin
  if aDB.PhysicalRecordCount <= 0 then Exit; // nothing to pack
  // TDbf packs by writing the table to a new FILE named after the table's
  // own file plus "_1" (dbf_common.FindNextName) and renaming it back. An
  // in-memory table (ABOUT, LIST, TEMPEPS) has no file name, so that copy
  // was created as "_1", "_2", ... in the current directory and left
  // there. Its deleted records are hidden anyway (ShowDeleted is False),
  // and the memory is freed when the table closes.
  if aDB.Storage = stoMemory then Exit;

  WasReadOnly := AcquireExclusive(aDB, 'pack the table');
  try
    aDB.PackTable;
  finally
    ReleaseExclusive(aDB, WasReadOnly);
    aDB.First;
  end;
end;

procedure ZapPackTable(var aDB: TDbf; AOnStatus: TDBFStatusEvent);
var
  WasReadOnly: Boolean;
begin
  if not Assigned(aDB) then Exit;
  if (aDB.PhysicalRecordCount <= 0) then Exit;
  // don't bother if nothing to Zap

  // Zap + PackTable physically rewrite the table on disk, so -- unlike a
  // mere export -- this genuinely needs exclusive access: proceeding
  // without it risks corrupting the file for whoever else has it open.
  WasReadOnly := AcquireExclusive(aDB, 'empty (zap) the table');
  aDB.Active := True;
  aDB.ShowDeleted := True;
  // CopyFile(TableName, TableName + '.bak');}{BackupFileForWrite(TableName);}

  aDB.DisableControls;
  try
    if Assigned(AOnStatus) then AOnStatus('ZAPPING ' + aDB.TableName);
    aDB.Zap;
    if Assigned(AOnStatus) then AOnStatus('ZAPPED ' + aDB.TableName);
    // Not for an in-memory table - see PackThisTable. Zap has already set
    // its record count to 0, so there is nothing left to reclaim.
    if aDB.Storage <> stoMemory then aDB.PackTable;
  finally
    aDB.Close;
    // for safety, after packing, close then reopen
    aDB.Open;
    aDB.EnableControls;
    aDB.ShowDeleted := False;
    // Release exclusive mode now that the destructive work is done, so
    // other instances can open the table normally again.
    ReleaseExclusive(aDB, WasReadOnly);
    aDB.First;
  end;
end;

initialization
  DebugLog('uDBFManager.pas initialization');

end.
