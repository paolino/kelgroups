# Build all packages
build:
    cabal build all -O0

# Run tests
test:
    cabal test all -O0 --test-show-details=direct

# Format Haskell sources
format:
    fourmolu -i lib/**/*.hs test/*.hs app/*.hs

# Lint Haskell sources
lint:
    hlint lib/

# Format cabal file
cabal-fmt:
    cabal-fmt -i kelgroups.cabal

# Build Lean proofs
lean:
    cd lean && lake build

# Build PureScript client
build-client:
    cd client && npm install && spago build

# Bundle PureScript client
bundle-client:
    cd client && spago bundle -p kelgroups-trivial

# Format PureScript sources
format-client:
    cd client && purs-tidy format-in-place "kelgroups-client/src/**/*.purs" "kelgroups-trivial/src/**/*.purs"

# Lint PureScript sources
lint-client:
    cd client && spago build

# Test PureScript client
test-client:
    cd client && spago test -p kelgroups-client

# Run the client end-to-end suite against the server at url (an empty url fails)
e2e-client-against url:
    cd client && KELGROUPS_SUITE=e2e KELGROUPS_URL="{{url}}" spago test -p kelgroups-client

# Run the client end-to-end suite against a kelgroups-server it starts on a new
# database (on a free port, or on $E2E_CLIENT_PORT); it fails unless the socket
# listening on that port belongs to the server it started
e2e-client:
    #!/usr/bin/env bash
    set -euo pipefail
    cabal build -O0 exe:kelgroups-server
    bin=$(cabal list-bin -O0 exe:kelgroups-server)
    port="${E2E_CLIENT_PORT:-}"
    if [ -z "$port" ]; then
        port=$(node -e 'const s = require("net").createServer(); s.listen(0, "127.0.0.1", () => { console.log(s.address().port); s.close(); })')
    fi
    listening() {
        awk -v p="$(printf ':%04X' "$port")" \
            '$4 == "0A" && substr($2, length($2) - 4) == p { print $10 }' \
            /proc/net/tcp /proc/net/tcp6 2>/dev/null
    }
    if [ -n "$(listening)" ]; then
        echo "e2e-client: port $port is already in use" >&2
        exit 1
    fi
    dir=$(mktemp -d)
    "$bin" "$port" "$dir/e2e.db" > "$dir/server.log" 2>&1 &
    pid=$!
    trap 'kill "$pid" 2>/dev/null || true; rm -rf "$dir"' EXIT
    owned=""
    for _ in $(seq 1 200); do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "e2e-client: the server exited" >&2
            cat "$dir/server.log" >&2
            exit 1
        fi
        for inode in $(listening); do
            if ls -l "/proc/$pid/fd" 2>/dev/null | grep -q "socket:\[$inode\]"; then
                owned=yes
            fi
        done
        if [ -n "$owned" ]; then break; fi
        sleep 0.1
    done
    if [ -z "$owned" ] || [ ! -f "$dir/e2e.db" ]; then
        echo "e2e-client: port $port is not served by the server started on $dir/e2e.db" >&2
        exit 1
    fi
    just e2e-client-against "http://127.0.0.1:$port"

# Full CI check
ci: format cabal-fmt lint build test lean build-client test-client e2e-client

# Build documentation
docs:
    mkdocs build --config-file docs/mkdocs.yml

# Run the server (with static file serving)
serve port="8080" db="kelgroups.db": bundle-client
    cabal run kelgroups-server -O0 -- {{port}} {{db}}

# Restart the server (rebundle + relaunch)
restart port="8080" db="kelgroups.db": bundle-client
    -pkill -f "kelgroups-server"
    cabal run kelgroups-server -O0 -- {{port}} {{db}}

# Clean build artifacts
clean:
    cabal clean
    cd lean && lake clean
    cd client && rm -rf .spago output node_modules
