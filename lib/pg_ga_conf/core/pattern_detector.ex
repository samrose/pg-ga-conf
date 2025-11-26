defmodule PgGaConf.Core.PatternDetector do
  @moduledoc """
  Detects patterns in database column values.
  """

  @doc """
  Detects string patterns in a list of values.
  Returns list of {pattern_type, confidence} tuples.
  """
  def detect_string_patterns(values) when is_list(values) do
    sample = Enum.take(values, 100)
    patterns = []

    # Email pattern
    email_count = Enum.count(sample, &is_email?/1)
    patterns = if email_count > 0 do
      [{:email, email_count / length(sample)} | patterns]
    else
      patterns
    end

    # UUID pattern
    uuid_count = Enum.count(sample, &is_uuid?/1)
    patterns = if uuid_count > 0 do
      [{:uuid, uuid_count / length(sample)} | patterns]
    else
      patterns
    end

    # URL pattern
    url_count = Enum.count(sample, &is_url?/1)
    patterns = if url_count > 0 do
      [{:url, url_count / length(sample)} | patterns]
    else
      patterns
    end

    # Phone pattern
    phone_count = Enum.count(sample, &is_phone?/1)
    patterns = if phone_count > 0 do
      [{:phone, phone_count / length(sample)} | patterns]
    else
      patterns
    end

    # JSON pattern
    json_count = Enum.count(sample, &is_json?/1)
    patterns = if json_count > 0 do
      [{:json, json_count / length(sample)} | patterns]
    else
      patterns
    end

    patterns
  end

  @doc """
  Categorizes a string column based on its values.
  """
  def categorize_string_column(values) when is_list(values) do
    patterns = detect_string_patterns(values)

    cond do
      has_pattern?(patterns, :email, 0.8) -> :email
      has_pattern?(patterns, :uuid, 0.8) -> :uuid
      has_pattern?(patterns, :url, 0.8) -> :url
      has_pattern?(patterns, :phone, 0.8) -> :phone
      has_pattern?(patterns, :json, 0.8) -> :json
      all_match?(values, ~r/^[A-Z][a-z]+ [A-Z][a-z]+$/) -> :full_name
      all_match?(values, ~r/^[A-Z][a-z]+$/) -> :first_name
      all_match?(values, ~r/^\d{4}-\d{2}-\d{2}$/) -> :date_string
      all_match?(values, ~r/^[A-Z]{2,5}$/) -> :code
      true -> :generic_text
    end
  end

  # Private helpers

  defp is_email?(value) when is_binary(value) do
    String.match?(value, ~r/@.*\./)
  end
  defp is_email?(_), do: false

  defp is_uuid?(value) when is_binary(value) do
    String.match?(value, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i)
  end
  defp is_uuid?(_), do: false

  defp is_url?(value) when is_binary(value) do
    String.match?(value, ~r/^https?:\/\//)
  end
  defp is_url?(_), do: false

  defp is_phone?(value) when is_binary(value) do
    String.match?(value, ~r/^[\+\d\s\-\(\)]{10,}$/)
  end
  defp is_phone?(_), do: false

  defp is_json?(value) when is_binary(value) do
    String.starts_with?(value, "{") or String.starts_with?(value, "[")
  end
  defp is_json?(_), do: false

  defp has_pattern?(patterns, type, min_confidence) do
    case List.keyfind(patterns, type, 0) do
      {^type, confidence} -> confidence >= min_confidence
      nil -> false
    end
  end

  defp all_match?(values, regex) do
    sample = Enum.take(values, 20)
    match_count = Enum.count(sample, &String.match?(&1, regex))
    match_count / length(sample) > 0.8
  end
end
