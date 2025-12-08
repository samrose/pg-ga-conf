defmodule PgGaConf.DataGenerator.DependencyGraphTest do
  use ExUnit.Case, async: true

  alias PgGaConf.DataGenerator.DependencyGraph

  describe "topological_sort/2" do
    test "returns tables with no FKs in any order" do
      tables = [
        %{name: "users", schema: "public"},
        %{name: "products", schema: "public"}
      ]

      foreign_keys = []

      sorted = DependencyGraph.topological_sort(tables, foreign_keys)

      assert length(sorted) == 2
      assert Enum.all?(tables, fn t -> t in sorted end)
    end

    test "orders parent before child with single FK" do
      tables = [
        %{name: "posts", schema: "public"},
        %{name: "users", schema: "public"}
      ]

      foreign_keys = [
        %{table: "posts", columns: ["user_id"], foreign_table: "users", foreign_columns: ["id"]}
      ]

      sorted = DependencyGraph.topological_sort(tables, foreign_keys)

      users_idx = Enum.find_index(sorted, &(&1.name == "users"))
      posts_idx = Enum.find_index(sorted, &(&1.name == "posts"))

      assert users_idx < posts_idx, "users should come before posts"
    end

    test "handles chain of dependencies" do
      tables = [
        %{name: "comments", schema: "public"},
        %{name: "posts", schema: "public"},
        %{name: "users", schema: "public"}
      ]

      foreign_keys = [
        %{table: "posts", columns: ["user_id"], foreign_table: "users", foreign_columns: ["id"]},
        %{table: "comments", columns: ["post_id"], foreign_table: "posts", foreign_columns: ["id"]}
      ]

      sorted = DependencyGraph.topological_sort(tables, foreign_keys)

      users_idx = Enum.find_index(sorted, &(&1.name == "users"))
      posts_idx = Enum.find_index(sorted, &(&1.name == "posts"))
      comments_idx = Enum.find_index(sorted, &(&1.name == "comments"))

      assert users_idx < posts_idx, "users should come before posts"
      assert posts_idx < comments_idx, "posts should come before comments"
    end

    test "handles multiple parents" do
      tables = [
        %{name: "order_items", schema: "public"},
        %{name: "orders", schema: "public"},
        %{name: "products", schema: "public"}
      ]

      foreign_keys = [
        %{table: "order_items", columns: ["order_id"], foreign_table: "orders", foreign_columns: ["id"]},
        %{table: "order_items", columns: ["product_id"], foreign_table: "products", foreign_columns: ["id"]}
      ]

      sorted = DependencyGraph.topological_sort(tables, foreign_keys)

      orders_idx = Enum.find_index(sorted, &(&1.name == "orders"))
      products_idx = Enum.find_index(sorted, &(&1.name == "products"))
      items_idx = Enum.find_index(sorted, &(&1.name == "order_items"))

      assert orders_idx < items_idx, "orders should come before order_items"
      assert products_idx < items_idx, "products should come before order_items"
    end

    test "detects circular dependency" do
      tables = [
        %{name: "a", schema: "public"},
        %{name: "b", schema: "public"}
      ]

      foreign_keys = [
        %{table: "a", columns: ["b_id"], foreign_table: "b", foreign_columns: ["id"]},
        %{table: "b", columns: ["a_id"], foreign_table: "a", foreign_columns: ["id"]}
      ]

      assert {:error, :circular_dependency} = DependencyGraph.topological_sort(tables, foreign_keys)
    end

    test "handles self-referencing FK" do
      tables = [
        %{name: "categories", schema: "public"}
      ]

      foreign_keys = [
        %{table: "categories", columns: ["parent_id"], foreign_table: "categories", foreign_columns: ["id"]}
      ]

      sorted = DependencyGraph.topological_sort(tables, foreign_keys)

      # Self-reference doesn't affect order, table should still be included
      assert length(sorted) == 1
      assert hd(sorted).name == "categories"
    end
  end

  describe "build_graph/2" do
    test "builds adjacency list from FKs" do
      tables = [
        %{name: "posts", schema: "public"},
        %{name: "users", schema: "public"}
      ]

      foreign_keys = [
        %{table: "posts", columns: ["user_id"], foreign_table: "users", foreign_columns: ["id"]}
      ]

      graph = DependencyGraph.build_graph(tables, foreign_keys)

      assert Map.has_key?(graph, "users")
      assert Map.has_key?(graph, "posts")
      assert "posts" in graph["users"]  # users -> posts (posts depends on users)
      assert graph["posts"] == []
    end
  end
end
