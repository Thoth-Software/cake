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
  Gets a single user, or `nil`.

  `nil` is the answer for an id no user has and for a value that is not an
  id at all, so it can be handed what a request carried. It is for a caller
  that has something to say when the user is gone: the admin panel, when a
  login is deleted while a page still shows it.

  ## Examples

      iex> get_user("3f5242a5-dd9a-44ca-8316-7ecb66b4d10f")
      %User{}

      iex> get_user("not-an-id")
      nil

  """
  @spec get_user(term()) :: User.t() | nil
  def get_user(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(User, uuid)
      :error -> nil
    end
  end

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

  The username, email and password are held to the rules registration holds
  them to. The user is confirmed from the start and is sent nothing, so they
  can log in at once: log-in waits on confirmation, and where the first
  admin is made there may be no mail to confirm by.

  In a release, call it through `bin/cake rpc`; in dev, through `mix run -e`.
  Never pass the password on the command line, where it is left in the shell
  history and shown in the process list. With `mix run -e` it can come from
  the environment. Through `rpc` it has to come from standard input: the
  expression is evaluated on the running node, which does not have the
  environment of the shell that ran `rpc`. The README has both commands
  ("Roles and the First Admin").

  ## Examples

      iex> create_user(%{username: "caleb", email: "caleb@example.com", password: "a long password", role: :admin})
      {:ok, %User{}}

      iex> create_user(%{username: "caleb", email: "caleb@example.com", password: "a long password"})
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

  ## Confirming by hand

  @doc """
  Confirms a user's email by hand, or takes the confirmation back.

  A user cannot log in until their email is confirmed. They confirm it by
  following the mailed link (`confirm_user/1`); this is for when that is
  not possible or not wanted: mail may have nowhere to go, or an admin
  wants a user to prove the address again.

  `actor` is who is doing it: the admin, or `:operator` at the command line
  and in the seed, where nobody is logged in. Nobody takes their own
  confirmation back, since they could not log in again: that is
  `{:error, :own_account}`, and nothing changes. It goes by the two users'
  ids. Whether `actor` may do this at all is not decided here: the admin
  routes are what keep a member out.

  There is always a confirmed admin, once there is one, since an admin who
  is not confirmed cannot log in to the admin panel. Taking back the
  confirmation of the last one is refused with
  `{:error, :last_confirmed_admin}`, and nothing changes. That is so whoever
  asks, `:operator` included: the rule is about what the database is left
  with. It goes by the role and the confirmation in the database, and is
  safe when requests race: it is decided under the lock that a demotion and
  a deletion are decided under (see `delete_user/1`), so two admins cannot
  each take back the other's.

  Confirming is never refused here, and does not take that lock: it can
  only add a confirmed admin. So it is the way out, from the command line,
  for a database where no admin is confirmed (the README has the command,
  under "Roles and the First Admin").

  Confirming also drops the user's pending confirmation links. A user who
  is already as asked is returned as they are. Taking a confirmation back
  does not end the sessions the user already has (#401).

  Raises `Ecto.NoResultsError` if the user no longer exists.

  ## Examples

      iex> set_user_confirmed(admin, unconfirmed_user, true)
      {:ok, %User{}}

      iex> set_user_confirmed(admin, admin, false)
      {:error, :own_account}

      iex> set_user_confirmed(:operator, user, false)
      {:ok, %User{confirmed_at: nil}}

      iex> set_user_confirmed(:operator, the_only_confirmed_admin, false)
      {:error, :last_confirmed_admin}

  """
  @spec set_user_confirmed(User.t() | :operator, User.t(), boolean()) ::
          {:ok, User.t()} | {:error, :own_account | :last_confirmed_admin}
  def set_user_confirmed(%User{id: id}, %User{id: id}, false), do: {:error, :own_account}

  def set_user_confirmed(actor, %User{id: id}, true)
      when is_struct(actor, User) or actor == :operator do
    case Repo.get!(User, id) do
      %User{confirmed_at: nil} = current ->
        {:ok, %{user: user}} = Repo.transaction(confirm_user_multi(current))
        {:ok, user}

      %User{confirmed_at: %DateTime{}} = current ->
        {:ok, current}
    end
  end

  def set_user_confirmed(actor, %User{} = user, false)
      when is_struct(actor, User) or actor == :operator do
    under_last_admin_rule(user, fn
      %User{confirmed_at: nil} = current ->
        {:ok, current}

      %User{confirmed_at: %DateTime{}} = current ->
        with :ok <- may_lose_confirmation(current) do
          Repo.update(Ecto.Changeset.change(current, confirmed_at: nil))
        end
    end)
  end

  ## Roles, the last admin and the last confirmed admin

  @doc """
  Changes a user's username, email and role, as an admin does from the panel.

  Nothing else is changed: a password or a confirmation among the attributes
  is ignored. (An admin sets a password with `reset_user_password/2`, which
  also ends the user's sessions, and a confirmation with
  `set_user_confirmed/3`.) A changed email leaves the user confirmed or not,
  as they were: the admin vouches for the address they type, as for a login
  they create.

  The role is changed under the rule `update_user_role/2` keeps, in the same
  way: demoting the last admin is refused with `{:error, :last_admin}`, and
  demoting the last confirmed admin with `{:error, :last_confirmed_admin}`,
  and then nothing changes, the username included. The decision goes by the
  role and the confirmation in the database, and is safe when requests race
  (see `delete_user/1`).

  A username or an email that breaks a rule or is already taken, a missing
  email, or a role that is neither `:member` nor `:admin`, is
  `{:error, changeset}`.

  Raises `Ecto.NoResultsError` if the user no longer exists.

  ## Examples

      iex> update_user(user, %{username: "caleb", email: "caleb@example.com", role: :admin})
      {:ok, %User{}}

      iex> update_user(the_only_admin, %{role: :member})
      {:error, :last_admin}

      iex> update_user(user, %{username: "taken"})
      {:error, %Ecto.Changeset{}}

  """
  @spec update_user(User.t(), map()) ::
          {:ok, User.t()}
          | {:error, :last_admin | :last_confirmed_admin | Ecto.Changeset.t()}
  def update_user(%User{} = user, attrs) do
    under_last_admin_rule(user, fn current ->
      changeset = User.update_changeset(current, attrs)

      with :ok <- may_make(changeset), do: Repo.update(changeset)
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking the changes `update_user/2`
  makes, for the admin panel's form.

  It validates as `update_user/2` does, except that it does not ask the
  database whether the username or the email is taken, and knows nothing of
  the last-admin rule: those are decided when the change is made.

  ## Examples

      iex> change_user(user)
      %Ecto.Changeset{data: %User{}}

  """
  @spec change_user(User.t(), map()) :: Ecto.Changeset.t()
  def change_user(%User{} = user, attrs \\ %{}) do
    User.update_changeset(user, attrs, validate_username: false, validate_email: false)
  end

  @doc """
  Changes a user's role.

  There is always at least one admin: demoting the last one is refused with
  `{:error, :last_admin}`, and nothing changes.

  There is also always a confirmed admin, once there is one: an admin who
  is not confirmed cannot log in, so they are no admin to fall back on.
  Demoting a confirmed admin while every other admin is unconfirmed is
  refused with `{:error, :last_confirmed_admin}`, and nothing changes. An
  admin who is not confirmed is not what that rule keeps, so they can be
  demoted while any other admin remains.

  Every other change is allowed, a promotion included. A role that is
  neither `:member` nor `:admin` is `{:error, changeset}`.

  The decision goes by the user's role and confirmation in the database,
  read inside the same transaction as the change, not by those on the struct
  passed in. It is safe when requests race: see `delete_user/1` for how.

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

      iex> update_user_role(the_only_confirmed_admin, :member)
      {:error, :last_confirmed_admin}

  """
  @spec update_user_role(User.t(), atom() | String.t()) ::
          {:ok, User.t()}
          | {:error, :last_admin | :last_confirmed_admin | Ecto.Changeset.t()}
  def update_user_role(%User{} = user, role) do
    under_last_admin_rule(user, fn current ->
      changeset = User.role_changeset(current, %{role: role})

      with :ok <- may_make(changeset), do: Repo.update(changeset)
    end)
  end

  # Whether the rule allows the change in `changeset`. Only a demotion is
  # its business: a valid change to a role other than admin. An invalid one
  # steps nowhere: it is refused as invalid, by `Repo.update/1`.
  defp may_make(%Ecto.Changeset{valid?: valid?, data: %User{} = current} = changeset) do
    if valid? and Ecto.Changeset.get_field(changeset, :role) != :admin,
      do: may_stop_being_admin(current),
      else: :ok
  end

  @doc """
  Deletes a user, and with them their sessions and other tokens.

  There is always at least one admin, and always a confirmed one once there
  is one: deleting the last admin is refused with `{:error, :last_admin}`,
  and deleting a confirmed admin while every other admin is unconfirmed with
  `{:error, :last_confirmed_admin}`, and nothing is deleted. As in
  `update_user_role/2`, the decision goes by the role and the confirmation
  in the database.

  ## Concurrency

  Two requests can each see two admins and each remove one; or one can
  demote a user whose promotion, still uncommitted when it looked, made
  them the only admin; or two admins can each take back the other's
  confirmation. All come from deciding on what was true a moment ago. So
  this function, `update_user_role/2`, `update_user/2` and the taking back
  of a confirmation (`set_user_confirmed/3`) are decided one at a time: each
  takes the same transaction-level advisory lock before it reads anything,
  and holds it until it commits or rolls back. Whatever it then reads
  (whether another admin exists, whether another confirmed one does) cannot
  be changed under it by another call to any of the four.

  It is one lock for all users, not a lock on rows, so two calls cannot wait
  on each other in a circle, and a call does not hold up anything else that
  touches another user: logging in, registering, changing a password.

  `create_user/1` does not take the lock, and neither does confirming a
  user: by hand, by the mailed link, or by the link mailed to a changed
  email address (`update_user_email/2`). Each can only add a confirmed admin,
  never remove one. For another user, the worst a race with one does is
  refuse a change that would have been allowed a moment later. For the user
  the change is about, a confirmation matters more: read as unconfirmed,
  they could be confirmed before the change is written, and the only
  confirmed admin demoted or deleted. So each of the four also locks the
  user's own row when it reads them, after the advisory lock: a confirmation
  in flight is waited for and seen, and a later one waits its turn.

  All of this relies on two things, both true of every caller there is. The
  database runs at READ COMMITTED, Postgres's default: at REPEATABLE READ a
  call would decide on what was true before it waited for the lock, and the
  rule would not hold. And a call is not made inside a transaction of the
  caller's: one that had already read would decide the same stale way, one
  that confirmed a user and then removed another could deadlock with a
  removal of the first, and a refusal would roll the caller's transaction
  back, which then answers `{:error, :rollback}` and not the reason.

  Raises `Ecto.NoResultsError` if the user no longer exists.

  ## Examples

      iex> delete_user(member)
      {:ok, %User{}}

      iex> delete_user(the_only_admin)
      {:error, :last_admin}

      iex> delete_user(the_only_confirmed_admin)
      {:error, :last_confirmed_admin}

  """
  @spec delete_user(User.t()) ::
          {:ok, User.t()} | {:error, :last_admin | :last_confirmed_admin}
  def delete_user(%User{} = user) do
    under_last_admin_rule(user, fn current ->
      with :ok <- may_stop_being_admin(current), do: Repo.delete(current)
    end)
  end

  # The advisory lock taken by every change that can take an admin, or a
  # confirmed admin, away: a change of role, a deletion, a confirmation
  # taken back. Any number will do, as long as nothing else in the database
  # uses it; this one is derived from a name so that it says what it is
  # for. The name is from when role changes were all it covered.
  @role_changes_lock :erlang.phash2("cake:accounts:role_changes")

  # Runs `change` in a transaction that holds the role-changes lock, so that
  # it is the only such change in flight. `change` gets the user as the
  # database has them now, and answers `{:ok, user}` to keep what it did or
  # `{:error, reason}` to roll it back. What it asks of the rule
  # (`may_stop_being_admin/1`, `may_lose_confirmation/1`) it has to ask in
  # here, where the answer cannot change under it.
  #
  # The lock comes first, before anything is read: a statement run after it
  # is granted sees every such change that committed while this call waited.
  # That is so at READ COMMITTED, which Postgres defaults to and `Cake.Repo`
  # runs at, where each statement sees what had committed when it began. At
  # REPEATABLE READ a transaction's view is fixed by its first statement,
  # here the one that waits for the lock, and the rule would decide on what
  # was true before it waited. So would a caller's own transaction that had
  # read anything before calling in. Nothing does either.
  #
  # The user is then read with their row locked, because one change that
  # matters takes no part in the lock: a confirmation. A confirmation of
  # this user still in flight is waited for, and seen; one that comes later
  # waits for this change. Without it, a user read as unconfirmed could be
  # confirmed before the change is written, and the only confirmed admin
  # demoted or deleted.
  #
  # `FOR NO KEY UPDATE` is the lock a change of role or of confirmation
  # takes anyway, and it holds up nobody who only refers to the user, as
  # logging in does when it stores a session. A rename, a changed email and
  # a deletion take the stronger lock when they write, as they did before
  # the row was locked here, and wait then for anyone storing a session for
  # the user.
  #
  # Nothing that locks a user's row takes the advisory lock afterwards, so
  # the two cannot wait on each other. And everything else that writes both
  # a user and their tokens writes the user first, so none can hold what a
  # deletion or a rename waits for while waiting for the row. A transaction
  # that stored a token for a user and then updated that user would: it
  # would deadlock with a deletion or a rename of them.
  defp under_last_admin_rule(%User{id: id}, change) do
    Repo.transaction(fn ->
      _ = Repo.query!("SELECT pg_advisory_xact_lock($1)", [@role_changes_lock])

      case change.(User |> lock("FOR NO KEY UPDATE") |> Repo.get!(id)) do
        {:ok, user} -> user
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Whether `user` may be demoted or deleted: not when that leaves no admin,
  # and not when it leaves no confirmed admin where there was one. A member
  # is no admin to lose.
  defp may_stop_being_admin(%User{role: :admin, id: id} = user) do
    cond do
      not other_admin?(id) -> {:error, :last_admin}
      last_confirmed_admin?(user) -> {:error, :last_confirmed_admin}
      true -> :ok
    end
  end

  defp may_stop_being_admin(%User{}), do: :ok

  # Whether `user`'s confirmation may be taken back: they stay an admin, so
  # only the second half of the rule is asked.
  defp may_lose_confirmation(%User{} = user) do
    if last_confirmed_admin?(user), do: {:error, :last_confirmed_admin}, else: :ok
  end

  # An admin who is not confirmed is not what keeps the panel reachable, so
  # they are never the last confirmed admin, whoever else there is.
  defp last_confirmed_admin?(%User{role: :admin, confirmed_at: %DateTime{}, id: id}) do
    not other_confirmed_admin?(id)
  end

  defp last_confirmed_admin?(%User{}), do: false

  defp other_admin?(id) do
    Repo.exists?(from u in User, where: u.role == :admin and u.id != ^id)
  end

  defp other_confirmed_admin?(id) do
    Repo.exists?(
      from u in User,
        where: u.role == :admin and u.id != ^id and not is_nil(u.confirmed_at)
    )
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
