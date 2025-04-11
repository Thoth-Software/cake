defmodule Caque.Documents.ParsedDocument do
  use Caque.Schema
  import Ecto.Changeset
  import Ecto.Query, warn: false

  @moduledoc """
  Schema for parsed documentation chunks, used to generate embedding vectors
  and store searchable metadata for OpenSearch.

  Fields are tagged to indicate how they're used downstream:
  - `embedding_input`: indexed for embedding
  - `plaintext`: indexed for full-text keyword search
  - `metadata:<key>`: included in OpenSearch metadata under the given key

  :embedding should contain an embedding representing the value of :content.
  That is, if you take the right deep learning model and decode the embedding, you should
  get exactly what's in :content
  """

  @derive {Jason.Encoder, except: [:__meta__]}
  schema "parsed_documents" do
    # metadata: source
    # Where it came from (hexdocs, javadocs, mozilladocs)
    field :source, :string

    # metadata: version
    # version of the language (if core) or package (if not)
    field :version, :string

    # metadata: package
    # Name of the package, which can have different names in different languages.
    # In Elixir, these are modules. In Ruby, they're gems. And so on.
    field :package, :string

    # metadata: language 
    # Elixir, Python, Java, Clojure, etc
    field :language, :string

    # embedding_input + metadata
    # Name of the function/class/method/etc
    field :title, :string

    # metadata: url
    # url to the original doc
    field :url, :string

    # embedding
    # vector representation of the text
    field :embedding, {:array, :float}

    # text
    # the actual text
    field :text, :string

    # metadata: core
    # is this package part of the core language/standard library?
    field :core, :boolean, default: true

    timestamps()
  end

  @doc false
  def changeset(parsed_doc, attrs \\ %{}) do
    parsed_doc
    |> cast(attrs, [
      :source,
      :version,
      :package,
      :language,
      :title,
      :url,
      :embedding,
      :text,
      :core
    ])
    |> validate_required([
      :source,
      :version,
      :package,
      # :title,
      :url
      # text:
    ])
  end

  def base_query(), do: from(p in __MODULE__)

  def by_version(query, version) do
    from h in query,
      where: h.version == ^version
  end

  def by_language(query, language) do
    from h in query,
      where: h.language == ^language
  end

  def by_source(query, source) do
    from h in query,
      where: h.source == ^source
  end
end
