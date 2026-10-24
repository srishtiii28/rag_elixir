defmodule ElixirRag.DataCase do
  @moduledoc "Runs each test in a database transaction that is rolled back."
  use ExUnit.CaseTemplate

  using do
    quote do
      alias ElixirRag.Repo
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(ElixirRag.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
