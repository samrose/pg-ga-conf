defmodule PgGaConf.Optimizer.Utils do
  @moduledoc """
  Utility functions for optimizer implementations.
  Handles encoding/decoding between Elixir and Python/Julia formats.
  """

  alias PgGaConf.KnobSpace

  @doc """
  Convert knob space to Python-compatible format.
  %{shared_buffers: {:continuous, 128.0, 16384.0}} -> %{"shared_buffers" => [128.0, 16384.0]}
  """
  @spec encode_knob_space(map()) :: map()
  def encode_knob_space(knob_space) do
    Map.new(knob_space, fn {name, def} ->
      {Atom.to_string(name), encode_knob_def(def)}
    end)
  end

  defp encode_knob_def({:continuous, min, max}), do: %{"type" => "float", "low" => min, "high" => max}
  defp encode_knob_def({:integer, min, max}), do: %{"type" => "int", "low" => min, "high" => max}
  defp encode_knob_def({:categorical, choices}), do: %{"type" => "categorical", "choices" => choices}

  @doc """
  Convert Python config back to atoms.
  %{"shared_buffers" => 4096} -> %{shared_buffers: 4096}
  """
  @spec decode_config(map()) :: map()
  def decode_config(config) do
    Map.new(config, fn {k, v} ->
      key = if is_binary(k), do: String.to_existing_atom(k), else: k
      {key, v}
    end)
  rescue
    ArgumentError -> config
  end

  @doc """
  Convert Elixir config to Python format.
  """
  @spec encode_config(map()) :: map()
  def encode_config(config) do
    Map.new(config, fn {k, v} ->
      {Atom.to_string(k), v}
    end)
  end

  @doc """
  Encode categorical knob value to integer for CMA-ES.
  """
  @spec encode_categorical(atom(), String.t()) :: integer() | nil
  def encode_categorical(knob, value) do
    case KnobSpace.choices(knob) do
      nil -> nil
      choices -> Enum.find_index(choices, &(&1 == value))
    end
  end

  @doc """
  Decode integer back to categorical value for CMA-ES.
  """
  @spec decode_categorical(atom(), number()) :: String.t() | nil
  def decode_categorical(knob, index) do
    case KnobSpace.choices(knob) do
      nil -> nil
      choices -> Enum.at(choices, round(index))
    end
  end

  @doc """
  Encode a config for CMA-ES (categoricals to integers).
  """
  @spec encode_config_for_cma(map(), [atom()]) :: map()
  def encode_config_for_cma(config, knob_names) do
    Map.new(config, fn {name, value} ->
      if name in knob_names and KnobSpace.categorical?(name) do
        {name, encode_categorical(name, value)}
      else
        {name, value}
      end
    end)
  end

  @doc """
  Decode a CMA-ES config (integers back to categoricals).
  """
  @spec decode_config_from_cma(map(), map()) :: map()
  def decode_config_from_cma(config, knob_defs) do
    Map.new(config, fn {name, value} ->
      name_atom = if is_binary(name), do: String.to_existing_atom(name), else: name

      case Map.get(knob_defs, name_atom) do
        {:categorical, _} ->
          {name_atom, decode_categorical(name_atom, value)}

        {:integer, _, _} ->
          {name_atom, round(value)}

        {:continuous, _, _} ->
          {name_atom, value}

        nil ->
          {name_atom, value}
      end
    end)
  rescue
    ArgumentError -> config
  end

  @doc """
  Convert knob space for CMA-ES (categoricals become integer ranges).
  """
  @spec knob_space_for_cma(map()) :: map()
  def knob_space_for_cma(knob_space) do
    Map.new(knob_space, fn {name, def} ->
      case def do
        {:continuous, min, max} -> {name, {:continuous, min, max}}
        {:integer, min, max} -> {name, {:integer, min, max}}
        {:categorical, choices} -> {name, {:integer, 0, length(choices) - 1}}
      end
    end)
  end

  @doc """
  Generate a random config within knob space bounds.
  """
  @spec random_config(map()) :: map()
  def random_config(knob_space) do
    Map.new(knob_space, fn {name, def} ->
      {name, random_value(def)}
    end)
  end

  defp random_value({:continuous, min, max}) do
    min + :rand.uniform() * (max - min)
  end

  defp random_value({:integer, min, max}) do
    min + :rand.uniform(max - min + 1) - 1
  end

  defp random_value({:categorical, choices}) do
    Enum.random(choices)
  end

  @doc """
  Clamp a config to knob space bounds.
  """
  @spec clamp_config(map(), map()) :: map()
  def clamp_config(config, knob_space) do
    Map.new(config, fn {name, value} ->
      case Map.get(knob_space, name) do
        {:continuous, min, max} ->
          {name, max(min, min(max, value))}

        {:integer, min, max} ->
          {name, max(min, min(max, round(value)))}

        {:categorical, choices} ->
          if value in choices do
            {name, value}
          else
            {name, hd(choices)}
          end

        nil ->
          {name, value}
      end
    end)
  end
end
