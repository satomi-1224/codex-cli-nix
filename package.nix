{
  lib,
  stdenv,
  fetchurl,
  makeWrapper,
  patchelf,
  ncurses,
  versionCheckHook,
  additionalPaths ? [ ],
  sourcesFile,
}:
let
  sourcesData = lib.importJSON sourcesFile;
  inherit (sourcesData) version;
  sources = sourcesData.platforms;

  source =
    sources.${stdenv.hostPlatform.system}
      or (throw "Unsupported system: ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "codex";
  inherit version;

  src = fetchurl {
    inherit (source) url hash;
  };

  # The release archive expands straight into bin/, codex-path/,
  # codex-resources/ and codex-package.json with no top-level directory.
  sourceRoot = ".";

  nativeBuildInputs = [
    makeWrapper
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [ patchelf ];

  # Linux artifacts are static-pie and Darwin artifacts are Developer ID
  # signed, so stripping is pointless at best and breaks the signature at
  # worst. Leave every shipped binary byte-for-byte as upstream built it.
  dontStrip = true;
  dontPatchELF = true;

  installPhase = ''
    runHook preInstall

    # codex resolves its bundled `rg`, `bwrap` and patched zsh relative to the
    # package root discovered from `current_exe`, so the upstream layout has to
    # survive intact. `current_exe` is canonicalised before that lookup, which
    # is why a plain symlink in $out/bin is enough to find it.
    mkdir -p "$out/libexec/codex" "$out/bin"
    cp -R bin codex-path codex-resources codex-package.json "$out/libexec/codex/"
    ln -s ../libexec/codex/bin/codex "$out/bin/codex"

    runHook postInstall
  '';

  postFixup =
    # Only the bundled zsh fork (used by codex's shell_zsh_fork feature) is
    # dynamically linked; everything else in the archive is static-pie and
    # needs no interpreter fixup.
    lib.optionalString stdenv.hostPlatform.isLinux ''
      patchelf \
        --set-interpreter ${stdenv.cc.bintools.dynamicLinker} \
        --set-rpath ${
          lib.makeLibraryPath [
            stdenv.cc.libc
            ncurses
          ]
        } \
        "$out/libexec/codex/codex-resources/zsh/bin/zsh"
    ''
    + lib.optionalString (additionalPaths != [ ]) ''
      rm "$out/bin/codex"
      makeWrapper "$out/libexec/codex/bin/codex" "$out/bin/codex" \
        --prefix PATH : ${lib.escapeShellArg (lib.concatStringsSep ":" additionalPaths)}
    '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];
  versionCheckProgramArg = "--version";

  passthru = {
    updateScript = ./update.nu;
  };

  meta = {
    inherit version;
    description = "Lightweight coding agent that runs in your terminal";
    homepage = "https://github.com/openai/codex";
    downloadPage = "https://github.com/openai/codex/releases";
    changelog = "https://github.com/openai/codex/releases/tag/rust-v${version}";
    license = lib.licenses.asl20;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    mainProgram = "codex";
    platforms = import ./systems.nix;
    maintainers = [ ];
  };
}
