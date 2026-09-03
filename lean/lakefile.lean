import Lake
open Lake DSL

package plugin

-- NO `require`. §16 permits exactly one runtime dependency
-- (voxgig/struct) and Lean has no port of it, so this package fetches
-- nothing and `lake build` never touches the network.

-- BOTH LIBRARIES ARE DEFAULT TARGETS, and `roots` names every module.
-- Lake builds only what a target's import graph reaches, so a module
-- nothing imports reports no errors because it is never compiled at
-- all — which is how fifteen modules in this port sat "green" without
-- having been looked at once.
@[default_target]
lean_lib Plugin where
  srcDir := "src"

@[default_target]
lean_lib Test where
  srcDir := "test"
  roots := #[`Corpus, `Driver, `Run]

@[default_target]
lean_exe run where
  root := `Run
  srcDir := "test"
