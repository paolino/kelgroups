# Build all packages
build:
    cabal build all -O0

# Run tests
test:
    cabal test all -O0 --test-show-details=direct

# Format Haskell sources
format:
    fourmolu -i lib/**/*.hs

# Lint Haskell sources
lint:
    hlint lib/

# Format cabal file
cabal-fmt:
    cabal-fmt -i kelgroups.cabal

# Build Lean proofs
lean:
    cd lean && lake build

# Full CI check
ci: format cabal-fmt lint build lean

# Build documentation
docs:
    mkdocs build --config-file docs/mkdocs.yml

# Clean build artifacts
clean:
    cabal clean
    cd lean && lake clean
