import Config

if config_env() != :test do
  if api_key = System.get_env("GEMINI_API_KEY") do
    config :elixir_rag, ElixirRag.LLM.Gemini, api_key: api_key
  end

  if database_url = System.get_env("DATABASE_URL") do
    config :elixir_rag, ElixirRag.Repo, url: database_url
  end
end
