{ check-arg, info-args, p, u }:
{ config, lib, ... }:
with builtins;
let
  l = lib;
  t = l.types;
  inherit (l) mkOption;

  oneOfSubmodule = submodules:
    t.addCheck
      (t.submodule {
        options =
          mapAttrs
            (_: v:
              v // {
                type = t.nullOr v.type;
                default = null;
              }
            )
            submodules;
      })
      (s: length (attrNames s) == 1 && attrVals s != [ null ]);

  info = t.submodule {
    options = {
      version = mkOption {
        description = "The package's version";
        type = t.nullOr t.str;
        default = null;
      };

      dependencies = mkOption {
        description = "The package's dependencies";
        type = t.listOf (t.either t.str t.package);
        default = [ ];
      };

      src = mkOption {
        description = "The 'src' directory from the source of the package";
        type = t.str;
        default = "src";
      };

      install = mkOption {
        description = "How to install the package from the source";
        type = t.str;
        default = "ln -s $src/${l.escapeShellArg config.ro.info.src} $out";
      };

      foreign = mkOption {
        description = "How to install the package from the source";
        type = t.nullOr (t.attrsOf (oneOfSubmodule {
          node_modules = mkOption {
            description = "abc";
            type = t.path;
          };

          src = mkOption {
            description = "abc";
            type = t.path;
          };
        }));

        default = null;
      };

      pursuit = mkOption {
        description = "Pursuit info";
        type = t.nullOr (t.submodule {
          options = {
            name = mkOption {
              description = "The name of the package on Pursuit";
              type = t.str;
              default = config.name;
            };

            repo = mkOption {
              description = "The Git repo that shows up on pursuit";
              type = t.str;
            };

            license = mkOption {
              description = "The license to show on Pursuit";
              type = t.anything;
            };
          };
        });

        default = null;
      };
    };
  };
in
{
  options = {
    name = mkOption {
      description = "The name of the package. This is often applied automatically from the name of an attrset";
      type = t.str;
    };

    src = mkOption {
      description = "package source";
      type = oneOfSubmodule {
        git = mkOption {
          description = "git source";
          type = t.submodule {
            options = {
              repo = mkOption {
                description = "git repo URL";
                type = t.str;
              };

              rev = mkOption {
                description = "git commit hash";
                type = t.str;
              };

              ref = mkOption {
                description = "git ref";
                type = t.nullOr t.str;
                default = null;
              };
            };
          };
        };

        flake = mkOption {
          description = "flake source";
          type = t.submodule {
            options = {
              url = mkOption {
                description = "flake URL";
                type = t.str;
              };

              package = mkOption {
                description = "the flake package corresponding to the PureScript package";
                type = t.str;
                default = "default";
              };
            };
          };
        };

        path = mkOption {
          description = "a path for the package";
          type = t.path;
        };
      };
    };

    info = mkOption {
      description = "info for the package, or a path to the info";
      type = t.either t.path info;
    };

    ro = {
      info = mkOption {
        description = "info for the package";
        type = info;
        readOnly = true;
      };

      src = mkOption {
        description = "path source";
        type = t.path;
        readOnly = true;
      };
    };
  };

  config = {
    ro = {
      info =
        if isPath config.info then
          let f = import (config.ro.src + config.info); in
          if (l.functionArgs f) ? ${check-arg} then
            abort "${config.name}: The info function expects a '${check-arg}' attribute. The purpose of this attribute is to ensure the info function will not break if new arguments are added. If you're encountering this error, use the `...` syntax instead of specifying '${check-arg}' explicityly."
          else
            f info-args
        else
          config.info;

      src =
        if u.has config.src "git" then
          let
            cfg = config.src.git;

            ref =
              if u.has cfg "ref" then
                cfg.ref
              else if u.has config.info "version" then
                "refs/tags/v" + config.info.version
              else
                null;
          in
          fetchGit
            ({
              url = cfg.repo;
              inherit (cfg) rev;
            } // (l.optionalAttrs (ref != null) { inherit ref; }))
        else if u.has config.src "flake" then
          let cfg = config.src.flake; in
          (getFlake cfg.url).packages.${p.system}.${cfg.package}
        else if u.has config.src "path" then
          config.src.path
        else
          throw "no way to get the package src path";
    };
  };
}

