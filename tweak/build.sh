#!/bin/bash
# 编译 ProjectionOverride.dylib（iOS arm64）
set -e
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang \
  -arch arm64 -miphoneos-version-min=13.0 \
  -isysroot "$SDK" \
  -dynamiclib -O2 \
  -framework Foundation -framework CoreGraphics -framework CoreVideo -framework CoreText \
  -install_name @executable_path/Frameworks/ProjectionOverride.dylib \
  -o ProjectionOverride.dylib ProjectionOverride.m
echo "built: $(ls -la ProjectionOverride.dylib | awk '{print $5}') bytes"
