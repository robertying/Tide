#!/bin/sh
# Builds Tide.exe for 64-bit Windows: a single self-contained exe in windows/build/.
# Runs on macOS, Linux or Windows with the .NET 10 SDK (on a Mac: brew install dotnet).
#   windows/build.sh
set -e
cd "$(dirname "$0")"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
[ -z "$DOTNET_ROOT" ] && [ -d /opt/homebrew/opt/dotnet/libexec ] && export DOTNET_ROOT=/opt/homebrew/opt/dotnet/libexec
rm -rf build
dotnet publish Tide.csproj -c Release -o build --nologo
ls -lh build/Tide.exe
