defmodule ElixirRag.Voice do
  @moduledoc """
  How answers sound, set with `config :elixir_rag, voice: Module`.

  A voice adds a persona on top of the grounding rules, which every voice
  shares, and lists phrases its answers must never contain. An answer that
  contains one, or that greets a visitor who didn't greet first, is
  regenerated once with a reminder to avoid it.

  Greetings, thanks and questions about who you are get the voice's own
  `small_talk/1` reply, without retrieval or the model.
  """

  @callback persona() :: String.t()
  @callback no_answer() :: String.t()
  @callback small_talk(:greeting | :thanks | :introduction) :: String.t()
  @callback forbidden() :: [Regex.t()]

  @grounding """
  You answer questions using only the numbered passages you are given.
  Cite the passages you used, like [1] or [2][3].
  If the passages don't contain the answer, say that you don't know. Don't guess.
  Greetings, thanks and questions about who you are aren't questions about the
  passages: reply to those in one or two sentences, in character, without citations.
  Answer everything else from the passages as above.
  """

  @greeting ~r/^\W*(hello|hi|hey|greetings|good (morning|afternoon|evening)|welcome)\b/i
  @introduction ~r/\b(who (are|r) (you|u)|your name)\b/i

  def impl, do: Application.get_env(:elixir_rag, :voice, ElixirRag.Voice.Dragonkeeper)

  @retry_note """
  Your previous answer used wording you must avoid (pressure, false promises, talk
  of passages and documents, or a greeting the visitor didn't start).
  Answer again without it.
  """

  def system_prompt(voice, opts \\ []) do
    prompt = base_prompt(voice)
    if opts[:retry], do: prompt <> "\n" <> @retry_note, else: prompt
  end

  defp base_prompt(voice) do
    case voice.persona() do
      "" -> @grounding
      persona -> @grounding <> "\n" <> persona
    end
  end

  @doc "Returns `:greeting`, `:thanks` or `:introduction` for small talk, otherwise `nil`."
  def small_talk(question) do
    Enum.find_value(small_talk_patterns(), fn {kind, pattern} ->
      Regex.match?(pattern, question) && kind
    end)
  end

  defp small_talk_patterns do
    [
      greeting:
        ~r/^\W*(hello|hi|hey|greetings|good (morning|afternoon|evening))( there| nesta)?\W*$/i,
      thanks: ~r/^\W*(thanks|thank you|cheers)( so much| nesta)?\W*$/i,
      introduction: ~r/^\W*(who (are|r) (you|u)|what'?s your name|what is your name)\W*$/i
    ]
  end

  def check(voice, question, text) do
    cond do
      pattern = Enum.find(voice.forbidden(), &Regex.match?(&1, text)) ->
        {:error, {:forbidden, pattern.source}}

      Regex.match?(@greeting, text) and not Regex.match?(@greeting, question) and
          not Regex.match?(@introduction, question) ->
        {:error, :unprompted_greeting}

      true ->
        :ok
    end
  end
end
