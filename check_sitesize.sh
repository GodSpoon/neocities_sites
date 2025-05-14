#!/bin/bash
# check_sitesize.sh - Check total file count and size of a Neocities site without downloading

set -e # Exit on any error

if [ $# -lt 1 ]; then
    echo "Usage: $0 <neocities_username>"
    echo "Example: $0 toribytez"
    exit 1
fi

# Configuration
USERNAME="$1"
TEMP_DIR=$(mktemp -d)
USER_AGENT="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/112.0.0.0 Safari/537.36"
THREADS=$(($(nproc) > 8 ? 8 : $(nproc)))  # Reduced thread count to avoid overloading

# Clean up temp files on exit
trap 'rm -rf "$TEMP_DIR"; exit' INT TERM EXIT

echo "Analyzing Neocities site: $USERNAME"

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
    echo "Checking homepage..."
    curl -s "https://${USERNAME}.neocities.org/" >"$TEMP_DIR/index.html"
    if [ -s "$TEMP_DIR/index.html" ]; then
        grep -oP 'href="\K[^"]+' "$TEMP_DIR/index.html" |
            grep -v "^http" |
            grep -v "^#" |
            sed "s|^/|https://${USERNAME}.neocities.org/|" |
            sed "s|^|https://${USERNAME}.neocities.org/|" >"$TEMP_DIR/index_urls.txt"
    fi

    # Also do a quick crawl to find additional links (depth of 2 - reduced to speed up)
    echo "Crawling links (this may take a moment)..."
    wget -q --spider --force-html -r -l 2 "https://${USERNAME}.neocities.org/" 2>&1 |
        grep '^--' |
        awk '{print $3}' |
        grep -E "^https://${USERNAME}.neocities.org/" >"$TEMP_DIR/crawled_urls.txt"

    # Combine and deduplicate URLs
    echo "Processing URLs..."
    cat "$TEMP_DIR/sitemap_urls.txt" "$TEMP_DIR/index_urls.txt" "$TEMP_DIR/crawled_urls.txt" 2>/dev/null |
        sort | uniq >"$TEMP_DIR/all_urls.txt"

    # Count files
    total_urls=$(wc -l < "$TEMP_DIR/all_urls.txt" 2>/dev/null || echo 0)
    echo "Found $total_urls unique URLs"
}

# Function to calculate total size using curl with a timeout
calculate_size() {
    echo "Calculating site size (checking each file)..."
    
    local total_size=0
    local total_files=0
    local total_urls=$(wc -l < "$TEMP_DIR/all_urls.txt")
    local counter=0
    
    # Create a file to store sizes for reporting
    > "$TEMP_DIR/url_sizes.txt"
    
    # Process URLs in smaller batches to show progress
    while IFS= read -r url; do
        counter=$((counter + 1))
        
        # Show progress every 10 files
        if [ $((counter % 10)) -eq 0 ] || [ "$counter" -eq "$total_urls" ]; then
            echo -ne "Progress: $counter/$total_urls URLs processed ($(( (counter * 100) / total_urls ))%)\r"
        fi
        
        # Get file size with timeout to avoid hanging
        size=$(curl -sI -A "$USER_AGENT" --max-time 5 "$url" | grep -i Content-Length | awk '{print $2}' | tr -d '\r\n')
        
        # Handle empty content length
        if [ -z "$size" ]; then
            size=1024  # Default 1KB if size unknown
        fi
        
        total_size=$((total_size + size))
        total_files=$((total_files + 1))
        
        # Save for reporting
        echo "$url $size" >> "$TEMP_DIR/url_sizes.txt"
    done < "$TEMP_DIR/all_urls.txt"
    
    echo -e "\nTotal files: $total_files"
    
    # Format the size nicely
    if [ "$total_size" -ge 1073741824 ]; then
        echo "Total size: $(bc <<< "scale=2; $total_size / 1073741824") GB"
    elif [ "$total_size" -ge 1048576 ]; then
        echo "Total size: $(bc <<< "scale=2; $total_size / 1048576") MB"
    elif [ "$total_size" -ge 1024 ]; then
        echo "Total size: $(bc <<< "scale=2; $total_size / 1024") KB"
    else
        echo "Total size: $total_size bytes"
    fi
}

# Get URLs to analyze
get_urls

# If we found URLs, calculate their sizes
if [ -s "$TEMP_DIR/all_urls.txt" ]; then
    calculate_size
    
    # Show top 10 largest files
    echo ""
    echo "Top 10 largest files:"
    sort -k2 -nr "$TEMP_DIR/url_sizes.txt" | head -10 | while read -r url size; do
        if [ "$size" -ge 1048576 ]; then
            file_size="$(bc <<< "scale=2; $size / 1048576") MB"
        elif [ "$size" -ge 1024 ]; then
            file_size="$(bc <<< "scale=2; $size / 1024") KB"
        else
            file_size="$size bytes"
        fi
        echo "$(basename "$url") - $file_size"
    done
else
    echo "No URLs found for $USERNAME.neocities.org"
fi

# Clean exit
echo "Analysis complete"
