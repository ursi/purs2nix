# Creating Derivations

You can use **purs-nix** to make a derivations for your PureScript bundle, your compiler output, and to make executables. They all use incremental compiling, so you don't have you recompile your entire project every time you make a small change.

## modules

You access these derivations via the [modules](./purs-nix.md#user-content-purs-modules) attribute set, using the name of your module as the attribute.

NOTE: If the module name contains a `.`, it will require quotation marks around its name (e.g. `modules."Foo.Bar.Main".bundle`)

There are four different attributes for each module.

### output
```nix
{ verbose-errors ? false
, comments ? false
, codegen ? null
, no-prefix ? false
, json-errors ? false

, incremental ? false
}
```

- `incremental`: Whether or not to build the modules incrementally. This will almost certainly cause your build times to be slower, but may give some improvements when iterating on certain modules in very large projects.
Note: turning this off will not disable the separate compiling of dependencies.

The upper options correspond to the flags you can pass `purs compile`.

`modules.Module.output {}` is a derivation containing the compiler output for all your project's dependencies plus all of `Module`'s local dependencies.

### bundle

```nix
{ esbuild # additional esbuild flags
  ? { format ? "esm"
    , log-level ? "warning"
    , outfile ? "main.js"
    }
, main ? true
, incremental ? false
}

```

- `main`: whether or not to automatically execute the main function of the module you're bundling.
- `incremental`: whether or not to build the modules incrementally. This will almost certainly cause your build times to be slower, but may give some improvements when iterating on certain modules in very large projects.
Note: turning this off will not disable the separate compiling of dependencies.

`modules.Module.bundle {}` is a derivation containing the bundled code of the module `Module`.

### script

```nix
{ esbuild ? { minify ? true; }
, incremental ? false
}
```
- `esbuild`: Arguments to pass to `esbuild` when bundling.
- `incremental`: Whether or not to build the modules incrementally. This will almost certainly cause your build times to be slower, but may give some improvements when iterating on certain modules in very large projects.
Note: turning this off will not disable the separate compiling of dependencies.

- `incremental`: Whether or not to build the modules incrementally. This will almost certainly cause your build times to be slower, but may give some improvements when iterating on certain modules

`modules.Module.script {}` is a derivation that is an executable that will run the `main` `Effect` of the module `Module`.

### app

```nix
{ name
, version ? null
, command ? name
, esbuild ? { minify ? true; }
, incremental ? false
}
```
- `name`: The `pname`/`name` of the derivation.
- `version`: The version of the derivation.
- `command`: The name of the executable.
- `esbuild`: Arguments to pass to `esbuild` when bundling.
- `incremental`: Whether or not to build the modules incrementally. This will almost certainly cause your build times to be slower, but may give some improvements when iterating on certain modules in very large projects.
Note: turning this off will not disable the separate compiling of dependencies.

`modules.Module.app { name = "my-command"; version = "1.0.0"; }` is a derivation containing an executable at `bin/my-command` that will execute the `main` `Effect` of the module `Module`.

## test

You access these derivations via the [test](./purs-nix.md#user-content-purs-test) attribute.


### run

`test.run {}` returns an executable that runs your test module's `main` function with Node.js. It takes the same arguments as [output](#output).

### check

`test.check {}` Is a derivation that runs `test.run`. It's a convenience function for adding your tests as a Nix flake check. It takes the same arguments as [output](#output).
