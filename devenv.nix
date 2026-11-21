{ pkgs, ... }:

{
  packages = [
    # Must satisfy minimum_zig_version in build.zig.zon.
    pkgs.zig
    pkgs.jujutsu

    # scripts/helix-coverage.sh
    pkgs.duckdb
    pkgs.jq
    pkgs.ripgrep
    pkgs.curl
  ];

  # Build this checkout and run it, from any directory.
  scripts.flow-dev.exec = ''
    (cd "$DEVENV_ROOT" && zig build) && exec "$DEVENV_ROOT/zig-out/bin/flow" "$@"
  '';
}
