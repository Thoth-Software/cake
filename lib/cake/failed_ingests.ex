defmodule Cake.FailedIngests do
  @moduledoc """
  The FailedIngests context.
  """

  import Ecto.Query, warn: false
  alias Cake.Repo

  alias Cake.FailedIngests.FailedIngest

  @doc """
  Returns the list of failed_ingests.

  ## Examples

      iex> list_failed_ingests()
      [%FailedIngest{}, ...]

  """
  def list_failed_ingests do
    Repo.all(FailedIngest)
  end

  @doc """
  Returns all non-fatal FailedIngest records matching the given
  behaviour, implementation, and version.
  """
  def list_failed_ingests_for(behaviour, implementation, version) do
    from(f in FailedIngest,
      where: f.pipeline_behaviour == ^behaviour,
      where: f.pipeline_implementation == ^implementation,
      where: f.version == ^version,
      where: f.pipeline_fatal == false
    )
    |> Repo.all()
  end

  @doc """
  Gets a single failed_ingest.

  Raises `Ecto.NoResultsError` if the Failed ingest does not exist.

  ## Examples

      iex> get_failed_ingest!(123)
      %FailedIngest{}

      iex> get_failed_ingest!(456)
      ** (Ecto.NoResultsError)

  """
  def get_failed_ingest!(id), do: Repo.get!(FailedIngest, id)

  @doc """
  Creates a failed_ingest.

  ## Examples

      iex> create_failed_ingest(%{field: value})
      {:ok, %FailedIngest{}}

      iex> create_failed_ingest(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_failed_ingest(attrs \\ %{}) do
    %FailedIngest{}
    |> FailedIngest.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a failed_ingest.

  ## Examples

      iex> update_failed_ingest(failed_ingest, %{field: new_value})
      {:ok, %FailedIngest{}}

      iex> update_failed_ingest(failed_ingest, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_failed_ingest(%FailedIngest{} = failed_ingest, attrs) do
    failed_ingest
    |> FailedIngest.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a failed_ingest.

  ## Examples

      iex> delete_failed_ingest(failed_ingest)
      {:ok, %FailedIngest{}}

      iex> delete_failed_ingest(failed_ingest)
      {:error, %Ecto.Changeset{}}

  """
  def delete_failed_ingest(%FailedIngest{} = failed_ingest) do
    Repo.delete(failed_ingest)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking failed_ingest changes.

  ## Examples

      iex> change_failed_ingest(failed_ingest)
      %Ecto.Changeset{data: %FailedIngest{}}

  """
  def change_failed_ingest(%FailedIngest{} = failed_ingest, attrs \\ %{}) do
    FailedIngest.changeset(failed_ingest, attrs)
  end
end
