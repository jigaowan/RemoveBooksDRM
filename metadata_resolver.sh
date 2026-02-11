#!/bin/bash

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <original_book_dir> <decrypted_book_dir>" >&2
    exit 1
fi

ORIGINAL_BOOK_DIR="$1"
DECRYPTED_BOOK_DIR="$2"

extract_opf_path() {
    local book_dir="$1"
    local container_xml="$book_dir/META-INF/container.xml"

    if [ ! -f "$container_xml" ]; then
        echo "Missing container.xml: $container_xml" >&2
        return 1
    fi

    local rel_path
    rel_path=$(grep -o 'full-path="[^"]*"' "$container_xml" | head -n1 | cut -d'"' -f2)
    if [ -z "$rel_path" ]; then
        echo "Failed to read OPF path from container.xml: $container_xml" >&2
        return 1
    fi

    echo "$book_dir/$rel_path"
}

extract_dc_value() {
    local opf_path="$1"
    local tag="$2"
    DC_TAG="$tag" perl -0777 -ne '
        my $tag = $ENV{"DC_TAG"};
        if ($_ =~ m#<dc:$tag\b[^>]*>(.*?)</dc:$tag>#s) {
            my $value = $1;
            $value =~ s/<[^>]+>//g;
            $value =~ s/^\s+|\s+$//g;
            print $value;
        }
    ' "$opf_path"
}

extract_opf_meta_property() {
    local opf_path="$1"
    local prop="$2"
    OPF_PROP="$prop" perl -0777 -ne '
        my $prop = $ENV{"OPF_PROP"};
        if ($_ =~ m#<meta\b[^>]*\bproperty="\Q$prop\E"[^>]*>(.*?)</meta>#s) {
            my $value = $1;
            $value =~ s/<[^>]+>//g;
            $value =~ s/^\s+|\s+$//g;
            print $value;
        }
    ' "$opf_path"
}

extract_opf_meta_name() {
    local opf_path="$1"
    local name="$2"
    OPF_NAME="$name" perl -0777 -ne '
        my $name = $ENV{"OPF_NAME"};
        if ($_ =~ m#<meta\b[^>]*\bname="\Q$name\E"[^>]*\bcontent="([^"]*)"#s) {
            print $1;
        }
    ' "$opf_path"
}

extract_spine_attr() {
    local opf_path="$1"
    local attr="$2"
    SPINE_ATTR="$attr" perl -0777 -ne '
        my $attr = $ENV{"SPINE_ATTR"};
        if ($_ =~ m#<spine\b[^>]*\b\Q$attr\E="([^"]*)"#s) {
            print $1;
        }
    ' "$opf_path"
}

count_opf_itemrefs() {
    local opf_path="$1"
    perl -0777 -ne '
        my $count = () = /<itemref\b/g;
        print $count;
    ' "$opf_path"
}

extract_itunes_value() {
    local plist_path="$1"
    local key="$2"
    plutil -extract "$key" raw -o - "$plist_path" 2>/dev/null || true
}

xml_escape() {
    local raw="$1"
    printf '%s' "$raw" \
        | sed -e 's/&/\&amp;/g' \
              -e 's/</\&lt;/g' \
              -e 's/>/\&gt;/g' \
              -e 's/"/\&quot;/g' \
              -e "s/'/\&apos;/g"
}

html_to_plain_text() {
    local raw="$1"
    printf '%s' "$raw" | perl -0777 -pe '
        s/<br\s*\/?>/\n/ig;
        s#</p>#\n#ig;
        s#<p\b[^>]*>#\n#ig;
        s/<[^>]+>//g;
        s/&nbsp;/ /g;
        s/&amp;/&/g;
        s/&lt;/</g;
        s/&gt;/>/g;
        s/&quot;/"/g;
        s/&#39;/'"'"'/g;
        s/&#x27;/'"'"'/ig;
        s/\r//g;
        s/[ \t]+\n/\n/g;
        s/\n{3,}/\n\n/g;
        s/^[ \t\n]+//;
        s/[ \t\n]+$//;
    '
}

