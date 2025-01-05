{ overlays ? [ ], pkgs, utils }:
with builtins;
let
  l = p.lib;
  p = pkgs;
  u = utils;

  build = pre-eval-args:
    let
      check-arg = "_accepts-future-args-check";
      info-args = {
        inherit build ps-pkgs ps-pkgs-ns;
        inherit (l) licenses;

        # make sure the function can accept new arguments in the future
        ${check-arg} = null;
      };

      args = (l.evalModules {
        modules = [
          pre-eval-args
          (import ./package-description.nix { inherit check-arg info-args p u; })
        ];
      }).config;

      inherit (args) name;
    in
    if u.has args.src "flake" then
      l.recursiveUpdate
        (getFlake args.src.flake.url).packages.${p.system}.${args.src.flake.package or "default"}
        { purs-nix-info = { inherit name; } // args.src; }
    else
      let
        inherit (args.ro) info;

        add-optional = attribute:
          if u.has info attribute
          then { ${attribute} = info.${attribute}; }
          else { };
      in
      p.stdenv.mkDerivation
        ({
          inherit (args.ro) src;
          phases = [
            "unpackPhase"
            "installPhase"
          ];

          passthru = {
            overlay =
              let
                f = foldl'
                  (acc: dep:
                    if typeOf dep == "string" then
                      acc
                    else
                      let info = dep.purs-nix-info; in
                      {
                        current = acc.current // { ${info.name} = dep; };

                        overlays =
                          let a = f acc info.dependencies; in
                          a.overlays ++ [ (_: _: a.current) ] ++ acc.overlays;
                      });

                a = f { current = { }; overlays = [ ]; } info.dependencies;
                inherit (a) current overlays;
              in
              l.composeManyExtensions (overlays ++ [ (_: _: current) ]);

            purs-nix-info = {
              inherit name;
              inherit (info) dependencies src;
            }
            // (
              if u.has args.src "git" then
                { inherit (args.src.git) repo rev; }
              else if u.hasByPath info [ "pursuit" "repo" ] then
                { inherit (info.pursuit) repo; }
              else
                { }
            )
            // add-optional "version"
            // add-optional "foreign"
            // add-optional "pursuit";
          };

          installPhase = info.install;
        }
        // u.make-name name info.version);

  build-set =
    f: l.fix (self: mapAttrs (n: v: build (v // { name = n; })) (f self));

  overlay-stuff =
    let
      build-set' =
        mapAttrs
          (n: v:
            if v ? type && v.type == "derivation" then v else build (v // { name = n; })
          );

      composeExtensions = f: g: final: prev:
        let
          fApplied = f final prev;
          prev' = build-set' (prev // fApplied);
        in
        fApplied // (g final prev');
    in
    # modified versions of the functions in lib.fixedPoints
    {
      extends = f: rattrs: self:
        let
          super = rattrs self;
          a = f self super;
        in
        super // build-set' a;

      composeManyExtensions = l.foldr composeExtensions (_: _: { });
    };

  ps-pkgs = l.fix
    (overlay-stuff.extends
      (overlay-stuff.composeManyExtensions overlays)
      (self:
        mapAttrs
          (n: v: build (v // { name = n; }))
          (import ./ps-pkgs.nix l self)));

  ps-pkgs-ns =
    foldl'
      (acc:
        { name, value }:
        let m = match "(.+)\\.(.+)" name; in
        if m == null then
          acc
        else
          let
            namespace = head m;
            no-namespace = l.last m;
          in
          acc
          // {
            ${namespace} =
              (acc.${namespace} or { }) // { ${no-namespace} = value; };
          }
      )
      { }
      (l.mapAttrsToList l.nameValuePair ps-pkgs);
in
{ inherit build build-set ps-pkgs ps-pkgs-ns; }
