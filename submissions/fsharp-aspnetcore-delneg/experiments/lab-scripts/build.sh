#!/usr/bin/env bash
# Build one variant on opt-box into ~/muclab/builds/<label> (never during a timed run: queue it).
#   build.sh <label> ours [SRC_DIR] [dotnet publish -p:... args]   our entry (default: ~/muclab/repo/submissions/fsharp-aspnetcore-delneg)
#   build.sh <label> csharp                                          examples/csharp, retargeted to net11.0 (same runtime as ours)
#   build.sh <label> rust <submission-folder>                         a Rust submission, built in the tdsc-rust:2404 image (rustc 1.94.0)
set -euo pipefail
L=~/muclab; R=$L/repo; label=$1; kind=$2; shift 2
B=$L/builds/$label; rm -rf "$B"; mkdir -p "$L/builds"
export DOTNET_ROOT=$L/dotnet PATH=$L/dotnet:$PATH DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 MSBUILDDISABLENODEREUSE=1 NUGET_PACKAGES=$L/nuget
case $kind in
  ours)
    src=$R/submissions/fsharp-aspnetcore-delneg
    if [ $# -gt 0 ] && [ -d "$1" ]; then src=$1; shift; fi
    rsync -a --exclude out --exclude bin --exclude obj "$src/" "$B/"
    # SC=1: self-contained (needed for composite ReadyToRun of the framework)
    (cd "$B/src" && dotnet publish Server.fsproj -c Release --use-current-runtime --self-contained $([ -n "${SC:-}" ] && echo true || echo false) -o ../out -p:RestoreLockedMode=true "$@" 2>&1 | grep -E "error|warn|->" | grep -v "^\s*$" | tail -15)
    ;;
  aot) # our entry with PublishAot, built in the muclab-aot image (clang, lld, zlib1g-dev); extra args go to publish
    src=$R/submissions/fsharp-aspnetcore-delneg
    if [ $# -gt 0 ] && [ -d "$1" ]; then src=$1; shift; fi
    rsync -a --exclude out --exclude bin --exclude obj "$src/" "$B/"
    docker run --rm -m 2200m -e NUGET_PACKAGES=/nuget -v $L/dotnet:/dotnet:ro -v $L/nuget:/nuget -v "$B":/b -w /b/src muclab-aot \
      bash -c "dotnet publish Server.fsproj -c Release -r linux-x64 -p:PublishAot=true -o ../out $* 2>&1 | grep -E 'error|warn|->' | sort | uniq -c | sort -rn | head -40; chown -R $(id -u):$(id -g) /b /nuget"
    ls -la "$B/out/Server" 2>/dev/null
    ;;
  csharp)
    rsync -a "$R/examples/csharp/" "$B/"
    (cd "$B" && sed -i 's#<TargetFramework>net10.0</TargetFramework>#<TargetFramework>net11.0</TargetFramework>#' FeedApi.csproj && dotnet publish FeedApi.csproj -c Release -o out "$@" 2>&1 | grep -E "error|->" | tail -5)
    sed -i "s#^exec dotnet #exec $L/dotnet/dotnet #" "$B/start.sh"
    ;;
  rust)
    sub=$1; shift
    rsync -a --exclude target "$R/submissions/$sub/" "$B/"
    docker run --rm -m 1500m -e CARGO_HOME=/cargo -v $L/cargo:/cargo -v "$B":/src -w /src tdsc-rust:2404 \
      bash -c "RUSTFLAGS='-C target-cpu=native' cargo build --release --locked 2>&1 | tail -3; chown -R $(id -u):$(id -g) /src /cargo"
    ;;
esac
dotnet build-server shutdown >/dev/null 2>&1 || true
echo "built $label ($kind) in $B"
