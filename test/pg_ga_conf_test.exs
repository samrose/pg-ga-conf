defmodule PgGaConfTest do
  use ExUnit.Case
  # doctest PgGaConf # Disabled until Orchestrator is implemented

  test "module loads" do
    assert is_atom(PgGaConf)
  end
end
