#!/bin/zsh
cd "${0:A:h}/.." || exit 1
mkdir -p build
swiftc src/breakscreen.swift -o build/breakscreen && echo "Built build/breakscreen"
