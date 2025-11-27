defmodule PgGaConf.Optimizer.UtilsTest do
  use ExUnit.Case, async: true

  alias PgGaConf.Optimizer.Utils
  alias PgGaConf.Test.Fixtures

  describe "encode_knob_space/1" do
    test "encodes continuous knobs" do
      knob_space = %{shared_buffers: {:continuous, 128.0, 16384.0}}
      result = Utils.encode_knob_space(knob_space)

      assert result == %{
               "shared_buffers" => %{"type" => "float", "low" => 128.0, "high" => 16384.0}
             }
    end

    test "encodes integer knobs" do
      knob_space = %{max_connections: {:integer, 20, 500}}
      result = Utils.encode_knob_space(knob_space)

      assert result == %{
               "max_connections" => %{"type" => "int", "low" => 20, "high" => 500}
             }
    end

    test "encodes categorical knobs" do
      knob_space = %{huge_pages: {:categorical, ["off", "on", "try"]}}
      result = Utils.encode_knob_space(knob_space)

      assert result == %{
               "huge_pages" => %{"type" => "categorical", "choices" => ["off", "on", "try"]}
             }
    end

    test "encodes mixed knob space" do
      knob_space = Fixtures.sample_knob_space()
      result = Utils.encode_knob_space(knob_space)

      assert map_size(result) == 4
      assert is_map(result["shared_buffers"])
      assert is_map(result["work_mem"])
      assert is_map(result["max_connections"])
      assert is_map(result["huge_pages"])
    end
  end

  describe "decode_config/1" do
    test "converts string keys to atoms" do
      config = %{"shared_buffers" => 4096.0, "work_mem" => 64.0}
      result = Utils.decode_config(config)

      assert result == %{shared_buffers: 4096.0, work_mem: 64.0}
    end

    test "preserves atom keys" do
      config = %{shared_buffers: 4096.0}
      result = Utils.decode_config(config)

      assert result == %{shared_buffers: 4096.0}
    end

    test "handles mixed keys" do
      config = %{"shared_buffers" => 4096.0, work_mem: 64.0}
      result = Utils.decode_config(config)

      assert result[:shared_buffers] == 4096.0
      assert result[:work_mem] == 64.0
    end
  end

  describe "encode_config/1" do
    test "converts atom keys to strings" do
      config = %{shared_buffers: 4096.0, work_mem: 64.0}
      result = Utils.encode_config(config)

      assert result == %{"shared_buffers" => 4096.0, "work_mem" => 64.0}
    end
  end

  describe "encode_categorical/2" do
    test "encodes valid categorical value to index" do
      assert Utils.encode_categorical(:huge_pages, "off") == 0
      assert Utils.encode_categorical(:huge_pages, "on") == 1
      assert Utils.encode_categorical(:huge_pages, "try") == 2
    end

    test "returns nil for non-categorical knob" do
      assert Utils.encode_categorical(:shared_buffers, "value") == nil
    end

    test "returns nil for invalid choice" do
      assert Utils.encode_categorical(:huge_pages, "invalid") == nil
    end
  end

  describe "decode_categorical/2" do
    test "decodes index to categorical value" do
      assert Utils.decode_categorical(:huge_pages, 0) == "off"
      assert Utils.decode_categorical(:huge_pages, 1) == "on"
      assert Utils.decode_categorical(:huge_pages, 2) == "try"
    end

    test "rounds float index" do
      assert Utils.decode_categorical(:huge_pages, 0.4) == "off"
      assert Utils.decode_categorical(:huge_pages, 0.6) == "on"
      assert Utils.decode_categorical(:huge_pages, 1.5) == "try"
    end

    test "returns nil for non-categorical knob" do
      assert Utils.decode_categorical(:shared_buffers, 0) == nil
    end
  end

  describe "encode_config_for_cma/2" do
    test "encodes categorical values to integers" do
      config = %{shared_buffers: 4096.0, huge_pages: "on"}
      knob_names = [:shared_buffers, :huge_pages]

      result = Utils.encode_config_for_cma(config, knob_names)

      assert result[:shared_buffers] == 4096.0
      assert result[:huge_pages] == 1
    end

    test "leaves non-categorical values unchanged" do
      config = %{shared_buffers: 4096.0, max_connections: 100}
      knob_names = [:shared_buffers, :max_connections]

      result = Utils.encode_config_for_cma(config, knob_names)

      assert result[:shared_buffers] == 4096.0
      assert result[:max_connections] == 100
    end
  end

  describe "decode_config_from_cma/2" do
    test "decodes integer indices to categorical values" do
      config = %{"shared_buffers" => 4096.0, "huge_pages" => 1}
      knob_defs = %{
        shared_buffers: {:continuous, 128.0, 16384.0},
        huge_pages: {:categorical, ["off", "on", "try"]}
      }

      result = Utils.decode_config_from_cma(config, knob_defs)

      assert result[:shared_buffers] == 4096.0
      assert result[:huge_pages] == "on"
    end

    test "rounds integer knob values" do
      config = %{"max_connections" => 100.7}
      knob_defs = %{max_connections: {:integer, 20, 500}}

      result = Utils.decode_config_from_cma(config, knob_defs)

      assert result[:max_connections] == 101
    end

    test "preserves continuous values" do
      config = %{"shared_buffers" => 4096.5}
      knob_defs = %{shared_buffers: {:continuous, 128.0, 16384.0}}

      result = Utils.decode_config_from_cma(config, knob_defs)

      assert result[:shared_buffers] == 4096.5
    end
  end

  describe "knob_space_for_cma/1" do
    test "converts categorical to integer range" do
      knob_space = %{huge_pages: {:categorical, ["off", "on", "try"]}}
      result = Utils.knob_space_for_cma(knob_space)

      assert result[:huge_pages] == {:integer, 0, 2}
    end

    test "preserves continuous knobs" do
      knob_space = %{shared_buffers: {:continuous, 128.0, 16384.0}}
      result = Utils.knob_space_for_cma(knob_space)

      assert result[:shared_buffers] == {:continuous, 128.0, 16384.0}
    end

    test "preserves integer knobs" do
      knob_space = %{max_connections: {:integer, 20, 500}}
      result = Utils.knob_space_for_cma(knob_space)

      assert result[:max_connections] == {:integer, 20, 500}
    end

    test "converts full sample knob space" do
      knob_space = Fixtures.sample_knob_space()
      result = Utils.knob_space_for_cma(knob_space)

      assert result[:shared_buffers] == {:continuous, 128.0, 16384.0}
      assert result[:work_mem] == {:continuous, 4.0, 2048.0}
      assert result[:max_connections] == {:integer, 20, 500}
      assert result[:huge_pages] == {:integer, 0, 2}
    end
  end

  describe "random_config/1" do
    test "generates config within continuous bounds" do
      knob_space = %{shared_buffers: {:continuous, 128.0, 16384.0}}

      for _ <- 1..10 do
        config = Utils.random_config(knob_space)
        assert config[:shared_buffers] >= 128.0
        assert config[:shared_buffers] <= 16384.0
      end
    end

    test "generates config within integer bounds" do
      knob_space = %{max_connections: {:integer, 20, 500}}

      for _ <- 1..10 do
        config = Utils.random_config(knob_space)
        assert config[:max_connections] >= 20
        assert config[:max_connections] <= 500
        assert is_integer(config[:max_connections])
      end
    end

    test "generates valid categorical values" do
      knob_space = %{huge_pages: {:categorical, ["off", "on", "try"]}}

      for _ <- 1..10 do
        config = Utils.random_config(knob_space)
        assert config[:huge_pages] in ["off", "on", "try"]
      end
    end

    test "generates full config from sample knob space" do
      knob_space = Fixtures.sample_knob_space()
      config = Utils.random_config(knob_space)

      assert map_size(config) == 4
      assert Map.has_key?(config, :shared_buffers)
      assert Map.has_key?(config, :work_mem)
      assert Map.has_key?(config, :max_connections)
      assert Map.has_key?(config, :huge_pages)
    end
  end

  describe "clamp_config/2" do
    test "clamps continuous values below minimum" do
      config = %{shared_buffers: 50.0}
      knob_space = %{shared_buffers: {:continuous, 128.0, 16384.0}}

      result = Utils.clamp_config(config, knob_space)

      assert result[:shared_buffers] == 128.0
    end

    test "clamps continuous values above maximum" do
      config = %{shared_buffers: 999999.0}
      knob_space = %{shared_buffers: {:continuous, 128.0, 16384.0}}

      result = Utils.clamp_config(config, knob_space)

      assert result[:shared_buffers] == 16384.0
    end

    test "preserves continuous values within bounds" do
      config = %{shared_buffers: 4096.0}
      knob_space = %{shared_buffers: {:continuous, 128.0, 16384.0}}

      result = Utils.clamp_config(config, knob_space)

      assert result[:shared_buffers] == 4096.0
    end

    test "clamps and rounds integer values" do
      config = %{max_connections: 10.7}
      knob_space = %{max_connections: {:integer, 20, 500}}

      result = Utils.clamp_config(config, knob_space)

      assert result[:max_connections] == 20
    end

    test "replaces invalid categorical with first choice" do
      config = %{huge_pages: "invalid"}
      knob_space = %{huge_pages: {:categorical, ["off", "on", "try"]}}

      result = Utils.clamp_config(config, knob_space)

      assert result[:huge_pages] == "off"
    end

    test "preserves valid categorical values" do
      config = %{huge_pages: "on"}
      knob_space = %{huge_pages: {:categorical, ["off", "on", "try"]}}

      result = Utils.clamp_config(config, knob_space)

      assert result[:huge_pages] == "on"
    end

    test "preserves values for unknown knobs" do
      config = %{unknown_knob: 123}
      knob_space = %{}

      result = Utils.clamp_config(config, knob_space)

      assert result[:unknown_knob] == 123
    end

    test "clamps full sample config" do
      config = %{
        shared_buffers: -100.0,
        work_mem: 999999.0,
        max_connections: 10,
        huge_pages: "invalid"
      }

      knob_space = Fixtures.sample_knob_space()
      result = Utils.clamp_config(config, knob_space)

      assert result[:shared_buffers] == 128.0
      assert result[:work_mem] == 2048.0
      assert result[:max_connections] == 20
      assert result[:huge_pages] == "off"
    end
  end
end
