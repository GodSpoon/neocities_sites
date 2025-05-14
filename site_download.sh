#!/bin/bash
# site_download.sh - High-performance parallel download of Neocities sites

set -e # Exit on any error

if [ $# -lt 1 ]; then
    echo "Usage: $0 <neocities_username>"
    echo "Example: $0 toribytez"
    exit 1
fi

# Configuration
USERNAME="$1"
OUTPUT_DIR=~/SPOON_GIT/neocities_sites/$USERNAME
# Dynamically set thread count based on CPU cores (with a reasonable max)
THREADS=$(($(nproc) > 16 ? 16 : $(nproc)))
# Use more connections per server but avoid being blocked
MAX_CONNECTIONS=10
# User agent
USER_AGENT="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/112.0.0.0 Safari/537.36"
# Temp directory for processing
TEMP_DIR=$(mktemp -d)

# Clean up temp files on exit
trap 'rm -rf "$TEMP_DIR"; exit' INT TERM EXIT

echo "Starting download with $THREADS threads and $MAX_CONNECTIONS connections per server"

# Create output directory
mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR" || {
    echo "Failed to change to output directory"
    exit 1
}

# Check for aria2c (much faster than wget for parallel downloads)
if command -v aria2c >/dev/null 2>&1; then
    USE_ARIA2=true
    echo "Using aria2c for faster downloads"
else
    USE_ARIA2=false
    echo "aria2c not found, using wget (consider installing aria2c for faster downloads)"
fi

# Function to get URLs using multiple methods for comprehensive results
get_urls() {
    echo "Discovering site structure..."

    # Try sitemap.xml first (faster and more reliable)
    curl -s "https://${USERNAME}.neocities.org/sitemap.xml" >"$TEMP_DIR/sitemap.xml"
    if [ -s "$TEMP_DIR/sitemap.xml" ]; then
        echo "Found sitemap.xml"
        grep -oP '(?<=<loc>)[^<]+' "$TEMP_DIR/sitemap.xml" >"$TEMP_DIR/sitemap_urls.txt"
    fi

    # Get the homepage and parse for links
    curl -s "https://${USERNAME}.neocities.org/" >"$TEMP_DIR/index.html"
    if [ -s "$TEMP_DIR/index.html" ]; then
        grep -oP 'href="\K[^"]+' "$TEMP_DIR/index.html" |
            grep -v "^http" |
            grep -v "^#" |
            sed "s|^/|https://${USERNAME}.neocities.org/|" |
            sed "s|^|https://${USERNAME}.neocities.org/|" >"$TEMP_DIR/index_urls.txt"
    fi

    # Also do a quick crawl to find additional links (depth of 3 instead of 2)
    wget -q --spider --force-html -r -l 3 "https://${USERNAME}.neocities.org/" 2>&1 |
        grep '^--' |
        awk '{print $3}' |
        grep -E "^https://${USERNAME}.neocities.org/" >"$TEMP_DIR/crawled_urls.txt"

    # Combine and deduplicate URLs
    cat "$TEMP_DIR/sitemap_urls.txt" "$TEMP_DIR/index_urls.txt" "$TEMP_DIR/crawled_urls.txt" 2>/dev/null |
        sort | uniq >"$TEMP_DIR/all_urls.txt"

    # Split into pages and assets for optimized downloading
    grep -v "\.(jpg|jpeg|png|gif|css|js)$" "$TEMP_DIR/all_urls.txt" 2>/dev/null >"$TEMP_DIR/page_urls.txt"
    grep "\.(jpg|jpeg|png|gif|css|js)$" "$TEMP_DIR/all_urls.txt" 2>/dev/null >"$TEMP_DIR/asset_urls.txt"

    # If still no URLs found, generate a basic URL list
    if [ ! -s "$TEMP_DIR/page_urls.txt" ]; then
        echo "https://${USERNAME}.neocities.org/" >"$TEMP_DIR/page_urls.txt"
        echo "https://${USERNAME}.neocities.org/index.html" >>"$TEMP_DIR/page_urls.txt"
    fi

    echo "Found $(wc -l <"$TEMP_DIR/page_urls.txt" 2>/dev/null || echo 0) pages and $(wc -l <"$TEMP_DIR/asset_urls.txt" 2>/dev/null || echo 0) assets to download."
}

# Create aria2 input file with optimized settings for bulk downloads
create_aria2_input() {
    local url_file="$1"
    local output_file="$2"

    while IFS= read -r url; do
        echo "$url"
        echo "  dir=$OUTPUT_DIR"
        echo "  out=$(basename "$url")"
        echo "  max-connection-per-server=$MAX_CONNECTIONS"
        echo "  split=10"
        echo "  min-split-size=1M"
        echo "  user-agent=$USER_AGENT"
        echo "  enable-http-pipelining=true"
        echo "  retry-wait=1"
        echo "  max-tries=5"
        echo "  timeout=30"
        echo "  connect-timeout=10"
        echo
    done <"$url_file" >"$output_file"
}

# Download function using aria2 if available, otherwise wget
download_with_aria2() {
    local url_file="$1"
    create_aria2_input "$url_file" "$TEMP_DIR/aria2_input.txt"

    aria2c --input-file="$TEMP_DIR/aria2_input.txt" \
        --max-concurrent-downloads=$THREADS \
        --file-allocation=none \
        --auto-file-renaming=true \
        --allow-overwrite=true \
        --continue=true \
        --disable-ipv6 \
        --http-accept-gzip=true \
        --download-result=full \
        --summary-interval=5 \
        --enable-http2=true
}

