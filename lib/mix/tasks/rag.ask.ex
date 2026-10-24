defmodule Mix.Tasks.Rag.Ask do
  @shortdoc "Asks a question of the indexed documents"
  @moduledoc """
      mix rag.ask "How much is the deposit for a Ridgeback?"
      mix rag.ask --top-k 3 "What happens if my dragon won't land?"
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl true
  def run(args) do
    {opts, words} = OptionParser.parse!(args, strict: [top_k: :integer])
    question = Enum.join(words, " ")

    if question == "", do: Mix.raise(~s(Usage: mix rag.ask "your question"))

    case ElixirRag.Indexer.status() do
      :empty ->
        Mix.raise("Nothing indexed yet. Run `mix rag.index` first.")

      :stale ->
        Mix.shell().error(
          "The index was built with another embedding model. Run `mix rag.index`."
        )

      :ok ->
        :ok
    end

    case ElixirRag.ask(question, opts) do
      {:ok, %{answer: answer, sources: sources}} ->
        Mix.shell().info(answer <> "\n")

        sources
        |> Enum.with_index(1)
        |> Enum.each(fn {chunk, n} ->
          Mix.shell().info(
            "[#{n}] #{chunk.source} ##{chunk.chunk_index}  distance #{Float.round(chunk.distance, 3)}"
          )
        end)

      {:error, reason} ->
        Mix.raise("Failed: #{inspect(reason)}")
    end
  end
end
