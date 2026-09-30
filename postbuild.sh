#!/bin/sh
#
# postbuild.sh -- run by Lazarus after each Linux build of filey
# (Project Options -> Compiler Commands -> Execute after). Copies the
# freshly built executable to where it is used:
#   * ~/.local/bin, so "filey" on the PATH is always the latest
#   * the AppImage's AppDir, ready for the next AppImage build
#
# A destination folder that does not exist is reported and skipped,
# never created, so a typo cannot scatter files around the disk.

SRC="$(dirname -- "$0")"
# Where every Linux build mode writes the executable (BuildModes.xml:
# Target Filename "bin\$(TargetCPU)-$(TargetOS)\filey").
EXE="$SRC/bin/x86_64-linux/filey"
# AppDir sits next to src (main/AppDir), where bundleme.sh expects it.
DESTS="$HOME/.local/bin $SRC/../AppDir/usr/bin"

if [ ! -f "$EXE" ]; then
    echo "postbuild.sh: $EXE not found -- nothing copied." >&2
    exit 1
fi

STATUS=0
for DEST in $DESTS; do
    if [ -d "$DEST" ]; then
        cp -f -- "$EXE" "$DEST/" && echo "postbuild.sh: copied to $DEST" || STATUS=1
    else
        echo "postbuild.sh: $DEST does not exist -- skipped." >&2
        STATUS=1
    fi
done
exit $STATUS
