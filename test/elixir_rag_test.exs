defmodule ElixirRagTest do
  use ElixirRag.DataCase, async: true

  import Mox

  alias ElixirRag.{FakeLLM, MockLLM, VectorStore, Voice}

  setup :verify_on_exit!

  setup do
    stub_with(MockLLM, FakeLLM)

    passages = [
      "We open from dawn until the second bell after sunset.",
      "The deposit is 100 gold for a Puddlewyrm and 250 gold for a Ridgeback.",
      "Every hire includes a saddle, a helmet and a fireproof cloak."
    ]

    {:ok, 3} =
      VectorStore.replace_source(
        "roost.md",
        passages,
        Enum.map(passages, &FakeLLM.vector/1),
        FakeLLM.embedding_signature()
      )

    :ok
  end

  test "answers from the most relevant passage and returns the sources" do
    expect(MockLLM, :generate, fn system, prompt ->
      assert system =~ "using only the numbered passages"
      assert prompt =~ "[1] (source: roost.md)\nThe deposit is 100 gold"
      assert prompt =~ "Question: How big is the deposit for a Ridgeback?"
      {:ok, "250 gold [1]."}
    end)

    assert {:ok, %{answer: "250 gold [1].", sources: [best | _]}} =
             ElixirRag.ask("How big is the deposit for a Ridgeback?")

    assert best.source == "roost.md"
    assert best.content =~ "deposit"
  end

  test "top_k limits how many passages reach the prompt" do
    expect(MockLLM, :generate, fn _system, prompt ->
      assert prompt =~ "[1]"
      refute prompt =~ "[2]"
      {:ok, "ok"}
    end)

    assert {:ok, %{sources: [_]}} = ElixirRag.ask("deposit", top_k: 1)
  end

  test "doesn't call the model when nothing is close enough" do
    expect(MockLLM, :generate, 0, fn _, _ -> {:ok, "unreachable"} end)

    assert {:ok, %{answer: answer, sources: []}} =
             ElixirRag.ask("Do you rent unicorns?", max_distance: 0.5)

    assert answer == Voice.impl().no_answer()
  end

  @tag :capture_log
  test "an off-voice answer is regenerated once with a reminder" do
    expect(MockLLM, :generate, fn system, _prompt ->
      assert system =~ "Nesta Ashryver"
      refute system =~ "Answer again"
      {:ok, "Only 2 left, act now!!"}
    end)

    expect(MockLLM, :generate, fn system, _prompt ->
      assert system =~ "Nesta Ashryver"
      assert system =~ "Answer again without it."
      {:ok, "The deposit is 250 gold [1]."}
    end)

    assert {:ok, %{answer: "The deposit is 250 gold [1]."}} = ElixirRag.ask("deposit")
  end

  @tag :capture_log
  test "fails when the retry is off-voice too" do
    expect(MockLLM, :generate, 2, fn _system, _prompt -> {:ok, "Hurry!!"} end)

    assert {:error, {:off_voice, {:forbidden, _}}} = ElixirRag.ask("deposit")
  end

  test "a follow-up is rewritten into a standalone question before retrieval" do
    expect(MockLLM, :generate, fn system, prompt ->
      assert system =~ "makes sense on its own"
      assert prompt =~ "Visitor: Tell me about Ridgebacks\nKeeper: They carry two riders."
      assert prompt =~ "Last message: how big is the deposit for one?"
      {:ok, "How big is the deposit for a Ridgeback?"}
    end)

    expect(MockLLM, :generate, fn _system, prompt ->
      assert prompt =~ "[1] (source: roost.md)\nThe deposit is 100 gold"
      assert prompt =~ "Question: How big is the deposit for a Ridgeback?"
      {:ok, "250 gold [1]."}
    end)

    history = [{:user, "Tell me about Ridgebacks"}, {:assistant, "They carry two riders."}]

    assert {:ok, %{question: "How big is the deposit for a Ridgeback?"}} =
             ElixirRag.ask("how big is the deposit for one?", history: history)
  end

  test "a first question is used as it is" do
    expect(MockLLM, :generate, fn _system, _prompt -> {:ok, "ok"} end)

    assert {:ok, %{question: "deposit"}} = ElixirRag.ask("deposit")
  end

  test "small talk gets the voice's own reply, without retrieval or the model" do
    expect(MockLLM, :embed_query, 0, fn _ -> {:ok, []} end)
    expect(MockLLM, :generate, 0, fn _, _ -> {:ok, "unreachable"} end)

    history = [{:user, "Can I buy a dragon?"}, {:assistant, "No [1]."}]

    assert {:ok, %{answer: answer, sources: []}} = ElixirRag.ask("Who are you?", history: history)
    assert answer == Voice.impl().small_talk(:introduction)
  end

  test "returns embedding errors" do
    expect(MockLLM, :embed_query, fn _ -> {:error, :timeout} end)

    assert ElixirRag.ask("deposit") == {:error, :timeout}
  end

  test "returns generation errors" do
    expect(MockLLM, :generate, fn _, _ -> {:error, {:http_error, 503, %{}}} end)

    assert ElixirRag.ask("deposit") == {:error, {:http_error, 503, %{}}}
  end
end
