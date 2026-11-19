
#!/usr/bin/env bash
set -Eeuo pipefail

ONE_PER_VIDEO=0
SKIP_EXISTING_VARIANT=0
PREFER="mp4,mkv,m4v,webm,mov,avi,mpeg,mpg,wmv,flv,ts,ogv,3gp"

usage() {
    cat <<'EOF'
Usage:
  archive-video-download.sh [OPTIONS] URL OUTPUT_DIR

Options:
  --one-per-video           Select one format per video
  --prefer EXT,EXT          Preferred formats, in order
  --skip-existing-variant   Don't download if another local
                            video format already exists
  -h, --help                Show this help

Examples:
  archive-video-download.sh \
    --one-per-video \
    --prefer mp4,mkv \
    --skip-existing-variant \
    "https://archive.org/details/example" \
    "/mnt/media/movies"
EOF
}

POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --one-per-video)
            ONE_PER_VIDEO=1
            shift
            ;;
        --skip-existing-variant)
            SKIP_EXISTING_VARIANT=1
            shift
            ;;
        --prefer)
            [[ $# -ge 2 ]] || {
                echo "ERROR: --prefer requires a value" >&2
                exit 1
            }
            PREFER="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

if [[ ${#POSITIONAL[@]} -ne 2 ]]; then
    usage
    exit 1
fi

for cmd in python3 curl wget; do
    command -v "$cmd" >/dev/null || {
        echo "Missing dependency: $cmd" >&2
        exit 1
    }
done

ARCHIVE_URL="${POSITIONAL[0]}"
OUTPUT_DIR="${POSITIONAL[1]}"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Parse and validate identifier
IDENTIFIER="$(python3 - "$ARCHIVE_URL" <<'PY'
import sys
from urllib.parse import urlparse, unquote

value = sys.argv[1].strip()

if "://" not in value:
    ident = value
else:
    parsed = urlparse(value)

    if parsed.scheme not in ("http", "https"):
        sys.exit("Invalid URL scheme")

    if parsed.hostname not in ("archive.org", "www.archive.org"):
        sys.exit("Not an Internet Archive URL")

    parts = parsed.path.strip("/").split("/")

    if len(parts) < 2 or parts[0] not in ("details", "download"):
        sys.exit("Expected an Archive.org item URL")

    ident = unquote(parts[1])

if not ident or "/" in ident or ident in (".", ".."):
    sys.exit("Invalid identifier")

print(ident)
PY
)"

ENCODED_ID="$(python3 - "$IDENTIFIER" <<'PY'
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe=""))
PY
)"

echo "======================================"
echo " Internet Archive Video Downloader"
echo "======================================"
echo "Item:          $IDENTIFIER"
echo "Output:        $OUTPUT_DIR"
echo "One per video: $ONE_PER_VIDEO"
echo "Skip variants: $SKIP_EXISTING_VARIANT"
echo "Preferences:   $PREFER"
echo

echo "[INFO] Fetching metadata..."

curl -fLsS \
    --retry 5 \
    --connect-timeout 20 \
    "https://archive.org/metadata/$ENCODED_ID" \
    -o "$TMP_DIR/metadata.json"

cat > "$TMP_DIR/manifest.py" <<'PY'
import json
import sys
import os
import re
from pathlib import Path, PurePosixPath
from urllib.parse import quote
from collections import defaultdict

(
    metadata_file,
    identifier,
    output_dir,
    one_per_video,
    skip_existing,
    preferred,
    multi_count_file
) = sys.argv[1:]

one_per_video = one_per_video == "1"
skip_existing = skip_existing == "1"

extensions = {
    ".mp4", ".mkv", ".avi", ".mov",
    ".webm", ".m4v", ".mpeg", ".mpg",
    ".wmv", ".flv", ".ts", ".ogv", ".3gp"
}

preferred = [
    "." + x.strip().lower().lstrip(".")
    for x in preferred.split(",")
    if x.strip()
]

if not preferred or any(x not in extensions for x in preferred):
    sys.exit("Invalid --prefer extension list")

with open(metadata_file, encoding="utf-8") as fh:
    metadata = json.load(fh)

if metadata.get("is_dark") or metadata.get("is_dark_item"):
    sys.exit("Archive item is restricted or unavailable")

