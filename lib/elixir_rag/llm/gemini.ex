defmodule ElixirRag.LLM.Gemini do
  @moduledoc """
  Google Gemini over HTTP, configured under `config :elixir_rag, ElixirRag.LLM.Gemini`.
  """

  @behaviour ElixirRag.LLM

  @base_url "https://generativelanguage.googleapis.com/v1beta"
  @batch_size 100

  @impl true
  def embed_documents(texts) do
    texts
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
      case embed_batch(batch, "RETRIEVAL_DOCUMENT") do
        {:ok, vectors} -> {:cont, {:ok, acc ++ vectors}}
        error -> {:halt, error}
      end
    end)
  end

  @impl true
  def embed_query(text) do
    with {:ok, [vector]} <- embed_batch([text], "RETRIEVAL_QUERY") do
      {:ok, vector}
    end
  end

  @impl true
  def generate(system, prompt) do
    model = config(:generation_model)

    body = %{
      systemInstruction: %{parts: [%{text: system}]},
      contents: [%{role: "user", parts: [%{text: prompt}]}],
      generationConfig: %{
        temperature: 0.2,
        maxOutputTokens: 1024,
        thinkingConfig: thinking_config(model)
      }
    }

    case post("/models/#{model}:generateContent", body) do
      {:ok, %{"candidates" => [%{"content" => %{"parts" => parts}} | _]}} ->
        {:ok, parts |> Enum.map_join(&(&1["text"] || "")) |> String.trim()}

      {:ok, body} ->
        {:error, {:unexpected_response, body}}

      error ->
        error
    end
  end

  @impl true
  def embedding_signature do
    "#{config(:embedding_model)}@#{config(:embedding_dimensions)}"
  end

  defp embed_batch(texts, task_type) do
    model = config(:embedding_model)

    requests =
      Enum.map(texts, fn text ->
        %{
          model: "models/#{model}",
          content: %{parts: [%{text: text}]},
          taskType: task_type,
          outputDimensionality: config(:embedding_dimensions)
        }
      end)

    case post("/models/#{model}:batchEmbedContents", %{requests: requests}) do
      {:ok, %{"embeddings" => embeddings}} -> {:ok, Enum.map(embeddings, & &1["values"])}
      {:ok, body} -> {:error, {:unexpected_response, body}}
      error -> error
    end
  end

  defp post(path, body) do
    with {:ok, key} <- api_key() do
      [
        base_url: @base_url,
        url: path,
        json: body,
        headers: [{"x-goog-api-key", key}],
        retry: &retry/2,
        max_retries: 3,
        receive_timeout: 30_000
      ]
      |> Keyword.merge(config(:req_options, []))
      |> Req.new()
      |> Req.post()
      |> case do
        {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
        {:ok, %Req.Response{status: status, body: body}} -> {:error, {:http_error, status, body}}
        error -> error
      end
    end
  end

  defp retry(_request, %Req.Response{status: 429, body: body}) do
    case retry_delay(body) do
      nil -> true
      delay -> {:delay, delay}
    end
  end

  defp retry(_request, %Req.Response{status: status}), do: status in [408, 500, 502, 503, 504]
  defp retry(_request, %Req.TransportError{}), do: true
  defp retry(_request, _exception), do: false

  @max_retry_delay 65_000

  @doc false
  def retry_delay(%{"error" => %{"details" => details}}) when is_list(details) do
    Enum.find_value(details, fn
      %{"@type" => "type.googleapis.com/google.rpc.RetryInfo", "retryDelay" => delay} ->
        case Float.parse(delay) do
          {seconds, "s"} when seconds >= 0 -> min(ceil(seconds * 1000) + 500, @max_retry_delay)
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  def retry_delay(<<0x1F, 0x8B, _::binary>> = gzipped), do: retry_delay(:zlib.gunzip(gzipped))

  def retry_delay(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> retry_delay(decoded)
      _ -> nil
    end
  end

  def retry_delay(_body), do: nil

  defp thinking_config("gemini-3" <> _), do: %{thinkingLevel: "minimal"}
  defp thinking_config(_model), do: %{thinkingBudget: 0}

  defp api_key do
    case config(:api_key) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_api_key}
    end
  end

  defp config(key, default \\ nil) do
    :elixir_rag |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
