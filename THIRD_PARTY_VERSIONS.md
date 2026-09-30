# Third-Party Bundled Binary Versions

Filey bundles or shells out to a small number of third-party binaries.
Most should simply be kept at the latest available version. The
exceptions, and the reasons they're pinned, are documented here so the
reasoning isn't lost to a buried source comment or a forum thread only
one of us remembers finding.

## mkvmerge.exe / mkvpropedit.exe (Windows builds)

**Pinned to: v64.0.0 "Willows" (2021-12-27), 32-bit**

This is deliberate, not neglect. It is the last official mkvtoolnix
release built against Qt5. Every build from v64.0.0.45 onward moved to
Qt6, whose minimum supported Windows version is Windows 10. Those
later builds call Windows-10+-only Win32 APIs unconditionally (e.g.
`kernel32.dll`'s `SetThreadDescription`) and fail to launch at all on
Windows 7 or 8.1, with an "Entry Point Not Found... could not be
located in the dynamic link library" error.

mkvtoolnix's own "Officially supported operating systems and versions"
wiki page only ever describes *current* policy (currently: Windows 10
and newer) - it does not record *when* Windows 7/8.1 support was
actually dropped. That history lives only in the Qt5->Qt6 migration,
confirmed via the version range in community reports (builds between
64.0.0.45 and 67.0.0.1 were the Qt6 transition).

**Before updating either binary:** confirm any replacement build is
still Qt5-era (v64.0.0.44 or earlier), or re-verify Windows 7/8.1
launch compatibility from scratch. A newer official mkvtoolnix release
will work perfectly on Windows 10/11 and silently fail to even start
on Windows 7/8.1.

Both binaries are 32-bit, which runs fine under WOW64 on 64-bit
Windows and keeps compatibility with any remaining 32-bit-only hosts.
Filey shells out to these as external processes (see
`TForm1.ValidateAndDiscoverTools` in `fileyfrm.pas`), so their bitness
is independent of Filey's own build architecture.

## libeay32.dll / ssleay32.dll (Windows builds)

Bundled OpenSSL DLLs, extracted from Filey's embedded source-zip
resource (`g.FilePathSourceZip`) at first run via
`TForm1.CheckResourceFiles` / `ConfigureOpenSSLLibPaths`
(`fileyfrm.pas`). No specific version pin is currently documented
here - if one becomes necessary (e.g. for the same kind of
OS-compatibility reason as mkvtoolnix above), record it here following
the same format.

## ffprobe.exe

No pin currently in effect - track any future pin reason here if one
arises.
