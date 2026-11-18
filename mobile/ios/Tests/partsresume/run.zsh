#!/bin/zsh
# Regression guard: FEAT-31 P1. Feed.putParts keeps its part list and resumes (fake transport, no network).
set -e
root=${0:A:h:h:h:h:h}; d=$(mktemp -d)
xcrun swiftc -O $root/mobile/FileProviderCore/Core.swift $root/mobile/ios/Tests/partsresume/main.swift -o $d/partsresume
$d/partsresume; r=$?
rm -rf $d
exit $r
