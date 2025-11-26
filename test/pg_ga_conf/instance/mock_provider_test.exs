defmodule PgGaConf.Instance.MockProviderTest do
  use ExUnit.Case, async: true

  alias PgGaConf.Instance.MockProvider
  alias PgGaConf.Core.ConfigChromosome

  describe "start_instance/1" do
    test "returns mock connection info" do
      chromosome = ConfigChromosome.new(%{shared_buffers: 1000})

      assert {:ok, conn_info} = MockProvider.start_instance(chromosome)
      assert is_map(conn_info)
      assert conn_info.hostname == "mock-host"
      assert conn_info.port == 5432
      assert conn_info.username == "mock-user"
      assert conn_info.database == "mock-db"
      assert is_binary(conn_info.instance_id)
    end

    test "generates unique instance IDs" do
      {:ok, conn_info1} = MockProvider.start_instance(ConfigChromosome.new())
      {:ok, conn_info2} = MockProvider.start_instance(ConfigChromosome.new())

      assert conn_info1.instance_id != conn_info2.instance_id
    end
  end

  describe "stop_instance/1" do
    test "accepts instance id and returns :ok" do
      {:ok, conn_info} = MockProvider.start_instance(ConfigChromosome.new())

      assert :ok = MockProvider.stop_instance(conn_info.instance_id)
    end

    test "can stop the same instance multiple times" do
      {:ok, conn_info} = MockProvider.start_instance(ConfigChromosome.new())

      assert :ok = MockProvider.stop_instance(conn_info.instance_id)
      assert :ok = MockProvider.stop_instance(conn_info.instance_id)
    end
  end

  describe "apply_config/2" do
    test "accepts config and returns :ok" do
      chromosome = ConfigChromosome.new(%{shared_buffers: 1000})
      {:ok, conn_info} = MockProvider.start_instance(chromosome)

      assert :ok = MockProvider.apply_config(conn_info.instance_id, chromosome)
    end
  end
end
