defmodule ElixirRag.Repo do
  use Ecto.Repo,
    otp_app: :elixir_rag,
    adapter: Ecto.Adapters.Postgres
end