ORIGINAL_ITUNES_PLIST="$ORIGINAL_BOOK_DIR/iTunesMetadata.plist"
if [ ! -f "$ORIGINAL_ITUNES_PLIST" ]; then
    echo "Missing iTunesMetadata.plist: $ORIGINAL_ITUNES_PLIST" >&2
    exit 1
fi

ORIGINAL_OPF_PATH=$(extract_opf_path "$ORIGINAL_BOOK_DIR")
DECRYPTED_OPF_PATH=$(extract_opf_path "$DECRYPTED_BOOK_DIR")

if [ ! -f "$ORIGINAL_OPF_PATH" ]; then
    echo "Missing original OPF: $ORIGINAL_OPF_PATH" >&2
    exit 1
fi
if [ ! -f "$DECRYPTED_OPF_PATH" ]; then
    echo "Missing decrypted OPF: $DECRYPTED_OPF_PATH" >&2
    exit 1
fi

ITUNES_TITLE=$(extract_itunes_value "$ORIGINAL_ITUNES_PLIST" "itemName")
ITUNES_AUTHOR=$(extract_itunes_value "$ORIGINAL_ITUNES_PLIST" "artistName")

EPUB_TITLE=$(extract_dc_value "$ORIGINAL_OPF_PATH" "title")
EPUB_AUTHOR=$(extract_dc_value "$ORIGINAL_OPF_PATH" "creator")
ITUNES_PUBLISHER=$(extract_itunes_value "$ORIGINAL_ITUNES_PLIST" "publisher")
EPUB_PUBLISHER=$(extract_dc_value "$ORIGINAL_OPF_PATH" "publisher")

ITUNES_LANGUAGE=$(extract_itunes_value "$ORIGINAL_ITUNES_PLIST" "primaryLanguage")
EPUB_LANGUAGE=$(extract_dc_value "$ORIGINAL_OPF_PATH" "language")

ITUNES_IDENTIFIER=$(extract_itunes_value "$ORIGINAL_ITUNES_PLIST" "book-info.publisher-unique-id")
EPUB_IDENTIFIER=$(extract_dc_value "$ORIGINAL_OPF_PATH" "identifier")

ITUNES_PAGE_PROGRESSION=$(extract_itunes_value "$ORIGINAL_ITUNES_PLIST" "book-info.page-progression-direction")
if [ -z "${ITUNES_PAGE_PROGRESSION:-}" ]; then
    ITUNES_PAGE_PROGRESSION=$(extract_itunes_value "$ORIGINAL_ITUNES_PLIST" "book-info.PageProgression")
fi
EPUB_PAGE_PROGRESSION=$(extract_spine_attr "$ORIGINAL_OPF_PATH" "page-progression-direction")

ITUNES_RELEASE_DATE=$(extract_itunes_value "$ORIGINAL_ITUNES_PLIST" "releaseDate")
EPUB_MODIFIED_DATE=$(extract_opf_meta_property "$ORIGINAL_OPF_PATH" "dcterms:modified")

ITUNES_ISBN=$(extract_itunes_value "$ORIGINAL_ITUNES_PLIST" "isbn")
ITUNES_GENRE=$(extract_itunes_value "$ORIGINAL_ITUNES_PLIST" "genre")
ITUNES_PAGE_COUNT=$(extract_itunes_value "$ORIGINAL_ITUNES_PLIST" "pageCount")
ITUNES_DESCRIPTION_RAW=$(extract_itunes_value "$ORIGINAL_ITUNES_PLIST" "longDescription")
ITUNES_DESCRIPTION=$(html_to_plain_text "${ITUNES_DESCRIPTION_RAW:-}")

