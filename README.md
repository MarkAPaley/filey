# Filey - TV Episode File Manager

![Filey Logo](./filey64.png)

**Transform your messy TV episode files into perfectly organized, consistently named collections.**

## What is Filey?

Filey automatically renames and organizes your TV episode video files with consistent, professional naming conventions. No more manually typing episode titles or guessing season/episode numbers!

[More Information](https://gitlab.com/MarkAPaley/filey/-/blob/master/README2.md)

### Before Filey:

```
random.file.name.mkv
Some.Show.S01E01.terrible.naming.avi
episode_1_season_2_bad_quality.mp4
```

### After Filey:

```
Game of Thrones S01E01 Winter Is Coming.mkv
Breaking Bad S02E01 Seven Thirty-Seven.mkv
The Office S03E01 Gay Witch Hunt.mp4
```

## Key Features

✅ **Smart Episode Detection** - Automatically identifies season/episode numbers from various naming formats  
✅ **Online Episode Lookup** - Downloads episode titles and information from online databases  
✅ **Batch Processing** - Handle many files at once  
✅ **Video Analysis** - Embeds episode information (name and number, codec, resolution, audio channels, subtitle, and release group) directly into mkv title metadata,  to display at top of VLC screen
✅ **Format Support** - Works with all major video formats (MKV, MP4, AVI, etc.)  
✅ **Cross-Platform** - Runs on Windows, Wine, and Linux  
✅ **Safe Operation** - Preview changes before applying them  

## Quick Start

### System Requirements

- **Windows:** Windows 7 or later
- **Linux:** Most modern distributions
- **Dependencies:** Automatically handles ffprobe and mkvpropedit tools

### Installation

1. Download the latest release from the [Releases page](https://gitlab.com/MarkAPaley/filey/-/tree/master/releases)
2. Extract the files to your preferred location
3. Run `filey.exe` (Windows) or `filey` (Linux)

### Basic Usage

1. **Add Files**: Drag and drop your TV episode files into Filey
2. **Select Show**: Choose the TV show from the database or add a new one
3. **Review**: Preview the new file names in the list
4. **Rename**: Click "Rename Files" to apply changes

## Advanced Features

### Episode Information Lookup

- Automatically downloads episode titles from online databases
- Supports major TV databases and episode guides
- Caches information for offline use

### Video File Analysis

- Detects video codec (x264, x265, etc.)
- Identifies resolution (720p, 1080p, 4K)
- Analyzes audio channels (stereo, 5.1 surround)
- Finds embedded subtitles

### Batch Operations

- Process entire seasons at once
- Handle mixed formats and naming conventions
- Maintain folder structure while renaming

### Database Management

- Built-in show database for quick access
- Add custom shows and episode information

## File Format Support

### Video Formats

MKV, MP4, AVI, WMV, MOV, MPEG, M2TS, FLV, WEBM, and more

### Subtitle Formats

SRT, SUB, IDX, NFO

## Troubleshooting

### Common Issues

**Files not being renamed:**

- Check that files aren't currently being used by other programs
- Verify you have write permissions to the folder

**Episode information not found:**

- Ensure internet connection is working
- Try manually searching for the show name
- Check spelling of show title

**Linux wine requirements:**

- Some features may require Wine for Windows tool compatibility
- Most native Linux tools are supported when available

## Privacy & Legal

- **Privacy Policy**: See [Privacy_Policy.html](https://gitlab.com/MarkAPaley/filey/-/blob/master/Privacy_Policy.html)
- **License**: GNU General Public License v2+
- **Copyright**: (C) 2026 Mark A Paley

## Technical Details

### Built With

- **Language**: FreePascal/Lazarus
- **Database**: dBASE format files
- **External Tools**: ffprobe, mkvpropedit
- **Architecture**: Cross-platform GUI application

### System Integration

- Supports drag-and-drop file operations
- Integrates with system file associations
- Respects system font and theme settings

---

**Ready to organize your TV collection?** [Download Filey](https://gitlab.com/MarkAPaley/filey/-/tree/master/releases) and start managing your episode files like a pro!e
