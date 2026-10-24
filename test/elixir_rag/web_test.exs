defmodule ElixirRag.WebTest do
  use ElixirRag.DataCase, async: true

  import Mox
  import Plug.Test

  alias ElixirRag.{FakeLLM, MockLLM, VectorStore, Web}

  setup :verify_on_exit!

  setup do
    stub_with(MockLLM, FakeLLM)
    passages = ["The deposit is 250 gold for a Ridgeback."]

    {:ok, 1} =
      VectorStore.replace_source(
        "policies.md",
        passages,
        Enum.map(passages, &FakeLLM.vector/1),
        FakeLLM.embedding_signature()
      )

    :ok
  end

  defp post_json(body) do
    conn(:post, "/api/ask", Jason.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Web.call(Web.init([]))
  end

  test "serves the chat page" do
    conn = conn(:get, "/") |> Web.call(Web.init([]))

    assert conn.status == 200
    assert conn.resp_body =~ "<title>"
  end

  test "answers a question with its sources" do
    expect(MockLLM, :generate, fn _system, _prompt -> {:ok, "It's 250 gold [1]."} end)

    conn = post_json(%{question: "How much is the deposit?"})

    assert conn.status == 200

    assert %{
             "answer" => "It's 250 gold [1].",
             "sources" => [%{"source" => "policies.md", "chunk_index" => 0, "distance" => _}]
           } = Jason.decode!(conn.resp_body)
  end

  test "answers in the dragonkeeper's voice" do
    expect(MockLLM, :generate, fn system, _prompt ->
      assert system =~ "Nesta Ashryver"
      {:ok, "250 gold [1]."}
    end)

    assert post_json(%{question: "deposit"}).status == 200
  end

  test "passes recent history and returns the question it answered" do
    expect(MockLLM, :generate, fn _system, prompt ->
      assert prompt =~ "Visitor: Tell me about Ridgebacks\nKeeper: They carry two riders."
      refute prompt =~ "malformed"
      {:ok, "How much is the deposit for a Ridgeback?"}
    end)

    expect(MockLLM, :generate, fn _system, _prompt -> {:ok, "250 gold [1]."} end)

    history = [
      %{role: "user", text: "Tell me about Ridgebacks"},
      %{role: "assistant", text: "They carry two riders."},
      %{role: "system", text: "malformed"}
    ]

    conn = post_json(%{question: "and the deposit?", history: history})

    assert conn.status == 200

    assert %{"question" => "How much is the deposit for a Ridgeback?"} =
             Jason.decode!(conn.resp_body)
  end

  test "rejects a question that isn't text" do
    assert post_json(%{question: %{"a" => 1}}).status == 422
  end

  test "rejects an empty question" do
    conn = post_json(%{question: "  "})

    assert conn.status == 422
    assert %{"error" => _} = Jason.decode!(conn.resp_body)
  end

  @tag :capture_log
  test "reports a model failure without details" do
    expect(MockLLM, :generate, fn _, _ -> {:error, {:http_error, 503, %{}}} end)

    conn = post_json(%{question: "deposit"})

    assert conn.status == 502
    refute conn.resp_body =~ "503"
  end
end
