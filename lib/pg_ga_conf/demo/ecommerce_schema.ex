defmodule PgGaConf.Demo.EcommerceSchema do
  @moduledoc """
  Creates a complex e-commerce database schema for testing PostgreSQL tuning.

  Includes:
  - 12 tables with realistic relationships
  - Foreign keys, indexes, triggers
  - Check constraints and unique constraints
  - Realistic data volumes and distributions
  """

  require Logger

  @doc """
  Creates the full e-commerce schema in the given database connection.
  """
  def create_schema(conn) do
    Logger.info("Creating e-commerce schema...")

    # Drop existing tables (in reverse dependency order)
    drop_tables(conn)

    # Create tables in dependency order
    create_extensions(conn)
    create_enums(conn)
    create_tables(conn)
    create_indexes(conn)
    create_triggers(conn)

    Logger.info("E-commerce schema created successfully")
    :ok
  end

  @doc """
  Populates the schema with realistic test data.

  ## Options
    * `:scale` - Multiplier for row counts (default: 1.0)
      - scale 1.0 = ~100k total rows
      - scale 10.0 = ~1M total rows
  """
  def populate_data(conn, opts \\ []) do
    scale = Keyword.get(opts, :scale, 1.0)
    progress_fn = Keyword.get(opts, :progress_fn, fn msg -> Logger.info(msg) end)

    progress_fn.("Populating e-commerce data (scale=#{scale})...")

    # Generate data in FK dependency order
    generate_categories(conn, scale, progress_fn)
    generate_users(conn, scale, progress_fn)
    generate_addresses(conn, scale, progress_fn)
    generate_products(conn, scale, progress_fn)
    generate_inventory(conn, scale, progress_fn)
    generate_orders(conn, scale, progress_fn)
    generate_order_items(conn, scale, progress_fn)
    generate_reviews(conn, scale, progress_fn)
    generate_wishlists(conn, scale, progress_fn)
    generate_cart_items(conn, scale, progress_fn)
    generate_audit_log(conn, scale, progress_fn)

    # Update statistics
    Postgrex.query!(conn, "ANALYZE", [])

    progress_fn.("E-commerce data populated successfully")
    :ok
  end

  @doc """
  Creates schema and populates with data in one call.
  """
  def setup(conn, opts \\ []) do
    :ok = create_schema(conn)
    :ok = populate_data(conn, opts)
    :ok
  end

  # ============================================================================
  # Schema DDL
  # ============================================================================

  defp drop_tables(conn) do
    tables = ~w(
      audit_log cart_items wishlists reviews order_items orders
      inventory products addresses users categories
    )

    Enum.each(tables, fn table ->
      Postgrex.query(conn, "DROP TABLE IF EXISTS #{table} CASCADE", [])
    end)

    Postgrex.query(conn, "DROP TYPE IF EXISTS order_status CASCADE", [])
    Postgrex.query(conn, "DROP TYPE IF EXISTS payment_method CASCADE", [])
  end

  defp create_extensions(conn) do
    Postgrex.query!(conn, "CREATE EXTENSION IF NOT EXISTS pgcrypto", [])
  end

  defp create_enums(conn) do
    Postgrex.query!(conn, """
      CREATE TYPE order_status AS ENUM (
        'pending', 'confirmed', 'processing', 'shipped', 'delivered', 'cancelled', 'refunded'
      )
    """, [])

    Postgrex.query!(conn, """
      CREATE TYPE payment_method AS ENUM (
        'credit_card', 'debit_card', 'paypal', 'bank_transfer', 'crypto'
      )
    """, [])
  end

  defp create_tables(conn) do
    # Categories (self-referencing for hierarchy)
    Postgrex.query!(conn, """
      CREATE TABLE categories (
        id SERIAL PRIMARY KEY,
        name VARCHAR(100) NOT NULL,
        slug VARCHAR(100) NOT NULL UNIQUE,
        description TEXT,
        parent_id INTEGER REFERENCES categories(id) ON DELETE SET NULL,
        is_active BOOLEAN DEFAULT true,
        sort_order INTEGER DEFAULT 0,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """, [])

    # Users
    Postgrex.query!(conn, """
      CREATE TABLE users (
        id SERIAL PRIMARY KEY,
        email VARCHAR(255) NOT NULL UNIQUE,
        password_hash VARCHAR(255) NOT NULL,
        first_name VARCHAR(100),
        last_name VARCHAR(100),
        phone VARCHAR(20),
        is_active BOOLEAN DEFAULT true,
        is_verified BOOLEAN DEFAULT false,
        last_login_at TIMESTAMP WITH TIME ZONE,
        login_count INTEGER DEFAULT 0,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """, [])

    # Addresses
    Postgrex.query!(conn, """
      CREATE TABLE addresses (
        id SERIAL PRIMARY KEY,
        user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        label VARCHAR(50) DEFAULT 'home',
        street_address VARCHAR(255) NOT NULL,
        city VARCHAR(100) NOT NULL,
        state VARCHAR(100),
        postal_code VARCHAR(20) NOT NULL,
        country VARCHAR(100) NOT NULL DEFAULT 'USA',
        is_default BOOLEAN DEFAULT false,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """, [])

    # Products
    Postgrex.query!(conn, """
      CREATE TABLE products (
        id SERIAL PRIMARY KEY,
        sku VARCHAR(50) NOT NULL UNIQUE,
        name VARCHAR(255) NOT NULL,
        description TEXT,
        category_id INTEGER REFERENCES categories(id) ON DELETE SET NULL,
        price NUMERIC(10,2) NOT NULL CHECK (price >= 0),
        cost NUMERIC(10,2) CHECK (cost >= 0),
        weight_kg NUMERIC(8,3),
        is_active BOOLEAN DEFAULT true,
        is_featured BOOLEAN DEFAULT false,
        metadata JSONB DEFAULT '{}',
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """, [])

    # Inventory
    Postgrex.query!(conn, """
      CREATE TABLE inventory (
        id SERIAL PRIMARY KEY,
        product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        warehouse_code VARCHAR(20) NOT NULL DEFAULT 'MAIN',
        quantity INTEGER NOT NULL DEFAULT 0 CHECK (quantity >= 0),
        reserved_quantity INTEGER NOT NULL DEFAULT 0 CHECK (reserved_quantity >= 0),
        reorder_level INTEGER DEFAULT 10,
        last_restocked_at TIMESTAMP WITH TIME ZONE,
        UNIQUE(product_id, warehouse_code)
      )
    """, [])

    # Orders
    Postgrex.query!(conn, """
      CREATE TABLE orders (
        id SERIAL PRIMARY KEY,
        order_number VARCHAR(50) NOT NULL UNIQUE,
        user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
        shipping_address_id INTEGER REFERENCES addresses(id) ON DELETE SET NULL,
        billing_address_id INTEGER REFERENCES addresses(id) ON DELETE SET NULL,
        status order_status NOT NULL DEFAULT 'pending',
        payment_method payment_method,
        subtotal NUMERIC(12,2) NOT NULL DEFAULT 0,
        tax_amount NUMERIC(12,2) NOT NULL DEFAULT 0,
        shipping_amount NUMERIC(12,2) NOT NULL DEFAULT 0,
        discount_amount NUMERIC(12,2) NOT NULL DEFAULT 0,
        total_amount NUMERIC(12,2) NOT NULL DEFAULT 0,
        notes TEXT,
        placed_at TIMESTAMP WITH TIME ZONE,
        shipped_at TIMESTAMP WITH TIME ZONE,
        delivered_at TIMESTAMP WITH TIME ZONE,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """, [])

    # Order Items
    Postgrex.query!(conn, """
      CREATE TABLE order_items (
        id SERIAL PRIMARY KEY,
        order_id INTEGER NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
        product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
        quantity INTEGER NOT NULL CHECK (quantity > 0),
        unit_price NUMERIC(10,2) NOT NULL,
        discount_percent NUMERIC(5,2) DEFAULT 0 CHECK (discount_percent >= 0 AND discount_percent <= 100),
        line_total NUMERIC(12,2) NOT NULL,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """, [])

    # Reviews
    Postgrex.query!(conn, """
      CREATE TABLE reviews (
        id SERIAL PRIMARY KEY,
        product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        rating INTEGER NOT NULL CHECK (rating >= 1 AND rating <= 5),
        title VARCHAR(255),
        body TEXT,
        is_verified_purchase BOOLEAN DEFAULT false,
        helpful_votes INTEGER DEFAULT 0,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        UNIQUE(product_id, user_id)
      )
    """, [])

    # Wishlists
    Postgrex.query!(conn, """
      CREATE TABLE wishlists (
        id SERIAL PRIMARY KEY,
        user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        priority INTEGER DEFAULT 0,
        notes TEXT,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        UNIQUE(user_id, product_id)
      )
    """, [])

    # Cart Items
    Postgrex.query!(conn, """
      CREATE TABLE cart_items (
        id SERIAL PRIMARY KEY,
        user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE,
        quantity INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
        added_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
        UNIQUE(user_id, product_id)
      )
    """, [])

    # Audit Log
    Postgrex.query!(conn, """
      CREATE TABLE audit_log (
        id BIGSERIAL PRIMARY KEY,
        table_name VARCHAR(100) NOT NULL,
        record_id INTEGER NOT NULL,
        action VARCHAR(20) NOT NULL,
        old_values JSONB,
        new_values JSONB,
        user_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
        ip_address INET,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      )
    """, [])
  end

  defp create_indexes(conn) do
    indexes = [
      # Users
      "CREATE INDEX idx_users_email ON users(email)",
      "CREATE INDEX idx_users_last_login ON users(last_login_at DESC NULLS LAST)",

      # Addresses
      "CREATE INDEX idx_addresses_user_id ON addresses(user_id)",

      # Products
      "CREATE INDEX idx_products_category ON products(category_id)",
      "CREATE INDEX idx_products_price ON products(price)",
      "CREATE INDEX idx_products_active ON products(is_active) WHERE is_active = true",
      "CREATE INDEX idx_products_metadata ON products USING GIN (metadata)",

      # Inventory
      "CREATE INDEX idx_inventory_product ON inventory(product_id)",
      "CREATE INDEX idx_inventory_low_stock ON inventory(product_id) WHERE quantity <= reorder_level",

      # Orders
      "CREATE INDEX idx_orders_user ON orders(user_id)",
      "CREATE INDEX idx_orders_status ON orders(status)",
      "CREATE INDEX idx_orders_placed_at ON orders(placed_at DESC NULLS LAST)",
      "CREATE INDEX idx_orders_created_at ON orders(created_at DESC)",

      # Order Items
      "CREATE INDEX idx_order_items_order ON order_items(order_id)",
      "CREATE INDEX idx_order_items_product ON order_items(product_id)",

      # Reviews
      "CREATE INDEX idx_reviews_product ON reviews(product_id)",
      "CREATE INDEX idx_reviews_user ON reviews(user_id)",
      "CREATE INDEX idx_reviews_rating ON reviews(product_id, rating)",

      # Wishlists
      "CREATE INDEX idx_wishlists_user ON wishlists(user_id)",

      # Cart
      "CREATE INDEX idx_cart_user ON cart_items(user_id)",

      # Audit
      "CREATE INDEX idx_audit_table_record ON audit_log(table_name, record_id)",
      "CREATE INDEX idx_audit_created ON audit_log(created_at DESC)"
    ]

    Enum.each(indexes, fn sql ->
      Postgrex.query!(conn, sql, [])
    end)
  end

  defp create_triggers(conn) do
    # Updated_at trigger function
    Postgrex.query!(conn, """
      CREATE OR REPLACE FUNCTION update_updated_at_column()
      RETURNS TRIGGER AS $$
      BEGIN
        NEW.updated_at = NOW();
        RETURN NEW;
      END;
      $$ language 'plpgsql'
    """, [])

    # Apply to tables with updated_at
    tables_with_updated_at = ~w(categories users products orders)

    Enum.each(tables_with_updated_at, fn table ->
      Postgrex.query!(conn, """
        CREATE TRIGGER update_#{table}_updated_at
        BEFORE UPDATE ON #{table}
        FOR EACH ROW EXECUTE FUNCTION update_updated_at_column()
      """, [])
    end)

    # Order total calculation trigger
    Postgrex.query!(conn, """
      CREATE OR REPLACE FUNCTION calculate_order_total()
      RETURNS TRIGGER AS $$
      BEGIN
        UPDATE orders SET
          subtotal = (SELECT COALESCE(SUM(line_total), 0) FROM order_items WHERE order_id = NEW.order_id),
          total_amount = subtotal + tax_amount + shipping_amount - discount_amount
        WHERE id = NEW.order_id;
        RETURN NEW;
      END;
      $$ language 'plpgsql'
    """, [])

    Postgrex.query!(conn, """
      CREATE TRIGGER update_order_total
      AFTER INSERT OR UPDATE OR DELETE ON order_items
      FOR EACH ROW EXECUTE FUNCTION calculate_order_total()
    """, [])
  end

  # ============================================================================
  # Data Generation
  # ============================================================================

  defp generate_categories(conn, scale, progress_fn) do
    count = round(50 * scale)
    progress_fn.("  Generating #{count} categories...")

    # Parent categories
    parent_categories = [
      {"Electronics", "electronics"},
      {"Clothing", "clothing"},
      {"Home & Garden", "home-garden"},
      {"Sports", "sports"},
      {"Books", "books"},
      {"Toys", "toys"},
      {"Beauty", "beauty"},
      {"Automotive", "automotive"}
    ]

    # Insert parent categories
    Enum.each(parent_categories, fn {name, slug} ->
      Postgrex.query!(conn, """
        INSERT INTO categories (name, slug, description, sort_order)
        VALUES ($1, $2, $3, $4)
      """, [name, slug, "#{name} products and accessories", :rand.uniform(100)])
    end)

    # Get parent IDs
    %{rows: parent_rows} = Postgrex.query!(conn, "SELECT id, slug FROM categories", [])
    parent_map = Map.new(parent_rows, fn [id, slug] -> {slug, id} end)

    # Generate subcategories
    subcategories = [
      {"Smartphones", "smartphones", "electronics"},
      {"Laptops", "laptops", "electronics"},
      {"Headphones", "headphones", "electronics"},
      {"Men's Shirts", "mens-shirts", "clothing"},
      {"Women's Dresses", "womens-dresses", "clothing"},
      {"Furniture", "furniture", "home-garden"},
      {"Kitchen", "kitchen", "home-garden"},
      {"Running", "running", "sports"},
      {"Fiction", "fiction", "books"},
      {"Skincare", "skincare", "beauty"}
    ]

    Enum.each(subcategories, fn {name, slug, parent_slug} ->
      parent_id = Map.get(parent_map, parent_slug)
      Postgrex.query!(conn, """
        INSERT INTO categories (name, slug, description, parent_id, sort_order)
        VALUES ($1, $2, $3, $4, $5)
      """, [name, slug, "#{name} category", parent_id, :rand.uniform(100)])
    end)
  end

  defp generate_users(conn, scale, progress_fn) do
    count = round(10_000 * scale)
    progress_fn.("  Generating #{count} users...")

    batch_size = 1000
    batches = ceil(count / batch_size)

    Enum.each(1..batches, fn batch ->
      start_idx = (batch - 1) * batch_size + 1
      end_idx = min(batch * batch_size, count)

      values =
        Enum.map(start_idx..end_idx, fn i ->
          first = Enum.random(~w(James Mary John Patricia Robert Jennifer Michael Linda William Elizabeth))
          last = Enum.random(~w(Smith Johnson Williams Brown Jones Garcia Miller Davis Rodriguez Martinez))
          email = "#{String.downcase(first)}.#{String.downcase(last)}#{i}@#{Enum.random(~w(gmail.com yahoo.com outlook.com example.com))}"

          "(
            '#{email}',
            '#{Base.encode64(:crypto.strong_rand_bytes(32))}',
            '#{first}',
            '#{last}',
            '+1#{:rand.uniform(9_000_000_000) + 1_000_000_000}',
            #{:rand.uniform() > 0.1},
            #{:rand.uniform() > 0.3},
            #{if :rand.uniform() > 0.4, do: "NOW() - INTERVAL '#{:rand.uniform(365)} days'", else: "NULL"},
            #{:rand.uniform(100)}
          )"
        end)
        |> Enum.join(",\n")

      Postgrex.query!(conn, """
        INSERT INTO users (email, password_hash, first_name, last_name, phone, is_active, is_verified, last_login_at, login_count)
        VALUES #{values}
      """, [])
    end)
  end

  defp generate_addresses(conn, scale, progress_fn) do
    count = round(15_000 * scale)
    progress_fn.("  Generating #{count} addresses...")

    %{rows: [[max_user_id]]} = Postgrex.query!(conn, "SELECT MAX(id) FROM users", [])

    cities = ~w(New\ York Los\ Angeles Chicago Houston Phoenix Philadelphia San\ Antonio San\ Diego Dallas San\ Jose)
    states = ~w(NY CA IL TX AZ PA TX CA TX CA)

    batch_size = 1000
    batches = ceil(count / batch_size)

    Enum.each(1..batches, fn batch ->
      start_idx = (batch - 1) * batch_size + 1
      end_idx = min(batch * batch_size, count)

      values =
        Enum.map(start_idx..end_idx, fn _ ->
          city_idx = :rand.uniform(length(cities)) - 1
          city = Enum.at(cities, city_idx)
          state = Enum.at(states, city_idx)

          "(
            #{:rand.uniform(max_user_id)},
            '#{Enum.random(~w(home work shipping billing))}',
            '#{:rand.uniform(9999)} #{Enum.random(~w(Main Oak Pine Maple Cedar))} #{Enum.random(~w(St Ave Blvd Rd Ln))}',
            '#{city}',
            '#{state}',
            '#{10000 + :rand.uniform(89999)}',
            'USA',
            #{:rand.uniform() > 0.8}
          )"
        end)
        |> Enum.join(",\n")

      Postgrex.query!(conn, """
        INSERT INTO addresses (user_id, label, street_address, city, state, postal_code, country, is_default)
        VALUES #{values}
        ON CONFLICT DO NOTHING
      """, [])
    end)
  end

  defp generate_products(conn, scale, progress_fn) do
    count = round(5_000 * scale)
    progress_fn.("  Generating #{count} products...")

    %{rows: category_rows} = Postgrex.query!(conn, "SELECT id FROM categories", [])
    category_ids = Enum.map(category_rows, fn [id] -> id end)

    adjectives = ~w(Premium Deluxe Professional Essential Basic Advanced Ultra Super Mega Pro)
    nouns = ~w(Widget Gadget Tool Device Kit Set Pack Bundle System Module)

    batch_size = 500
    batches = ceil(count / batch_size)

    Enum.each(1..batches, fn batch ->
      start_idx = (batch - 1) * batch_size + 1
      end_idx = min(batch * batch_size, count)

      values =
        Enum.map(start_idx..end_idx, fn i ->
          adj = Enum.random(adjectives)
          noun = Enum.random(nouns)
          name = "#{adj} #{noun} #{i}"
          sku = "SKU-#{String.pad_leading(to_string(i), 8, "0")}"
          price = :rand.uniform(50000) / 100 + 9.99
          cost = price * (0.3 + :rand.uniform() * 0.4)
          cat_id = Enum.random(category_ids)

          "(
            '#{sku}',
            '#{name}',
            'High-quality #{String.downcase(adj)} #{String.downcase(noun)} for all your needs.',
            #{cat_id},
            #{Float.round(price, 2)},
            #{Float.round(cost, 2)},
            #{Float.round(:rand.uniform() * 10, 3)},
            #{:rand.uniform() > 0.1},
            #{:rand.uniform() > 0.9},
            '{\"color\": \"#{Enum.random(~w(red blue green black white))}\", \"brand\": \"#{Enum.random(~w(Acme TechCo ProGear MaxBrand ValueCo))}\"}'
          )"
        end)
        |> Enum.join(",\n")

      Postgrex.query!(conn, """
        INSERT INTO products (sku, name, description, category_id, price, cost, weight_kg, is_active, is_featured, metadata)
        VALUES #{values}
      """, [])
    end)
  end

  defp generate_inventory(conn, _scale, progress_fn) do
    progress_fn.("  Generating inventory records...")

    %{rows: [[product_count]]} = Postgrex.query!(conn, "SELECT COUNT(*) FROM products", [])

    # Generate inventory for each product in 1-3 warehouses
    Postgrex.query!(conn, """
      INSERT INTO inventory (product_id, warehouse_code, quantity, reserved_quantity, reorder_level, last_restocked_at)
      SELECT
        p.id,
        w.code,
        floor(random() * 500)::int,
        floor(random() * 20)::int,
        floor(random() * 50 + 5)::int,
        NOW() - (random() * INTERVAL '90 days')
      FROM products p
      CROSS JOIN (SELECT unnest(ARRAY['MAIN', 'WEST', 'EAST']) as code) w
      WHERE random() > 0.3
      ON CONFLICT DO NOTHING
    """, [])

    progress_fn.("    Generated inventory for #{product_count} products")
  end

  defp generate_orders(conn, scale, progress_fn) do
    count = round(50_000 * scale)
    progress_fn.("  Generating #{count} orders...")

    %{rows: [[max_user_id]]} = Postgrex.query!(conn, "SELECT MAX(id) FROM users", [])
    %{rows: [[max_addr_id]]} = Postgrex.query!(conn, "SELECT MAX(id) FROM addresses", [])

    statuses = ~w(pending confirmed processing shipped delivered cancelled refunded)
    status_weights = [0.05, 0.10, 0.10, 0.15, 0.50, 0.05, 0.05]
    payment_methods = ~w(credit_card debit_card paypal bank_transfer crypto)

    batch_size = 1000
    batches = ceil(count / batch_size)

    Enum.each(1..batches, fn batch ->
      start_idx = (batch - 1) * batch_size + 1
      end_idx = min(batch * batch_size, count)

      values =
        Enum.map(start_idx..end_idx, fn i ->
          status = weighted_random(statuses, status_weights)
          order_num = "ORD-#{:os.system_time(:millisecond)}-#{i}"
          user_id = :rand.uniform(max_user_id)
          ship_addr = if max_addr_id > 0, do: :rand.uniform(max_addr_id), else: "NULL"
          bill_addr = if max_addr_id > 0 && :rand.uniform() > 0.5, do: :rand.uniform(max_addr_id), else: ship_addr
          subtotal = :rand.uniform(100000) / 100 + 10
          tax = subtotal * 0.08
          shipping = if subtotal > 50, do: 0, else: 5.99 + :rand.uniform(1000) / 100
          discount = if :rand.uniform() > 0.8, do: subtotal * (:rand.uniform(20) / 100), else: 0

          placed = if status != "pending", do: "NOW() - INTERVAL '#{:rand.uniform(365)} days'", else: "NULL"
          shipped = if status in ~w(shipped delivered), do: "#{placed} + INTERVAL '#{:rand.uniform(5)} days'", else: "NULL"
          delivered = if status == "delivered", do: "#{shipped} + INTERVAL '#{:rand.uniform(7)} days'", else: "NULL"

          "(
            '#{order_num}',
            #{user_id},
            #{ship_addr},
            #{bill_addr},
            '#{status}'::order_status,
            '#{Enum.random(payment_methods)}'::payment_method,
            #{Float.round(subtotal, 2)},
            #{Float.round(tax, 2)},
            #{Float.round(shipping, 2)},
            #{Float.round(discount, 2)},
            #{Float.round(subtotal + tax + shipping - discount, 2)},
            #{if :rand.uniform() > 0.9, do: "'Customer note: Please leave at door'", else: "NULL"},
            #{placed},
            #{shipped},
            #{delivered}
          )"
        end)
        |> Enum.join(",\n")

      Postgrex.query!(conn, """
        INSERT INTO orders (order_number, user_id, shipping_address_id, billing_address_id, status, payment_method, subtotal, tax_amount, shipping_amount, discount_amount, total_amount, notes, placed_at, shipped_at, delivered_at)
        VALUES #{values}
      """, [])
    end)
  end

  defp generate_order_items(conn, scale, progress_fn) do
    count = round(150_000 * scale)
    progress_fn.("  Generating #{count} order items...")

    %{rows: [[max_order_id]]} = Postgrex.query!(conn, "SELECT MAX(id) FROM orders", [])
    %{rows: [[max_product_id]]} = Postgrex.query!(conn, "SELECT MAX(id) FROM products", [])

    batch_size = 2000
    batches = ceil(count / batch_size)

    Enum.each(1..batches, fn batch ->
      start_idx = (batch - 1) * batch_size + 1
      end_idx = min(batch * batch_size, count)

      values =
        Enum.map(start_idx..end_idx, fn _ ->
          order_id = :rand.uniform(max_order_id)
          product_id = :rand.uniform(max_product_id)
          qty = :rand.uniform(5)
          unit_price = :rand.uniform(50000) / 100 + 9.99
          discount = if :rand.uniform() > 0.8, do: :rand.uniform(20), else: 0
          line_total = qty * unit_price * (1 - discount / 100)

          "(#{order_id}, #{product_id}, #{qty}, #{Float.round(unit_price, 2)}, #{discount}, #{Float.round(line_total, 2)})"
        end)
        |> Enum.join(",\n")

      Postgrex.query!(conn, """
        INSERT INTO order_items (order_id, product_id, quantity, unit_price, discount_percent, line_total)
        VALUES #{values}
        ON CONFLICT DO NOTHING
      """, [])
    end)
  end

  defp generate_reviews(conn, scale, progress_fn) do
    count = round(20_000 * scale)
    progress_fn.("  Generating #{count} reviews...")

    %{rows: [[max_user_id]]} = Postgrex.query!(conn, "SELECT MAX(id) FROM users", [])
    %{rows: [[max_product_id]]} = Postgrex.query!(conn, "SELECT MAX(id) FROM products", [])

    titles = [
      "Great product!", "Exactly as described", "Good value", "Disappointed",
      "Exceeded expectations", "Average quality", "Would buy again", "Not worth it",
      "Perfect!", "Could be better"
    ]

    batch_size = 1000
    batches = ceil(count / batch_size)

    Enum.each(1..batches, fn batch ->
      start_idx = (batch - 1) * batch_size + 1
      end_idx = min(batch * batch_size, count)

      values =
        Enum.map(start_idx..end_idx, fn _ ->
          rating = weighted_random([1, 2, 3, 4, 5], [0.05, 0.10, 0.15, 0.30, 0.40])
          title = Enum.random(titles)

          "(
            #{:rand.uniform(max_product_id)},
            #{:rand.uniform(max_user_id)},
            #{rating},
            '#{title}',
            'This product is #{if rating >= 4, do: "great", else: "okay"}. #{if rating >= 3, do: "Would recommend.", else: "Could be improved."}',
            #{:rand.uniform() > 0.3},
            #{:rand.uniform(50)}
          )"
        end)
        |> Enum.join(",\n")

      Postgrex.query!(conn, """
        INSERT INTO reviews (product_id, user_id, rating, title, body, is_verified_purchase, helpful_votes)
        VALUES #{values}
        ON CONFLICT DO NOTHING
      """, [])
    end)
  end

  defp generate_wishlists(conn, scale, progress_fn) do
    count = round(30_000 * scale)
    progress_fn.("  Generating #{count} wishlist items...")

    %{rows: [[max_user_id]]} = Postgrex.query!(conn, "SELECT MAX(id) FROM users", [])
    %{rows: [[max_product_id]]} = Postgrex.query!(conn, "SELECT MAX(id) FROM products", [])

    batch_size = 2000
    batches = ceil(count / batch_size)

    Enum.each(1..batches, fn batch ->
      start_idx = (batch - 1) * batch_size + 1
      end_idx = min(batch * batch_size, count)

      values =
        Enum.map(start_idx..end_idx, fn _ ->
          "(#{:rand.uniform(max_user_id)}, #{:rand.uniform(max_product_id)}, #{:rand.uniform(10)})"
        end)
        |> Enum.join(",\n")

      Postgrex.query!(conn, """
        INSERT INTO wishlists (user_id, product_id, priority)
        VALUES #{values}
        ON CONFLICT DO NOTHING
      """, [])
    end)
  end

  defp generate_cart_items(conn, scale, progress_fn) do
    count = round(5_000 * scale)
    progress_fn.("  Generating #{count} cart items...")

    %{rows: [[max_user_id]]} = Postgrex.query!(conn, "SELECT MAX(id) FROM users", [])
    %{rows: [[max_product_id]]} = Postgrex.query!(conn, "SELECT MAX(id) FROM products", [])

    values =
      Enum.map(1..count, fn _ ->
        "(#{:rand.uniform(max_user_id)}, #{:rand.uniform(max_product_id)}, #{:rand.uniform(5)})"
      end)
      |> Enum.join(",\n")

    Postgrex.query!(conn, """
      INSERT INTO cart_items (user_id, product_id, quantity)
      VALUES #{values}
      ON CONFLICT DO NOTHING
    """, [])
  end

  defp generate_audit_log(conn, scale, progress_fn) do
    count = round(100_000 * scale)
    progress_fn.("  Generating #{count} audit log entries...")

    %{rows: [[max_user_id]]} = Postgrex.query!(conn, "SELECT MAX(id) FROM users", [])

    tables = ~w(users orders products inventory)
    actions = ~w(INSERT UPDATE DELETE)

    batch_size = 5000
    batches = ceil(count / batch_size)

    Enum.each(1..batches, fn batch ->
      start_idx = (batch - 1) * batch_size + 1
      end_idx = min(batch * batch_size, count)

      values =
        Enum.map(start_idx..end_idx, fn _ ->
          table = Enum.random(tables)
          action = Enum.random(actions)
          user_id = if :rand.uniform() > 0.2, do: :rand.uniform(max_user_id), else: "NULL"
          ip = "#{:rand.uniform(255)}.#{:rand.uniform(255)}.#{:rand.uniform(255)}.#{:rand.uniform(255)}"

          "(
            '#{table}',
            #{:rand.uniform(100_000)},
            '#{action}',
            #{if action != "INSERT", do: "'{\"old\": \"value\"}'", else: "NULL"},
            #{if action != "DELETE", do: "'{\"new\": \"value\"}'", else: "NULL"},
            #{user_id},
            '#{ip}'::inet,
            NOW() - INTERVAL '#{:rand.uniform(90)} days'
          )"
        end)
        |> Enum.join(",\n")

      Postgrex.query!(conn, """
        INSERT INTO audit_log (table_name, record_id, action, old_values, new_values, user_id, ip_address, created_at)
        VALUES #{values}
      """, [])
    end)
  end

  # Helper for weighted random selection
  defp weighted_random(items, weights) do
    total = Enum.sum(weights)
    threshold = :rand.uniform() * total

    {item, _} =
      Enum.zip(items, weights)
      |> Enum.reduce_while({nil, 0}, fn {item, weight}, {_, acc} ->
        new_acc = acc + weight
        if new_acc >= threshold do
          {:halt, {item, new_acc}}
        else
          {:cont, {item, new_acc}}
        end
      end)

    item
  end
end
