defmodule Cake.Documents.Hexdocs do
  @moduledoc """
  The Hexdocs context.
  """

  import Ecto.Query, warn: false
  alias Cake.Repo

  alias Cake.Documents.Hexdocs.Hexdoc

  @doc """
  Returns all hexdocs from the passed Elixir version.
  """
  @spec hexdocs_by_version(String.t()) :: [struct()]
  def hexdocs_by_version(version) do
    Hexdoc.base_query()
    |> Hexdoc.by_version(version)
    |> Repo.all()
  end

  @doc """
  Returns the list of hexdocs.

  ## Examples

      iex> list_hexdocs()
      [%Hexdoc{}, ...]

  """
  @spec list_hexdocs() :: [struct()]
  def list_hexdocs do
    Repo.all(Hexdoc)
  end

  @doc """
  Gets a single hexdoc.

  Raises `Ecto.NoResultsError` if the Hexdoc does not exist.

  ## Examples

      iex> get_hexdoc!(123)
      %Hexdoc{}

      iex> get_hexdoc!(456)
      ** (Ecto.NoResultsError)

  """
  @spec get_hexdoc!(binary()) :: struct()
  def get_hexdoc!(id), do: Repo.get!(Hexdoc, id)

  @doc """
  Creates a hexdoc.

  ## Examples

      iex> create_hexdoc(%{field: value})
      {:ok, %Hexdoc{}}

      iex> create_hexdoc(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  @spec create_hexdoc(map()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def create_hexdoc(attrs \\ %{}) do
    %Hexdoc{}
    |> Hexdoc.changeset(attrs)
    |> Repo.insert(log: false)
  end

  @doc """
  Updates a hexdoc.

  ## Examples

      iex> update_hexdoc(hexdoc, %{field: new_value})
      {:ok, %Hexdoc{}}

      iex> update_hexdoc(hexdoc, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  @spec update_hexdoc(struct(), map()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def update_hexdoc(%Hexdoc{} = hexdoc, attrs) do
    hexdoc
    |> Hexdoc.changeset(attrs)
    |> Repo.update(log: false)
  end

  @doc """
  Deletes a hexdoc.

  ## Examples

      iex> delete_hexdoc(hexdoc)
      {:ok, %Hexdoc{}}

      iex> delete_hexdoc(hexdoc)
      {:error, %Ecto.Changeset{}}

  """
  @spec delete_hexdoc(struct()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def delete_hexdoc(%Hexdoc{} = hexdoc) do
    Repo.delete(hexdoc)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking hexdoc changes.

  ## Examples

      iex> change_hexdoc(hexdoc)
      %Ecto.Changeset{data: %Hexdoc{}}

  """
  @spec change_hexdoc(struct(), map()) :: Ecto.Changeset.t()
  def change_hexdoc(%Hexdoc{} = hexdoc, attrs \\ %{}) do
    Hexdoc.changeset(hexdoc, attrs)
  end
end
