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

summarize_value() {
    local raw="${1:-}"
    local max_length="${2:-90}"
    MAX_LENGTH="$max_length" perl -CS -0777 -ne '
        my $max = $ENV{"MAX_LENGTH"} || 90;
        s/\s+/ /g;
        s/^\s+|\s+$//g;
        if (length($_) > $max) {
            $_ = substr($_, 0, $max - 3) . "...";
        }
        print length($_) ? $_ : "<empty>";
    ' <<< "$raw"
}

print_value_line() {
    local label="$1"
    local value="${2:-}"
    local max_length="${3:-90}"
    printf '    %-12s %s\n' "$label:" "$(summarize_value "$value" "$max_length")"
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

DECRYPTED_OPF_PATH=$(extract_opf_path "$DECRYPTED_BOOK_DIR")

if [ ! -f "$DECRYPTED_OPF_PATH" ]; then
    echo "Missing decrypted OPF: $DECRYPTED_OPF_PATH" >&2
    exit 1
fi

ITUNES_TITLE=$(extract_itunes_value "$ORIGINAL_ITUNES_PLIST" "itemName")
ITUNES_AUTHOR=$(extract_itunes_value "$ORIGINAL_ITUNES_PLIST" "artistName")
ITUNES_PUBLISHER=$(extract_itunes_value "$ORIGINAL_ITUNES_PLIST" "publisher")
ITUNES_DESCRIPTION_RAW=$(extract_itunes_value "$ORIGINAL_ITUNES_PLIST" "longDescription")
ITUNES_DESCRIPTION=$(html_to_plain_text "${ITUNES_DESCRIPTION_RAW:-}")

EPUB_TITLE=$(extract_dc_value "$DECRYPTED_OPF_PATH" "title")
EPUB_AUTHOR=$(extract_dc_value "$DECRYPTED_OPF_PATH" "creator")
EPUB_PUBLISHER=$(extract_dc_value "$DECRYPTED_OPF_PATH" "publisher")
EPUB_DESCRIPTION=$(extract_dc_value "$DECRYPTED_OPF_PATH" "description")

ITUNES_LANGUAGE=$(extract_itunes_value "$ORIGINAL_ITUNES_PLIST" "primaryLanguage")
EPUB_LANGUAGE=$(extract_dc_value "$DECRYPTED_OPF_PATH" "language")

ITUNES_IDENTIFIER=$(extract_itunes_value "$ORIGINAL_ITUNES_PLIST" "book-info.publisher-unique-id")
EPUB_IDENTIFIER=$(extract_dc_value "$DECRYPTED_OPF_PATH" "identifier")

ITUNES_PAGE_PROGRESSION=$(extract_itunes_value "$ORIGINAL_ITUNES_PLIST" "book-info.page-progression-direction")
if [ -z "${ITUNES_PAGE_PROGRESSION:-}" ]; then
    ITUNES_PAGE_PROGRESSION=$(extract_itunes_value "$ORIGINAL_ITUNES_PLIST" "book-info.PageProgression")
fi
EPUB_PAGE_PROGRESSION=$(extract_spine_attr "$DECRYPTED_OPF_PATH" "page-progression-direction")

ITUNES_RELEASE_DATE=$(extract_itunes_value "$ORIGINAL_ITUNES_PLIST" "releaseDate")
EPUB_MODIFIED_DATE=$(extract_opf_meta_property "$DECRYPTED_OPF_PATH" "dcterms:modified")

ITUNES_ISBN=$(extract_itunes_value "$ORIGINAL_ITUNES_PLIST" "isbn")
ITUNES_GENRE=$(extract_itunes_value "$ORIGINAL_ITUNES_PLIST" "genre")
ITUNES_PAGE_COUNT=$(extract_itunes_value "$ORIGINAL_ITUNES_PLIST" "pageCount")
EPUB_LAYOUT=$(extract_opf_meta_property "$DECRYPTED_OPF_PATH" "rendition:layout")
EPUB_SPREAD=$(extract_opf_meta_property "$DECRYPTED_OPF_PATH" "rendition:spread")
EPUB_PRIMARY_WRITING_MODE=$(extract_opf_meta_name "$DECRYPTED_OPF_PATH" "primary-writing-mode")
EPUB_BOOK_TYPE=$(extract_opf_meta_name "$DECRYPTED_OPF_PATH" "book-type")
EPUB_PAGE_COUNT=$(count_opf_itemrefs "$DECRYPTED_OPF_PATH")

MAIN_DIFF_COUNT=0

print_main_candidate() {
    local field="$1"
    local itunes_value="${2:-}"
    local epub_value="${3:-}"
    local status="same"
    if [ "$itunes_value" != "$epub_value" ]; then
        status="different"
        MAIN_DIFF_COUNT=$((MAIN_DIFF_COUNT + 1))
    fi

    echo "  - $field ($status)"
    print_value_line "iTunes" "$itunes_value"
    print_value_line "EPUB" "$epub_value"
}

NOTICE_LINES=()

add_notice_diff() {
    local field="$1"
    local itunes_value="${2:-}"
    local epub_value="${3:-}"
    if [ "$itunes_value" != "$epub_value" ]; then
        NOTICE_LINES+=("$field | iTunes: $(summarize_value "$itunes_value" 70) | EPUB: $(summarize_value "$epub_value" 70)")
    fi
}

add_notice_value() {
    local field="$1"
    local value="${2:-}"
    if [ -n "$value" ]; then
        NOTICE_LINES+=("$field | $(summarize_value "$value" 90)")
    fi
}

add_notice_diff "language" "$ITUNES_LANGUAGE" "$EPUB_LANGUAGE"
add_notice_diff "identifier" "$ITUNES_IDENTIFIER" "$EPUB_IDENTIFIER"
add_notice_diff "page-progression-direction" "$ITUNES_PAGE_PROGRESSION" "$EPUB_PAGE_PROGRESSION"
add_notice_diff "date (iTunes release vs OPF modified)" "$ITUNES_RELEASE_DATE" "$EPUB_MODIFIED_DATE"
add_notice_diff "page-count (iTunes vs OPF itemref count)" "$ITUNES_PAGE_COUNT" "$EPUB_PAGE_COUNT"
add_notice_value "iTunes isbn" "$ITUNES_ISBN"
add_notice_value "iTunes genre" "$ITUNES_GENRE"
add_notice_value "EPUB layout" "$EPUB_LAYOUT"
add_notice_value "EPUB spread" "$EPUB_SPREAD"
add_notice_value "EPUB writing-mode" "$EPUB_PRIMARY_WRITING_MODE"
add_notice_value "EPUB book-type" "$EPUB_BOOK_TYPE"

echo
echo "Main metadata candidates:"
print_main_candidate "title" "$ITUNES_TITLE" "$EPUB_TITLE"
print_main_candidate "author" "$ITUNES_AUTHOR" "$EPUB_AUTHOR"
print_main_candidate "publisher" "$ITUNES_PUBLISHER" "$EPUB_PUBLISHER"
print_main_candidate "description" "$ITUNES_DESCRIPTION" "$EPUB_DESCRIPTION"

echo
echo "Notice-only differences and reference fields:"
echo "  These fields will not be replaced."
if [ "${#NOTICE_LINES[@]}" -eq 0 ]; then
    echo "  - <none>"
else
    for line in "${NOTICE_LINES[@]}"; do
        echo "  - $line"
    done
fi

if [ "$MAIN_DIFF_COUNT" -eq 0 ]; then
    echo
    echo "No differences found in the four writable metadata fields. Keeping EPUB metadata."
    CHOICE="epub"
else
    echo
    echo "Choose main metadata source for final decrypted EPUB:"
    echo "1) Use iTunes main metadata"
    echo "2) Keep EPUB main metadata"
    while true; do
        read -r -p "Selection [1/2]: " user_choice
        case "$user_choice" in
            1) CHOICE="itunes"; break ;;
            2) CHOICE="epub"; break ;;
            *) echo "Invalid selection. Enter 1 or 2." ;;
        esac
    done
