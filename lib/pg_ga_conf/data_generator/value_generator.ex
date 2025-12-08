defmodule PgGaConf.DataGenerator.ValueGenerator do
  @moduledoc """
  Generates synthetic values for database columns based on type and profile.

  Supports:
  - Histogram-based distribution for numerics (matches PostgreSQL planner)
  - Pattern-based generation for strings (email, UUID, phone, etc.)
  - Frequency-based sampling for low-cardinality columns
  """

  import Bitwise

  @first_names ~w(James Mary John Patricia Robert Jennifer Michael Linda William Elizabeth David Barbara Richard Susan Joseph Jessica Thomas Sarah Charles Karen)
  @last_names ~w(Smith Johnson Williams Brown Jones Garcia Miller Davis Rodriguez Martinez Hernandez Lopez Gonzalez Wilson Anderson Thomas Taylor Moore Jackson Martin)
  @domains ~w(gmail.com yahoo.com outlook.com example.com company.org business.net mail.io)
  @words ~w(lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua)

  # ============================================================================
  # Numeric Generators
  # ============================================================================

  @doc """
  Generates an integer within bounds, optionally using histogram distribution.
  """
  def generate_integer(min, max, _histogram) when min == max, do: min

  def generate_integer(min, max, nil) do
    min + :rand.uniform(max - min + 1) - 1
  end

  def generate_integer(min, max, histogram) when is_list(histogram) do
    value = generate_from_histogram(min / 1, max / 1, histogram)
    round(value)
  end

  @doc """
  Generates a float within bounds with specified precision.
  """
  def generate_float(min, max, histogram, precision \\ 2)

  def generate_float(min, max, nil, precision) do
    value = min + :rand.uniform() * (max - min)
    Float.round(value, precision)
  end

  def generate_float(min, max, histogram, precision) when is_list(histogram) do
    value = generate_from_histogram(min, max, histogram)
    Float.round(value, precision)
  end

  @doc """
  Generates a decimal value (returns float, caller converts to Decimal if needed).
  """
  def generate_decimal(min, max, histogram, scale \\ 2) do
    generate_float(min, max, histogram, scale)
  end

  # ============================================================================
  # Date/Time Generators
  # ============================================================================

  @doc """
  Generates a date within bounds.
  """
  def generate_date(min, max, histogram)

  def generate_date(min, max, nil) do
    min_days = Date.to_gregorian_days(min)
    max_days = Date.to_gregorian_days(max)

    days = min_days + :rand.uniform(max_days - min_days + 1) - 1
    Date.from_gregorian_days(days)
  end

  def generate_date(min, max, histogram) when is_list(histogram) do
    min_days = Date.to_gregorian_days(min)
    max_days = Date.to_gregorian_days(max)

    days = generate_from_histogram(min_days / 1, max_days / 1, histogram) |> round()
    Date.from_gregorian_days(days)
  end

  @doc """
  Generates a timestamp within bounds.
  """
  def generate_timestamp(min, max, histogram)

  def generate_timestamp(min, max, nil) do
    min_unix = DateTime.to_unix(min)
    max_unix = DateTime.to_unix(max)

    unix = min_unix + :rand.uniform(max_unix - min_unix + 1) - 1
    DateTime.from_unix!(unix)
  end

  def generate_timestamp(min, max, histogram) when is_list(histogram) do
    min_unix = DateTime.to_unix(min)
    max_unix = DateTime.to_unix(max)

    unix = generate_from_histogram(min_unix / 1, max_unix / 1, histogram) |> round()
    DateTime.from_unix!(unix)
  end

  # ============================================================================
  # String Pattern Generators
  # ============================================================================

  @doc """
  Generates a realistic email address.
  """
  def generate_email do
    first = Enum.random(@first_names) |> String.downcase()
    last = Enum.random(@last_names) |> String.downcase()
    num = :rand.uniform(9999)
    domain = Enum.random(@domains)

    "#{first}.#{last}#{num}@#{domain}"
  end

  @doc """
  Generates a UUID v4.
  """
  def generate_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    # Set version (4) and variant bits
    c_versioned = (c &&& 0x0FFF) ||| 0x4000
    d_variant = (d &&& 0x3FFF) ||| 0x8000

    :io_lib.format(
      "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
      [a, b, c_versioned, d_variant, e]
    )
    |> IO.iodata_to_binary()
  end

  @doc """
  Generates a phone number in E.164 format.
  """
  def generate_phone do
    digits = for _ <- 1..10, into: "", do: Integer.to_string(:rand.uniform(10) - 1)
    "+1#{digits}"
  end

  @doc """
  Generates a URL.
  """
  def generate_url do
    protocol = Enum.random(["https", "http"])
    domain = Enum.random(@domains)
    path = Enum.random(@words)
    "#{protocol}://#{domain}/#{path}"
  end

  @doc """
  Generates a realistic name.
  """
  def generate_name do
    first = Enum.random(@first_names)
    last = Enum.random(@last_names)
    "#{first} #{last}"
  end

  @doc """
  Generates a first name.
  """
  def generate_first_name do
    Enum.random(@first_names)
  end

  @doc """
  Generates a last name.
  """
  def generate_last_name do
    Enum.random(@last_names)
  end

  @doc """
  Generates random text of specified length.
  """
  def generate_text(min_length, max_length) when min_length >= max_length do
    generate_text_of_length(min_length)
  end

  def generate_text(min_length, max_length) do
    length = min_length + :rand.uniform(max_length - min_length + 1) - 1
    generate_text_of_length(length)
  end

  defp generate_text_of_length(0), do: ""

  defp generate_text_of_length(target_length) do
    Stream.cycle(@words)
    |> Enum.reduce_while("", fn word, acc ->
      new_acc = if acc == "", do: word, else: "#{acc} #{word}"

      if String.length(new_acc) >= target_length do
        {:halt, String.slice(new_acc, 0, target_length)}
      else
        {:cont, new_acc}
      end
    end)
  end

  # ============================================================================
  # Low-Cardinality / Categorical Generators
  # ============================================================================

  @doc """
  Generates a value sampled from a list with optional frequency weights.
  """
  def generate_from_values(values, nil) do
    Enum.random(values)
  end

  def generate_from_values(values, frequencies) when is_list(frequencies) do
    idx = weighted_random(frequencies)
    Enum.at(values, idx)
  end

  # ============================================================================
  # Special Type Generators
  # ============================================================================

  @doc """
  Generates a boolean with optional null percentage and true percentage.
  """
  def generate_boolean(null_pct, true_pct) do
    if :rand.uniform() < null_pct do
      nil
    else
      :rand.uniform() < true_pct
    end
  end

  @doc """
  Generates a JSON value (object or array).
  """
  def generate_json(:object) do
    keys = Enum.take_random(@words, :rand.uniform(5))

    Map.new(keys, fn key ->
      value =
        case :rand.uniform(4) do
          1 -> Enum.random(@words)
          2 -> :rand.uniform(1000)
          3 -> :rand.uniform() < 0.5
          4 -> nil
        end

      {key, value}
    end)
  end

  def generate_json(:array) do
    count = :rand.uniform(5)
    for _ <- 1..count, do: Enum.random(@words)
  end

  def generate_json(_) do
    generate_json(:object)
  end

  @doc """
  Generates a random IPv4 address.
  """
  def generate_inet do
    octets = for _ <- 1..4, do: :rand.uniform(256) - 1
    Enum.join(octets, ".")
  end

  @doc """
  Generates an array of values using the provided generator function.
  """
  def generate_array(generator_fn, min_len, max_len) do
    len = min_len + :rand.uniform(max_len - min_len + 1) - 1
    for _ <- 1..len, do: generator_fn.()
  end

  # ============================================================================
  # Distribution Helpers
  # ============================================================================

  @doc """
  Selects a random index based on weighted probabilities.
  """
  def weighted_random(weights) do
    total = Enum.sum(weights)
    threshold = :rand.uniform() * total

    weights
    |> Enum.with_index()
    |> Enum.reduce_while(0.0, fn {weight, idx}, acc ->
      new_acc = acc + weight

      if new_acc >= threshold do
        {:halt, idx}
      else
        {:cont, new_acc}
      end
    end)
  end

  @doc """
  Generates a value from histogram-based distribution.
  """
  def generate_from_histogram(min, max, histogram) do
    bucket_idx = weighted_random(histogram)
    bucket_count = length(histogram)
    bucket_size = (max - min) / bucket_count

    bucket_min = min + bucket_idx * bucket_size
    bucket_max = bucket_min + bucket_size

    # Uniform random within selected bucket
    bucket_min + :rand.uniform() * (bucket_max - bucket_min)
  end
end
