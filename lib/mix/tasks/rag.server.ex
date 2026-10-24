defmodule Mix.Tasks.Rag.Server do
  @shortdoc "Serves the chat page on localhost"
  @moduledoc """
      mix rag.server
      mix rag.server --port 4001
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [port: :integer])
    port = opts[:port] || 4000

    if ElixirRag.Indexer.status() == :empty do
      Mix.raise("Nothing indexed yet. Run `mix rag.index` first.")
    end

    {:ok, _} = Bandit.start_link(plug: ElixirRag.Web, ip: :loopback, port: port)
    Mix.shell().info("Chat at http://localhost:#{port}")
    Process.sleep(:infinity)
  end
end
