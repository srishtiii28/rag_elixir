import Config

config :elixir_rag, ElixirRag.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "elixir_rag_dev",
  pool_size: 5

config :logger, level: :info
