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

-- `Run` IS THE EXE'S ROOT AND MUST NOT ALSO BE A LIB ROOT. Both targets
-- are default targets, so listing it twice had lake compiling the same
-- module to the same `.olean` from two jobs at once: a race that failed
-- the build roughly one run in three with a bare "Some required builds
-- logged failures: - Run", and passed on the retry because the artifact
-- was then already there. The exe covers `Run`; the lib covers the two
-- modules `Run` imports, so nothing goes uncompiled either way.
@[default_target]
lean_lib Test where
  srcDir := "test"
  roots := #[`Corpus, `Driver]

@[default_target]
lean_exe run where
  root := `Run
  srcDir := "test"
