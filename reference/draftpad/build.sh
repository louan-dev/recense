#!/bin/zsh
# Builds draftpad from draftpad.swift.
#   zsh build.sh              build for this Mac
#   zsh build.sh universal    build one binary that runs on Apple Silicon and Intel
set -e
cd "$(dirname "$0")"

# Catch stray text pasted above the code (for example "Draftpad · SWIFT" from a download card).
first=$(grep -m1 -v '^[[:space:]]*$' draftpad.swift)
if [[ "$first" != //* && "$first" != import* ]]; then
  echo "draftpad.swift starts with unexpected text: $first" >&2
  echo "Delete everything above the line '// draftpad.swift' and run this again." >&2
  exit 1
fi

if [[ "$1" == "universal" ]]; then
  swiftc -O -target arm64-apple-macos12 draftpad.swift -o .draftpad-arm64
  swiftc -O -target x86_64-apple-macos12 draftpad.swift -o .draftpad-x86_64
  lipo -create -output draftpad .draftpad-arm64 .draftpad-x86_64
  rm -f .draftpad-arm64 .draftpad-x86_64
else
  swiftc -O draftpad.swift -o draftpad
fi

echo "Built $(pwd)/draftpad"