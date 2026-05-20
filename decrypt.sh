#!/bin/bash

if [[ $(csrutil status) == *"enabled." ]]; then
    echo "SIP must be disabled."
    echo "Consult this documentation for help doing this: https://developer.apple.com/documentation/security/disabling_and_enabling_system_integrity_protection#3599244"
    exit 1
fi

if [[ $(csrutil status) == *"unknown"* ]]; then
    echo "SIP status unknown."
    echo "Make sure SIP is disabled."
fi

if [[ $(defaults read /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation) != "1" ]]; then
    echo "Library validation must be disabled."
    echo "Disable it with: sudo defaults write /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation -bool true"
    exit 1
fi

function injectDylib {
	DYLD_INSERT_LIBRARIES=./injected.dylib /System/Applications/Books.app/Contents/MacOS/Books
}

function clearBooksTmp {
    local tmpDir="$BOOKS_HOME/tmp"

    if [ -z "$tmpDir" ] || [ "$tmpDir" = "/" ]; then
        echo "Refusing to clear unsafe tmp path: $tmpDir" >&2
        return 1
    fi

    mkdir -p "$tmpDir"
    find "$tmpDir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}


BOOKS_HOME=~/Library/Containers/com.apple.iBooksX/Data
BOOKS_EPUB_DIR=~/Library/Containers/com.apple.BKAgentService/Data/Documents/iBooks/Books

mkdir -p "$BOOKS_HOME/tmp"
mkdir -p "./decrypted_books"
chmod +x ./metadata_resolver.sh

epubFiles=()
itemNames=()

for file in "$BOOKS_EPUB_DIR"/*.epub
do
    itemName=$(plutil -extract itemName raw "$file/iTunesMetadata.plist")
    if [[ -z "$itemName" ]]; then
        echo "Failed to extract itemName from $file"
        continue
    fi
    epubFiles+=("$file")
    itemNames+=("$itemName")
done

function printBookMenu {
    echo "Enter the number of the book to decrypt, or q to quit."
    local i
    for i in "${!itemNames[@]}"; do
        echo "$((i + 1))) ${itemNames[$i]}"
    done
}

function packageEpub {
    local sourceDir="$1"
    local outputFile="$2"

    (
        cd "$sourceDir" || exit 1

        if [ ! -f "mimetype" ]; then
            echo "Missing mimetype file in decrypted EPUB directory: $sourceDir" >&2
            exit 1
        fi

        rm -f "$outputFile"
        zip -X -0 "$outputFile" mimetype
        zip -X -r "$outputFile" . -x mimetype
    )
}

function detectArtworkExtension {
    local artworkFile="$1"
    local format
    format=$(sips -g format "$artworkFile" 2>/dev/null | awk -F': ' '/format:/{print tolower($2); exit}')

    case "$format" in
        jpeg|jpg) echo "jpg" ;;
        png) echo "png" ;;
        gif) echo "gif" ;;
        tiff|tif) echo "tiff" ;;
        webp) echo "webp" ;;
        *) echo "artwork" ;;
    esac
}

function copyITunesArtwork {
    local sourceEpub="$1"
    local outputEpub="$2"
    local artworkFile="$sourceEpub/iTunesArtwork"

    if [ ! -f "$artworkFile" ]; then
        return 0
    fi

    local outputDir
    local outputBase
    local extension
    local outputArtwork
    outputDir=$(dirname "$outputEpub")
    outputBase=$(basename "$outputEpub" .epub)
    extension=$(detectArtworkExtension "$artworkFile")
    outputArtwork="$outputDir/$outputBase.$extension"

    if ! cp "$artworkFile" "$outputArtwork"; then
        echo "Failed to copy iTunes artwork: $artworkFile" >&2
        return 1
    fi

    echo "Copied iTunes artwork: $outputArtwork"
}

while true
do
    printBookMenu
    read -r -p "Selection (q to quit): " REPLY

    if [[ "$REPLY" == "q" || "$REPLY" == "Q" ]]; then
        echo "Exiting."
        break
    fi

    # Validate the user's input
    if [[ "$REPLY" =~ ^[0-9]+$ ]] && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le ${#itemNames[@]} ]; then

        selected_epub="${epubFiles[REPLY-1]}"

        open "$BOOKS_HOME/tmp"

        if ! clearBooksTmp; then
            echo "Failed to clear Books tmp directory: $BOOKS_HOME/tmp" >&2
            continue
        fi

        cp -R "$selected_epub" "$BOOKS_HOME/tmp"

        injectDylib

        fileName=$(basename "$selected_epub")
        copiedFilePath="$BOOKS_HOME/tmp/$fileName"
        decryptedEpubPath="${copiedFilePath%.epub}_decrypted.epub"

        if [ ! -d "$decryptedEpubPath" ]; then
            echo "Failed to locate decrypted output: $decryptedEpubPath"
            rm -rf "$copiedFilePath"
            continue
        fi

        ./metadata_resolver.sh "$selected_epub" "$decryptedEpubPath"

        mv "$decryptedEpubPath" ./decrypted_books
        rm -rf "$copiedFilePath"

        # convert it to an actual epub...
        if ! packageEpub "./decrypted_books/${fileName%.epub}_decrypted.epub" "../${fileName}"; then
            echo "Failed to package EPUB: ./decrypted_books/${fileName}"
            continue
        fi

        if ! copyITunesArtwork "$selected_epub" "./decrypted_books/${fileName}"; then
            echo "Failed to export iTunes artwork for: $fileName"
            continue
        fi

        # and now we clean up.
        rm -rf "./decrypted_books/${fileName%.epub}_decrypted.epub"
        echo "Finished: ./decrypted_books/${fileName}"

    else
        echo "Invalid selection. Please select a number from 1 to ${#itemNames[@]}, or q to quit."
    fi
    echo
done