# Common Internet Archive derivative suffixes.
# Only remove suffixes that strongly indicate
# transcoded versions of the same source video.
derivative_suffixes = (
    "_512kb",
    "_256kb",
    "_h264",
    "_h265",
    "_x264",
    "_x265"
)

def normalise_stem(stem):
    s = stem.casefold()

    changed = True
    while changed:
        changed = False
        for suffix in derivative_suffixes:
            if s.endswith(suffix):
                s = s[:-len(suffix)]
                changed = True
                break

    return s

def identity(name):
    path = PurePosixPath(name)
    return (
        str(path.parent).casefold(),
        normalise_stem(path.stem)
    )

def preference(entry):
    name = entry["name"]
    extension = PurePosixPath(name).suffix.lower()

    try:
        priority = preferred.index(extension)
    except ValueError:
        priority = len(preferred) + 1

    source_priority = (
        0 if entry.get("source") == "original" else 1
    )

    try:
        size = int(entry.get("size", 0))
    except (TypeError, ValueError):
        size = 0

    # Format priority first, original source second,
    # then larger file as final tie-breaker.
    return (priority, source_priority, -size, name)

files = []

for entry in metadata.get("files", []):
    name = entry.get("name", "")

    if not name or not isinstance(name, str):
        continue

    parts = name.split("/")

    # Prevent path traversal or unsafe local paths.
    if (
        name.startswith("/")
        or "\\" in name
        or any(p in ("", ".", "..") for p in parts)
    ):
        continue

    extension = PurePosixPath(name).suffix.lower()

    if extension not in extensions:
        continue

    # .ia, XML, torrent, metadata etc. are excluded.
    files.append(entry)

print(f"[INFO] Video files found: {len(files)}", file=sys.stderr)

# Always build groups so we can report multi-format videos.
groups = defaultdict(list)
for entry in files:
    groups[identity(entry["name"])].append(entry)

multi_groups = sum(1 for g in groups.values() if len(g) > 1)

with open(multi_count_file, "w") as fh:
    fh.write(str(multi_groups))

# Pick only one file from each matching group.
if one_per_video:
    selected = [
        min(group, key=preference)
        for group in groups.values()
    ]
else:
    selected = files

selected.sort(key=lambda x: x["name"].casefold())

print(
    f"[INFO] Selected video files: {len(selected)}",
    file=sys.stderr
)

# Check local files for existing alternative formats.
# Limit checks to directories containing selected files.
existing = defaultdict(list)

if skip_existing:
    directories = {
        str(PurePosixPath(e["name"]).parent)
        for e in selected
    }

    for rel_dir in directories:
        local_dir = os.path.join(output_dir, rel_dir)

        if not os.path.isdir(local_dir):
            continue

        for filename in os.listdir(local_dir):
            local_path = os.path.join(local_dir, filename)

            if not os.path.isfile(local_path):
                continue

            if Path(filename).suffix.lower() not in extensions:
                continue

            if os.path.getsize(local_path) <= 0:
                continue

            relative = str(PurePosixPath(rel_dir) / filename)
            existing[identity(relative)].append(relative)

download_count = 0
skipped_count = 0

for entry in selected:
    name = entry["name"]
    key = identity(name)

    alternatives = [
        item for item in existing.get(key, [])
        if item.casefold() != name.casefold()
    ]

    if skip_existing and alternatives:
        print(
            f"[SKIP] {name} - existing variant: "
            f"{alternatives[0]}",
            file=sys.stderr
        )
        skipped_count += 1
        continue

    url = (
        "https://archive.org/download/"
        + identifier
        + "/"
        + quote(name, safe="/")
    )

    size = str(entry.get("size", ""))
    md5  = str(entry.get("md5",  ""))
    sha1 = str(entry.get("sha1", ""))

    for value in (url, name, size, md5, sha1):
        sys.stdout.buffer.write(
            value.encode("utf-8") + b"\0"
        )

    download_count += 1

print(
    f"[INFO] Queued: {download_count}, "
    f"existing variants skipped: {skipped_count}",
    file=sys.stderr
)
PY