EPUB_LAYOUT=$(extract_opf_meta_property "$ORIGINAL_OPF_PATH" "rendition:layout")
EPUB_SPREAD=$(extract_opf_meta_property "$ORIGINAL_OPF_PATH" "rendition:spread")
EPUB_PRIMARY_WRITING_MODE=$(extract_opf_meta_name "$ORIGINAL_OPF_PATH" "primary-writing-mode")
EPUB_BOOK_TYPE=$(extract_opf_meta_name "$ORIGINAL_OPF_PATH" "book-type")
EPUB_PAGE_COUNT=$(count_opf_itemrefs "$ORIGINAL_OPF_PATH")
EPUB_DESCRIPTION=$(extract_dc_value "$ORIGINAL_OPF_PATH" "description")

echo
echo "Metadata comparison:"
echo "  iTunes title : ${ITUNES_TITLE:-<empty>}"
echo "  EPUB   title : ${EPUB_TITLE:-<empty>}"
echo "  iTunes author: ${ITUNES_AUTHOR:-<empty>}"
echo "  EPUB   author: ${EPUB_AUTHOR:-<empty>}"
echo

DIFF_COUNT=0
DIFF_LINES=()

add_diff() {
    local field="$1"
    local itunes_value="${2:-}"
    local epub_value="${3:-}"
    if [ "$itunes_value" != "$epub_value" ]; then
        DIFF_COUNT=$((DIFF_COUNT + 1))
        DIFF_LINES+=("$field | iTunes: ${itunes_value:-<empty>} | EPUB: ${epub_value:-<empty>}")
    fi
}

add_diff "title" "$ITUNES_TITLE" "$EPUB_TITLE"
add_diff "author" "$ITUNES_AUTHOR" "$EPUB_AUTHOR"
add_diff "publisher" "$ITUNES_PUBLISHER" "$EPUB_PUBLISHER"
add_diff "language" "$ITUNES_LANGUAGE" "$EPUB_LANGUAGE"
add_diff "identifier" "$ITUNES_IDENTIFIER" "$EPUB_IDENTIFIER"
add_diff "page-progression-direction" "$ITUNES_PAGE_PROGRESSION" "$EPUB_PAGE_PROGRESSION"
add_diff "date (iTunes release vs OPF modified)" "$ITUNES_RELEASE_DATE" "$EPUB_MODIFIED_DATE"
add_diff "page-count (iTunes vs OPF itemref count)" "$ITUNES_PAGE_COUNT" "$EPUB_PAGE_COUNT"
add_diff "description (iTunes longDescription vs OPF dc:description)" "$ITUNES_DESCRIPTION" "$EPUB_DESCRIPTION"

echo "Major metadata snapshot:"
echo "  iTunes isbn: ${ITUNES_ISBN:-<empty>}"
echo "  iTunes genre: ${ITUNES_GENRE:-<empty>}"
echo "  EPUB layout: ${EPUB_LAYOUT:-<empty>}"
echo "  EPUB spread: ${EPUB_SPREAD:-<empty>}"
echo "  EPUB writing-mode: ${EPUB_PRIMARY_WRITING_MODE:-<empty>}"
echo "  EPUB book-type: ${EPUB_BOOK_TYPE:-<empty>}"

if [ "$DIFF_COUNT" -gt 0 ]; then
    echo
    echo "Different major metadata fields:"
    for line in "${DIFF_LINES[@]}"; do
        echo "  - $line"
    done
fi

if [ "$DIFF_COUNT" -eq 0 ]; then
    echo "No differences found in major comparable metadata. Defaulting to EPUB metadata."
    CHOICE="epub"
else
    echo
    echo "Choose metadata source for final decrypted EPUB:"
    echo "1) itunes"
    echo "2) epub"
    while true; do
        read -r -p "Selection [1/2]: " user_choice
        case "$user_choice" in
            1) CHOICE="itunes"; break ;;
            2) CHOICE="epub"; break ;;
            *) echo "Invalid selection. Enter 1 or 2." ;;
        esac
    done
fi

