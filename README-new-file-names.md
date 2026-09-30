<!--
  Three pieces to paste into README.md. Paste each one where its comment says.
  Then regenerate README.html from README.md (pandoc, as usual), and rebuild
  filey-src.zip, so that the Readme tab inside Filey shows the new section.
-->

<!-- PIECE 1 of 3: "Key Features" list. Add after the "Format Support" line.
     Keep the two trailing spaces: the other lines use them as line breaks. -->

✅ **Windows-Safe Names** - Colons, question marks, slashes and the rest stay readable as look-alike characters (or become underscores, if you prefer)  

<!-- PIECE 2 of 3: "After Filey" example (optional). Add this line to the
     code block, to show a look-alike colon in action. -->

```
Star Trek꞉ Strange New Worlds S01E01 Strange New Worlds.mkv
```

<!-- PIECE 3 of 3: "Advanced Features". Add as the first subsection, just
     above "### Episode Information Lookup". -->

### New File Names

Windows doesn't allow `: ? * / \ | < > "` in file names, and plenty of show titles use them: *Star Trek: Strange New Worlds*, *M\*A\*S\*H*, *What If...?*, *Face/Off*. Two settings in Filey's **File > New file names** menu decide what happens to those characters, and what goes between words. A choice is saved as soon as you click it and applies to every name Filey builds after that.

**Characters Windows doesn't allow**

- **Look-alikes** (the default): each one becomes a Unicode character that looks like it and that Windows does allow.
- **Underscores**: each one becomes `_`, as in `Star Trek_ Strange New Worlds`.

The look-alikes:

- Colon `:` becomes `꞉`, as in Star Trek꞉ Picard
- Question mark `?` becomes `？`, as in What If...？
- Asterisk `*` becomes `∗`, as in M∗A∗S∗H
- Slash `/` becomes `∕`, as in Face∕Off
- Backslash `\` becomes `∖`
- Vertical bar `|` becomes `ǀ`
- Angle brackets `<` and `>` become `‹` and `›`
- Straight quotes `"` become curly quotes `“` and `”`, as in “Weird Al” Yankovic

**Between words**

- **Spaces** (the default): `Star Trek꞉ Strange New Worlds S04E01 Valles Marineris 1080p x264.mkv`
- **Dots**: `Star.Trek꞉.Strange.New.Worlds.S04E01.Valles.Marineris.1080p.x264.mkv`

**Good to know**

- Filey's show and episode lists keep every title exactly as epguides.com spells it. These settings only change the names Filey writes, so you can switch back and forth at any time.
- Filey recognises a show however its files were named: with look-alikes, underscores, dots or spaces, or with the full-width characters some other programs (yt-dlp, rclone) use in place of `: ? * / \ | < > "`.
- When Filey offers to rename a show's folder, the folder name follows the same setting, without trailing dots (Windows doesn't allow a folder name to end in one).
- A look-alike shows as an empty box only on a system whose fonts don't have it. The file name is still correct. If that bothers you, choose **Underscores**.
- In `filey.ini` these are `ReservedCharacters=lookalike` (or `underscore`) and `WordSeparator=space` (or `dot`), in the `[Main]` section.
