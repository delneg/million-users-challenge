# NativeAOT build env (the scoring box would get the same packages from install.sh): Ubuntu 24.04 + clang/lld + zlib.
# The SDK is mounted from ~/muclab/dotnet at /dotnet.
FROM ubuntu:24.04
RUN apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends clang lld zlib1g-dev libicu74 ca-certificates && rm -rf /var/lib/apt/lists/*
ENV DOTNET_ROOT=/dotnet PATH=/dotnet:$PATH DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
