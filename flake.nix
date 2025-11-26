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
        beam = pkgs.beam.packagesWith pkgs.beam.interpreters.erlang_26;
        elixir = beam.elixir_1_16;

        # PostgreSQL for local development
        postgresql = pkgs.postgresql_15;

      in {
        # Development shell
        devShells.default = pkgs.mkShell {
          buildInputs = [
            elixir
            postgresql
            pkgs.git
            pkgs.docker
            pkgs.curl
            pkgs.jq
          ];

          shellHook = ''
            # Set up PostgreSQL data directory
            export PGDATA="$PWD/.postgres"
            export PGHOST="localhost"
            export PGPORT=5432
            export DATABASE_URL="postgresql://postgres@localhost:5432/pgga_dev"

            # Initialize PostgreSQL if needed
            if [ ! -d "$PGDATA" ]; then
              echo "Initializing PostgreSQL database..."
              initdb -U postgres --no-locale --encoding=UTF8
              echo "unix_socket_directories = '$PGDATA'" >> "$PGDATA/postgresql.conf"
              echo "listen_addresses = 'localhost'" >> "$PGDATA/postgresql.conf"

              # Start postgres temporarily to set up
              pg_ctl start -l "$PGDATA/logfile" -o "-c unix_socket_directories=$PGDATA"
              sleep 2

              # Create development database
              createdb -h localhost -U postgres pgga_dev

              # Enable required extensions
              psql -h localhost -U postgres -d pgga_dev -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"

              pg_ctl stop
            fi

            echo "PostgreSQL ready. Commands:"
            echo "  pg_start     - Start PostgreSQL"
            echo "  pg_stop      - Stop PostgreSQL"
            echo "  pg_connect   - Connect to dev database"
            echo ""
            echo "Elixir commands:"
            echo "  mix deps.get - Install dependencies"
            echo "  mix test     - Run tests"
            echo "  iex -S mix   - Start interactive shell"

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
