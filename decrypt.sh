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
        cd "./decrypted_books/${fileName%.epub}_decrypted.epub" || continue
        zip -r "../${fileName}" .

        # and now we clean up.
        cd ../../ || continue
        rm -rf "./decrypted_books/${fileName%.epub}_decrypted.epub"
        echo "Finished: ./decrypted_books/${fileName}"

    else
        echo "Invalid selection. Please select a number from 1 to ${#itemNames[@]}, or q to quit."
    fi
    echo
done
