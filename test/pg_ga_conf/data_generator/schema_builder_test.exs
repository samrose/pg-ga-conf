defmodule PgGaConf.DataGenerator.SchemaBuilderTest do
  use ExUnit.Case, async: true

  alias PgGaConf.DataGenerator.SchemaBuilder

  describe "build_create_table/2" do
    test "generates CREATE TABLE for simple table" do
      table = %{name: "users", schema: "public"}
      columns = [
        %{name: "id", table: "users", data_type: "integer", nullable: false, is_identity: true},
        %{name: "name", table: "users", data_type: "character varying", char_max_length: 100, nullable: false},
        %{name: "email", table: "users", data_type: "character varying", char_max_length: 255, nullable: true}
      ]

      sql = SchemaBuilder.build_create_table(table, columns)

      assert String.contains?(sql, "CREATE TABLE public.users")
      assert String.contains?(sql, "id integer")
      assert String.contains?(sql, "name character varying(100) NOT NULL")
      assert String.contains?(sql, "email character varying(255)")
    end

    test "handles numeric precision and scale" do
      table = %{name: "products", schema: "public"}
      columns = [
        %{name: "price", table: "products", data_type: "numeric", numeric_precision: 10, numeric_scale: 2, nullable: false}
      ]

      sql = SchemaBuilder.build_create_table(table, columns)

      assert String.contains?(sql, "price numeric(10,2) NOT NULL")
    end

    test "handles text type without length" do
      table = %{name: "posts", schema: "public"}
      columns = [
        %{name: "content", table: "posts", data_type: "text", nullable: true}
      ]

      sql = SchemaBuilder.build_create_table(table, columns)

      assert String.contains?(sql, "content text")
    end

    test "handles timestamp types" do
      table = %{name: "events", schema: "public"}
      columns = [
        %{name: "created_at", table: "events", data_type: "timestamp without time zone", nullable: false},
        %{name: "updated_at", table: "events", data_type: "timestamp with time zone", nullable: true}
      ]

      sql = SchemaBuilder.build_create_table(table, columns)

      assert String.contains?(sql, "created_at timestamp without time zone NOT NULL")
      assert String.contains?(sql, "updated_at timestamp with time zone")
    end
  end

  describe "build_primary_key/1" do
    test "generates single column PK" do
      pk = %{table: "users", columns: ["id"], name: "users_pkey"}

      sql = SchemaBuilder.build_primary_key(pk)

      assert sql == "ALTER TABLE users ADD CONSTRAINT users_pkey PRIMARY KEY (id)"
    end

    test "generates composite PK" do
      pk = %{table: "order_items", columns: ["order_id", "product_id"], name: "order_items_pkey"}

      sql = SchemaBuilder.build_primary_key(pk)

      assert sql == "ALTER TABLE order_items ADD CONSTRAINT order_items_pkey PRIMARY KEY (order_id, product_id)"
    end
  end

  describe "build_foreign_key/1" do
    test "generates FK constraint" do
      fk = %{
        table: "posts",
        name: "posts_user_id_fkey",
        columns: ["user_id"],
        foreign_table: "users",
        foreign_columns: ["id"],
        on_delete: "CASCADE",
        on_update: "NO ACTION"
      }

      sql = SchemaBuilder.build_foreign_key(fk)

      assert String.contains?(sql, "ALTER TABLE posts ADD CONSTRAINT posts_user_id_fkey")
      assert String.contains?(sql, "FOREIGN KEY (user_id) REFERENCES users(id)")
      assert String.contains?(sql, "ON DELETE CASCADE")
      assert String.contains?(sql, "ON UPDATE NO ACTION")
    end

    test "generates multi-column FK" do
      fk = %{
        table: "order_details",
        name: "order_details_fkey",
        columns: ["order_id", "line_num"],
        foreign_table: "orders",
        foreign_columns: ["id", "line_num"],
        on_delete: "NO ACTION",
        on_update: "NO ACTION"
      }

      sql = SchemaBuilder.build_foreign_key(fk)

      assert String.contains?(sql, "FOREIGN KEY (order_id, line_num)")
      assert String.contains?(sql, "REFERENCES orders(id, line_num)")
    end
  end

  describe "build_unique_constraint/1" do
    test "generates unique constraint" do
      constraint = %{
        table: "users",
        name: "users_email_unique",
        columns: ["email"]
      }

      sql = SchemaBuilder.build_unique_constraint(constraint)

      assert sql == "ALTER TABLE users ADD CONSTRAINT users_email_unique UNIQUE (email)"
    end
  end

  describe "build_index/1" do
    test "generates simple index" do
      index = %{
        table: "posts",
        name: "idx_posts_user_id",
        definition: "CREATE INDEX idx_posts_user_id ON public.posts USING btree (user_id)"
      }

      sql = SchemaBuilder.build_index(index)

      assert sql == index.definition
    end
  end

  describe "build_sequence/1" do
    test "generates sequence" do
      sequence = %{
        schema: "public",
        name: "users_id_seq",
        start_value: 1,
        increment_by: 1
      }

      sql = SchemaBuilder.build_sequence(sequence)

      assert String.contains?(sql, "CREATE SEQUENCE public.users_id_seq")
      assert String.contains?(sql, "START WITH 1")
      assert String.contains?(sql, "INCREMENT BY 1")
    end
  end

  describe "build_enum/1" do
    test "generates enum type" do
      enum = %{
        schema: "public",
        name: "status",
        values: ["pending", "active", "closed"]
      }

      sql = SchemaBuilder.build_enum(enum)

      assert sql == "CREATE TYPE public.status AS ENUM ('pending', 'active', 'closed')"
    end
  end

  describe "column_definition/1" do
    test "formats column with all attributes" do
      column = %{
        name: "amount",
        data_type: "numeric",
        numeric_precision: 10,
        numeric_scale: 2,
        nullable: false,
        default: "0.00"
      }

      definition = SchemaBuilder.column_definition(column)

      assert definition == "amount numeric(10,2) NOT NULL DEFAULT 0.00"
    end
  end
end
