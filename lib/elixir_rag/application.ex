defmodule ElixirRag.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [ElixirRag.Repo]
    Supervisor.start_link(children, strategy: :one_for_one, name: ElixirRag.Supervisor)
  end
end
