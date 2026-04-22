defmodule Cake.Search.OpenSearchTest do
  use ExUnit.Case, async: true

  alias Cake.Search.OpenSearch

  describe "default accessors" do
    test "default_size/0" do
      assert OpenSearch.default_size() == 30
    end

    test "default_k/0" do
      assert OpenSearch.default_k() == 30
    end

    test "default_ef_search/0" do
      assert OpenSearch.default_ef_search() == 256
    end

    test "default_keyword_weight/0" do
      assert OpenSearch.default_keyword_weight() == 0.8
    end

    test "default_expand_offset/0" do
      assert OpenSearch.default_expand_offset() == 2
    end

    test "chunk_fields/0" do
      assert OpenSearch.chunk_fields() == ["section_title^2", "text"]
    end

    test "doc_fields/0" do
      assert OpenSearch.doc_fields() == ["title^3", "text"]
    end
  end
end
