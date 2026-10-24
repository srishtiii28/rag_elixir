import Config

config :elixir_rag, ecto_repos: [ElixirRag.Repo]

config :elixir_rag, ElixirRag.Repo, types: ElixirRag.PostgrexTypes

config :elixir_rag,
  llm: ElixirRag.LLM.Gemini,
  voice: ElixirRag.Voice.Dragonkeeper,
  top_k: 5,
  max_distance: nil,
  chunk_size: 400,
  chunk_overlap: 60

config :elixir_rag, ElixirRag.LLM.Gemini,
  embedding_model: "gemini-embedding-001",
  embedding_dimensions: 768,
  generation_model: "gemini-3.5-flash-lite"

import_config "#{config_env()}.exs"
