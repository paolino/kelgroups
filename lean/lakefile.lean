import Lake
open Lake DSL

package kelgroups where
  leanOptions := #[
    ⟨`autoImplicit, false⟩
  ]

@[default_target]
lean_lib KelGroups where
  srcDir := "."
