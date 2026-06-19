defmodule Cake.Documents.ParsedDocument do
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

  use Cake.Schema
  use Cake.GDS

  import Ecto.Changeset

  # Cake.GDS callbacks

  @impl Cake.GDS
  def index_name, do: "docs"

  @impl Cake.GDS
  def search_fields, do: ["title^3", "text"]

  @impl Cake.GDS
  defdelegate load_from_hits(hits), to: Cake.Documents.ParsedDocuments

  # expand_with_neighbors/2 inherited from `use Cake.GDS` default (identity).
  # ParsedDocument has no ordering concept.

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

  @type t :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Ecto.UUID.t() | nil,
          source: String.t(),
          version: String.t(),
          package: String.t(),
          language: String.t() | nil,
          title: String.t() | nil,
          url: String.t(),
          embedding: [float()] | nil,
          text: String.t(),
          core: boolean(),
          inserted_at: NaiveDateTime.t() | nil,
          updated_at: NaiveDateTime.t() | nil
        }

  @doc false
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
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
      :url,
      :text
    ])
    |> sanitize_text_fields()
  end

  @spec base_query() :: Ecto.Query.t()
  def base_query(), do: from(p in __MODULE__)

  @spec by_version(Ecto.Query.t(), String.t()) :: Ecto.Query.t()
  def by_version(query, version) do
    from h in query,
      where: h.version == ^version
  end

  @spec by_language(Ecto.Query.t(), String.t()) :: Ecto.Query.t()
  def by_language(query, language) do
    from h in query,
      where: h.language == ^language
  end

  @spec by_source(Ecto.Query.t(), String.t()) :: Ecto.Query.t()
  def by_source(query, source) do
    from h in query,
      where: h.source == ^source
  end

  @spec doc_attrs() :: map()
  def doc_attrs do
    %{}
  end
end

defimpl Cake.Promptable, for: Cake.Documents.ParsedDocument do
  @spec prompt_context(Cake.Documents.ParsedDocument.t()) :: String.t()
  def prompt_context(doc) do
    "Package: #{doc.package} | Function: #{doc.title}\n" <>
      "URL: #{doc.url}\n\n" <>
      doc.text
  end
end

defimpl Cake.Citable, for: Cake.Documents.ParsedDocument do
  @preview_length 200

  @spec metadata(Cake.Documents.ParsedDocument.t()) :: Cake.Citable.metadata()
  def metadata(doc) do
    %{
      id: doc.id,
      label: "#{doc.package} — #{doc.title}",
      source_ref: doc.url,
      preview: String.slice(doc.text, 0, @preview_length),
      extras: %{
        package: doc.package,
        title: doc.title,
        version: doc.version,
        language: doc.language,
        source: doc.source
      }
    }
  end
end
