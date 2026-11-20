# Internet Archive Video Downloader

A Bash script for bulk-downloading video files from [Internet Archive](https://archive.org) items. It fetches item metadata via the Archive.org API, filters to video files only, verifies downloads using checksums, skips files already downloaded successfully, and retries any failures automatically — making it safe to re-run after an interrupted session.

## Features

- Downloads all video files from any Internet Archive item
- Preserves the item's directory structure (e.g. `Season 1/`, `Season 2/`)
- Skips non-video files entirely — subtitles, XML, torrents, artwork, `.ia.*` re-encodes, etc.
- Filters out Internet Archive's internal `.ia.*` derivative files (e.g. `episode.ia.mp4`) when an original version exists; falls back to the `.ia.*` file if it is the only version available
- Verifies completed downloads using SHA1 or MD5 checksums from the Archive.org metadata API
- Skips files that are already present and verified — re-running is always safe
- Re-downloads files that fail checksum verification (e.g. from a previous interrupted download)
- Resumes partial downloads using `wget --continue`
- Automatically retries failed files after the main pass completes, with a 10-second pause between passes
- Reports first-pass failures, successful retries, and final failures separately
- Prompts interactively if multiple formats are detected for the same video and `--one-per-video` was not specified
- Optionally selects only one format per video when multiple encodes exist
- Optionally skips a video entirely if any local variant of it already exists
- Configurable format preference order
- Adds a random 2–5 second delay between each file to avoid hammering Archive.org's servers

## Requirements

| Dependency | Purpose |
|---|---|
| `bash` 4.0+ | Script runtime |
| `python3` | Metadata parsing and manifest generation |
| `curl` | Fetching item metadata from the Archive.org API |
| `wget` | Downloading files with resume support |
| `sha1sum` / `md5sum` | Checksum verification (optional but recommended) |

On most Linux distributions these are available by default or via your package manager. On macOS, `wget` and GNU `coreutils` (for `sha1sum` / `md5sum`) can be installed via [Homebrew](https://brew.sh):

```bash
brew install wget coreutils
```

## Installation

```bash
git clone https://github.com/disappointingsupernova/internet-archive-video-downloader.git
cd internet-archive-video-downloader
chmod +x archive-video-download.sh
```

Optionally, place the script somewhere on your `$PATH`:

```bash
sudo cp archive-video-download.sh /usr/local/bin/archive-video-download
```

## Usage

```
archive-video-download.sh [OPTIONS] URL OUTPUT_DIR
```

`URL` may be an Archive.org item URL (either a `/details/` or `/download/` URL) or a bare item identifier.

`OUTPUT_DIR` is the local directory to save files into. It will be created if it does not exist.

### Options

| Option | Description |
|---|---|
| `--one-per-video` | Select only one format per video, using the preference order |
| `--prefer EXT,EXT,...` | Comma-separated list of preferred extensions, in priority order |
| `--skip-existing-variant` | Skip a video if any local file with the same base name already exists, regardless of format |
| `-h`, `--help` | Show usage information |

### Default format preference

If `--prefer` is not specified, the default order is:

```
mp4, mkv, m4v, webm, mov, avi, mpeg, mpg, wmv, flv, ts, ogv, 3gp
```

## Examples

Download everything from an item:

```bash
./archive-video-download.sh \
    "https://archive.org/details/example-item-identifier" \
    "/mnt/media/archive"
```

Download one file per video, preferring MP4 then MKV:

```bash
./archive-video-download.sh \
    --one-per-video \
    --prefer mp4,mkv \
    "https://archive.org/details/example-item-identifier" \
    "/mnt/media/archive"
```

Skip videos where you already have any local format:

```bash
./archive-video-download.sh \
    --one-per-video \
    --prefer mp4,mkv \
    --skip-existing-variant \
    "https://archive.org/details/example-item-identifier" \
    "/mnt/media/archive"
```

Use a bare identifier instead of a full URL:

```bash
./archive-video-download.sh example-item-identifier /mnt/media/archive
```

## Subdirectory filtering

Some Archive.org items organise their files into subdirectories. If you pass a URL that includes a path below the item identifier, the script will detect it and prompt you:

```
[INFO] URL contains subdirectory: Season 1
       Download this subdirectory only? [Y/n]
```

- Press Enter or `y` to download only files under that subdirectory
- Press `n` to download the entire item regardless

For example, this URL:

```
https://archive.org/download/example-item/Season%201/
```

will detect `Season 1` as the subdirectory and offer to filter to it. If you accept, only files whose path begins with `Season 1/` will be queued.

## How it works

1. The Archive.org item identifier is extracted and validated from the provided URL or bare identifier. If the URL includes a path below the identifier, that subdirectory is detected and the user is prompted to confirm whether to filter to it or download the whole item
2. The item's metadata JSON is fetched from `https://archive.org/metadata/<identifier>`
3. A Python script parses the metadata and builds a null-delimited download manifest:
   - Non-video files are excluded (subtitles, XML, torrents, images, etc.)
   - `.ia.*` derivative files (Archive.org internal re-encodes) are excluded when an original version of the same video exists; kept if they are the only available version
   - If `--one-per-video` is set, only the highest-priority format for each video is selected
   - If `--one-per-video` is not set but multiple formats are detected, the script prompts interactively
   - Each manifest entry contains: URL, relative path, file size, MD5, and SHA1
4. The main download loop processes each entry:
   - If the file already exists and its size matches, the SHA1 (or MD5) checksum is verified. If it passes, the file is skipped. If it fails, the file is re-downloaded
   - Downloads use `wget --continue` so interrupted transfers resume rather than restart
   - After each download, size and checksum are verified
   - A random 2–5 second delay is applied between each file
5. Any files that failed the main pass are collected and retried automatically after a 10-second pause
6. A summary is printed showing first-pass failures, successful retries, and any remaining failures
7. The script exits with a non-zero status if any file failed both passes

## Output and directory structure

The script preserves whatever directory structure the Archive.org item uses. For example, an item organised as:

```
Season 1/episode-01.mp4
Season 1/episode-02.mp4
Season 2/episode-01.mp4
```

will be saved locally as:

```
OUTPUT_DIR/
  Season 1/
    episode-01.mp4
    episode-02.mp4
  Season 2/
    episode-01.mp4
```

## Example output

```
======================================
 Internet Archive Video Downloader
======================================
Item:          example-item-identifier
Output:        /mnt/media/archive
One per video: 1
Skip variants: 0
Preferences:   mp4,mkv,m4v,webm,...

[INFO] Fetching metadata...
[INFO] Video files found: 52
[INFO] Selected video files: 26

[1] Season 1/episode-01.mp4
[OK] Downloaded

[2] Season 1/episode-02.mp4
[SKIP] Already downloaded (verified)

...

======================================
 Retrying 2 failed file(s)
======================================

[RETRY] Season 2/episode-05.mp4
[OK] Downloaded

======================================
 Download summary
======================================
Queued:             26
Downloaded:         24
Already complete:   1
Failed (first pass):2
Retried OK:         1
Failed (final):     1
Location:           /mnt/media/archive
```

## Exit codes

| Code | Meaning |
|---|---|
| `0` | All files downloaded and verified successfully (including retries) |
| `1` | One or more files failed both the main pass and the retry pass |

## Notes on Archive.org etiquette

The Internet Archive is a non-profit that relies on donations. Please be considerate:

- This script adds a random 2–5 second delay between each file automatically
- Avoid running multiple instances against the same item simultaneously
- Consider scheduling large downloads during off-peak hours

## Contributing

Bug reports and pull requests are welcome. There are no formal contribution guidelines — just keep changes focused and test against a real Archive.org item before submitting.

## Licence

MIT — see [LICENSE](LICENSE) for details.
