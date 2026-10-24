# rag_elixir

A small retrieval-augmented generation (RAG) pipeline in Elixir. Documents are
chunked, embedded with Gemini and stored in Postgres with pgvector; questions
are answered from the nearest chunks, with citations.

```
$ mix rag.ask "My dragon set a shed on fire. Am I covered?"
If you have Fire Cover, which costs 15 gold a day when you book, it covers fire
damage up to 2,000 gold [1]. Without Fire Cover, you must pay the full cost of
the damage [1].

[1] policies.md #1  distance 0.23
...
```

The documents in `priv/docs` are the handbook of Ember & Scale Dragon Hire, a
dragon rental roost that (sadly) doesn't exist: its four kinds of dragon and
every dragon by name, prices, policies, flying rules, a first hire step by
step, the riding school, how the dragons are looked after, routes and landing
fields, the seasons, weddings and festivals, gifts and group visits, working
at the roost, the town's Dragon Charter, and why you can't buy a dragon. Replace them with your own. Keep each paragraph under `:chunk_size`
and name its subject in it, so every chunk makes sense on its own.

## How it works

```
index time                              query time

priv/docs/*.md                          "How much is the deposit?"
     │                                         │
     ▼                                         ▼
Chunker.chunk/2  (400 chars, 60 overlap)    LLM.embed_query/1  (RETRIEVAL_QUERY)
     │                                         │
     ▼                                         ▼
LLM.embed_documents/1 (RETRIEVAL_DOCUMENT)  VectorStore.search/2  (ORDER BY embedding <=> $1)
     │                                         │
     ▼                                         ▼
VectorStore.replace_source/4 ──► chunks ◄── top k chunks → numbered passages in the prompt
                                 table             │
                                                   ▼
                                            LLM.generate/2 → answer with [n] citations
```

| Module | Job |
|---|---|
| `ElixirRag` | `ask/2`, `retrieve/2`: the query side; `standalone/2` rewrites follow-ups |
| `ElixirRag.Chunker` | Splits text into overlapping chunks at paragraph boundaries |
| `ElixirRag.Indexer` | Reads files, chunks, embeds, stores; reports whether the index is stale |
| `ElixirRag.VectorStore` | Inserts chunks and runs cosine-distance search with pgvector |
| `ElixirRag.LLM` | Behaviour for the model provider |
| `ElixirRag.LLM.Gemini` | Gemini implementation over Req |
| `ElixirRag.Voice` | Grounding rules, personas, and the check that rejects off-voice answers |
| `ElixirRag.Web` | The chat page and `POST /api/ask` |

## Running it

You need Elixir 1.15+, Postgres with the [pgvector](https://github.com/pgvector/pgvector)
extension, and a [Gemini API key](https://aistudio.google.com/apikey) (the free
tier is enough).

```sh
docker compose up -d
export GEMINI_API_KEY=...
mix setup
mix rag.index
mix rag.server                # chat at http://localhost:4000
```

Or from the terminal:

```sh
mix rag.ask "Can I feed my dragon a goat?"
mix rag.ask "Can I buy a dragon?"
```

Or from IEx (`iex -S mix`):

```elixir
ElixirRag.ask("What happens if I bring the dragon back late?")
ElixirRag.ask("Do you rent unicorns?")
ElixirRag.retrieve("hoard", top_k: 3)
```

Follow-ups work in the chat page and with the `:history` option, e.g.
`ElixirRag.ask("and the deposit?", history: [{:user, "Tell me about Hazel"}, {:assistant, "..."}])`:
the model first rewrites the message into a standalone question, and that is
what gets retrieved and answered.

To index other documents, put `.md` or `.txt` files in `priv/docs` or run
`mix rag.index --dir path/to/docs`. Re-running the task re-embeds every file
and removes chunks of files that were deleted.

**"permission denied to create extension vector"**: the migration runs
`CREATE EXTENSION vector`, which needs a superuser. If your database role
isn't one, run `CREATE EXTENSION vector;` once in each database as a
superuser, then migrate again.

## Configuration

`config/config.exs`:

| Key | Default | |
|---|---|---|
| `:top_k` | 5 | Chunks retrieved per question |
| `:max_distance` | `nil` | Drop chunks further than this; if none are left the model isn't called |
| `:voice` | `ElixirRag.Voice.Dragonkeeper` | How answers sound |
| `:chunk_size` / `:chunk_overlap` | 400 / 60 | Characters |
| `ElixirRag.LLM.Gemini, :embedding_model` | `gemini-embedding-001` | |
| `ElixirRag.LLM.Gemini, :embedding_dimensions` | 768 | Must match `vector(768)` in the migration |
| `ElixirRag.LLM.Gemini, :generation_model` | `gemini-3.5-flash-lite` | |

Cosine distances depend on the embedding model, so tune `:max_distance` by
asking a few questions the documents can and can't answer and looking at the
distances `mix rag.ask` prints.

If you change the embedding model or size, change the migration's vector size
to match and run `mix rag.index` again. Every chunk is stamped with the
model it was embedded by, and `mix rag.ask` warns when the index was built
by a different one: vectors from different models are not comparable, and
searching them gives poor matches without any error.

## Voices

Every voice shares the same grounding rules: answer only from the retrieved
passages, cite them, and say so when they don't contain the answer. A voice
adds a persona on top and lists phrases its answers must never contain.

`ElixirRag.Voice.Dragonkeeper` is Nesta Ashryver, the roost's head keeper:
dry, warm and fond of every dragon. She answers first, may add one joke, and
calls the dragons by name, but her jokes never add facts, she drops them after
bad news, and she never pressures or invents offers. If an answer contains a
forbidden phrase ("act now", "limited time", "according to the documents",
...), it is logged and regenerated once with a reminder; if the retry is off
too, the request fails rather than show it.

Greetings, thanks and "who are you?" skip retrieval and the model and get
the voice's own `small_talk/1` reply.

To write your own, implement `persona/0`, `no_answer/0`, `small_talk/1` and `forbidden/0`
from `ElixirRag.Voice` and set `config :elixir_rag, voice: MyVoice`.

## Using another provider

Implement the four callbacks in `ElixirRag.LLM` (`embed_documents/1`,
`embed_query/1`, `generate/2`, `embedding_signature/0`) and set:

```elixir
config :elixir_rag, llm: MyApp.OpenAI
```

## Tests

```sh
mix test
```

The tests need Postgres but no API key. The pipeline runs against
`ElixirRag.FakeLLM`, whose embeddings are hashed word counts, and the Gemini
client is tested against `Req.Test` stubs.

## License

MIT
