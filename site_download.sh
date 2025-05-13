#!/bin/bash
# site_download.sh - Parallelized download of Neocities sites

if [ $# -lt 1 ]; then
    echo "Usage: $0 <neocities_username>"
    echo "Example: $0 toribytez"
    exit 1
fi

USERNAME="$1"
OUTPUT_DIR=~/SPOON_GIT/neocities_sites/$USERNAME
THREADS=8

# Create output directory
mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"

# First, get the list of URLs to download
wget -q -O- "https://${USERNAME}.neocities.org/sitemap.xml" 2>/dev/null | grep -oP '(?<=<loc>)[^<]+' >urls.txt
if [ ! -s urls.txt ]; then
    # If no sitemap, do an initial crawl to find links
    wget -q --spider --force-html -r -l 2 "https://${USERNAME}.neocities.org/" 2>&1 |
        grep '^--' | grep -v '\.\(css\|js\|png\|jpg\|gif\)' |
        awk '{print $3}' | grep -E "^https://${USERNAME}.neocities.org/" >urls.txt
fi

# If still no URLs found, fall back to basic mirroring
if [ ! -s urls.txt ]; then
    echo "No URL list could be generated. Falling back to standard wget mirror..."
    wget --mirror \
        --page-requisites \
        --convert-links \
        --adjust-extension \
        --no-parent \
        --execute robots=off \
        --wait=0.5 \
        --random-wait \
        --user-agent="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36" \
        "https://${USERNAME}.neocities.org/"
    echo "Download complete. Site saved to $OUTPUT_DIR"
    exit 0
fi

# Define download function
download_url() {
    wget --page-requisites \
        --convert-links \
        --adjust-extension \
        --no-parent \
        --execute robots=off \
        --random-wait \
        --user-agent="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36" \
        --directory-prefix="$OUTPUT_DIR" \
        --no-directories \
        --no-host-directories \
        "$1"
    sleep 0.2
}
export -f download_url
export OUTPUT_DIR

# Download in parallel
echo "Downloading https://${USERNAME}.neocities.org/ with $THREADS parallel threads"
cat urls.txt | parallel --jobs $THREADS download_url

# Final pass to catch anything missed and fix structure
wget --mirror \
    --page-requisites \
    --convert-links \
    --adjust-extension \
    --no-parent \
    --execute robots=off \
    --wait=0.5 \
    --random-wait \
    --user-agent="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36" \
    --directory-prefix="$OUTPUT_DIR" \
    -X "*\.(jpg|jpeg|png|gif|css|js)" \
    -N \
    "https://${USERNAME}.neocities.org/"

echo "Download complete. Site saved to $OUTPUT_DIR"
