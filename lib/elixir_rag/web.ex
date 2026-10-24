defmodule ElixirRag.Web do
  @moduledoc "The chat page and its JSON endpoint. Started by `mix rag.server`."

  use Plug.Router

  require Logger

  @history_limit 6

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  get "/" do
    conn
    |> put_resp_content_type("text/html")
    |> send_file(200, Application.app_dir(:elixir_rag, "priv/static/index.html"))
  end

  post "/api/ask" do
    question = conn.body_params |> Map.get("question") |> text()
    history = conn.body_params |> Map.get("history") |> history()

    cond do
      question == "" ->
        json(conn, 422, %{error: "Please type a question."})

      String.length(question) > 500 ->
        json(conn, 422, %{error: "Please keep questions under 500 characters."})

      true ->
        case ElixirRag.ask(question, history: history) do
          {:ok, %{answer: answer, question: asked, sources: sources}} ->
            json(conn, 200, %{
              answer: answer,
              question: asked,
              sources: Enum.map(sources, &source_json/1)
            })

          {:error, reason} ->
            Logger.error("ask failed: #{inspect(reason)}")
            json(conn, 502, %{error: "Sorry, something went wrong. Please try again."})
        end
    end
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_value), do: ""

  defp history(messages) when is_list(messages) do
    messages
    |> Enum.flat_map(fn
      %{"role" => "user", "text" => text} when is_binary(text) -> [{:user, text}]
      %{"role" => "assistant", "text" => text} when is_binary(text) -> [{:assistant, text}]
      _ -> []
    end)
    |> Enum.take(-@history_limit)
  end

  defp history(_messages), do: []

  defp source_json(chunk) do
    %{
      source: chunk.source,
      chunk_index: chunk.chunk_index,
      content: chunk.content,
      distance: Float.round(chunk.distance, 3)
    }
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
