defmodule Cake.Books.PipelineTest do
  use ExUnit.Case, async: true

  alias Cake.Books.Chunk
  alias Cake.Books.ParsedBook
  alias Cake.Books.Pipeline

  describe "munge_persisted_stream/1" do
    test "unwraps {:ok, {:ok, value}} into {:ok, value}" do
      book = %ParsedBook{title: "T"}
      chunks = [%Chunk{text: "c"}]

      assert {:ok, {^book, ^chunks}} =
               Pipeline.munge_persisted_stream({:ok, {:ok, {book, chunks}}})
    end

    test "unwraps {:ok, {:error, {path, reason}}} into {:error, {path, stringified}}" do
      assert {:error, {"/tmp/x.pdf", reason}} =
               Pipeline.munge_persisted_stream({:ok, {:error, {"/tmp/x.pdf", :some_reason}}})

      assert reason =~ "some_reason"
    end

    test "unwraps {:ok, {:error, reason}} into {:error, reason}" do
      assert {:error, :boom} = Pipeline.munge_persisted_stream({:ok, {:error, :boom}})
    end

    test "handles {:exit, {input_with_book, reason}}" do
      book = %ParsedBook{source_file_path: "/tmp/test.pdf"}
      chunks = [%Chunk{text: "c"}]

      assert {:error, {"/tmp/test.pdf", _}} =
               Pipeline.munge_persisted_stream({:exit, {{book, chunks}, :killed}})
    end

    test "handles {:exit, {non_book_input, reason}}" do
      assert {:error, {nil, _}} =
               Pipeline.munge_persisted_stream({:exit, {"unknown", :killed}})
    end
  end
end
