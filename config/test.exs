import Config

config :elixir_rag, ElixirRag.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "elixir_rag_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :elixir_rag, llm: ElixirRag.MockLLM

config :elixir_rag, ElixirRag.LLM.Gemini,
  api_key: "test-key",
  req_options: [plug: {Req.Test, ElixirRag.LLM.Gemini}, retry: false]

config :logger, level: :warning