fi

select_final_value() {
    local itunes_value="${1:-}"
    local epub_value="${2:-}"
    if [ "$CHOICE" = "itunes" ] && [ -n "$itunes_value" ]; then
        printf '%s' "$itunes_value"
    else
        printf '%s' "$epub_value"
    fi
}

select_final_source() {
    local itunes_value="${1:-}"
    if [ "$CHOICE" = "itunes" ] && [ -n "$itunes_value" ]; then
        printf 'iTunes'
    else
        printf 'EPUB'
    fi
}

FINAL_TITLE=$(select_final_value "$ITUNES_TITLE" "$EPUB_TITLE")
FINAL_AUTHOR=$(select_final_value "$ITUNES_AUTHOR" "$EPUB_AUTHOR")
FINAL_PUBLISHER=$(select_final_value "$ITUNES_PUBLISHER" "$EPUB_PUBLISHER")
FINAL_DESCRIPTION=$(select_final_value "$ITUNES_DESCRIPTION" "$EPUB_DESCRIPTION")

echo
echo "Final metadata preview:"
echo "  - title ($(select_final_source "$ITUNES_TITLE"))"
print_value_line "value" "$FINAL_TITLE"
echo "  - author ($(select_final_source "$ITUNES_AUTHOR"))"
print_value_line "value" "$FINAL_AUTHOR"
echo "  - publisher ($(select_final_source "$ITUNES_PUBLISHER"))"
print_value_line "value" "$FINAL_PUBLISHER"
echo "  - description ($(select_final_source "$ITUNES_DESCRIPTION"))"
print_value_line "value" "$FINAL_DESCRIPTION" 140

