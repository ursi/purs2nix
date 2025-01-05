{ defaults
, docs-search
, overlays
, parsec
, pkgs
, ps-tools
}:
with builtins;
let
  l = p.lib;
  p = pkgs;
  u = import ./utils.nix p;
  parser = import ./parser.nix { inherit l parsec; };
  purescript' = ps-tools.for-0_15.purescript;

  ps-package-stuff = import ./build-pkgs.nix {
    inherit overlays pkgs;
    utils = u;
  };

  inherit (ps-package-stuff) ps-pkgs;
in
{
  inherit (ps-package-stuff)
    build
    build-set
    ps-pkgs
    ps-pkgs-ns;
  inherit (pkgs) esbuild;
  inherit (pkgs.lib) licenses;
  purescript = purescript';

  purs =
    { nodejs ? pkgs.nodejs
    , purescript ? purescript'
    , foreign ? { }
    , # this parameter is purposely undocumented because I don't see a reason to make
      # it part of the API. However, I have already done the work to make it optional,
      # so I will leave it here for now just in case.
      _compile-packages-separately ? true
    , ...
    }@args:
    let
      inherit (p.stdenv) mkDerivation;

      srcs =
        if args ? dir then
          map (s: args.dir + "/${s}") (args.srcs or [ "src" ])
        else
          args.srcs or (throw ''
            In order to build derivations from your PureScript code, you must supply a 'dir' or 'srcs' argument to 'purs'

            See:
            https://github.com/purs-nix/purs-nix/blob/ps-0.15/docs/purs-nix.md#purs
          '');

      test-src =
        if args ? dir then
          args.dir + "/${args.test or "test"}"
        else
          args.test or (throw ''
            In order to build derivations from your PureScript code, you must supply a 'dir' or 'test' argument to 'purs'

            See:
            https://github.com/purs-nix/purs-nix/blob/ps-0.15/docs/purs-nix.md#purs
          '');

      test-module = args.test-module or "Test.Main";

      create-closure-set = deps:
        let
          f = direct:
            let g = f false; in
            foldl'
              (acc: dep:
                let
                  name = u.dep-name dep;
                  included = acc ? ${name};
                in
                if typeOf dep == "string" then
                  if !included then
                    g (acc // { ${dep} = ps-pkgs.${dep}; })
                      ps-pkgs.${dep}.purs-nix-info.dependencies
                  else
                    acc
                else
                  let info = dep.purs-nix-info; in
                  if direct then
                    g (acc // { ${info.name} = dep; }) info.dependencies
                  else if !included then
                    g (acc // { ${info.name} = ps-pkgs.${info.name}; })
                      info.dependencies
                  else
                    acc);
        in
        f true { } deps;

      create-closure = deps: attrValues (create-closure-set deps);

      dependencies =
        if args ? dependencies then create-closure args.dependencies else [ ];

      all-dependencies =
        if args ? test-dependencies then
          create-closure (dependencies ++ args.test-dependencies)
        else
          dependencies;

      make-dep-globs = deps: toString (map (a: ''"${a}/**/*.purs"'') deps);

      dep-globs = make-dep-globs dependencies;
      all-dep-globs = make-dep-globs all-dependencies;

      local-graph =
        include-test:
        let
          partial = parser
            (map (a: "${a}")
              (srcs ++ (if include-test then [ test-src ] else [ ])));
        in
        mapAttrs
          (_: v: {
            depends = filter (v: partial ? ${v}) v.depends;

            inherit (v) path;
          })
          partial;

      # These are needed to prevent repeate evaluation
      local-graph-tests = local-graph true;
      local-graph-no-tests = local-graph false;

      link-foreign = foreign: prefix:
        let
          make-module = drv:
            if (readDir drv) ? "package.json" then
              drv
            else
              p.runCommand "${drv.pname or drv.name}+package.json" { } ''
                mkdir $out
                cd $_
                cp -r ${drv}/. .
                echo '{ "type": "module" }' > package.json
              '';
        in
        foldl'
          (acc:
            { name, value }:
            let module-path = "${prefix}/${name}"; in
            ''
              ${acc}

              if [[ -e ${module-path} ]]; then
                ${
                  if u.has value "node_modules" then
                    "ln -fsT ${value.node_modules} ${module-path}/node_modules"
                  else if u.has value "src" then
                    ''
                      if [[ -h ${module-path} ]]; then
                        echo "Error: You're trying to add foreign dependencies to the module '${name}', but that module is not part of this project. Add the foreign dependencies to the package that contains '${name}'."
                        exit 1
                      else
                        ln -fsT ${make-module value.src} ${module-path}/foreign
                      fi
                    ''
                  else
                    abort "The only supported foreign options are 'node_modules' and 'src'."
                }
              fi
            '')
          ""
          (l.mapAttrsToList l.nameValuePair foreign);

      link-all-foreign = deps:
        let
          combined =
            foldl'
              (acc: dep: l.recursiveUpdate acc (dep.purs-nix-info.foreign or { }))
              foreign
              deps;
        in
        link-foreign combined;

      copy = "cp --no-preserve=mode --preserve=timestamps -r";

      compile-and-process =
        { name
        , deps
        , postprocessing ? null
        , pre-compile ? null
        }:
        args:
        let
          unprocessed = mkDerivation {
            inherit name;
            phases = [ "buildPhase" "installPhase" ];

            buildPhase =
              if deps != [ ] then
                ''
                  ${if pre-compile != null then
                      "${copy} ${pre-compile args} output"
                    else
                      ""
                  }

                  ${u.compile purescript
                      (args
                       // { globs = make-dep-globs deps;
                            output = "output";
                          })
                  }
                ''
              else
                "mkdir output";

            installPhase = "mv output $out";
          };
        in
        if postprocessing != null then
          postprocessing name deps unprocessed
        else
          unprocessed;

      get-leaves =
        deps:
        attrValues
          (foldl'
            (
              acc: d:
              let
                info = u.dep-info ps-pkgs d;
                dep-deps = map u.dep-name info.dependencies;
              in
              removeAttrs acc dep-deps // { ${info.name} = d; }
            )
            { }
            deps
          );

      incremental-compile =
        { lookups
        , acc
        , local-globs ? ""
        , dependencies
        , name
        , foreign ? { }
        }:
        args:
        let
          lookup = package: lookups.${u.dep-name package};
          all-deps = map lookup (create-closure (map lookup dependencies));

          bin = acc': package:
            let
              info = package.purs-nix-info;

              merge-cache = p.writeShellScript "merge-cache" ''
                f=$(mktemp)
                ${p.jq}/bin/jq -s '.[0] * .[1]' "$1" "$2" > $f
                cat $f > "$3"
                rm $f
              '';

              result =
                if acc' ? ${info.name} then
                  {
                    drv = acc'.${info.name};
                    acc = acc';
                  }
                else
                  compile-package
                    {
                      inherit lookups package;
                      acc = acc';
                    }
                    args;
            in
            {
              augment = p.writeShellScript "${info.name}-merge" ''
                shopt -s extglob
                if [ -e output ]; then
                  ln -s ${result.drv}/!(cache-db.json) output 2> /dev/null
                  ${merge-cache} ${result.drv}/cache-db.json output/cache-db.json output/cache-db.json
                else
                  mkdir output
                  ln -s ${result.drv}/!(*.json) output
                  ${copy} ${result.drv}/*.json output
                fi
              '';

              acc = acc' // result.acc;
            };

          augmentations =
            foldl'
              (acc': d:
                let result = bin acc'.acc (lookup d); in
                {
                  acc = acc' // result.acc;
                  command = acc'.command + result.augment + ";";
                })
              {
                inherit acc;
                command = "";
              }
              (get-leaves dependencies);

          unprocessed = mkDerivation {
            inherit name;
            phases = [ "buildPhase" "installPhase" ];

            buildPhase = ''
              ${augmentations.command}

              ${u.compile purescript (
                args
                // { globs =
                       "${if local-globs == "" then
                            ""
                          else
                            ''"${local-globs}"''
                        } ${make-dep-globs all-deps}";
                     output = "output";
                   }
              )}

              ${link-foreign foreign "output"}
            '';

            installPhase = "mv output $out";
          };
        in
        {
          drv = unprocessed;
          acc = acc // augmentations.acc;
        };

      compile-package =
        { lookups ? create-closure-set package.purs-nix-info.dependencies
        , acc
        , package
        }:
        args:
        let
          info = package.purs-nix-info;

          a =
            incremental-compile
              {
                inherit acc lookups;
                inherit (info) dependencies;
                name = "${info.name}";
                local-globs = "${package}/**/*.purs";
                foreign = if u.has info "foreign" then info.foreign else { };
              }
              args;
        in
        {
          inherit (a) drv;
          acc = a.acc // { ${info.name} = a.drv; };
        };

      pp.foreign = name: _: output:
        let foreign' = link-foreign foreign "."; in
        if foreign' == "" then
          output
        else
          p.runCommand "${name}+foreign" { } ''
            mkdir $out; cd $out
            ${copy} ${output}/. .
            ${foreign'}
          '';

      built-deps =
        let name = "dependencies"; in
        if _compile-packages-separately then
          args:
          (incremental-compile
            {
              inherit dependencies name;
              acc = { };
              lookups = create-closure-set dependencies;
            }
            args
          ).drv
        else
          compile-and-process {
            inherit name;
            deps = dependencies;
          };

      all-built-deps =
        if _compile-packages-separately then
          args:
          (incremental-compile
            {
              name = "all-dependencies";
              acc = { };
              lookups = create-closure-set all-dependencies;
              dependencies = all-dependencies;
            }
            args
          ).drv
        else
          compile-and-process {
            name = "all-dependencies";
            deps = all-dependencies;
            pre-compile = built-deps;
          };

      build-single =
        { include-test ? false
        , name
        , local-deps
        }:
        let
          src =
            let
              graph-path =
                (if include-test
                then local-graph-tests
                else local-graph-no-tests).${name}.path;

              purs-path =
                let matches = match "/nix/store/[^/]+/(.+)$" graph-path; in
                if matches != null
                then head matches
                else throw "${name}: there should be a match here!";

              js-path = replaceStrings [ ".purs" ] [ ".js" ] purs-path;

              subsrc =
                let
                  src' =
                    l.findFirst (path: l.hasPrefix "${path}" graph-path)
                      (throw "should always find a match")
                      (srcs ++ (if include-test then [ test-src ] else [ ]));

                  relative-path = u.subtract-string graph-path "${src'}";
                  matches = match "(.+)/[^/]+$" relative-path;
                in
                if matches == null then src' else src' + head matches;
            in
            filterSource
              (path: _: l.hasSuffix purs-path path || l.hasSuffix js-path path)
              subsrc;

          output =
            { top-level ? true
            , include-test ? false
            }:
            args:
            let
              incremental = args.incremental or false;
              stripped = removeAttrs args [ "incremental" ];

              trans-deps =
                let
                  go = ds: foldl' (acc: d: acc ++ go d.local-deps) [ ] ds ++ ds;
                in
                l.unique (go local-deps);

              dg =
                if include-test then
                  {
                    deps-drv = all-built-deps;
                    deps-list = all-dependencies;
                    globs = all-dep-globs;
                  }
                else
                  {
                    deps-drv = built-deps;
                    deps-list = dependencies;
                    globs = dep-globs;
                  };
            in
            mkDerivation {
              name = "${name}-compiled";
              phases = [ "buildPhase" "installPhase" ];

              buildPhase =
                let
                  augmentations =
                    toString
                      (map (a: "${a.bin include-test args} output;")
                        trans-deps);

                  local-dep-globs =
                    toString (map (a: ''"${a.src}/**/*.purs"'') trans-deps);
                in
                ''
                  ${copy} ${dg.deps-drv stripped} output
                  ${if incremental then augmentations else ""}

                  ${u.compile purescript
                      (stripped
                       // { globs = ''"${src}/**/*.purs" ${local-dep-globs} ${dg.globs}'';
                            output = "output";
                          })
                  }
                '';

              installPhase = ''
                mv output $out
                cd $out

                ${if top-level then link-all-foreign dg.deps-list "." else ""}
              '';
            };

          bundle =
            { esbuild ? { }
            , main ? true
            , incremental ? false
            }:
            p.runCommand "${name}-bundle" { }
              (u.bundle {
                entry-point =
                  output { } { inherit incremental; } + "/${name}/index.js";
                esbuild = esbuild // { outfile = "$out"; };
                inherit main;
              });

          script =
            { esbuild ? { }
            , incremental ? false
            }:
            let
              bundle' = bundle {
                esbuild =
                  { minify = true; } // esbuild // { platform = "node"; };
                inherit incremental;
              };
            in
            p.runCommand "${name}-script" { } ''
              echo $'#! ${nodejs}/bin/node' > $out
              cat ${bundle'} >> $out
              chmod +x $out
            '';

          app =
            { name
            , version ? null
            , command ? name
            , esbuild ? { }
            , incremental ? false
            }:
            mkDerivation
              ({
                phases = [ "installPhase" ];

                installPhase = ''
                  mkdir -p $out/bin; cd $_

                  cp \
                    ${script { inherit esbuild incremental; }} \
                    ${l.escapeShellArg command}
                '';
              }
              // u.make-name name version);
        in
        {
          inherit
            app
            bundle
            local-deps
            name
            output
            script
            src;

          bin = include-test: args:
            let
              merge-cache = p.writeShellScript "merge-cache" ''
                f=$(mktemp)
                ${p.jq}/bin/jq -s '.[0] * .[1]' "$1" "$2" > $f
                cat $f > "$3"
                rm $f
              '';

              output' =
                output
                  {
                    inherit include-test;
                    top-level = false;
                  }
                  args;
            in
            p.writeShellScript name ''
              ${copy} ${output'}/${name} $1/${name}
              ${merge-cache} ${output'}/cache-db.json $1/cache-db.json $1/cache-db.json
            '';
        };

      builds =
        mapAttrs
          (name: v:
            build-single {
              inherit name;
              local-deps = map (v: builds.${v}) v.depends;
            })
          local-graph-no-tests;

      output = { test-modules ? false }: args:
        let
          dg =
            if test-modules then
              {
                name = "all-deps+modules+test-modules";

                pre-compile = compile-and-process {
                  name = "all-deps+modules";
                  deps = srcs ++ all-dependencies;
                  pre-compile = all-built-deps;
                };

                deps = srcs ++ [ test-src ] ++ all-dependencies;
              }
            else
              {
                name = "deps+modules";
                pre-compile = built-deps;
                deps = srcs ++ dependencies;
              };
        in
        compile-and-process
          {
            inherit (dg) name deps pre-compile;
            postprocessing = pp.foreign;
          }
          ((defaults.compile or { }) // args);

      bundle =
        { module ? "Main"
        , esbuild ? { }
        , main ? true
        }:
        p.runCommand "${module}-bundle" { }
          (u.bundle {
            entry-point = output { } { } + "/${module}/index.js";
            esbuild = esbuild // { outfile = "$out"; };
            inherit main;
          });

      script =
        { module ? "Main"
        , esbuild ? { }
        }:
        let
          bundle' = bundle {
            esbuild =
              { minify = true; } // esbuild // { platform = "node"; };
            inherit module;
          };
        in
        p.runCommand "${module}-script" { } ''
          echo $'#! ${nodejs}/bin/node' > $out
          cat ${bundle'} >> $out
          chmod +x $out
        '';

      app =
        { name
        , module ? "Main"
        , version ? null
        , command ? name
        , esbuild ? { }
        }:
        mkDerivation
          ({
            phases = [ "installPhase" ];

            installPhase = ''
              mkdir -p $out/bin; cd $_

              cp \
                ${script { inherit esbuild module; }} \
                ${l.escapeShellArg command}
            '';
          }
          // u.make-name name version);
    in
    {
      dependencies = all-dependencies;
      output = output { };
      inherit app bundle script;

      modules =
        l.warn
          ''
            The `modules` API is deprecated.
            see: https://github.com/purs-nix/purs-nix/blob/ps-0.15/docs/derivations.md
          ''
          (mapAttrs
            (_: v: {
              inherit (v) bundle script app;
              output = v.output { };
            })
            builds);

      command = import ./purs-nix-command.nix {
        inherit
          all-dependencies
          all-dep-globs
          defaults
          dep-globs
          docs-search
          nodejs
          pkgs
          ps-pkgs
          purescript;

        repl-globs = make-dep-globs (all-dependencies ++ [ ps-pkgs.psci-support ]);
        srcs' = (a: if args ? dir then args.srcs or a else a) [ "src" ];
        test' = (a: if args ? dir then args.test or a else a) "test";
        test-module' = test-module;
        utils = u;
        foreign = link-all-foreign all-dependencies;
      };

      test = rec {
        run =
          args:
          let output' = output { test-modules = true; } args; in
          p.writeScript "${test-module}-run"
            (u.node-command {
              argv-1 = "${test-module}-run";
              inherit nodejs;
              import = "${output'}/${test-module}/index.js";
              starting-arg = 1;
            });

        check =
          args:
          p.runCommand "${test-module}-check" { } ''
            ${run args}
            touch $out
          '';
      };
    };
}
