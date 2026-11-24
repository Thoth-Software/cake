defmodule Cake.Mailer do
  @moduledoc """
  The Swoosh mailer that `Cake.Accounts.UserNotifier`, its one caller, sends
  the account emails through. Its adapter comes from config:
  `Swoosh.Adapters.Local` (mail kept in memory, read at `/dev/mailbox` in
  dev) or `Swoosh.Adapters.Test` under test, and none that sends mail.
  """

  use Swoosh.Mailer, otp_app: :cake
end
