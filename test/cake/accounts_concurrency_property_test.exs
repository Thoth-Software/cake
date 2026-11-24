defmodule Cake.AccountsConcurrencyPropertyTest do
  @moduledoc """
  The last-admin rule under concurrent requests (#373), and its second half,
  the last confirmed admin (#405); and what a request about a user answers
  when that user is deleted, or demoted, while it is under way (#427).

  An admin who is not confirmed cannot log in. So what a database must keep
  is a confirmed admin, and three things can take one away: a demotion, a
  deletion, and a confirmation taken back.

  A run creates a few admins, confirmed and not, and members, decides what
  is asked of each (demote, delete, take the confirmation back, promote,
  confirm, or nothing), and releases every request at the same moment.
  Whatever the interleaving:

    * every request is answered, with `{:ok, user}`, `{:error, :last_admin}`
      or `{:error, :last_confirmed_admin}`, and only a request that takes a
      confirmed admin away is ever refused;
    * the database ends as if exactly the requests answered `:ok` had been
      applied, and it still has a confirmed admin;
    * no more is refused than the rule needs. With `c` confirmed admins, `r`
      of them asked to step down, be deleted or lose their confirmation, and
      nobody promoted or confirmed, exactly `max(0, r - (c - 1))` requests
      are refused: all of them go through while a confirmed admin would
      remain, and no further. Admins who are not confirmed change nothing in
      that count, however many there are.

  The last point cuts both ways. A rule that counts and then acts, with
  nothing holding the count still in between, refuses too few and leaves no
  confirmed admin; so does one that counts admins who cannot log in. A rule
  that locks too coarsely, or goes by a stale count, refuses requests it
  should have allowed.

  When members are promoted or admins confirmed in the same instant the
  exact count depends on who commits first, so the second property gives the
  range: one that lands first can spare one refusal, and no more.

  One user can also be the subject of two requests at once. The dangerous
  pair is a promotion and its undoing: a demotion or deletion that looks
  before the promotion commits (nobody is an admin, so this is not the last
  one) and acts after it. Tests fix that interleaving exactly, by holding
  the promotion's transaction open until the database reports the second
  request waiting on a lock, and a third property races several promotions
  and demotions of the same two users from a table with no admin at all.

  The same is done for the pair #405 is about: of two confirmed admins, one
  loses their confirmation while a request takes the other away. Each looks
  while the other is uncommitted, sees a confirmed admin who is about to
  stop being one, and goes ahead. Tests fix that interleaving, in both
  orders.

  And for the one request that takes no part in the lock, a confirmation:
  where no admin is confirmed, an admin's confirmation is held uncommitted
  while a request takes that same admin away.

  #427 is the other side of a deletion. A request about a user reads them,
  or is handed them by a page that read them earlier, and then writes them
  or a row that refers to them: a confirmation, a password change or reset,
  a session stored at log-in, a link mailed. A deletion can commit in
  between. Tests hold the deletion open until each request waits on the
  user, and a fourth property races a deletion against several requests
  about the same user, as the stress run that found it did. And a
  confirmation that waits on a demotion of the same admin must answer with
  the role the demotion left.

  The SQL sandbox gives a test one connection, on which nothing can race. So
  this module does not use it: every database call runs through
  `Cake.ConcurrencyHelpers.unboxed/1`, on a connection of its own, and
  commits. That is why the module is `async: false` (no sandboxed test is
  running to see the committed rows), why each run deletes its users, and why
  it first deletes any a killed run left behind. No property asks for more
  requests at once than the pool has connections; a test that holds a
  transaction open needs three (the held one, the second request, and the
  poll that watches for the wait).

  The requests are released by a message and collected with
  `Task.await_many/2`; nothing sleeps. A failure here comes from an
  interleaving, so a shrunk counterexample may not fail again when re-run:
  read the generated values as "a case that failed once", not as the smallest
  one. The same rule without concurrency, checked against a model step by
  step, is in `test/cake/accounts_property_test.exs`.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  import Cake.ConcurrencyHelpers
  import Ecto.Query

  alias Cake.Accounts
  alias Cake.Accounts.User
  alias Cake.Accounts.UserToken
  alias Cake.Repo

  # Each run commits users and races real connections.
  @max_runs 30

  @username_prefix "racer-"
  @password "hello world!"
  @new_password "another long password"

  # ---------------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------------

  # One request runs on one connection, so a run has at most as many users as
  # the pool has connections, and at most eight.
  defp most_users, do: min(8, Repo.config()[:pool_size])

  # Mostly asked to stop being a confirmed admin, by any of the ways there
  # are: contention for the last one is the case this file is for.
  defp confirmed_admin_request do
    frequency([
      {4, member_of([:demote, :demote_by_update, :delete, :unconfirm])},
      {1, constant(:none)}
    ])
  end

  # A population: `{role, confirmed?, request}` per user, with at least one
  # confirmed admin. The options say what the others may be asked: the
  # admins who are not confirmed (`:unconfirmed_admins`) and the members,
  # who are confirmed (`:members`).
  defp population(asked) do
    gen all(
          confirmed <-
            list_of(confirmed_admin_request(), min_length: 1, max_length: most_users()),
          others <- list_of(other_user(asked), max_length: most_users() - length(confirmed))
        ) do
      Enum.map(confirmed, &{:admin, true, &1}) ++ others
    end
  end

  # An admin who is not confirmed, or a member, who is.
  defp other_user(asked) do
    one_of([
      tuple({:admin, false, member_of(Keyword.fetch!(asked, :unconfirmed_admins))}),
      tuple({:member, true, member_of(Keyword.fetch!(asked, :members))})
    ])
  end

  # ---------------------------------------------------------------------------
  # Running a population
  # ---------------------------------------------------------------------------

  defp racers, do: from(u in User, where: like(u.username, ^"#{@username_prefix}%"))

  defp delete_racers, do: unboxed(fn -> Repo.delete_all(racers()) end)

  defp create_users(population) do
    unboxed(fn ->
      for {{role, confirmed?, request}, n} <- Enum.with_index(population) do
        user = create_user("#{@username_prefix}#{n}", role, confirmed?)
        %{user: user, role: role, confirmed?: confirmed?, request: request}
      end
    end)
  end

  # A user with a role, confirmed or not, made through the context: a
  # created user is confirmed from the start, and a registered one is an
  # unconfirmed member until promoted.
  defp create_user(username, role, true) do
    {:ok, user} = Accounts.create_user(Map.put(racer(username), :role, role))
    user
  end

  defp create_user(username, role, false) do
    {:ok, member} = Accounts.register_user(racer(username))
    {:ok, user} = Accounts.update_user_role(member, role)
    user
  end

  defp racer(username) do
    %{username: username, email: "#{username}@race.example", password: @password}
  end

  defp ask(user, :promote), do: fn -> Accounts.update_user_role(user, :admin) end
  defp ask(user, :demote), do: fn -> Accounts.update_user_role(user, :member) end
  defp ask(user, :delete), do: fn -> Accounts.delete_user(user) end

  # The admin panel's way to change a role (#376), held to the same rule.
  defp ask(user, :demote_by_update), do: fn -> Accounts.update_user(user, %{role: :member}) end

  # A confirmation by hand, and one taken back (#405). The operator asks:
  # the rule does not depend on who does.
  defp ask(user, :confirm), do: fn -> Accounts.set_user_confirmed(:operator, user, true) end
  defp ask(user, :unconfirm), do: fn -> Accounts.set_user_confirmed(:operator, user, false) end

  # Starts one process per request, each waiting for `:go` on a connection of
  # its own, releases them together, and returns their answers in order.
  defp race(requests) do
    tasks =
      for request <- requests do
        Task.async(fn ->
          receive do
            :go -> unboxed(request)
          end
        end)
      end

    Enum.each(tasks, &send(&1.pid, :go))
    Task.await_many(tasks, 15_000)
  end

  # Creates the population, races what is asked of it, and returns each user
  # with the answer to their request (`:not_asked` for a user asked nothing).
  defp run(population) do
    delete_racers()
    users = create_users(population)

    asked = Enum.reject(users, &(&1.request == :none))
    answers = race(for %{user: user, request: request} <- asked, do: ask(user, request))

    answered =
      Map.new(Enum.zip(asked, answers), fn {asked, answer} -> {asked.user.id, answer} end)

    for user <- users, do: Map.put(user, :answer, Map.get(answered, user.user.id, :not_asked))
  end

  # ---------------------------------------------------------------------------
  # What must hold
  # ---------------------------------------------------------------------------

  defp refused?(%{answer: answer}),
    do: answer in [{:error, :last_admin}, {:error, :last_confirmed_admin}]

  # A request that takes a confirmed admin away.
  defp removal?(%{role: role, confirmed?: confirmed?, request: request}) do
    role == :admin and confirmed? and
      request in [:demote, :demote_by_update, :delete, :unconfirm]
  end

  # What a user ends as, `{role, confirmed?}`, if the database applied
  # exactly the requests answered `:ok`; `:deleted` for a user who is gone.
  defp state_after(%{answer: {:ok, %User{}}, request: :delete}), do: :deleted

  defp state_after(%{answer: {:ok, %User{}}, request: request} = user) do
    case request do
      :promote -> {:admin, user.confirmed?}
      :demote -> {:member, user.confirmed?}
      :demote_by_update -> {:member, user.confirmed?}
      :confirm -> {user.role, true}
      :unconfirm -> {user.role, false}
    end
  end

  defp state_after(%{role: role, confirmed?: confirmed?}), do: {role, confirmed?}

  defp stored do
    unboxed(fn ->
      Map.new(Repo.all(racers()), &{&1.id, {&1.role, not is_nil(&1.confirmed_at)}})
    end)
  end

  defp admin_left?(stored), do: Enum.any?(stored, &match?({_id, {:admin, _confirmed?}}, &1))
  defp confirmed_admin_left?(stored), do: Enum.any?(stored, &match?({_id, {:admin, true}}, &1))

  # An answer is `{:ok, user}` or a refusal, and only a request that takes a
  # confirmed admin away is ever refused. A demotion or a deletion is
  # refused as the last admin when no other admin of any kind was left, and
  # as the last confirmed admin otherwise: which, depends on who went first.
  # A confirmation taken back removes no admin, so it is only ever the
  # second.
  defp assert_answer(%{answer: :not_asked}), do: :ok
  defp assert_answer(%{answer: {:ok, %User{}}}), do: :ok

  defp assert_answer(%{answer: {:error, reason}} = user)
       when reason in [:last_admin, :last_confirmed_admin] do
    assert removal?(user), "refused a request that takes no confirmed admin away"

    assert user.request != :unconfirm or reason == :last_confirmed_admin,
           "a confirmation taken back was refused as the last admin"
  end

  defp assert_answer(%{answer: answer}), do: flunk("a request was answered #{inspect(answer)}")

  # The checks every run owes, whatever was asked.
  defp assert_consistent(users) do
    Enum.each(users, &assert_answer/1)

    stored = stored()

    for user <- users do
      assert Map.get(stored, user.user.id, :deleted) == state_after(user)
    end

    assert confirmed_admin_left?(stored), "no confirmed admin is left"
  end

  # The refusals the rule needs when nobody is promoted or confirmed: every
  # request that takes a confirmed admin away goes through while another
  # would remain.
  defp refusals_needed(users) do
    confirmed_admins = Enum.count(users, &(&1.role == :admin and &1.confirmed?))
    max(0, Enum.count(users, &removal?/1) - (confirmed_admins - 1))
  end

  setup do
    delete_racers()
    on_exit(&delete_racers/0)
  end

  # ---------------------------------------------------------------------------
  # One user, two requests: a promotion still uncommitted, and its undoing
  # ---------------------------------------------------------------------------

  # Found in review on #387. A request to demote or delete a user can arrive
  # while that same user's promotion is still uncommitted. If it decides from
  # what it read before the promotion committed (nobody is an admin, so this
  # cannot be the last one) and acts after, the one admin there is goes.
  #
  # These tests hold the promotion's transaction open, start the second
  # request, wait until the database reports a session waiting on a lock, and
  # only then let the promotion commit. So the interleaving is the same on
  # every run, and nothing sleeps: the wait is a poll of `pg_stat_activity`.

  defp create_member do
    unboxed(fn -> create_user("#{@username_prefix}solo", :member, true) end)
  end

  # A confirmation taken back is the fourth way to undo the promotion of a
  # confirmed member (#405, found in review): it leaves them an admin, and
  # one who cannot log in.
  for {name, request, refusal} <- [
        {"demotion", quote(do: &Accounts.update_user_role(&1, :member)), :last_admin},
        {"demotion through update_user/2", quote(do: &Accounts.update_user(&1, %{role: :member})),
         :last_admin},
        {"deletion", quote(do: &Accounts.delete_user/1), :last_admin},
        {"confirmation taken back", quote(do: &Accounts.set_user_confirmed(:operator, &1, false)),
         :last_confirmed_admin}
      ] do
    test "a #{name} that arrives while the same user's promotion is uncommitted is refused once it commits" do
      member = create_member()
      request = unquote(request)

      promotion = change_and_hold(fn -> Accounts.update_user_role(member, :admin) end, self())
      assert_receive :change_uncommitted

      undoing = Task.async(fn -> unboxed(fn -> request.(member) end) end)
      assert await_blocked_or_done(undoing) == :blocked

      send(promotion.pid, :commit)
      assert {:ok, %User{}} = Task.await(promotion, 15_000)

      # The promotion committed first, so the user is the only admin.
      assert Task.await(undoing, 15_000) == {:error, unquote(refusal)}
      assert stored() == %{member.id => {:admin, true}}
    end
  end

  # ---------------------------------------------------------------------------
  # One admin, two requests: a confirmation still uncommitted, and a removal
  # ---------------------------------------------------------------------------

  # Found in review on #416. Confirming takes no part in the lock: it can
  # only add a confirmed admin. But it can add one out from under a request
  # that has already looked. Where no admin is confirmed, an admin may be
  # demoted or deleted while another admin remains. If that request reads
  # the admin as unconfirmed, and their confirmation commits before it
  # writes, it takes away the only confirmed admin there is: the database
  # had one, by a committed change, and then has none.
  #
  # It is the state the command-line recovery is for, so the confirmation is
  # likely to be the operator's. The removal has to see it: these tests hold
  # the confirmation open until the removal is waiting on a lock, then let
  # it commit first.
  #
  # Three things confirm a user, and none takes the lock: an admin or the
  # operator by hand, the mailed confirmation link, and the link mailed to a
  # changed email address (`update_user_email/2`), which an admin whose
  # confirmation was taken back can still follow from a session they kept
  # (#401). A fix that only taught the first two about the lock would pass
  # without the third.

  defp create_two_unconfirmed_admins do
    unboxed(fn ->
      for name <- ["first", "second"] do
        create_user("#{@username_prefix}#{name}", :admin, false)
      end
    end)
  end

  defp confirmation_token(user) do
    unboxed(fn ->
      Cake.AccountsFixtures.extract_user_token(
        &Accounts.deliver_user_confirmation_instructions(user, &1)
      )
    end)
  end

  defp changed_email_token(user) do
    unboxed(fn ->
      Cake.AccountsFixtures.extract_user_token(
        &Accounts.deliver_user_update_email_instructions(
          %{user | email: "new-" <> user.email},
          user.email,
          &1
        )
      )
    end)
  end

  # `confirm` is given the admin and answers the confirmation to make: a
  # link's token is made first, outside the transaction held open.
  for {way, confirm} <- [
        {"by hand",
         quote do
           fn user -> fn -> Accounts.set_user_confirmed(:operator, user, true) end end
         end},
        {"by the mailed link",
         quote do
           fn user ->
             token = confirmation_token(user)
             fn -> Accounts.confirm_user(token) end
           end
         end},
        {"by the changed email's link",
         quote do
           fn user ->
             token = changed_email_token(user)

             fn ->
               :ok = Accounts.update_user_email(user, token)
               {:ok, Repo.get!(User, user.id)}
             end
           end
         end}
      ],
      {name, request} <- [
        {"demotion", quote(do: &Accounts.update_user_role(&1, :member))},
        {"demotion through update_user/2",
         quote(do: &Accounts.update_user(&1, %{role: :member}))},
        {"deletion", quote(do: &Accounts.delete_user/1)}
      ] do
    test "a #{name} that arrives while the same admin's confirmation #{way} is uncommitted is refused once it commits" do
      [first, second] = create_two_unconfirmed_admins()
      confirm = unquote(confirm).(first)
      request = unquote(request)

      confirmation = change_and_hold(confirm, self())
      assert_receive :change_uncommitted

      removal = Task.async(fn -> unboxed(fn -> request.(first) end) end)
      assert await_blocked_or_done(removal) == :blocked

      send(confirmation.pid, :commit)
      assert {:ok, %User{confirmed_at: %DateTime{}}} = Task.await(confirmation, 15_000)

      # The confirmation committed first, so the first admin is the only
      # confirmed one.
      assert Task.await(removal, 15_000) == {:error, :last_confirmed_admin}
      assert stored() == %{first.id => {:admin, true}, second.id => {:admin, false}}
    end
  end

  # ---------------------------------------------------------------------------
  # Two confirmed admins: one loses their confirmation, the other is taken away
  # ---------------------------------------------------------------------------

  # #405. Of two confirmed admins, each change below is allowed on its own:
  # the other admin remains, confirmed. Asked together, each can look while
  # the other is uncommitted, see a confirmed admin, and go ahead, leaving
  # none. The plainest case is the one the issue was cut for: two admins
  # who take back each other's confirmation.
  #
  # As above, the first change is held open until the database reports the
  # second request waiting on a lock, so the interleaving is the same on
  # every run. A second request that does not wait at all has decided on
  # what it could see, which is the defect.

  defp create_two_admins do
    unboxed(fn ->
      for name <- ["first", "second"] do
        create_user("#{@username_prefix}#{name}", :admin, true)
      end
    end)
  end

  # `request` is given the admin it is done to, and the other one.
  for {name, request} <- [
        {"confirmation taken back in return",
         quote(do: fn second, first -> Accounts.set_user_confirmed(first, second, false) end)},
        {"demotion",
         quote(do: fn second, _first -> Accounts.update_user_role(second, :member) end)},
        {"demotion through update_user/2",
         quote(do: fn second, _first -> Accounts.update_user(second, %{role: :member}) end)},
        {"deletion", quote(do: fn second, _first -> Accounts.delete_user(second) end)}
      ] do
    test "a #{name} that arrives while the other admin's confirmation is being taken back is refused once that commits" do
      [first, second] = create_two_admins()
      request = unquote(request)

      taking_back =
        change_and_hold(fn -> Accounts.set_user_confirmed(second, first, false) end, self())

      assert_receive :change_uncommitted

      removal = Task.async(fn -> unboxed(fn -> request.(second, first) end) end)
      assert await_blocked_or_done(removal) == :blocked

      send(taking_back.pid, :commit)
      assert {:ok, %User{confirmed_at: nil}} = Task.await(taking_back, 15_000)

      # The first admin is still one, and cannot log in: the second is the
      # last confirmed admin.
      assert Task.await(removal, 15_000) == {:error, :last_confirmed_admin}
      assert stored() == %{first.id => {:admin, false}, second.id => {:admin, true}}
    end
  end

  for {name, request, left_as} <- [
        {"demotion", quote(do: &Accounts.update_user_role(&1, :member)), {:member, true}},
        {"demotion through update_user/2", quote(do: &Accounts.update_user(&1, %{role: :member})),
         {:member, true}},
        {"deletion", quote(do: &Accounts.delete_user/1), :deleted}
      ] do
    test "a confirmation taken back while the other admin's #{name} is uncommitted is refused once that commits" do
      [first, second] = create_two_admins()
      request = unquote(request)

      removal = change_and_hold(fn -> request.(second) end, self())
      assert_receive :change_uncommitted

      taking_back =
        Task.async(fn ->
          unboxed(fn -> Accounts.set_user_confirmed(:operator, first, false) end)
        end)

      assert await_blocked_or_done(taking_back) == :blocked

      send(removal.pid, :commit)
      assert {:ok, %User{}} = Task.await(removal, 15_000)

      # The second admin is gone or a member: the first is the last
      # confirmed admin, and the only admin.
      assert Task.await(taking_back, 15_000) == {:error, :last_confirmed_admin}

      stored = stored()
      assert Map.fetch!(stored, first.id) == {:admin, true}
      assert Map.get(stored, second.id, :deleted) == unquote(Macro.escape(left_as))
    end
  end

  # ---------------------------------------------------------------------------
  # One user, two requests: a deletion still uncommitted, and a request about them
  # ---------------------------------------------------------------------------

  # #427, found by the reviews of #416. Each request below reads a user, or
  # is handed one that a page read earlier, and then writes them, or writes
  # a row that refers to them. A deletion can commit in between: the request
  # waits on the user's row, or on the reference to it, and finds it gone.
  # It answers as it answers for a user deleted before the call (in
  # `Cake.AccountsTest`, "a user deleted before the call"), never with the
  # exception of a write that found nothing: an `Ecto.StaleEntryError` for
  # an update, an `Ecto.ConstraintError` for a token's reference.
  #
  # The deletion is held open until the request waits on it, as above.

  # Each request, by what it is to a user: the first three confirm, the
  # next two set a password, one stores a session at log-in, and the last
  # three mail a link.
  @requests_about_a_user [
    confirm_by_hand: "a confirmation by hand",
    confirm_by_link: "a confirmation by the mailed link",
    change_email_by_link: "an email change by the mailed link",
    change_password: "a password change",
    reset_password: "a password reset",
    store_session: "storing a session at log-in",
    send_confirmation: "mailing confirmation instructions",
    send_email_change: "mailing an email change's link",
    send_password_reset: "mailing password reset instructions"
  ]

  # An unconfirmed member: a confirmation, and its instructions, then have
  # something to do.
  defp create_unconfirmed_member do
    unboxed(fn ->
      {:ok, user} = Accounts.register_user(racer("#{@username_prefix}solo"))
      user
    end)
  end

  defp tokens_left?(%User{id: id}) do
    unboxed(fn -> Repo.exists?(from t in UserToken, where: t.user_id == ^id) end)
  end

  # The request to make about `user`, made ready while they exist: a link's
  # token is made first.
  defp prepare(user, :confirm_by_hand),
    do: fn -> Accounts.set_user_confirmed(:operator, user, true) end

  defp prepare(user, :confirm_by_link) do
    token = confirmation_token(user)
    fn -> Accounts.confirm_user(token) end
  end

  defp prepare(user, :change_email_by_link) do
    token = changed_email_token(user)
    fn -> Accounts.update_user_email(user, token) end
  end

  defp prepare(user, :change_password),
    do: fn -> Accounts.update_user_password(user, @password, %{password: @new_password}) end

  defp prepare(user, :reset_password),
    do: fn -> Accounts.reset_user_password(user, %{password: @new_password}) end

  defp prepare(user, :store_session), do: fn -> Accounts.generate_user_session_token(user) end

  defp prepare(user, :send_confirmation),
    do: fn -> Accounts.deliver_user_confirmation_instructions(user, &link/1) end

  defp prepare(user, :send_email_change) do
    changed = %{user | email: "new-" <> user.email}
    fn -> Accounts.deliver_user_update_email_instructions(changed, user.email, &link/1) end
  end

  defp prepare(user, :send_password_reset),
    do: fn -> Accounts.deliver_user_reset_password_instructions(user, &link/1) end

  defp link(token), do: "/#{token}"

  # What each request answers for a user who is gone. A link is no longer
  # good, as for a link that never was. Confirming by hand raises, as the
  # admin panel's other changes to a login do, and its page rescues. A
  # change or a token has nobody to be for.
  defp gone_answer(:confirm_by_hand), do: {:raised, Ecto.NoResultsError}
  defp gone_answer(request) when request in [:confirm_by_link, :change_email_by_link], do: :error
  defp gone_answer(_request), do: {:error, :gone}

  # What a request answers, or the exception it raised, so that one table
  # can give either as the answer it expects.
  defp answer(request) do
    request.()
  rescue
    exception -> {:raised, exception.__struct__}
  end

  for {request, name} <- @requests_about_a_user do
    test "#{name} that waits on the same user's deletion answers as for a user who is gone" do
      user = create_unconfirmed_member()
      request = prepare(user, unquote(request))

      deletion = change_and_hold(fn -> Accounts.delete_user(user) end, self())
      assert_receive :change_uncommitted

      asked = Task.async(fn -> unboxed(fn -> answer(request) end) end)
      assert await_blocked_or_done(asked) == :blocked

      send(deletion.pid, :commit)
      assert {:ok, %User{}} = Task.await(deletion, 15_000)

      assert Task.await(asked, 15_000) == gone_answer(unquote(request))
      assert stored() == %{}
      refute tokens_left?(user)
    end
  end

  # ---------------------------------------------------------------------------
  # One admin, two requests: a demotion still uncommitted, and a confirmation
  # ---------------------------------------------------------------------------

  # #427. A confirmation reads the user, writes their confirmation, and
  # answers with the user. A demotion of the same admin can commit in
  # between, and the answer then says `role: :admin` of a member: the admin
  # panel shows the answer, and so the old role, until the page is reloaded.
  # The rule is not misled, since it goes by the database. The answer has to
  # be the user as the database has them once the confirmation is written.
  #
  # The demotion is held open until the confirmation waits on it. Of the two
  # admins, the first is not confirmed, so demoting them takes no confirmed
  # admin away and is allowed; the second is.

  defp create_unconfirmed_and_confirmed_admin do
    unboxed(fn ->
      [
        create_user("#{@username_prefix}first", :admin, false),
        create_user("#{@username_prefix}second", :admin, true)
      ]
    end)
  end

  for request <- [:confirm_by_hand, :confirm_by_link] do
    test "#{Keyword.fetch!(@requests_about_a_user, request)} that waits on the same admin's demotion answers with the role the demotion left" do
      [first, second] = create_unconfirmed_and_confirmed_admin()
      confirmation = prepare(first, unquote(request))

      demotion = change_and_hold(fn -> Accounts.update_user_role(first, :member) end, self())
      assert_receive :change_uncommitted

      confirming = Task.async(fn -> unboxed(confirmation) end)
      assert await_blocked_or_done(confirming) == :blocked

      send(demotion.pid, :commit)
      assert {:ok, %User{role: :member}} = Task.await(demotion, 15_000)

      assert {:ok, %User{role: :member} = confirmed} = Task.await(confirming, 15_000)
      assert confirmed == unboxed(fn -> Repo.get!(User, first.id) end)
      assert stored() == %{first.id => {:member, true}, second.id => {:admin, true}}
    end
  end

  # ---------------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------------

  property "of requests made at once, exactly those that would leave no confirmed admin are refused" do
    check all(
            population <-
              population(
                unconfirmed_admins: [:demote, :demote_by_update, :delete, :unconfirm, :none],
                members: [:demote, :delete, :unconfirm, :none]
              ),
            max_runs: @max_runs
          ) do
      users = run(population)

      assert_consistent(users)
      assert Enum.count(users, &refused?/1) == refusals_needed(users)
    end
  end

  property "with members promoted and admins confirmed in the same instant, a confirmed admin still remains and each spares at most one refusal" do
    check all(
            population <-
              population(
                unconfirmed_admins: [:confirm, :confirm, :demote, :delete, :none],
                members: [:promote, :promote, :demote, :delete, :none]
              ),
            max_runs: @max_runs
          ) do
      users = run(population)

      assert_consistent(users)

      # Each makes one more confirmed admin, if it lands first: a confirmed
      # member promoted, an admin confirmed.
      sparing = Enum.count(users, &(&1.request in [:promote, :confirm]))
      most = refusals_needed(users)
      least = max(0, most - sparing)

      assert Enum.count(users, &refused?/1) in least..most
    end
  end

  # Several requests for the same user at once, starting from no admin at
  # all. Run one after another in any order, the first promotion makes an
  # admin and from then on there is always one. So when anything is promoted,
  # an admin is left; and when nothing is, every demotion is of a member and
  # is allowed.
  property "from no admins, whatever promotions and demotions of the same users race, an admin is left exactly when one was promoted" do
    check all(
            requests <-
              list_of(
                tuple({integer(0..1), member_of([:promote, :demote])}),
                min_length: 1,
                max_length: most_users()
              ),
            max_runs: @max_runs
          ) do
      delete_racers()
      users = create_users([{:member, true, :none}, {:member, true, :none}])

      answers =
        race(for {n, request} <- requests, do: ask(Enum.at(users, n).user, request))

      for answer <- answers do
        assert match?({:ok, %User{}}, answer) or answer == {:error, :last_admin},
               "a request was answered #{inspect(answer)}"
      end

      admin_left? = admin_left?(stored())
      promoted? = Enum.any?(requests, fn {_n, request} -> request == :promote end)

      assert admin_left? == promoted?
    end
  end

  # #427, as the stress run that found it: a user is deleted at the moment
  # any of the requests about them are made. Whichever goes first, each
  # request is answered as for a user who exists, or as for one who is gone,
  # and nothing is left of the user. It reaches what the tests above do not
  # fix: a deletion that commits between a request's read and its write
  # without the request ever waiting on it.
  property "whatever is asked about a user in the instant they are deleted, each request is answered as for a user who exists or one who is gone" do
    check all(
            requests <-
              list_of(member_of(Keyword.keys(@requests_about_a_user)),
                min_length: 1,
                max_length: most_users() - 1
              ),
            max_runs: @max_runs
          ) do
      delete_racers()
      user = create_unconfirmed_member()
      asked = Enum.map(requests, &prepare(user, &1))

      [deletion | answers] =
        race([
          fn -> Accounts.delete_user(user) end
          | Enum.map(asked, fn request -> fn -> answer(request) end end)
        ])

      assert {:ok, %User{}} = deletion

      for {request, answer} <- Enum.zip(requests, answers) do
        assert answer == gone_answer(request) or answered_for_user?(request, answer),
               "#{inspect(request)} was answered #{inspect(answer)}"
      end

      assert stored() == %{}
      refute tokens_left?(user)
    end
  end

  # What each request answers for a user who still exists when it is made.
  # A link can also be used up in the same instant, by another confirmation
  # or by a password change, which deletes the user's tokens: that is
  # `:error`, as for a user who is gone.
  defp answered_for_user?(request, answer) when request in [:confirm_by_hand, :confirm_by_link],
    do: match?({:ok, %User{confirmed_at: %DateTime{}}}, answer)

  defp answered_for_user?(:change_email_by_link, answer), do: answer == :ok

  defp answered_for_user?(request, answer) when request in [:change_password, :reset_password],
    do: match?({:ok, %User{}}, answer)

  defp answered_for_user?(:store_session, answer),
    do: match?({:ok, token} when is_binary(token), answer)

  defp answered_for_user?(_mailing, answer), do: match?({:ok, %Swoosh.Email{}}, answer)
end