build_manifest() {
    python3 "$TMP_DIR/manifest.py" \
        "$TMP_DIR/metadata.json" \
        "$ENCODED_ID" \
        "$OUTPUT_DIR" \
        "$ONE_PER_VIDEO" \
        "$SKIP_EXISTING_VARIANT" \
        "$PREFER" \
        "$TMP_DIR/multi_count" \
        > "$TMP_DIR/manifest.bin"
}

build_manifest

# If --one-per-video wasn't set and multiple formats exist, prompt.
if [[ "$ONE_PER_VIDEO" -eq 0 && -f "$TMP_DIR/multi_count" ]]; then
    MULTI_COUNT="$(cat "$TMP_DIR/multi_count")"

    if [[ "$MULTI_COUNT" =~ ^[0-9]+$ && "$MULTI_COUNT" -gt 0 ]]; then
        echo
        echo "[INFO] $MULTI_COUNT video(s) have multiple formats available."
        printf "       Enable --one-per-video to download only the preferred format? [y/N] "
        read -r REPLY </dev/tty

        if [[ "$REPLY" =~ ^[Yy]$ ]]; then
            ONE_PER_VIDEO=1
            echo "[INFO] One-per-video enabled (preference: $PREFER)"
            build_manifest
        fi
    fi
fi

TOTAL=0
SUCCESS=0
FAILED=0
SKIPPED=0

while IFS= read -r -d '' URL &&
      IFS= read -r -d '' NAME &&
      IFS= read -r -d '' SIZE &&
      IFS= read -r -d '' MD5 &&
      IFS= read -r -d '' SHA1; do

    ((TOTAL+=1))

    DEST="$OUTPUT_DIR/$NAME"
    mkdir -p "$(dirname "$DEST")"

    echo
    echo "[$TOTAL] $NAME"

    # Skip a complete, verified file of the same name.
    if [[ -f "$DEST" && "$SIZE" =~ ^[0-9]+$ ]]; then
        LOCAL_SIZE="$(stat -c %s "$DEST")"

        if [[ "$LOCAL_SIZE" -eq "$SIZE" ]]; then
            VERIFIED=0

            if [[ -n "$SHA1" ]] && command -v sha1sum >/dev/null 2>&1; then
                echo "$SHA1  $DEST" | sha1sum -c --status && VERIFIED=1
            elif [[ -n "$MD5" ]] && command -v md5sum >/dev/null 2>&1; then
                echo "$MD5  $DEST" | md5sum -c --status && VERIFIED=1
            else
                VERIFIED=1
            fi

            if [[ "$VERIFIED" -eq 1 ]]; then
                echo "[SKIP] Already downloaded (verified)"
                ((SKIPPED+=1))
                continue
            else
                echo "[INFO] Checksum mismatch, re-downloading"
            fi
        fi
    fi

    if wget \
        --continue \
        --tries=5 \
        --timeout=60 \
        --waitretry=5 \
        --progress=bar:force \
        --output-document="$DEST" \
        "$URL"; then

        PASS=1

        if [[ "$SIZE" =~ ^[0-9]+$ ]] &&
           [[ "$(stat -c %s "$DEST")" -ne "$SIZE" ]]; then
            echo "[ERROR] Size mismatch"
            PASS=0
        elif [[ -n "$SHA1" ]] && command -v sha1sum >/dev/null 2>&1; then
            echo "$SHA1  $DEST" | sha1sum -c --status || { echo "[ERROR] SHA1 mismatch"; PASS=0; }
        elif [[ -n "$MD5" ]] && command -v md5sum >/dev/null 2>&1; then
            echo "$MD5  $DEST" | md5sum -c --status || { echo "[ERROR] MD5 mismatch"; PASS=0; }
        fi

        if [[ "$PASS" -eq 1 ]]; then
            echo "[OK] Downloaded"
            ((SUCCESS+=1))
        else
            ((FAILED+=1))
        fi
    else
        echo "[ERROR] Download failed"
        ((FAILED+=1))
    fi

done < "$TMP_DIR/manifest.bin"

echo
echo "======================================"
echo " Download summary"
echo "======================================"
echo "Queued:             $TOTAL"
echo "Downloaded:         $SUCCESS"
echo "Already complete:   $SKIPPED"
echo "Failed:             $FAILED"
echo "Location:           $OUTPUT_DIR"

[[ "$FAILED" -eq 0 ]]
