# Internet Archive Video Downloader

A Bash script for downloading video files from [Internet Archive](https://archive.org) items. It fetches the item's metadata via the Archive.org API, filters to video files only, verifies downloads using checksums provided by the API, and skips files that have already been downloaded successfully — making it safe to re-run after an interrupted download.

## Features

- Downloads all video files from any Internet Archive item
- Preserves the item's directory structure (e.g. `Season 1/`, `Season 2/`)
- Skips non-video files entirely (subtitles, XML, torrents, artwork, etc.)
- Verifies completed downloads using SHA1 or MD5 checksums from the Archive.org metadata API
- Skips files that are already present and verified — re-running is always safe
- Re-downloads files that are present but fail checksum verification (e.g. from a previous interrupted download)
- Resumes partial downloads using `wget --continue`
- Optionally selects only one format per video when multiple encodes exist
- Optionally skips a video entirely if any local variant of it already exists
- Configurable format preference order

## Requirements

| Dependency | Purpose |
|---|---|
| `bash` 4.0+ | Script runtime |
| `python3` | Metadata parsing and manifest generation |
| `curl` | Fetching item metadata from the Archive.org API |
| `wget` | Downloading files with resume support |
| `sha1sum` / `md5sum` | Checksum verification (optional but recommended) |

On most Linux distributions these are available by default or via your package manager. On macOS, `wget` and GNU `coreutils` (for `sha1sum`/`md5sum`) can be installed via [Homebrew](https://brew.sh):

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
    "https://archive.org/details/some-item-identifier" \
    "/mnt/media/archive"
```

Download one file per video, preferring MP4 then MKV:

```bash
./archive-video-download.sh \
    --one-per-video \
    --prefer mp4,mkv \
    "https://archive.org/details/some-item-identifier" \
    "/mnt/media/archive"
```

Skip videos where you already have any local format:

```bash
./archive-video-download.sh \
    --one-per-video \
    --prefer mp4,mkv \
    --skip-existing-variant \
    "https://archive.org/details/some-item-identifier" \
    "/mnt/media/archive"
```

Use a bare identifier instead of a full URL:

```bash
./archive-video-download.sh some-item-identifier /mnt/media/archive
```

## How it works

1. The Archive.org item identifier is extracted and validated from the provided URL
2. The item's metadata JSON is fetched from `https://archive.org/metadata/<identifier>`
3. A Python script parses the metadata, filters to video files only, and builds a null-delimited download manifest containing the URL, relative path, file size, MD5, and SHA1 for each file
4. The Bash download loop processes each entry:
   - If the destination file already exists and its size matches, the SHA1 (or MD5) checksum is verified against the value from the metadata. If it passes, the file is skipped. If it fails, the file is re-downloaded
   - Downloads use `wget --continue` so interrupted transfers resume rather than restart
   - After each download, the size and checksum are verified. A mismatch is recorded as a failure
5. A summary is printed at the end. The script exits with a non-zero status if any file failed

## Directory structure

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

## Exit codes

| Code | Meaning |
|---|---|
| `0` | All queued files downloaded and verified successfully |
| `1` | One or more files failed to download or failed verification |

## Licence

MIT
