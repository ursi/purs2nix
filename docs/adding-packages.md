```nix
{ name = ''
    The name of the package. When defining a package in an overlay,
    this value will be filled in automatically from the name of the
    attribute in the overlay
  '';

  src = ''
    The source of the package. This can be specified in the following ways:
    - Git: { git =
               { repo = "The URL of the Git repo";

                 rev = "The commit hash";

                 # optional
                 ref = "A ref needed to find the `rev`";
               };
           }

    - Flakes: { flake =
                  { url = "A flake URL";
                    package = '''
                      default: "default"
                      The name of the package in the flake that is the PureScript package
                    ''';
              }

    - Path: { path = "A nix path value to the location of the package"; }
  '';

  info = { # optional
           version = "the package's version (no 'v' prefix)";

           dependencies = ''
             default = []
             list of package's dependencies
           '';

           src = ''
            default = "src"
            The 'src' directory from the source of the package
           '';

           install = ''
             default = "ln -s $src/${lib.escapeShellArg src} $out"
             How to install the package from the source
           '';

           # optional
           pursuit = { name = ''
                         default = config.name
                         The name of the package on Pursuit
                       '';

                       repo = "The Git repo that shows up on pursuit";
                       license = "A lib.licenses value, or something in the shape of one;
                     }
         };
}
```
# Adding Packages

## Package Set: Git

Packages are added by adding a package description attributes set to either [ps-pkgs.nix](/ps-pkgs.nix) or `namespaces/<namespace>.nix`, or by adding your package to the [official package set](https://github.com/purescript/package-sets) and [updating the generated](/official-package-set) nix.\
The packages descriptions sets consist of two parts:
```
{ src.git
, info
}
```
- `src.git`: An attrset that has `repo` and `rev` attributes, as well as an optional `ref` attribute if need be.
- `info`: `info` supports two variants. It is either a literal attrset containing the info, or an absolute path to a function that returns the info, relative to the source specified with `src`.

### Example
   ```
   # ...

   arrays =
     { src.git =
         { repo = "https://github.com/purescript/purescript-arrays.git";
           rev = "d20bae2f76db6cf29b7b75e26e82b8a54c32295e";
         };

       info =
        { version = "7.0.0";

          dependencies =
            [ "bifunctors"
              "control"
              "foldable-traversable"
              "maybe"
              "nonempty"
              "partial"
              "prelude"
              "st"
              "tailrec"
              "tuples"
              "unfoldable"
              "unsafe-coerce"
            ];
        }
     };

   is-even =
     { src.git =
         { repo = "https://github.com/purs-nix/test-packages.git";
           rev = "7e50388792dfa720e52b23219021f3c350e6bb30";
         };

       info = /is-even/package.nix;
     };

   # ...
   ```

The attributes supported by `info` are:
- `version` (without the "v" prefix)
- `dependencies` (default: `[]`)
- `foreign` (default: `{}`)
- `pursuit` (default: `{}`)
- `src` (default: `"src"`)
- `install` (default: `"ln -s $src/${src} $out"`)

All of these are optional.

## <span id="user-content-using-info">Using `info` as a path</span>
If you're using a file in for the package info, you need to make sure it's a function that accepts attribute sets of arbitrary size, either by using the `...` syntax or by not destructuring at all. This is to make sure purs-nix can call it with new arguments in the future and your package will still be compatible.\
Here's an example:
```nix
{ ps-pkgs, ... }:
  with ps-pkgs:
  { version = "6.0.0";

    dependencies =
      [ "bifunctors"
        "control"
        "foldable-traversable"
        "maybe"
        "nonempty"
        "partial"
        "prelude"
        "st"
        "tailrec"
        "tuples"
        "unfoldable"
        "unsafe-coerce"
      ];
  }
```

The arguments that are currently passed are:\
`build` `build-set` `ps-pkgs` `ps-pkgs-ns` [`licenses`](https://github.com/NixOS/nixpkgs/blob/master/lib/licenses.nix)

## <code id="user-content-build">build</code>
purs-nix exports a `build` function that can be used to add packages to your project from arbitrary sources. It takes an argument in mostly the same form as described above, but with a few differences.
- `name`: You must specify a name attribute for the package.
- `src.path`: This is another type of source you can specify for `build` (and technically the package set as well). `src.path` takes a path or derivation that points to the source of the package.

## <code id="user-content-build-set">build-set</code>
purs-nix exports a `build-set` function that can be used to add packages to your project from arbitrary sources. It is used to build the standard `ps-pkgs` package set and therefore takes an attrset in the same form shown above.

## Package Set: Flake

If your package includes foreign dependencies, the easiest way to include it in the package set is to build the package with `build`, using `src.path = ./.;` and then expose that as a package on your flake. Then you can add it to the package set by using `src.flake.url`. The `info` attribute is not used because the package is already built. If your package is not `default`, you can use `src.flake.package` and give it a string corresponding to the package name. We do it this way, instead of just using `builtins.getFlake` directly, so that this information can be collected for `purs-nix package-info`/`nix run purs-nix#package-info.<package>`.
