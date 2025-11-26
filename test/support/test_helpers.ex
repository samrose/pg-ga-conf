defmodule PgGaConf.TestHelpers do
  @moduledoc """
  Test helpers for setting up test databases.
  """

  def create_test_connection do
    {:ok, conn} = Postgrex.start_link(
      hostname: "localhost",
      username: "postgres",
      database: "pgga_test",
      pool_size: 1,
      backoff_type: :stop
    )
    conn
  end

  def setup_test_schema(conn) do
    Postgrex.query!(conn, "DROP SCHEMA IF EXISTS public CASCADE", [])
    Postgrex.query!(conn, "CREATE SCHEMA public", [])
    # Don't fail if extension already exists
    try do
      Postgrex.query!(conn, "CREATE EXTENSION IF NOT EXISTS pg_stat_statements", [])
    rescue
      _ -> :ok
    end
  end

  def create_test_tables(conn) do
    Postgrex.query!(conn, """
      CREATE TABLE authors (
        id SERIAL PRIMARY KEY,
        name VARCHAR(100) NOT NULL,
        email VARCHAR(255) UNIQUE,
        created_at TIMESTAMP DEFAULT NOW()
      )
    """, [])

    Postgrex.query!(conn, """
      CREATE TABLE books (
        id SERIAL PRIMARY KEY,
        title VARCHAR(255) NOT NULL,
        author_id INTEGER REFERENCES authors(id),
        isbn VARCHAR(13) UNIQUE,
        published_date DATE,
        price DECIMAL(10, 2)
      )
    """, [])

    Postgrex.query!(conn, """
      CREATE INDEX idx_books_author ON books(author_id)
    """, [])
  end

  def insert_test_data(conn) do
    Postgrex.query!(conn, """
      INSERT INTO authors (name, email) VALUES
      ('John Doe', 'john@example.com'),
      ('Jane Smith', 'jane@example.com')
    """, [])

    Postgrex.query!(conn, """
      INSERT INTO books (title, author_id, isbn, price) VALUES
      ('Book One', 1, '1234567890123', 29.99),
      ('Book Two', 1, '1234567890124', 39.99),
      ('Book Three', 2, '1234567890125', 19.99)
    """, [])
  end
end
