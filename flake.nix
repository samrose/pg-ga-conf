{
  description = "PostgreSQL Genetic Algorithm Configuration Optimizer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Elixir and Erlang versions
        erlang = pkgs.beam.interpreters.erlang_27;
        beam = pkgs.beam.packagesWith erlang;
        elixir = beam.elixir_1_18;
        rebar3 = beam.rebar3;

        # PostgreSQL for local development
        postgresql = pkgs.postgresql_15;

        # Julia for Sobol sensitivity analysis
        julia = pkgs.julia-bin;

      in {
        # Development shell
        devShells.default = pkgs.mkShell {
          buildInputs = [
            erlang
            elixir
            rebar3
            postgresql
            julia
            pkgs.git
            pkgs.docker
            pkgs.curl
            pkgs.jq
            pkgs.python311  # For Pythonx
            pkgs.gcc        # For erlexec native compilation
            pkgs.gnumake    # For erlexec native compilation
          ];

          shellHook = ''
            # =====================================================
            # TWO-DATABASE ARCHITECTURE
            # =====================================================
            # App DB (port 5432): Stores tuning sessions, results, cache
            #                    NEVER restarted during tuning
            # Target DB (port 5433): The database being tuned/benchmarked
            #                        Restarted when testing restart-required params
            # =====================================================

            # App database (for application state - never restarted)
            export PGDATA_APP="$PWD/.postgres-app"
            export PGPORT_APP=5432
            export DATABASE_URL="postgresql://postgres@localhost:5432/pgga_dev"

            # Target database (for tuning/benchmarks - may be restarted)
            export PGDATA_TARGET="$PWD/.postgres-target"
            export PGPORT_TARGET=5433
            export TARGET_DATABASE_URL="postgresql://postgres@localhost:5433/pgga_target"

            # Legacy exports for compatibility
            export PGDATA="$PGDATA_APP"
            export PGHOST="localhost"
            export PGPORT=5432

            # Elixir/Mix paths
            export MIX_HOME="$PWD/.nix-mix"
            export HEX_HOME="$PWD/.nix-hex"

            # Julia project path
            export JULIA_PROJECT="$PWD/priv/julia"
            export JULIA_SERVICE_MODE="local"

            # Initialize App PostgreSQL if needed (port 5432)
            if [ ! -d "$PGDATA_APP" ]; then
              echo "Initializing App PostgreSQL (port 5432)..."
              initdb -D "$PGDATA_APP" -U postgres --no-locale --encoding=UTF8
              echo "unix_socket_directories = '$PGDATA_APP'" >> "$PGDATA_APP/postgresql.conf"
              echo "listen_addresses = 'localhost'" >> "$PGDATA_APP/postgresql.conf"
              echo "port = 5432" >> "$PGDATA_APP/postgresql.conf"

              # Start app postgres temporarily to set up
              pg_ctl -D "$PGDATA_APP" start -l "$PGDATA_APP/logfile" -o "-c unix_socket_directories=$PGDATA_APP"
              sleep 2

              # Create development database
              createdb -h localhost -p 5432 -U postgres pgga_dev

              pg_ctl -D "$PGDATA_APP" stop
            fi

            # Initialize Target PostgreSQL if needed (port 5433)
            if [ ! -d "$PGDATA_TARGET" ]; then
              echo "Initializing Target PostgreSQL (port 5433)..."
              initdb -D "$PGDATA_TARGET" -U postgres --no-locale --encoding=UTF8
              echo "unix_socket_directories = '$PGDATA_TARGET'" >> "$PGDATA_TARGET/postgresql.conf"
              echo "listen_addresses = 'localhost'" >> "$PGDATA_TARGET/postgresql.conf"
              echo "port = 5433" >> "$PGDATA_TARGET/postgresql.conf"
              echo "shared_preload_libraries = 'pg_stat_statements'" >> "$PGDATA_TARGET/postgresql.conf"

              # Start target postgres temporarily to set up
              pg_ctl -D "$PGDATA_TARGET" start -l "$PGDATA_TARGET/logfile" -o "-c unix_socket_directories=$PGDATA_TARGET"
              sleep 2

              # Create target database
              createdb -h localhost -p 5433 -U postgres pgga_target

              # Enable required extensions
              psql -h localhost -p 5433 -U postgres -d pgga_target -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"

              pg_ctl -D "$PGDATA_TARGET" stop
            fi

            # Initialize Julia project if needed
            if [ ! -f "$JULIA_PROJECT/Manifest.toml" ] && [ -f "$JULIA_PROJECT/Project.toml" ]; then
              echo "Installing Julia dependencies..."
              julia --project="$JULIA_PROJECT" -e 'using Pkg; Pkg.instantiate()'
            fi

            echo ""
            echo "=== Two-Database Architecture ==="
            echo "  App DB (port 5432):    For application state (never restarted)"
            echo "  Target DB (port 5433): For tuning benchmarks (may be restarted)"
            echo ""
            echo "PostgreSQL commands:"
            echo "  pg_start_all    - Start both databases"
            echo "  pg_stop_all     - Stop both databases"
            echo "  pg_start_app    - Start app database only"
            echo "  pg_start_target - Start target database only"
            echo "  pg_stop_target  - Stop target database only"
            echo "  pg_connect      - Connect to app database"
            echo "  pg_connect_target - Connect to target database"
            echo ""
            echo "Elixir commands:"
            echo "  mix deps.get - Install dependencies"
            echo "  mix test     - Run tests"
            echo "  iex -S mix   - Start interactive shell"
            echo ""
            echo "Julia commands:"
            echo "  julia --project=priv/julia - Start Julia REPL"

            # Helper functions for App DB (port 5432)
            pg_start_app() {
              echo "Starting App PostgreSQL on port 5432..."
              pg_ctl -D "$PGDATA_APP" start -l "$PGDATA_APP/logfile" -o "-c unix_socket_directories=$PGDATA_APP"
            }

            pg_stop_app() {
              echo "Stopping App PostgreSQL..."
              pg_ctl -D "$PGDATA_APP" stop
            }

            # Helper functions for Target DB (port 5433)
            pg_start_target() {
              echo "Starting Target PostgreSQL on port 5433..."
              pg_ctl -D "$PGDATA_TARGET" start -l "$PGDATA_TARGET/logfile" -o "-c unix_socket_directories=$PGDATA_TARGET"
            }

            pg_stop_target() {
              echo "Stopping Target PostgreSQL..."
              pg_ctl -D "$PGDATA_TARGET" stop
            }

            pg_restart_target() {
              echo "Restarting Target PostgreSQL..."
              pg_ctl -D "$PGDATA_TARGET" restart -l "$PGDATA_TARGET/logfile"
            }

            # Combined helpers
            pg_start_all() {
              pg_start_app
              pg_start_target
            }

            pg_stop_all() {
              pg_stop_target
              pg_stop_app
            }

            # Legacy aliases
            pg_start() {
              pg_start_all
            }

            pg_stop() {
              pg_stop_all
            }

            pg_connect() {
              psql -h localhost -p 5432 -U postgres pgga_dev
            }

            pg_connect_target() {
              psql -h localhost -p 5433 -U postgres pgga_target
            }

            export -f pg_start_app pg_stop_app pg_start_target pg_stop_target pg_restart_target
            export -f pg_start_all pg_stop_all pg_start pg_stop pg_connect pg_connect_target
          '';
        };

        # Flake apps for different operations
        apps = {
          # Quick development mode
          dev = {
            type = "app";
            program = toString (pkgs.writeShellScript "pg-ga-dev" ''
              export PGDATA="$PWD/.postgres"

              if [ ! -d "$PGDATA" ]; then
                echo "Setting up development environment..."
                ${postgresql}/bin/initdb -U postgres --no-locale --encoding=UTF8
                echo "unix_socket_directories = '$PGDATA'" >> "$PGDATA/postgresql.conf"
              fi

              ${postgresql}/bin/pg_ctl start -l "$PGDATA/logfile" -o "-c unix_socket_directories=$PGDATA"

              echo "PostgreSQL started. Press Ctrl+C to stop"

              # Cleanup on exit
              trap "${postgresql}/bin/pg_ctl stop" EXIT

              # Keep running
              tail -f "$PGDATA/logfile"
            '');
          };
        };
      }
    );
}