download_url() {
    local url="$1"
    local output_file="$(basename "$url")"

    if $USE_ARIA2; then
        aria2c "$url" \
            --dir="$OUTPUT_DIR" \
            --out="$output_file" \
            --max-connection-per-server="$MAX_CONNECTIONS" \
            --split=10 \
            --min-split-size=1M \
            --file-allocation=none \
            --user-agent="$USER_AGENT" \
            --retry-wait=1 \
            --http-accept-gzip=true \
            --enable-http2=true \
            --quiet
    else
        wget --page-requisites \
            --convert-links \
            --adjust-extension \
            --no-parent \
            --execute robots=off \
            --user-agent="$USER_AGENT" \
            --directory-prefix="$OUTPUT_DIR" \
            --no-directories \
            --no-host-directories \
            --timeout=15 \
            --tries=3 \
            --no-verbose \
            "$url"
    fi
}
export -f download_url
export USE_ARIA2
export OUTPUT_DIR
export USER_AGENT
export MAX_CONNECTIONS

# Get the list of URLs to download
get_urls

# Download pages in parallel
echo "Downloading pages from https://${USERNAME}.neocities.org/ with $THREADS parallel threads"

if $USE_ARIA2 && [ -s "$TEMP_DIR/page_urls.txt" ] && [ "$(wc -l <"$TEMP_DIR/page_urls.txt")" -gt 5 ]; then
    # For many URLs, aria2c can handle them all at once
    download_with_aria2 "$TEMP_DIR/page_urls.txt"
else
    # Use parallel with wget or for smaller URL sets
    if [ -s "$TEMP_DIR/page_urls.txt" ]; then
        cat "$TEMP_DIR/page_urls.txt" | parallel --jobs $THREADS --bar download_url
    fi
fi

# Download assets in parallel
if [ -s "$TEMP_DIR/asset_urls.txt" ]; then
    echo "Downloading assets (images, CSS, JS)..."
    if $USE_ARIA2; then
        download_with_aria2 "$TEMP_DIR/asset_urls.txt"
    else
        cat "$TEMP_DIR/asset_urls.txt" | parallel --jobs $THREADS --bar download_url
    fi
fi

# Parse downloaded HTML to find additional assets
echo "Checking for additional assets in downloaded pages..."
find "$OUTPUT_DIR" -type f -name "*.html" -o -name "*.htm" >"$TEMP_DIR/html_files.txt"

if [ -s "$TEMP_DIR/html_files.txt" ]; then
    # Extract URLs from HTML files
    cat "$TEMP_DIR/html_files.txt" | xargs grep -o 'href="[^"]*\.\(css\|js\)' 2>/dev/null | cut -d'"' -f2 |
        grep -v '^http' | sed "s|^|https://${USERNAME}.neocities.org/|" >"$TEMP_DIR/css_js_urls.txt"
    cat "$TEMP_DIR/html_files.txt" | xargs grep -o 'src="[^"]*\.\(jpg\|jpeg\|png\|gif\|js\)' 2>/dev/null | cut -d'"' -f2 |
        grep -v '^http' | sed "s|^|https://${USERNAME}.neocities.org/|" >>"$TEMP_DIR/more_asset_urls.txt"

    # Identify assets we haven't downloaded yet
    cat "$TEMP_DIR/css_js_urls.txt" "$TEMP_DIR/more_asset_urls.txt" 2>/dev/null |
        sort | uniq >"$TEMP_DIR/new_asset_urls.txt"

    if [ -s "$TEMP_DIR/new_asset_urls.txt" ] && [ -s "$TEMP_DIR/asset_urls.txt" ]; then
        comm -23 <(sort "$TEMP_DIR/new_asset_urls.txt") <(sort "$TEMP_DIR/asset_urls.txt") >"$TEMP_DIR/missing_assets.txt"
    elif [ -s "$TEMP_DIR/new_asset_urls.txt" ]; then
        cp "$TEMP_DIR/new_asset_urls.txt" "$TEMP_DIR/missing_assets.txt"
    fi

    # Download missing assets in parallel
    if [ -s "$TEMP_DIR/missing_assets.txt" ]; then
        echo "Downloading $(wc -l <"$TEMP_DIR/missing_assets.txt") additional assets found in HTML..."
        if $USE_ARIA2; then
            download_with_aria2 "$TEMP_DIR/missing_assets.txt"
        else
            cat "$TEMP_DIR/missing_assets.txt" | parallel --jobs $THREADS --bar download_url
        fi
    fi
fi

# Much faster final check instead of the original slow wget mirror approach
echo "Performing quick final check for missing files..."
curl -s -o "$TEMP_DIR/final_index.html" "https://${USERNAME}.neocities.org/"

if [ -s "$TEMP_DIR/final_index.html" ]; then
    grep -oP 'href="\K[^"]*' "$TEMP_DIR/final_index.html" |
        grep -v "^http" | grep -v "^#" |
        sed "s|^|https://${USERNAME}.neocities.org/|" >"$TEMP_DIR/final_check_urls.txt"

    for url in $(cat "$TEMP_DIR/final_check_urls.txt" 2>/dev/null); do
        filename=$(basename "$url")
        if [ ! -f "$OUTPUT_DIR/$filename" ]; then
            echo "Downloading missing file: $filename"
            download_url "$url"
        fi
    done
fi

echo "Download complete. Site saved to $OUTPUT_DIR"
echo "Total files: $(find "$OUTPUT_DIR" -type f | wc -l)"
echo "Total size: $(du -sh "$OUTPUT_DIR" | awk '{print $1}')"
