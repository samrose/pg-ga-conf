defmodule PgGaConf.Core.DatabaseScannerTest do
  use ExUnit.Case

  @moduletag :integration

  alias PgGaConf.Core.{DatabaseScanner, ScanResult}
  alias PgGaConf.TestHelpers

  setup do
    conn = TestHelpers.create_test_connection()
    TestHelpers.setup_test_schema(conn)
    TestHelpers.create_test_tables(conn)
    TestHelpers.insert_test_data(conn)

    on_exit(fn ->
      # Stop the connection if it's still alive
      if Process.alive?(conn) do
        GenServer.stop(conn, :normal, 5000)
      end
    end)

    {:ok, conn: conn}
  end

  describe "scan_database/1" do
    test "returns ScanResult struct", %{conn: conn} do
      result = DatabaseScanner.scan_database(conn)

      assert %ScanResult{} = result
      assert result.scanned_at != nil
    end

    test "scans tables", %{conn: conn} do
      result = DatabaseScanner.scan_database(conn)

      assert length(result.tables) >= 2
      assert Enum.any?(result.tables, fn t -> t.name == "authors" end)
      assert Enum.any?(result.tables, fn t -> t.name == "books" end)
    end

    test "scans columns", %{conn: conn} do
      result = DatabaseScanner.scan_database(conn)

      assert length(result.columns) > 0

      # Find author name column
      name_col = Enum.find(result.columns, fn c ->
        c.table == "authors" and c.name == "name"
      end)

      assert name_col != nil
      assert name_col.data_type in ["character varying", "varchar"]
      assert name_col.nullable == false
    end

    test "scans foreign keys", %{conn: conn} do
      result = DatabaseScanner.scan_database(conn)

      fk = Enum.find(result.foreign_keys, fn fk ->
        fk.table == "books" and "author_id" in fk.columns
      end)

      assert fk != nil
      assert fk.foreign_table =~ "authors"
    end

    test "scans indexes", %{conn: conn} do
      result = DatabaseScanner.scan_database(conn)

      idx = Enum.find(result.indexes, fn idx ->
        idx.name == "idx_books_author"
      end)

      assert idx != nil
      assert idx.table == "books"
    end
  end
end
