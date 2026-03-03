defmodule Liteskill.Repo do
  @moduledoc false
  use Ecto.Repo,
    otp_app: :liteskill,
    adapter: Ecto.Adapters.SQLite3
end