if [ "$CHOICE" = "itunes" ]; then
    ESCAPED_TITLE=$(xml_escape "${ITUNES_TITLE:-}")
    ESCAPED_AUTHOR=$(xml_escape "${ITUNES_AUTHOR:-}")
    ESCAPED_PUBLISHER=$(xml_escape "${ITUNES_PUBLISHER:-}")
    ESCAPED_LANGUAGE=$(xml_escape "${ITUNES_LANGUAGE:-}")
    ESCAPED_IDENTIFIER=$(xml_escape "${ITUNES_IDENTIFIER:-}")
    ESCAPED_RELEASE_DATE=$(xml_escape "${ITUNES_RELEASE_DATE:-}")
    ESCAPED_PAGE_PROGRESSION=$(xml_escape "${ITUNES_PAGE_PROGRESSION:-}")
    ESCAPED_DESCRIPTION=$(xml_escape "${ITUNES_DESCRIPTION:-}")

    TITLE="$ESCAPED_TITLE" AUTHOR="$ESCAPED_AUTHOR" PUBLISHER="$ESCAPED_PUBLISHER" \
    LANGUAGE="$ESCAPED_LANGUAGE" IDENTIFIER="$ESCAPED_IDENTIFIER" RELEASE_DATE="$ESCAPED_RELEASE_DATE" \
    PAGE_PROGRESSION="$ESCAPED_PAGE_PROGRESSION" DESCRIPTION="$ESCAPED_DESCRIPTION" \
    perl -0777 -i -pe '
        my $title = $ENV{"TITLE"};
        my $author = $ENV{"AUTHOR"};
        my $publisher = $ENV{"PUBLISHER"};
        my $language = $ENV{"LANGUAGE"};
        my $identifier = $ENV{"IDENTIFIER"};
        my $release_date = $ENV{"RELEASE_DATE"};
        my $page_progression = $ENV{"PAGE_PROGRESSION"};
        my $description = $ENV{"DESCRIPTION"};
        s#(<dc:title\b[^>]*>).*?(</dc:title>)#$1$title$2#s;
        s#(<dc:creator\b[^>]*>).*?(</dc:creator>)#$1$author$2#s;
        if (length($publisher) > 0) {
            s#(<dc:publisher\b[^>]*>).*?(</dc:publisher>)#$1$publisher$2#s;
        }
        if (length($language) > 0) {
            s#(<dc:language\b[^>]*>).*?(</dc:language>)#$1$language$2#s;
        }
        if (length($identifier) > 0) {
            s#(<dc:identifier\b[^>]*>).*?(</dc:identifier>)#$1$identifier$2#s;
        }
        if (length($release_date) > 0) {
            s#(<meta\b[^>]*\bproperty="dcterms:modified"[^>]*>).*?(</meta>)#$1$release_date$2#s;
        }
        if (length($page_progression) > 0) {
            if (/<spine\b[^>]*\bpage-progression-direction="/s) {
                s#(<spine\b[^>]*\bpage-progression-direction=")[^"]*(")#$1$page_progression$2#s;
            } else {
                s#<spine\b([^>]*)>#<spine page-progression-direction="$page_progression"$1>#s;
            }
        }
        if (length($description) > 0) {
            if (/<dc:description\b/s) {
                s#(<dc:description\b[^>]*>).*?(</dc:description>)#$1$description$2#s;
            } else {
                s#</metadata>#<dc:description>$description</dc:description>\n\n</metadata>#s;
            }
        }
    ' "$DECRYPTED_OPF_PATH"
    echo "Applied iTunes metadata to decrypted OPF."
else
    echo "Kept EPUB metadata from OPF."
fi

FINAL_METADATA_FILE="$DECRYPTED_BOOK_DIR/final.metadata.opf"
cp "$DECRYPTED_OPF_PATH" "$FINAL_METADATA_FILE"
echo "Final metadata file generated: $FINAL_METADATA_FILE"
