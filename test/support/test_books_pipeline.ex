defmodule Cake.TestBooksPipeline do
  @moduledoc """
  Test implementation of `Cake.Books.Pipeline` behaviour.

  Returns pre-built {ParsedBook, [Chunk]} tuples without touching the
  filesystem or the Rust NIF.  The caller controls content via the
  process dictionary key `:test_books_pipeline_books`, which must be a
  list of `{path, {%ParsedBook{}, [%Chunk{}]}}` tuples keyed by file
  path.
  """

  @behaviour Cake.Books.Pipeline

  alias Cake.Books.Chunk
  alias Cake.Books.ParsedBook

  @impl Cake.Books.Pipeline
  def load_binary(path) do
    {:ok, {path, "fake-binary"}}
  end

  @impl Cake.Books.Pipeline
  @spec parse({String.t(), binary()}) :: {ParsedBook.t(), [Chunk.t()]}
  def parse({path, _binary}) do
    books = Process.get(:test_books_pipeline_books, [])

    case List.keyfind(books, path, 0) do
      {^path, {book, chunks}} -> {book, chunks}
      nil -> raise "TestBooksPipeline: no book registered for path #{inspect(path)}"
    end
  end

  @impl Cake.Books.Pipeline
  def format, do: :test

  @impl Cake.Books.Pipeline
  def success_message, do: "Test books ingested"
end
