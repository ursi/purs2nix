p:
with builtins;
let l = p.lib; in
rec {
  has = set: attr: set ? ${attr} && set.${attr} != null;
  hasByPath = set: path: l.hasAttrByPath path set && l.getAttrFromPath path set != null;
  bundle =
    { entry-point
    , esbuild ? { }
    , main ? true
    }:
    let
      esbuild' = {
        log-level = "warning";
        outfile = "main.js";
      }
      // (if esbuild ? platform then { } else { format = "esm"; })
      // esbuild
      // { bundle = true; };

      flags = toString
        (l.mapAttrsToList
          (n: v:
            let
              process = val:
                let str = toString val; in
                if any (a: l.hasPrefix a str) [ ''"'' "$" "'" ]
                then str
                else l.escapeShellArg str;
            in
            if isBool v then
              if v then "--${n}" else ""
            else if isList v then
              map (a: "--${n}:${process a}") v
            else
              "--${n}=${process v}")
          esbuild'
        );

      build = "${p.esbuild}/bin/esbuild ${flags}";
    in
    if main then
      ''echo 'import { main } from "${entry-point}"; main()' | ${build}''
    else
      "${build} ${entry-point}";

  compile =
    purescript:
    { globs
    , output ? null
    , verbose-errors ? false
    , comments ? false
    , codegen ? null
    , no-prefix ? false
    , json-errors ? false
    }:
    let
      flags = toString [
        (make-flag "--output " output)
        (make-flag "--verbose-errors" verbose-errors)
        (make-flag "--comments" comments)
        (make-flag "--codegen " codegen)
        (make-flag "--no-prefix" no-prefix)
        (make-flag "--json-errors" json-errors)
      ];
    in
    "${purescript}/bin/purs compile ${flags} ${globs}";

  repl = purescript:
    { globs
    , node-path ? null
    , node-opts ? null
    }:
    let
      flags = toString [
        (make-flag "--node-path " node-path)
        (make-flag "--node-opts " node-opts)
      ];
    in
    "${purescript}/bin/purs repl ${flags} ${globs}";

  make-flag = flag: arg:
    if arg == null || arg == false then
      ""
    else if arg == true then
      flag
    else
      flag + arg;

  make-name = unsanitized: version:
    let name = l.strings.sanitizeDerivationName unsanitized; in
    if version == null then
      { inherit name; }
    else
      {
        pname = name;
        inherit version;
      };

  node-command =
    { argv-1
    , import
    , nodejs
    , starting-arg ? 2
    }:
    ''
      ${nodejs}/bin/node \
        --input-type=module \
        -e 'import { main } from "${import}"; main()' \
        -- "${argv-1}" "''${@:${toString starting-arg}}"
    '';

  has-version = pkg:
    let info = pkg.purs-nix-info; in
    if info ? version then
      if info.version == null then
        l.warn "the package '${info.name}' is built with an old version of purs-nix, please update it if possible" false
      else
        true
    else
      false;

  package-info = pkg:
    let
      info = pkg.purs-nix-info;
      source-info =
        if has info "flake" then
          ''
            echo "flake:   ${info.flake.url}"
            echo "package: ${info.flake.package or "default"}"''
        else if has info "repo" then
          let
            more-info =
              if has info "rev"
              then ''echo "commit:  ${info.rev}"''
              else ''echo "path:    ${pkg.src}"'';
          in
          ''
            echo "repo:    ${info.repo}"
            ${more-info}''
        else
          ''echo "path:    ${pkg.src}"'';
    in
    ''
      echo "name:    ${info.name}"
      echo "version: ${if has-version pkg then info.version else "none"}"
      ${source-info}
      echo "source:  ${pkg}"
    '';

  # subtract-string "abcdef" "abc" => "def"
  subtract-string = s1: s2:
    assert l.hasPrefix s2 s1;
    let
      l1 = stringLength s1;
      l2 = stringLength s2;
    in
    substring l2 (l1 - l2) s1;

  dep-name = dep: if typeOf dep == "string" then dep else dep.purs-nix-info.name;

  dep-info = ps-pkgs: dep:
    (if typeOf dep == "string"
    then ps-pkgs.${dep}
    else dep).purs-nix-info;
}
