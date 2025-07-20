defmodule Caque.Documents.Hexdocs do
  @moduledoc """
  The Hexdocs context.
  """

  import Ecto.Query, warn: false
  alias Caque.Repo

  alias Caque.Documents.Hexdocs.Hexdoc

  @doc """
  Returns all hexdocs from the passed Elixir version.
  """
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
  def get_hexdoc!(id), do: Repo.get!(Hexdoc, id)

  @doc """
  Creates a hexdoc.

  ## Examples

      iex> create_hexdoc(%{field: value})
      {:ok, %Hexdoc{}}

      iex> create_hexdoc(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_hexdoc(attrs \\ %{}) do
    %Hexdoc{}
    |> Hexdoc.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a hexdoc.

  ## Examples

      iex> update_hexdoc(hexdoc, %{field: new_value})
      {:ok, %Hexdoc{}}

      iex> update_hexdoc(hexdoc, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_hexdoc(%Hexdoc{} = hexdoc, attrs) do
    hexdoc
    |> Hexdoc.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a hexdoc.

  ## Examples

      iex> delete_hexdoc(hexdoc)
      {:ok, %Hexdoc{}}

      iex> delete_hexdoc(hexdoc)
      {:error, %Ecto.Changeset{}}

  """
  def delete_hexdoc(%Hexdoc{} = hexdoc) do
    Repo.delete(hexdoc)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking hexdoc changes.

  ## Examples

      iex> change_hexdoc(hexdoc)
      %Ecto.Changeset{data: %Hexdoc{}}

  """
  def change_hexdoc(%Hexdoc{} = hexdoc, attrs \\ %{}) do
    Hexdoc.changeset(hexdoc, attrs)
  end
end
