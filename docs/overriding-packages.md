# Overriding Packages
To override a package the package set, simply add a package with the same name to your dependencies.

```nix
let
  prelude-override =
    purs-nix.build
      { name = "prelude";
        src.path = /home/me/my-prelude;
        info = /package.nix;
      };
in
purs-nix.purs
  { dependencies =
      with purs-nix.ps-pkgs;
      [ console
        effect
        prelude-override
      ];
  }
```
