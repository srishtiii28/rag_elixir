defmodule ElixirRag do
  @moduledoc """
  Answers questions from your own documents.

      ElixirRag.ask("How much is the deposit?")
      #=> {:ok, %{answer: "The deposit is ... [1]", question: "...", sources: [...]}}
  """

  require Logger

  alias ElixirRag.{LLM, VectorStore, Voice}

  @rewrite """
  You rewrite the visitor's last message so that it makes sense on its own.
  Replace words like "she", "it" or "that one" with what they refer to in the conversation.
  If the message already makes sense on its own, or is a greeting or thanks, return it unchanged.
  Reply with the rewritten message only.
  """

  @doc """
  Answers `question` from the indexed documents.

  ## Options

    * `:top_k` - how many chunks to retrieve (default 5)
    * `:max_distance` - drop chunks further than this cosine distance, and
      skip the model when none are left (default `nil`, keep all)
    * `:voice` - an `ElixirRag.Voice` module (default from config)
    * `:history` - earlier messages as `{:user | :assistant, text}`, oldest
      first. A follow-up is rewritten into a standalone question before
      retrieval, and `:question` in the result is the rewritten one.
  """
  def ask(question, opts \\ []) do
    voice = Keyword.get(opts, :voice, Voice.impl())

    case Voice.small_talk(question) do
      nil ->
        with {:ok, question} <- standalone(question, Keyword.get(opts, :history, [])),
             {:ok, chunks} <- retrieve(question, opts) do
          answer(question, chunks, voice)
        end

      kind ->
        {:ok, %{answer: voice.small_talk(kind), question: question, sources: []}}
    end
  end

  def standalone(question, []), do: {:ok, question}

  def standalone(question, history) do
    conversation =
      Enum.map_join(history, "\n", fn
        {:user, text} -> "Visitor: #{text}"
        {:assistant, text} -> "Keeper: #{text}"
      end)

    LLM.impl().generate(@rewrite, "Conversation:\n\n#{conversation}\n\nLast message: #{question}")
  end

  def retrieve(question, opts \\ []) do
    top_k = Keyword.get(opts, :top_k, Application.get_env(:elixir_rag, :top_k, 5))

    max_distance =
      Keyword.get(opts, :max_distance, Application.get_env(:elixir_rag, :max_distance))

    with {:ok, embedding} <- LLM.impl().embed_query(question) do
      chunks =
        embedding
        |> VectorStore.search(top_k)
        |> Enum.filter(&(is_nil(max_distance) or &1.distance <= max_distance))

      {:ok, chunks}
    end
  end

  def build_prompt(question, chunks) do
    passages =
      chunks
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {chunk, n} ->
        "[#{n}] (source: #{chunk.source})\n#{chunk.content}"
      end)

    "Passages:\n\n#{passages}\n\nQuestion: #{question}"
  end

  defp answer(question, [], voice),
    do: {:ok, %{answer: voice.no_answer(), question: question, sources: []}}

  defp answer(question, chunks, voice), do: generate(question, chunks, voice, false)

  defp generate(question, chunks, voice, retry) do
    prompt = build_prompt(question, chunks)

    with {:ok, text} <- LLM.impl().generate(Voice.system_prompt(voice, retry: retry), prompt) do
      case {Voice.check(voice, question, text), retry} do
        {:ok, _} ->
          {:ok, %{answer: text, question: question, sources: chunks}}

        {{:error, reason}, false} ->
          Logger.warning("#{inspect(voice)} answer rejected (#{inspect(reason)}); retrying")
          generate(question, chunks, voice, true)

        {{:error, reason}, true} ->
          Logger.error("#{inspect(voice)} answer rejected again (#{inspect(reason)})")
          {:error, {:off_voice, reason}}
      end
    end
  end
end
