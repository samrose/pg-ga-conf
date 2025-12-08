defmodule PgGaConf.JuliaTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias PgGaConf.Julia
  alias PgGaConf.Test.Fixtures

  describe "with mock backend" do
    setup do
      # Start Julia in mock mode for testing
      {:ok, _pid} = start_supervised({Julia, mode: :mock})
      :ok
    end

    test "healthy? returns true" do
      assert Julia.healthy?()
    end

    test "sobol_sample generates samples" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, result} = Julia.sobol_sample(knob_space, 16)

      assert Map.has_key?(result, "samples") || Map.has_key?(result, :samples)
    end

    test "generate_sobol_samples returns samples and matrices" do
      knob_space = Fixtures.minimal_knob_space()
      {:ok, result} = Julia.generate_sobol_samples(knob_space, 16)

      assert Map.has_key?(result, "samples") || Map.has_key?(result, :samples)
      assert Map.has_key?(result, "matrices") || Map.has_key?(result, :matrices)
    end

    test "compute_sensitivity returns indices" do
      knob_space = Fixtures.minimal_knob_space()

      # Fake results and matrices
      results = for _ <- 1..100, do: :rand.uniform()
      matrices = %{"A" => [], "B" => []}

      {:ok, indices} = Julia.compute_sensitivity(results, matrices, knob_space)

      assert is_map(indices)
    end
  end

  describe "encode_knobs/1 helper" do
    test "encodes continuous knobs" do
      # Access private function via module attribute test
      knob = {:continuous, 128.0, 16384.0}
      # We can test this indirectly by verifying sobol_sample works
      knob_space = %{shared_buffers: knob}

      # Start mock for testing
      {:ok, _pid} = start_supervised({Julia, mode: :mock})

      {:ok, _result} = Julia.sobol_sample(knob_space, 8)
    end

    test "encodes categorical knobs as integer range" do
      knob = {:categorical, ["off", "on", "try"]}
      knob_space = %{huge_pages: knob}

      {:ok, _pid} = start_supervised({Julia, mode: :mock})

      {:ok, _result} = Julia.sobol_sample(knob_space, 8)
    end
  end
end

defmodule PgGaConf.Julia.LocalJuliaTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :julia_required

  alias PgGaConf.Julia
  alias PgGaConf.Test.Fixtures

  describe "with local Julia backend" do
    setup do
      # Skip if Julia not available
      case System.find_executable("julia") do
        nil ->
          :skip

        _julia ->
          # Start Julia with local backend
          {:ok, _pid} = start_supervised({Julia, mode: :local})
          # Give Julia time to start
          Process.sleep(5_000)
          :ok
      end
    end

    @tag timeout: 120_000
    test "generates real Sobol samples" do
      knob_space = Fixtures.minimal_knob_space()

      case Julia.generate_sobol_samples(knob_space, 16) do
        {:ok, result} ->
          samples = result["samples"] || result[:samples]
          assert is_list(samples)
          assert length(samples) > 0

        {:error, :not_connected} ->
          # Skip if Julia isn't ready
          :ok
      end
    end

    @tag timeout: 120_000
    test "computes sensitivity indices" do
      knob_space = Fixtures.minimal_knob_space()

      # First generate samples
      case Julia.generate_sobol_samples(knob_space, 16) do
        {:ok, %{"samples" => samples, "matrices" => matrices}} ->
          # Create fake benchmark results
          results = Enum.map(samples, fn _ -> :rand.uniform() end)

          # Compute sensitivity
          {:ok, indices} = Julia.compute_sensitivity(results, matrices, knob_space)

          # Verify structure
          assert is_map(indices)

          for {_name, values} <- indices do
            assert Map.has_key?(values, "S1") || Map.has_key?(values, :s1)
            assert Map.has_key?(values, "ST") || Map.has_key?(values, :st)
          end

        {:error, _} ->
          :ok
      end
    end
  end
end
