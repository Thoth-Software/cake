defmodule Cake.Accounts.User do
  @moduledoc """
  Ecto schema for a user account: a username, an optional email, a
  bcrypt-hashed password and the confirmation timestamp. Provides the
  registration, email-change, and password-change changesets along with
  `valid_password?/2` for authentication.

  A user logs in with the username. It is 3 to 32 characters from `a-z`,
  `0-9`, `_`, `.` and `-`, with letters accepted in either case. The column
  is `citext`: the name is stored as typed and compared case-insensitively,
  so `Caleb` and `caleb` are one username. The email is optional, and the
  flows that send mail (confirmation, password reset, email change) apply
  only to a user who has one.
  """

  use Cake.Schema
  import Ecto.Changeset

  schema "users" do
    field :username, :string
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :current_password, :string, virtual: true, redact: true
    field :confirmed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @typedoc """
  A registered user. `username` is what the user logs in with; `email` is
  `nil` for a user registered without one. `password` and `current_password`
  are virtual fields that only changesets read; the stored secret is
  `hashed_password`.
  """
  @type t :: %__MODULE__{
          __meta__: Ecto.Schema.Metadata.t(),
          id: Ecto.UUID.t() | nil,
          username: String.t() | nil,
          email: String.t() | nil,
          password: String.t() | nil,
          hashed_password: String.t() | nil,
          current_password: String.t() | nil,
          confirmed_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec doc_attrs() :: map()
  def doc_attrs do
    %{}
  end

  @doc """
  A user changeset for registration.

  A username and a password are required; an email is optional, and is
  validated when given.

  The username must be 3 to 32 characters from `a-z`, `0-9`, `_`, `.` and
  `-`, in either letter case. Anything else is a validation error, a NUL
  byte included: the username is validated as it was typed, before
  `sanitize_text_fields/1` strips NUL bytes from the changes, so a name
  cannot become valid by losing one.

  It is important to validate the length of both email and password.
  Otherwise databases may truncate the email without warnings, which
  could lead to unpredictable or insecure behaviour. Long passwords may
  also be very expensive to hash for certain algorithms.

  ## Options

    * `:hash_password` - Hashes the password so it can be stored securely
      in the database and ensures the password field is cleared to prevent
      leaks in the logs. If password hashing is not needed and clearing the
      password field is not desired (like when using this changeset for
      validations on a LiveView form), this option can be set to `false`.
      Defaults to `true`.

    * `:validate_email` - Validates the uniqueness of the email, in case
      you don't want to validate the uniqueness of the email (like when
      using this changeset for validations on a LiveView form before
      submitting the form), this option can be set to `false`.
      Defaults to `true`.

    * `:validate_username` - Validates the uniqueness of the username,
      whatever its letter case. Set it to `false` for the same reason as
      `:validate_email`: it queries the database. Defaults to `true`.
  """
  @spec registration_changeset(t(), map(), keyword()) :: Ecto.Changeset.t()
  def registration_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email, :password])
    |> cast_username(attrs)
    |> validate_username(opts)
    |> validate_email(opts)
    |> validate_password(opts)
    |> sanitize_text_fields()
  end

  # `cast/4` trims a value before it decides whether the value is empty, so a
  # username of nothing but whitespace (spaces, a lone newline) would be cast
  # to nil and reported as "can't be blank". Whitespace is outside the
  # username set like any other character, so the username is cast untrimmed:
  # only the empty string is empty, and such a name reaches the format check.
  defp cast_username(changeset, attrs) do
    cast(changeset, attrs, [:username], trim_values: fn _type, value -> value end)
  end

  # Runs before `sanitize_text_fields/1`, on the value as typed. The anchors
  # are `\A` and `\z` because `$` also matches before a trailing newline, and
  # the letters are spelled out in both cases rather than matched with the
  # `i` modifier, which under Unicode also accepts the characters that
  # case-fold to ASCII letters (the Kelvin sign, the long s).
  defp validate_username(changeset, opts) do
    changeset
    |> validate_required([:username])
    |> validate_format(:username, ~r/\A[a-zA-Z0-9_.-]+\z/,
      message: "can only contain letters a-z, digits, underscores, dots and hyphens"
    )
    |> validate_length(:username, min: 3, max: 32)
    |> maybe_validate_unique_username(opts)
  end

  # The column is `citext`, so the uniqueness query and the unique index both
  # compare case-insensitively. `unsafe_validate_unique/3` skips its query for
  # a username that already has an error, so an ill-formed name (one with a
  # NUL byte, which Postgres refuses as text) is never sent to the database.
  defp maybe_validate_unique_username(changeset, opts) do
    if Keyword.get(opts, :validate_username, true) do
      changeset
      |> unsafe_validate_unique(:username, Cake.Repo)
      |> unique_constraint(:username)
    else
      changeset
    end
  end

  # Does not require the email: registration leaves it optional, and
  # `email_changeset/3` requires it itself.
  defp validate_email(changeset, opts) do
    changeset
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> validate_length(:email, max: 160)
    |> maybe_validate_unique_email(opts)
    |> sanitize_text_fields()
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 12, max: 72)
    # Examples of additional password validation:
    # |> validate_format(:password, ~r/[a-z]/, message: "at least one lower case character")
    # |> validate_format(:password, ~r/[A-Z]/, message: "at least one upper case character")
    # |> validate_format(:password, ~r/[!?@#$%^&*_0-9]/, message: "at least one digit or punctuation character")
    |> maybe_hash_password(opts)
    |> sanitize_text_fields()
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      # If using Bcrypt, then further validate it is at most 72 bytes long
      |> validate_length(:password, max: 72, count: :bytes)
      # Hashing could be done with `Ecto.Changeset.prepare_changes/2`, but that
      # would keep the database transaction open longer and hurt performance.
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  defp maybe_validate_unique_email(changeset, opts) do
    if Keyword.get(opts, :validate_email, true) do
      changeset
      |> unsafe_validate_unique(:email, Cake.Repo)
      |> unique_constraint(:email)
    else
      changeset
    end
  end

  @doc """
  A user changeset for changing the email.

  It requires the email to change otherwise an error is added.
  """
  @spec email_changeset(t(), map(), keyword()) :: Ecto.Changeset.t()
  def email_changeset(user, attrs, opts \\ []) do
    changeset =
      user
      |> cast(attrs, [:email])
      |> validate_required([:email])
      |> validate_email(opts)

    case changeset do
      %{changes: %{email: _}} = cs -> cs
      %{} = cs -> add_error(cs, :email, "did not change")
    end
  end

  @doc """
  A user changeset for changing the password.

  ## Options

    * `:hash_password` - Hashes the password so it can be stored securely
      in the database and ensures the password field is cleared to prevent
      leaks in the logs. If password hashing is not needed and clearing the
      password field is not desired (like when using this changeset for
      validations on a LiveView form), this option can be set to `false`.
      Defaults to `true`.
  """
  @spec password_changeset(%__MODULE__{}, map(), keyword()) :: Ecto.Changeset.t()
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
  end

  @doc """
  Confirms the account by setting `confirmed_at`.
  """
  @spec confirm_changeset(%__MODULE__{} | Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def confirm_changeset(user) do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    change(user, confirmed_at: now)
  end

  @doc """
  Verifies the password.

  If there is no user or the user doesn't have a password, we call
  `Bcrypt.no_user_verify/0` to avoid timing attacks.
  """
  @spec valid_password?(%__MODULE__{} | any(), String.t() | any()) :: boolean()
  def valid_password?(%Cake.Accounts.User{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end

  @doc """
  Validates the current password otherwise adds an error to the changeset.
  """
  @spec validate_current_password(Ecto.Changeset.t(), String.t()) :: Ecto.Changeset.t()
  def validate_current_password(changeset, password) do
    changeset = cast(changeset, %{current_password: password}, [:current_password])

    if valid_password?(changeset.data, password) do
      changeset
    else
      add_error(changeset, :current_password, "is not valid")
    end
  end
end
