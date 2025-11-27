defmodule PgGaConf.DataGenerator.DependencyGraph do
  @moduledoc """
  Builds dependency graph from foreign keys and provides topological sort
  for determining table generation order.
  """

  @doc """
  Topologically sorts tables based on foreign key dependencies.
  Returns tables ordered so that parent tables come before child tables.

  Returns `{:error, :circular_dependency}` if a cycle is detected.
  """
  def topological_sort(tables, foreign_keys) do
    graph = build_graph(tables, foreign_keys)
    table_names = Enum.map(tables, & &1.name)
    tables_by_name = Map.new(tables, &{&1.name, &1})

    case kahn_sort(graph, table_names) do
      {:ok, sorted_names} ->
        Enum.map(sorted_names, &Map.fetch!(tables_by_name, &1))

      {:error, :circular_dependency} = error ->
        error
    end
  end

  @doc """
  Builds an adjacency list representing dependencies.
  For each table, lists the tables that depend on it (children).

  Example: If posts has FK to users, graph["users"] contains "posts"
  """
  def build_graph(tables, foreign_keys) do
    # Initialize all tables with empty dependency lists
    initial = Map.new(tables, fn t -> {t.name, []} end)

    # Add edges from parent -> child
    Enum.reduce(foreign_keys, initial, fn fk, acc ->
      parent = fk.foreign_table
      child = fk.table

      # Skip self-referencing FKs
      if parent == child do
        acc
      else
        # Parent points to child (child depends on parent)
        Map.update(acc, parent, [child], fn children ->
          if child in children, do: children, else: [child | children]
        end)
      end
    end)
  end

  # Kahn's algorithm for topological sort
  defp kahn_sort(graph, table_names) do
    # Calculate in-degrees (number of dependencies for each table)
    in_degrees = calculate_in_degrees(graph, table_names)

    # Start with tables that have no dependencies (in-degree 0)
    queue =
      table_names
      |> Enum.filter(fn name -> Map.get(in_degrees, name, 0) == 0 end)

    do_kahn_sort(queue, graph, in_degrees, [], length(table_names))
  end

  defp do_kahn_sort([], _graph, _in_degrees, sorted, expected_count) do
    if length(sorted) == expected_count do
      {:ok, Enum.reverse(sorted)}
    else
      {:error, :circular_dependency}
    end
  end

  defp do_kahn_sort([current | rest], graph, in_degrees, sorted, expected_count) do
    # Get tables that depend on current
    children = Map.get(graph, current, [])

    # Decrease in-degree for each child
    {updated_in_degrees, new_queue_items} =
      Enum.reduce(children, {in_degrees, []}, fn child, {degrees, new_items} ->
        new_degree = Map.get(degrees, child, 0) - 1
        updated = Map.put(degrees, child, new_degree)

        if new_degree == 0 do
          {updated, [child | new_items]}
        else
          {updated, new_items}
        end
      end)

    # Add newly ready items to queue
    new_queue = rest ++ new_queue_items

    do_kahn_sort(new_queue, graph, updated_in_degrees, [current | sorted], expected_count)
  end

  defp calculate_in_degrees(graph, table_names) do
    # Start with 0 for all tables
    initial = Map.new(table_names, fn name -> {name, 0} end)

    # Count incoming edges
    Enum.reduce(graph, initial, fn {_parent, children}, acc ->
      Enum.reduce(children, acc, fn child, inner_acc ->
        Map.update(inner_acc, child, 1, &(&1 + 1))
      end)
    end)
  end
end
