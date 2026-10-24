defmodule ElixirRag.LLM.GeminiTest do
  use ExUnit.Case, async: true

  alias ElixirRag.LLM.Gemini

  defp json_body(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(body), conn}
  end

  test "embed_query asks for a query embedding at the configured size" do
    Req.Test.stub(Gemini, fn conn ->
      assert conn.request_path == "/v1beta/models/gemini-embedding-001:batchEmbedContents"
      assert Plug.Conn.get_req_header(conn, "x-goog-api-key") == ["test-key"]

      {%{"requests" => [request]}, conn} = json_body(conn)
      assert request["taskType"] == "RETRIEVAL_QUERY"
      assert request["outputDimensionality"] == 768
      assert request["content"] == %{"parts" => [%{"text" => "hello"}]}

      Req.Test.json(conn, %{"embeddings" => [%{"values" => [0.1, 0.2]}]})
    end)

    assert Gemini.embed_query("hello") == {:ok, [0.1, 0.2]}
  end

  test "embed_documents sends batches of at most 100 and keeps the order" do
    test = self()

    Req.Test.stub(Gemini, fn conn ->
      {%{"requests" => requests}, conn} = json_body(conn)
      send(test, {:batch, length(requests)})
      assert Enum.all?(requests, &(&1["taskType"] == "RETRIEVAL_DOCUMENT"))

      embeddings =
        Enum.map(requests, fn %{"content" => %{"parts" => [%{"text" => text}]}} ->
          %{"values" => [String.to_integer(text) * 1.0]}
        end)

      Req.Test.json(conn, %{"embeddings" => embeddings})
    end)

    texts = Enum.map(1..150, &Integer.to_string/1)

    assert {:ok, vectors} = Gemini.embed_documents(texts)
    assert vectors == Enum.map(1..150, &[&1 * 1.0])
    assert_received {:batch, 100}
    assert_received {:batch, 50}
  end

  test "generate sends the system prompt separately and returns the text" do
    Req.Test.stub(Gemini, fn conn ->
      assert conn.request_path =~ ":generateContent"

      {body, conn} = json_body(conn)
      assert body["systemInstruction"] == %{"parts" => [%{"text" => "be brief"}]}
      assert [%{"role" => "user", "parts" => [%{"text" => "question"}]}] = body["contents"]

      Req.Test.json(conn, %{
        "candidates" => [%{"content" => %{"parts" => [%{"text" => " An answer. "}]}}]
      })
    end)

    assert Gemini.generate("be brief", "question") == {:ok, "An answer."}
  end

  test "a response without candidates is an error" do
    Req.Test.stub(Gemini, &Req.Test.json(&1, %{"promptFeedback" => %{"blockReason" => "OTHER"}}))

    assert {:error, {:unexpected_response, _}} = Gemini.generate("system", "prompt")
  end

  test "HTTP errors are returned with the status" do
    Req.Test.stub(Gemini, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"error" => %{"message" => "bad request"}})
    end)

    assert {:error, {:http_error, 400, %{"error" => _}}} = Gemini.embed_query("hello")
  end

  test "a rate-limit error's retry delay is honoured, with a little slack" do
    body = %{
      "error" => %{
        "code" => 429,
        "details" => [
          %{"@type" => "type.googleapis.com/google.rpc.QuotaFailure"},
          %{"@type" => "type.googleapis.com/google.rpc.RetryInfo", "retryDelay" => "33s"}
        ]
      }
    }

    assert Gemini.retry_delay(body) == 33_500
    assert Gemini.retry_delay(put_in(body, ["error", "details"], [retry_info("1.25s")])) == 1_750
    assert Gemini.retry_delay(put_in(body, ["error", "details"], [retry_info("600s")])) == 65_000
    assert Gemini.retry_delay(put_in(body, ["error", "details"], [retry_info("soon")])) == nil
    assert Gemini.retry_delay(%{"error" => %{"code" => 429}}) == nil
    assert Gemini.retry_delay("Too Many Requests") == nil
    assert Gemini.retry_delay(Jason.encode!(body)) == 33_500
    assert Gemini.retry_delay(:zlib.gzip(Jason.encode!(body))) == 33_500
  end

  defp retry_info(delay),
    do: %{"@type" => "type.googleapis.com/google.rpc.RetryInfo", "retryDelay" => delay}
end
