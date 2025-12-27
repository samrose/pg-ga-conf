defmodule PgGaConf.PatternDiscoveryTest do
  use ExUnit.Case, async: true

  alias PgGaConf.PatternDiscovery

  describe "cosine_similarity/2" do
    test "returns 1.0 for identical vectors" do
      vec = [1.0, 2.0, 3.0, 4.0, 5.0]
      assert_in_delta PatternDiscovery.cosine_similarity(vec, vec), 1.0, 0.0001
    end

    test "returns 0.0 for orthogonal vectors" do
      vec1 = [1.0, 0.0, 0.0]
      vec2 = [0.0, 1.0, 0.0]
      assert_in_delta PatternDiscovery.cosine_similarity(vec1, vec2), 0.0, 0.0001
    end

    test "returns -1.0 for opposite vectors" do
      vec1 = [1.0, 2.0, 3.0]
      vec2 = [-1.0, -2.0, -3.0]
      assert_in_delta PatternDiscovery.cosine_similarity(vec1, vec2), -1.0, 0.0001
    end

    test "handles zero vectors" do
      vec1 = [0.0, 0.0, 0.0]
      vec2 = [1.0, 2.0, 3.0]
      assert PatternDiscovery.cosine_similarity(vec1, vec2) == 0.0
    end
  end

  describe "cosine_distance/2" do
    test "returns 0.0 for identical vectors" do
      vec = [1.0, 2.0, 3.0, 4.0, 5.0]
      assert_in_delta PatternDiscovery.cosine_distance(vec, vec), 0.0, 0.0001
    end

    test "returns 1.0 for orthogonal vectors" do
      vec1 = [1.0, 0.0, 0.0]
      vec2 = [0.0, 1.0, 0.0]
      assert_in_delta PatternDiscovery.cosine_distance(vec1, vec2), 1.0, 0.0001
    end

    test "returns 2.0 for opposite vectors" do
      vec1 = [1.0, 2.0, 3.0]
      vec2 = [-1.0, -2.0, -3.0]
      assert_in_delta PatternDiscovery.cosine_distance(vec1, vec2), 2.0, 0.0001
    end
  end
end