if [ "$CHOICE" = "itunes" ]; then
    while true; do
        read -r -p "Apply this iTunes metadata preview? [y/N]: " apply_choice
        case "$apply_choice" in
            y|Y|yes|YES) break ;;
            n|N|no|NO|"")
                echo "Cancelled metadata update. Kept EPUB main metadata from OPF."
                exit 0
                ;;
            *) echo "Invalid selection. Enter y or n." ;;
        esac
    done

    ESCAPED_TITLE=$(xml_escape "$FINAL_TITLE")
    ESCAPED_AUTHOR=$(xml_escape "$FINAL_AUTHOR")
    ESCAPED_PUBLISHER=$(xml_escape "$FINAL_PUBLISHER")
    ESCAPED_DESCRIPTION=$(xml_escape "$FINAL_DESCRIPTION")

    TITLE="$ESCAPED_TITLE" AUTHOR="$ESCAPED_AUTHOR" PUBLISHER="$ESCAPED_PUBLISHER" DESCRIPTION="$ESCAPED_DESCRIPTION" \
    perl -0777 -i -pe '
        my $title = $ENV{"TITLE"};
        my $author = $ENV{"AUTHOR"};
        my $publisher = $ENV{"PUBLISHER"};
        my $description = $ENV{"DESCRIPTION"};

        if (length($title) > 0) {
            if (/<dc:title\b/s) {
                s#(<dc:title\b[^>]*>).*?(</dc:title>)#$1$title$2#s;
            } else {
                s#<metadata\b([^>]*)>#<metadata$1>\n<dc:title>$title</dc:title>#s;
            }
        }
        if (length($author) > 0) {
            if (/<dc:creator\b/s) {
                s#(<dc:creator\b[^>]*>).*?(</dc:creator>)#$1$author$2#s;
            } else {
                s#</metadata>#<dc:creator>$author</dc:creator>\n\n</metadata>#s;
            }
        }
        if (length($publisher) > 0 && /<dc:publisher\b/s) {
            s#(<dc:publisher\b[^>]*>).*?(</dc:publisher>)#$1$publisher$2#s;
        } elsif (length($publisher) > 0) {
            s#</metadata>#<dc:publisher>$publisher</dc:publisher>\n\n</metadata>#s;
        }
        if (length($description) > 0) {
            if (/<dc:description\b/s) {
                s#(<dc:description\b[^>]*>).*?(</dc:description>)#$1$description$2#s;
            } else {
                s#</metadata>#<dc:description>$description</dc:description>\n\n</metadata>#s;
            }
        }
    ' "$DECRYPTED_OPF_PATH"
    echo "Applied iTunes main metadata to decrypted OPF."
else
    echo "Kept EPUB main metadata from OPF."
fi
