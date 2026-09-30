# filey

Rename TV episode files consistently

## About this program

- The purpose of this amateur pandemic-downtime project was to teach myself Windows/Linux programming with Internet data-scraping features.

- This program non-perfectly attempts to rename TV episode files into a consistent preferred format.

- Likely episode-naming-obstacles have been overcome, but not every conceivable naming permutation has been acid-tested.  There's NO GUARANTEE that this program will correctly rename any TV episode video file, or that its programming logic is flawless. You should review potential filename changes before approving them.

- ***Double Super-Secret Hint*** -- This is in actuality a cleverly-disguised skeleton template to be cannibalized for future programs having absolutely nothing at all to do with renaming files.
  
  - When considered from a certain perspective, most computer programs can be viewed merely as variations of database manipulation (i.e., [Maslow’s hammer](https://en.wiktionary.org/wiki/if_all_you_have_is_a_hammer,_everything_looks_like_a_nail)).

## Under the Hood

- This program uses minimal menus, to put as much information as possible directly in-your-face.

- dBase format was good enough for Jet Propulsion Laboratories (where it was invented), so it’s good enough for me.

- Run-time creation of dBase files here allows easy addition/changing of databases on an ad-hoc basis, rather than utilizing tedious design-time Data Modules.  The Array of DBFs allows quick iteration through all databases, regardless of structure.

- This standalone, self-contained program quite deliberately has **NO DEPENDENCIES** upon external runtimes such as: the Borland Database Engine (BDE), Python, Java, or .NET.  However, Windows *does* require “ssleay32.dll” and “libeay32.dll” to read Internet files -- so those DLLs will be re-created automatically, if not otherwise found.

- The executable files at [www.gitlab.com/MarkAPaley/filey](http://www.gitlab.com/MarkAPaley/filey) have been aggressively compiled for speed using [Whole Program Optimization](https://wiki.freepascal.org/Whole_Program_Optimization#Concrete_Lazarus_IDE_example).

- In my opinion, all programs should let you set fonts to whatever size is most readable to you.  Ctrl+Numpad+, Ctrl+Numpad-, or Ctrl+MouseWheel will quickly change every font to a larger or smaller size.

- When re-sized on screen, this program does the necessary math to look intuitively  “right."

- In my opinion, all Open Source programs should show you their Source Code under the “About” tab:

![ ](./screenshots/Windows_11_-_03_About_Source_Code.png)

- Note: If you prefer your video filenames to follow a different standard, well here’s the Source Code to let you create whatever formatting you like.

![ ](./screenshots/Linux_-_Usenet_10_Source_of_episode_information.png)

- This shows where the information comes from.

- Note: If [www.epguides.com](http://www.epguides.com) changes its web page layout, from which this program scrapes its data, then this program will stop working correctly.

***

## Installation

- Just copy **`filey.exe`** (Windows), or **`filey`** (Linux), into an empty folder, and run it.

### Video example: First-time running this program in an empty folder

![ ](./screenshots/Windows_11_-_01_First_Time_startup.gif)

- This program will create in its folder whatever other files it needs. A Windows Desktop Shortcut will be created automatically.

### Optional (recommended) files will be re-created

![ ](./screenshots/Windows_11_-_00_Recreate_02.png)

Select Yes to allow **`ffprobe`** to put video resolution size into each filename. You will see which files have the highest resolution, and which have subtitles.

![ ](./screenshots/Windows_11_-_00_Recreate_01.png)

Select Yes to allow **`mkvpropedit`**  to replace each Title metadata tag with the video’s new filename – to show on-screen the episode name of each Matroska Video (MKV) file you’re watching.

![ ](./screenshots/Windows_11_-_Getting_TV_Show_Names.png)

"Getting TV Show Names" appears if there is no SHOWS.DBF database.  A current version of [allshows.txt](http://www.epguides.com/common/allshows.txt) will be downloaded, and the SHOWS.DBF database will be created.  This requires a few minutes, since there are more than a million data fields.

### Manually Zapping the Shows Database

![ ](./screenshots/Windows_11_-_Zap_Databases.png)

If you later want to add brand-new TV series to the SHOWS database, select “Files | Maintenance | Zap” from the menu.   (Alternatively, manually delete SHOWS.DBF, then re-run the program to automatically re-create it.)

![ ](./screenshots/Windows_11_-_AfterZappingRebuildingShowsDatabase.png)

After Zapping the database,"Getting TV Show Names" will appear, and a fresh SHOWS.DBF database will be re-created from the current "allshows.txt" listing.

***

## Using this Program

### Drag/drop Video Files onto filey

![ ](./screenshots/filey_demo_01-many_files_with_differing_styles_of_filenames_at_once.gif)

Watch video:  Drag-Drop (or File-Open) files from a file manager onto this program's "FROM" column.  Include any corresponding .idx, .nfo, or .sub files, to rename those as well.

![ ](./screenshots/Windows_7_-_02_-_Files_dropped_into_filey.png)

Files were dragged from Windows Explorer (on the right), and dropped onto the "FROM" column in this program (on the left).

![ ](./screenshots/Windows_7_-_03b_-_Looked_up_episode_names.png)

Episode names were automatically looked-up from [epguides.com](http://www.epguides.com), and new standardized filenames were created in the "TO" column.

- When different TV series have the same name, the correct series will be determined by matching episode numbers and episode names.  (`S01E01 Pilot` will be ignored, for obvious reasons.)

### Click "Rename Matched Files"

![ ](./screenshots/Rename_Matched_Files_button.png)

- Click the "Rename Matched Files" button to approve/deny each (or all) of the suggested new names.

***

## More Examples of Using This Program

![ ](./screenshots/filey_demo_03_-_showing_how_filey_gets_its_data.gif)

Watch video:  Manually type TV series, then switch to Episodes tab, to lookup episodes.  The Browser and Memo tabs show where and how this program gets its data.

- Clicking the grid header bar will resize columns to fit.

- "LookupDate" speeds-up this program by limiting episode name lookup to once per day.  To look more than once per day, then just manually clear the LookupDate field.

***

### Video Example: Title of Series is missing from filenames

![ ](./screenshots/Getting_Series_from_Folder_name.gif)

Watch video:  Here, none of the filenames includes the Title of the TV series.  So, the program attempts to get that from the name of the folder holding these files.

***

### Video Example: Title of Series is completely missing, so tries guessing based on episode names and numbers already contained in Episodes tab

![ ](./screenshots/No_Series_Name_Ep_Num_and_Name_only.gif)

- Watch video:  This trick only works if you've already manually looked up the episodes for a particular series, showing them in the Episode tab.

- Here, the program stops several times, because the episode name does not precisely match that shown at [www.epguides.com](http://www.epguides.com).  The "Select A Show" pop-up is basically asking you for permission to blindly force an epguides.com episode name onto this file.

***

### Select a Show

![ ](./screenshots/filey_demo_02_-_multiple_shows_with_same_name_you_select_correct_year.gif)

Watch video:  If this program can’t figure out which series a particular episode belongs to (because it’s missing the Year or matchable Episode Name), from among several different TV Series each having the same Title, then you will be asked to select the correct TV series name.

- Note: If you're dropping a batch of files all from the same series, where the preceding video file *does* provide the correct TV Series name and year, then you won't be asked to select the Series.

![ ](./screenshots/Windows_11_-_04_Right-click_to_Select_a_Series.png)

- Right-Click to Select a Series

![ ](./screenshots/Windows_11_-_07_Clicked_on_Episodes_tab.png)

- The episode names of the selected series.

![ ](./screenshots/Windows_11_-_07_Showing_Hidden_Fields.png)

- If you want to see more information about the series, Right-Click and "Toggle Hidden Fields"

### Renaming oddly-named UseNet files

![ ](./screenshots/Linux_-_Usenet_03_drag_drop_files_into_filey.png)

- Drag/drop both the oddly-named MKV file and its matching NFO file, and both files will be re-named appropriately.

![ ](./screenshots/Linux_-_Usenet_04_after_automatic_renaming.png)

- Now you can click "Rename Matched Files" to put the filenames into the same consistent format as other video files.

![ ](./screenshots/Linux_-_Usenet_06c_File_Renamed.png)

- In your file explorer, you will see that the file has been renamed.

### Undo Renaming

![ ](./screenshots/Linux_-_Usenet_09_Undo.png)

To Undo a renaming, click the Undo tab, click Undo checkboxes, then click the "Undo Renaming of Selected Files" button.

### Manually looking up information

![ ](./screenshots/Linux_-_Usenet_05_All_files_containing_Flash.png)

- If you click on the Shows tab, and type in the show "Flash," you'll see that there are 9 different shows containing the word "Flash."

![ ](./screenshots/Linux_-_Usenet_06b_Episodes.png)

- Click on the Episodes tab to see episode names of this series.

![ ](./screenshots/Windows_11_-_05_Toggle_Hidden_Fields.png)

- If you want to see even more information about these shows, then Right-Click and select "Toggle Hidden Fields."

***

## Possible Error Conditions

### If OpenSSL library error

![ ](./screenshots/Windows_11_-_Could_not_initialize_OpenSSL.png)

- If “Could not initialize OpenSSL library” appears,  just click OK.  The Dynamic Link Libraries (DLLs) needed for Windows will be created automatically.  Or, just close the program, and run it again.  

### If no Internet connection error

![ ](./screenshots/Windows_11_-_06_Internet_disconnected_or_missing_libeay32.dll.png)

- This message means that you likely do not have an Internet connection.  New information can't be looked up until an Internet connection is established.

### If file sharing error

![ ](./screenshots/Unable_to_Open_File.png)

- If the program crashes while Exclusively using a DBF file, then the next time it tries to open that database file, it might show a sharing error.  An easy solution is to close this program, delete that DBF file, and let the program re-create it.

***

### Works on Windows XP

![ ](./screenshots/Windows_XP_01.png)

***

### Works on Windows 7

![ ](./screenshots/Running_on_Windows_7.png)

***

### Works on Windows 10

![ ](./screenshots/Running_on_Windows_10.png)

***

### Works on Windows 11

![ ](./screenshots/Windows_11_-_01_About.png)

***

### Windows Version Works on WINE in Linux

![ ](./screenshots/Running_on_Wine.png)

***

### Linux Version Works on Linux

![ ](./screenshots/Running_on_Linux.png)

***

## License

Filey - Rename TV episode files consistently
https://gitlab.com/MarkAPaley/filey

Copyright (C) 2026 Mark A Paley

This program is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation; either version 2 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program; if not, see <https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>.

Report bugs and questions at <https://gitlab.com/MarkAPaley/filey/-/issues>.

This program contains embedded copies of "ffprobe" (Linux) and "ffprobe.exe" (Windows), also free software redistributable under the GNU General Public License.  See ffprobe's license with the terminal command "ffprobe -L"  or at https://ffmpeg.org/ffprobe.html.

This program contains embedded copies of "mkvpropedit" (Linux) and "mkvpropedit.exe" (Windows),  a tool to update Matroska file tags, licensed under GPLv2, see: https://gitlab.com/mbunkus/mkvtoolnix/-/blob/main/COPYING, downloaded from: https://mkvtoolnix.download.

This program contains embedded copies of "libeay32.dll" and "ssleay32.dll" (Windows), an open source client/server communications library, downloaded from https://github.com/IndySockets/OpenSSL-Binaries, licensed under the Indy Modified BSD License, see: https://www.indyproject.org/license.

In Linux, to install OpenSSL, at the Terminal prompt enter:
sudo apt-get install openssl
sudo apt-get install libssl-dev
