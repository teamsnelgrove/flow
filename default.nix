# Build this checkout:  nix-build  (result/bin/flow)
#
# nixpkgs comes from devenv.lock, so the package and the dev shell use the
# same zig. After build.zig.zon changes, run nix/update-zig-deps-hash.sh.
let
  lock = (builtins.fromJSON (builtins.readFile ./devenv.lock)).nodes.nixpkgs.locked;
  nixpkgs = fetchTarball {
    url = "https://github.com/${lock.owner}/${lock.repo}/archive/${lock.rev}.tar.gz";
    sha256 = lock.narHash;
  };
in
{
  pkgs ? import nixpkgs { },
}:
let
  inherit (pkgs) lib zig;
  fs = lib.fileset;

  zigDeps = zig.fetchDeps {
    pname = "flow";
    # A fixed-output derivation is looked up by name and hash, so a stale hash
    # would keep resolving to the old dependencies. Naming it after
    # build.zig.zon forces a refetch, and a hash check, whenever that changes.
    version = builtins.substring 0 12 (builtins.hashFile "sha256" ./build.zig.zon);
    src = fs.toSource {
      root = ./.;
      fileset = fs.unions [
        ./build.zig
        ./build.zig.zon
      ];
    };
    # Only what the default (terminal) build needs. The lazy GUI dependencies
    # include freetype from savannah, whose mirrors zig cannot always reach.
    fetchAll = false;
    hash = lib.fileContents ./nix/zig-deps.hash;
  };
in
pkgs.stdenv.mkDerivation {
  pname = "flow";
  version = "dev";

  src = fs.toSource {
    root = ./.;
    fileset = fs.unions [
      ./build.zig
      ./build.zig.zon
      ./help.md
      ./src
      ./test
    ];
  };

  nativeBuildInputs = [ zig ];

  # No --release: build.zig then requires git for the version string, and
  # there is no git in the sandbox. The binary reports its version as unknown.
  dontSetZigDefaultFlags = true;
  zigBuildFlags = [
    "-Dcpu=baseline"
    "-Doptimize=fast"
  ];

  # zig unpacks dependencies from the package archives in its global cache,
  # so seeding that cache is enough to build offline.
  postConfigure = ''
    cp -r ${zigDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
    chmod -R u+w "$ZIG_GLOBAL_CACHE_DIR/p"
  '';

  __structuredAttrs = true;
  strictDeps = true;

  passthru = { inherit zigDeps; };

  meta.mainProgram = "flow";
}
