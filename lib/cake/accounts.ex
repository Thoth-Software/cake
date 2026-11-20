defmodule Cake.Accounts do
  @moduledoc """
  The Accounts context.
  """

  use Boundary, top_level?: true, deps: [Cake], exports: [User]

  import Ecto.Query, warn: false
  alias Cake.Repo

  alias Cake.Accounts.User
  alias Cake.Accounts.UserNotifier
  alias Cake.Accounts.UserToken

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  @spec get_user_by_email_and_password(String.t(), String.t()) :: User.t() | nil
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a user by username and password, for logging in.

  The username matches whatever its letter case. An unknown username and a
  wrong password both return `nil`, and both pay for a password check
  (`Cake.Accounts.User.valid_password?/2`), so neither the answer nor the
  time it takes says which half was wrong.

  A username Postgres cannot take as text (one with a NUL byte, or invalid
  UTF-8) is an unknown username: it returns `nil` without a query, where the
  query would raise.

  ## Examples

      iex> get_user_by_username_and_password("caleb", "correct_password")
      %User{}

      iex> get_user_by_username_and_password("CALEB", "correct_password")
      %User{}

      iex> get_user_by_username_and_password("caleb", "invalid_password")
      nil

  """
  @spec get_user_by_username_and_password(String.t(), String.t()) :: User.t() | nil
  def get_user_by_username_and_password(username, password)
      when is_binary(username) and is_binary(password) do
    user = if text_parameter?(username), do: Repo.get_by(User, username: username)
    if User.valid_password?(user, password), do: user
  end

  # Postgres refuses a text parameter that holds a NUL byte or is not valid
  # UTF-8, with an encoding error (22021) rather than an empty result.
  defp text_parameter?(value), do: String.valid?(value) and not String.contains?(value, <<0>>)

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  @spec get_user!(binary()) :: User.t()
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Returns every user, ordered by username whatever its letter case.

  It is the admin panel's list, and it is not paged: a Cake has as many
  users as an admin has made logins for.

  ## Examples

      iex> list_users()
      [%User{}, ...]

  """
  @spec list_users() :: [User.t()]
  def list_users do
    Repo.all(from u in User, order_by: [asc: u.username, asc: u.id])
  end

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  @spec register_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def register_user(attrs) do
    %User{role: :member}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates a user with a role.

  This is how the first admin is made, since every admin screen needs an
  admin, and how an admin makes logins for others. Unlike `register_user/1`,
  which is the public page and always makes a member, the caller says which
  role it means: `:role` is required, as `:member` or `:admin` (or the same
  as strings).

  The username and password are held to the rules registration holds them
  to, and the email is optional. The user can log in at once.

  In a release, call it through `bin/cake rpc`; in dev, through `mix run -e`.
  Never pass the password on the command line, where it is left in the shell
  history and shown in the process list. With `mix run -e` it can come from
  the environment. Through `rpc` it has to come from standard input: the
  expression is evaluated on the running node, which does not have the
  environment of the shell that ran `rpc`. The README has both commands
  ("Roles and the First Admin").

  ## Examples

      iex> create_user(%{username: "caleb", password: "a long password", role: :admin})
      {:ok, %User{}}

      iex> create_user(%{username: "caleb", password: "a long password"})
      {:error, %Ecto.Changeset{}}

  """
  @spec create_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def create_user(attrs) do
    %User{}
    |> User.creation_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking the creation of a user with a
  role, for the admin panel's form.

  It validates as `create_user/1` does, except that it does not hash the
  password and does not ask the database whether the username or the email
  is taken: it runs on every keystroke.

  ## Examples

      iex> change_user_creation(%User{})
      %Ecto.Changeset{data: %User{}}

  """
  @spec change_user_creation(User.t(), map()) :: Ecto.Changeset.t()
  def change_user_creation(%User{} = user, attrs \\ %{}) do
    User.creation_changeset(user, attrs,
      hash_password: false,
      validate_email: false,
      validate_username: false
    )
  end

  ## Roles and the last admin

  @doc """
  Changes a user's username and role, as an admin does from the panel.

  Nothing else is changed: a password or an email among the attributes is
  ignored. (An admin sets a password with `reset_user_password/2`, which
  also ends the user's sessions.)

  The role is changed under the rule `update_user_role/2` keeps, in the same
  way: demoting the last admin is refused with `{:error, :last_admin}`, and
  then nothing changes, the username included. The decision goes by the role
  in the database, and is safe when requests race (see `delete_user/1`).

  A username that breaks a rule or is already taken, or a role that is
  neither `:member` nor `:admin`, is `{:error, changeset}`.

  Raises `Ecto.NoResultsError` if the user no longer exists.

  ## Examples

      iex> update_user(user, %{username: "caleb", role: :admin})
      {:ok, %User{}}

      iex> update_user(the_only_admin, %{role: :member})
      {:error, :last_admin}

      iex> update_user(user, %{username: "taken"})
      {:error, %Ecto.Changeset{}}

  """
  @spec update_user(User.t(), map()) ::
          {:ok, User.t()} | {:error, :last_admin | Ecto.Changeset.t()}
  def update_user(%User{} = user, attrs) do
    under_last_admin_rule(user, fn current, last_admin? ->
      changeset = User.update_changeset(current, attrs)

      if last_admin? and steps_down?(changeset) do
        {:error, :last_admin}
      else
        Repo.update(changeset)
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking the changes `update_user/2`
  makes, for the admin panel's form.

  It validates as `update_user/2` does, except that it does not ask the
  database whether the username is taken, and knows nothing of the
  last-admin rule: both are decided when the change is made.

  ## Examples

      iex> change_user(user)
      %Ecto.Changeset{data: %User{}}

  """
  @spec change_user(User.t(), map()) :: Ecto.Changeset.t()
  def change_user(%User{} = user, attrs \\ %{}) do
    User.update_changeset(user, attrs, validate_username: false)
  end

  @doc """
  Changes a user's role.

  There is always at least one admin: demoting the last one is refused with
  `{:error, :last_admin}`, and nothing changes. Every other change is
  allowed, a promotion included. A role that is neither `:member` nor
  `:admin` is `{:error, changeset}`.

  The decision goes by the user's role in the database, read inside the same
  transaction as the change, not by the role on the struct passed in. It is
  safe when requests race: see `delete_user/1` for how.

  A change that would not be allowed if it came second may be allowed if it
  comes first: asked to promote one user and demote the only admin at the
  same instant, either both happen or the demotion is refused, depending on
  which is decided first.

  Raises `Ecto.NoResultsError` if the user no longer exists.

  ## Examples

      iex> update_user_role(member, :admin)
      {:ok, %User{}}

      iex> update_user_role(the_only_admin, :member)
      {:error, :last_admin}

  """
  @spec update_user_role(User.t(), atom() | String.t()) ::
          {:ok, User.t()} | {:error, :last_admin | Ecto.Changeset.t()}
  def update_user_role(%User{} = user, role) do
    under_last_admin_rule(user, fn current, last_admin? ->
      changeset = User.role_changeset(current, %{role: role})

      if last_admin? and steps_down?(changeset) do
        {:error, :last_admin}
      else
        Repo.update(changeset)
      end
    end)
  end

  # A valid change to a role other than admin. An invalid one steps nowhere:
  # it is refused as invalid, by `Repo.update/1`.
  defp steps_down?(%Ecto.Changeset{valid?: valid?} = changeset) do
    valid? and Ecto.Changeset.get_field(changeset, :role) != :admin
  end

  @doc """
  Deletes a user, and with them their sessions and other tokens.

  There is always at least one admin: deleting the last one is refused with
  `{:error, :last_admin}`, and nothing is deleted. As in
  `update_user_role/2`, the decision goes by the role in the database.

  ## Concurrency

  Two requests can each see two admins and each remove one; or one can
  demote a user whose promotion, still uncommitted when it looked, made
  them the only admin. Both come from deciding on what was true a moment
  ago. So this function and `update_user_role/2` are decided one at a time:
  each takes the same transaction-level advisory lock before it reads
  anything, and holds it until it commits or rolls back. Whatever it then
  reads (the user's role, whether another admin exists) cannot be changed
  under it by another call to either function.

  It is one lock for all users, not a lock on rows, so two calls cannot wait
  on each other in a circle, and a call does not hold up anything else that
  touches a user: logging in, registering, changing a password.

  `create_user/1` does not take the lock. It can only add an admin, never
  remove one, so the worst a race with it does is refuse a demotion that
  would have been allowed a moment later.

  Raises `Ecto.NoResultsError` if the user no longer exists.

  ## Examples

      iex> delete_user(member)
      {:ok, %User{}}

      iex> delete_user(the_only_admin)
      {:error, :last_admin}

  """
  @spec delete_user(User.t()) :: {:ok, User.t()} | {:error, :last_admin}
  def delete_user(%User{} = user) do
    under_last_admin_rule(user, fn current, last_admin? ->
      if last_admin?, do: {:error, :last_admin}, else: Repo.delete(current)
    end)
  end

  # The advisory lock every change of role and every deletion takes. Any
  # number will do, as long as nothing else in the database uses it; this one
  # is derived from a name so that it says what it is for.
  @role_changes_lock :erlang.phash2("cake:accounts:role_changes")

  # Runs `change` in a transaction that holds the role-changes lock, so that
  # it is the only such change in flight. `change` gets the user as the
  # database has them now and whether they are the only admin, and answers
  # `{:ok, user}` to keep what it did or `{:error, reason}` to roll it back.
  #
  # The lock comes first, before anything is read: a statement run after it
  # is granted sees every role change that committed while this call waited.
  defp under_last_admin_rule(%User{id: id}, change) do
    Repo.transaction(fn ->
      _ = Repo.query!("SELECT pg_advisory_xact_lock($1)", [@role_changes_lock])

      current = Repo.get!(User, id)

      case change.(current, current.role == :admin and not other_admin?(id)) do
        {:ok, user} -> user
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp other_admin?(id) do
    Repo.exists?(from u in User, where: u.role == :admin and u.id != ^id)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user changes.

  ## Examples

      iex> change_user_registration(user)
      %Ecto.Changeset{data: %User{}}

  """
  @spec change_user_registration(User.t(), map()) :: Ecto.Changeset.t()
  def change_user_registration(%User{} = user, attrs \\ %{}) do
    User.registration_changeset(user, attrs,
      hash_password: false,
      validate_email: false,
      validate_username: false
    )
  end

  ## Settings

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  @spec change_user_email(User.t(), map()) :: Ecto.Changeset.t()
  def change_user_email(user, attrs \\ %{}) do
    User.email_changeset(user, attrs, validate_email: false)
  end

  @doc """
  Emulates that the email will change without actually changing
  it in the database.

  ## Examples

      iex> apply_user_email(user, "valid password", %{email: ...})
      {:ok, %User{}}

      iex> apply_user_email(user, "invalid password", %{email: ...})
      {:error, %Ecto.Changeset{}}

  """
  @spec apply_user_email(User.t(), String.t(), map()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def apply_user_email(user, password, attrs) do
    user
    |> User.email_changeset(attrs)
    |> User.validate_current_password(password)
    |> Ecto.Changeset.apply_action(:update)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  The confirmed_at date is also updated to the current time.
  """
  @spec update_user_email(User.t(), String.t()) :: :ok | :error
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
         %UserToken{sent_to: email} <- Repo.one(query),
         {:ok, _} <- Repo.transaction(user_email_multi(user, email, context)) do
      :ok
    else
      _ -> :error
    end
  end

  defp user_email_multi(user, email, context) do
    changeset =
      user
      |> User.email_changeset(%{email: email})
      |> User.confirm_changeset()

    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, changeset)
    |> Ecto.Multi.delete_all(:tokens, UserToken.by_user_and_contexts_query(user, [context]))
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm_email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  @spec deliver_user_update_email_instructions(User.t(), String.t(), (String.t() -> String.t())) ::
          {:ok, map()}
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  @spec change_user_password(User.t(), map()) :: Ecto.Changeset.t()
  def change_user_password(user, attrs \\ %{}) do
    User.password_changeset(user, attrs, hash_password: false)
  end

  @doc """
  Updates the user password.

  ## Examples

      iex> update_user_password(user, "valid password", %{password: ...})
      {:ok, %User{}}

      iex> update_user_password(user, "invalid password", %{password: ...})
      {:error, %Ecto.Changeset{}}

  """
  @spec update_user_password(User.t(), String.t(), map()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_user_password(user, password, attrs) do
    changeset =
      user
      |> User.password_changeset(attrs)
      |> User.validate_current_password(password)

    result =
      Ecto.Multi.new()
      |> Ecto.Multi.update(:user, changeset)
      |> Ecto.Multi.delete_all(:tokens, UserToken.by_user_and_contexts_query(user, :all))
      |> Repo.transaction()

    case result do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
    end
  end

  ## Session

  @doc """
  Generates a session token.
  """
  @spec generate_user_session_token(User.t()) :: binary()
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.
  """
  @spec get_user_by_session_token(binary()) :: User.t() | nil
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Deletes the signed token with the given context.
  """
  @spec delete_user_session_token(binary()) :: :ok
  def delete_user_session_token(token) do
    Repo.delete_all(UserToken.by_token_and_context_query(token, "session"))
    :ok
  end

  ## Confirmation

  @doc ~S"""
  Delivers the confirmation email instructions to the given user.

  ## Examples

      iex> deliver_user_confirmation_instructions(user, &url(~p"/users/confirm/#{&1}"))
      {:ok, %{to: ..., body: ...}}

      iex> deliver_user_confirmation_instructions(confirmed_user, &url(~p"/users/confirm/#{&1}"))
      {:error, :already_confirmed}

  """
  @spec deliver_user_confirmation_instructions(User.t(), (String.t() -> String.t())) ::
          {:ok, map()} | {:error, :already_confirmed}
  def deliver_user_confirmation_instructions(%User{} = user, confirmation_url_fun)
      when is_function(confirmation_url_fun, 1) do
    if user.confirmed_at do
      {:error, :already_confirmed}
    else
      {encoded_token, user_token} = UserToken.build_email_token(user, "confirm")
      Repo.insert!(user_token)
      UserNotifier.deliver_confirmation_instructions(user, confirmation_url_fun.(encoded_token))
    end
  end

  @doc """
  Confirms a user by the given token.

  If the token matches, the user account is marked as confirmed
  and the token is deleted.
  """
  @spec confirm_user(binary()) :: {:ok, User.t()} | :error
  def confirm_user(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "confirm"),
         %User{} = user <- Repo.one(query),
         {:ok, %{user: user}} <- Repo.transaction(confirm_user_multi(user)) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  defp confirm_user_multi(user) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, User.confirm_changeset(user))
    |> Ecto.Multi.delete_all(:tokens, UserToken.by_user_and_contexts_query(user, ["confirm"]))
  end

  ## Reset password

  @doc ~S"""
  Delivers the reset password email to the given user.

  ## Examples

      iex> deliver_user_reset_password_instructions(user, &url(~p"/users/reset_password/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  @spec deliver_user_reset_password_instructions(User.t(), (String.t() -> String.t())) ::
          {:ok, map()}
  def deliver_user_reset_password_instructions(%User{} = user, reset_password_url_fun)
      when is_function(reset_password_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "reset_password")
    Repo.insert!(user_token)
    UserNotifier.deliver_reset_password_instructions(user, reset_password_url_fun.(encoded_token))
  end

  @doc """
  Gets the user by reset password token.

  ## Examples

      iex> get_user_by_reset_password_token("validtoken")
      %User{}

      iex> get_user_by_reset_password_token("invalidtoken")
      nil

  """
  @spec get_user_by_reset_password_token(binary()) :: User.t() | nil
  def get_user_by_reset_password_token(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "reset_password"),
         %User{} = user <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Resets the user password.

  ## Examples

      iex> reset_user_password(user, %{password: "new long password", password_confirmation: "new long password"})
      {:ok, %User{}}

      iex> reset_user_password(user, %{password: "valid", password_confirmation: "not the same"})
      {:error, %Ecto.Changeset{}}

  """
  @spec reset_user_password(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def reset_user_password(user, attrs) do
    result =
      Ecto.Multi.new()
      |> Ecto.Multi.update(:user, User.password_changeset(user, attrs))
      |> Ecto.Multi.delete_all(:tokens, UserToken.by_user_and_contexts_query(user, :all))
      |> Repo.transaction()

    case result do
      {:ok, %{user: user}} -> {:ok, user}
      {:error, :user, changeset, _} -> {:error, changeset}
    end
  end
end
