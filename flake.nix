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
            # Set up PostgreSQL data directory
            export PGDATA="$PWD/.postgres"
            export PGHOST="localhost"
            export PGPORT=5432
            export DATABASE_URL="postgresql://postgres@localhost:5432/pgga_dev"

            # Elixir/Mix paths
            export MIX_HOME="$PWD/.nix-mix"
            export HEX_HOME="$PWD/.nix-hex"

            # Julia project path
            export JULIA_PROJECT="$PWD/priv/julia"
            export JULIA_SERVICE_MODE="local"

            # Initialize PostgreSQL if needed
            if [ ! -d "$PGDATA" ]; then
              echo "Initializing PostgreSQL database..."
              initdb -U postgres --no-locale --encoding=UTF8
              echo "unix_socket_directories = '$PGDATA'" >> "$PGDATA/postgresql.conf"
              echo "listen_addresses = 'localhost'" >> "$PGDATA/postgresql.conf"
              echo "shared_preload_libraries = 'pg_stat_statements'" >> "$PGDATA/postgresql.conf"

              # Start postgres temporarily to set up
              pg_ctl start -l "$PGDATA/logfile" -o "-c unix_socket_directories=$PGDATA"
              sleep 2

              # Create development database
              createdb -h localhost -U postgres pgga_dev

              # Enable required extensions
              psql -h localhost -U postgres -d pgga_dev -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"

              pg_ctl stop
            fi

            # Initialize Julia project if needed
            if [ ! -f "$JULIA_PROJECT/Manifest.toml" ] && [ -f "$JULIA_PROJECT/Project.toml" ]; then
              echo "Installing Julia dependencies..."
              julia --project="$JULIA_PROJECT" -e 'using Pkg; Pkg.instantiate()'
            fi

            echo ""
            echo "PostgreSQL commands:"
            echo "  pg_start     - Start PostgreSQL"
            echo "  pg_stop      - Stop PostgreSQL"
            echo "  pg_connect   - Connect to dev database"
            echo ""
            echo "Elixir commands:"
            echo "  mix deps.get - Install dependencies"
            echo "  mix test     - Run tests"
            echo "  iex -S mix   - Start interactive shell"
            echo ""
            echo "Julia commands:"
            echo "  julia --project=priv/julia - Start Julia REPL"

            # Helper functions
            pg_start() {
              pg_ctl start -l "$PGDATA/logfile" -o "-c unix_socket_directories=$PGDATA"
            }

            pg_stop() {
              pg_ctl stop
            }

            pg_connect() {
              psql -h localhost -U postgres pgga_dev
            }

            export -f pg_start pg_stop pg_connect
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
