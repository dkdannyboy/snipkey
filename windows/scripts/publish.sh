#!/usr/bin/env bash
# SnipKey for Windows 배포본 만들기 — macOS·Linux·Windows(Git Bash) 어디서든 돈다.
# 결과: windows/dist/SnipKey.exe (런타임 포함 단일 파일, 설치 없이 실행)
set -euo pipefail
cd "$(dirname "$0")/.."
dotnet test tests/SnipKey.Core.Tests
dotnet publish src/SnipKey.Windows -c Release -r win-x64 --self-contained true \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
  -p:EnableCompressionInSingleFile=true -p:DebugType=none -o dist
ls -lh dist/SnipKey.exe
