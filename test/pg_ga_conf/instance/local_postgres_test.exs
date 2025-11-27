defmodule PgGaConf.Instance.LocalPostgresTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias PgGaConf.Instance.LocalPostgres
  alias PgGaConf.Core.ConfigChromosome

  describe "start_instance/1" do
    test "returns connection info for local PostgreSQL" do
      chromosome = ConfigChromosome.new(%{shared_buffers: 1000})

      assert {:ok, conn_info} = LocalPostgres.start_instance(chromosome)
      assert is_map(conn_info)
      assert conn_info.hostname == "localhost"
      assert conn_info.port == 5432
      assert conn_info.username == "postgres"
      assert conn_info.database == "pgga_test"
    end

    test "connection info can be used to connect" do
      chromosome = ConfigChromosome.new(%{shared_buffers: 1000})

      {:ok, conn_info} = LocalPostgres.start_instance(chromosome)

      # Test that we can actually connect with this info
      {:ok, conn} =
        Postgrex.start_link(
          hostname: conn_info.hostname,
          port: conn_info.port,
          username: conn_info.username,
          database: conn_info.database
        )

      assert Process.alive?(conn)
      GenServer.stop(conn)
    end
  end

  describe "stop_instance/1" do
    test "accepts instance id and returns :ok" do
      {:ok, conn_info} = LocalPostgres.start_instance(ConfigChromosome.new())

      assert :ok = LocalPostgres.stop_instance(conn_info.instance_id)
    end
  end

  describe "apply_config/2" do
    test "returns :ok (config application is a no-op for local)" do
      chromosome = ConfigChromosome.new(%{shared_buffers: 1000})

      {:ok, conn_info} = LocalPostgres.start_instance(chromosome)

      # For local postgres, applying config is informational only
      # We can't actually restart the instance without sudo/systemctl
      assert :ok = LocalPostgres.apply_config(conn_info.instance_id, chromosome)
    end
  end
end
