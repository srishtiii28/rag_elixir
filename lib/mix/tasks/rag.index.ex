defmodule Mix.Tasks.Rag.Index do
  @shortdoc "Chunks, embeds and stores the documents"
  @moduledoc """
  Indexes every `.md` and `.txt` file in the docs directory (default
  `priv/docs`). Running it again re-embeds every document and drops the chunks
  of files that were deleted.

      mix rag.index
      mix rag.index --dir path/to/docs
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [dir: :string])
    dir = opts[:dir] || ElixirRag.Indexer.docs_dir()

    case ElixirRag.Indexer.index_dir(dir) do
      {:ok, count} -> Mix.shell().info("Indexed #{count} chunks from #{dir}")
      {:error, reason} -> Mix.raise("Indexing failed: #{inspect(reason)}")
    end
  end
end
