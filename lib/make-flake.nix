nixpkgs:
{ inputs }:
let
  inherit (inputs) self;

  each-system = systems: definition:
    let
      hoisted = system: builtins.mapAttrs (n: v: { ${system} = v; }) (definition system);
      allSystems = builtins.map hoisted systems;
    in
      builtins.zipAttrsWith (
        name: values:
        builtins.foldl' (p: n: p // n) {} values
      ) allSystems;

  pyproject = builtins.fromTOML (builtins.readFile "${self}/pyproject.toml");

  pythonVersion = pyproject.tool.pyproject-nix.defaults.python;
  module-remap = pyproject.tool.pyproject-nix.remap;

  ifHasWith = default: path: source: func:
    let
      segments = nixpkgs.lib.splitString "." path;
      final = (builtins.foldl' (p: n: 
        let
          evaluated = p (i: i);
        in
        if p == null then
          null
        else
          if builtins.hasAttr n evaluated then
            (f: f evaluated.${n})
          else
            null
      ) (f: f source) segments);
    in
    if final == null then
      default
    else
      final func;

  ifHas = ifHasWith {};

  combineFragments = builtins.foldl' (p: n: p // n) {};

  clean-dependencies = dep-list:
    let
      cleaned = builtins.map (entry:
        let
          base = builtins.match ''^([^<>=~! ]+).*$'' entry;
        in
          if base == null then "" else builtins.elemAt base 0
      ) dep-list;
    
      # Filter out empty results
      filtered = builtins.filter (x: x != "") cleaned;

      normList = builtins.map (n: if builtins.hasAttr n module-remap then module-remap.${n} else [n]) filtered;
    in
    builtins.foldl' (p: n: p ++ n) [] normList;
      
  combineDependencies = builtins.foldl' (p: n: p ++ n) [];

  optionNames = ifHasWith [] "project.optional-dependencies" pyproject (builtins.attrNames);

  defaultDependencies = ifHasWith [] "project.dependencies" pyproject (i: i);
  defaultOptionNames = ifHasWith optionNames "tool.pyproject-nix.defaults.extras" pyproject (i: i);
  testOptionNames = ifHasWith optionNames "tool.pyproject-nix.test-extras" pyproject (i: i);

  pythonPackages = options: 
    combineDependencies ([(clean-dependencies defaultDependencies)] ++ (builtins.map (name: clean-dependencies pyproject.project.optional-dependencies.${name}) options));

  withPyPackages = names: ps: builtins.map (pkg: ps.${pkg}) names;

  specific = each-system pyproject.tool.pyproject-nix.systems (system:
    let 
      python = pkgs.${pythonVersion};
      pkgs = nixpkgs.legacyPackages.${system}; 
    in 
    combineFragments [
      ({
        devShells.default = 
          let
            packagedPython = python.withPackages (withPyPackages ((pythonPackages optionNames) ++ (ifHasWith [] "tool.pyproject-nix.console-dependencies" pyproject (v: clean-dependencies v))));
            scripts = pkgs.symlinkJoin {
              name = pyproject.project.name;
              paths = (ifHasWith [] "project.scripts" pyproject (scripts: nixpkgs.lib.mapAttrsToList (k: v: pkgs.writeShellScriptBin k ''
                ENTRY="${v}";
                MODULE="''${ENTRY%%:*}"
                FUNC="''${ENTRY##*:}"
                exec ${packagedPython}/bin/python -c "import sys, importlib; sys.argv[0] = '${k}'; getattr(importlib.import_module('$MODULE'), '$FUNC')(); sys.exit(0)" "$@"
              '') pyproject.project.scripts));
            };
          in
          pkgs.mkShell {
            inherit scripts;
            python = packagedPython;
            buildInputs = [ 
              packagedPython
              scripts
            ];
          };

        packages.default = (import nixpkgs { inherit system; overlays = [ self.overlays.default ]; }).${pythonVersion}.pkgs.${pyproject.project.name};
      })

      # build apps = { default = apps.${system}.[defaults.script]; ... = package/bin/${script} };
      (ifHas "project.scripts" pyproject (value: {
        apps = (combineFragments [
          (nixpkgs.lib.mapAttrs (k: v: {
            type = "app";
            program = "${self.packages.${system}.default}/bin/${k}";
          }) value)

          (ifHas "tool.pyproject-nix.defaults.script" pyproject (v: {
            default = self.apps.${system}.${v};
          }))
        ]);
      }))
    ]
  );

  unspecific = combineFragments [
    ({
      overlays.default =
        final: prev:
        {
          pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
            (
              python-final: python-prev: {
                ${pyproject.project.name} = 
                  let
                    capitalize = name: (nixpkgs.lib.toUpper (builtins.substring 0 1 name)) + (builtins.substring 1 ((builtins.stringLength name)+1) name);

                    buildDefaultExtraList =
                      builtins.listToAttrs (map (name: {
                        name = "enable${capitalize name}";
                        value = builtins.elem name defaultOptionNames;
                      }) optionNames);

                    extraMapToList =
                      functionArgs:
                      let
                        actualMap = builtins.intersectAttrs buildDefaultExtraList functionArgs;
                        rawList = 
                          builtins.map (name:
                            if actualMap."enable${capitalize name}" then
                              name
                            else 
                              null
                          ) optionNames;
                      in
                      builtins.filter (v: v != null) rawList;


                    buildDeps = clean-dependencies pyproject.build-system.requires;
                    rawAllDependencies = builtins.listToAttrs (map (pkg: {name = pkg; value = "none";}) ((pythonPackages optionNames) ++ (buildDeps)));
                    defaultDependencies = builtins.intersectAttrs rawAllDependencies python-final;

                    package =
                      dynamicAttributeList:
                      let
                        extras = extraMapToList dynamicAttributeList;
                        dependencies = defaultDependencies // (builtins.intersectAttrs rawAllDependencies dynamicAttributeList);
                        extractDeps = builtins.map (pkg: dependencies.${pkg});

                        build-system = extractDeps buildDeps;
                      in
                      python-final.buildPythonPackage (combineFragments [
                        ({
                          format = "pyproject";
                          inherit (pyproject.project) name;
                          pversion = pyproject.project.version;

                          src = "${self}";
                          build-system = build-system;
                          dependencies = build-system ++ (extractDeps (pythonPackages extras));

                          nativeCheckInputs = extractDeps (pythonPackages testOptionNames);

                          meta = combineFragments [
                            ({
                              platforms = pyproject.tool.pyproject-nix.systems;
                              sourceProvenance = [ final.lib.sourceTypes.fromSource ];
                            })
                            (ifHas "project.description" pyproject (description: {inherit description;}))
                            (ifHas "project.url" pyproject (homepage: {inherit homepage;}))
                            (ifHas "tool.pyproject-nix.license" pyproject (license: { license = final.lib.licenses.${license}; }))
                            (ifHas "tool.pyproject-nix.defaults.script" pyproject (mainProgram: { inherit mainProgram; }))
                            (ifHas "project.authors" pyproject (maintainers: { inherit maintainers; }))
                          ];
                        })

                        (ifHas "tool.pyproject-nix.disabledTests" pyproject (tests: { disabledTests = tests; }))
                      ]);
                  in
                  nixpkgs.lib.makeOverridable package (defaultDependencies // buildDefaultExtraList);
              }
            )
          ];
        };
    })

    (ifHas "tool.pyproject-nix.modules" pyproject (value: combineFragments [
      ({
        nixosModules = combineFragments [
          (nixpkgs.lib.mapAttrs (k: v: 
            import "${self}/${v}" { inherit self inputs; }
          ) pyproject.tool.pyproject-nix.modules)

          (ifHas "tool.pyproject-nix.defaults.module" pyproject (value: {
            default = self.nixosModules.${value};
          }))
        ];
      })

      (ifHas "tool.pyproject-nix.defaults.module" pyproject (value: {
        nixosModule = self.nixosModules.default;
      }))
    ]))
  ];
in
  specific // unspecific;
