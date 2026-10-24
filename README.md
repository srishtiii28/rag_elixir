# Build your first RAG in Elixir

A retrieval-augmented generation (RAG) app in Elixir, small enough to read in
an afternoon. Documents are chunked, embedded with Gemini and stored in
Postgres with pgvector. Questions are answered only from the nearest chunks,
with citations, in the voice of a dragon keeper, through the terminal or a
chat page.

**Read the walkthrough:** [Building Your First RAG in Elixir](https://srishtiii28.substack.com/p/building-your-first-rag-in-elixir)
explains every idea behind this code, from embeddings and cosine distance to
HNSW, grounding and query rewriting, and what went wrong along the way.

```
$ mix rag.ask "my kid is 14, can she fly a dragon by herself?"
Well, she can't fly one on her own at fourteen, I'm afraid [1]. Under-16s can
only ride if a parent or guardian signs the hire agreement and joins them [1].
Bless them, they do try to grow up too fast.

[1] policies.md #7  distance 0.227
[2] gifts-and-groups.md #6  distance 0.263
...
```

The handbook never says "kid", "14" or "by herself". Retrieval finds the
right paragraph by meaning, not by matching words.

## What's inside

- **Chunking** at paragraph boundaries, 400 characters with 60 characters of
  overlap
- **Embeddings** from `gemini-embedding-001` at 768 dimensions, with separate
  task types for documents and questions
- **Search** by cosine distance in Postgres, with an HNSW index from pgvector
- **Grounded answers** that cite their passages as `[1]`, `[2]` and say "I
  don't know" rather than guess
- **A voice**, Nesta Ashryver, the head keeper, plus a check in code that
  regenerates answers with forbidden phrasing or stray greetings
- **Follow-up questions**: "how much does she cost?" is rewritten to "how much
  does Hazel cost?" before retrieval
- **A chat page** with clickable citation seals that open the passage they
  cite
- **Offline tests** against a fake model, so `mix test` needs no API key

## The handbook

The documents in `priv/docs` are the handbook of Ember & Scale Dragon Hire, a
dragon rental roost that (sadly) doesn't exist. It's 17 pages: the four kinds
of dragon and all 21 dragons by name, prices, policies, flying rules, a first
hire step by step, the riding school, how the dragons are looked after,
routes and landing fields, the seasons, weddings and festivals, gifts and
group visits, working at the roost, the town's Dragon Charter, and why you
can't buy a dragon.

It's written to be a fair test: prices, rules and exceptions that people ask
about in a hundred different ways, and gaps the model has to admit to ("Do
you rent unicorns?").

## Running it

You need Elixir 1.15+, Docker (or a Postgres with the
[pgvector](https://github.com/pgvector/pgvector) extension), and a
[Gemini API key](https://aistudio.google.com/apikey). The free tier is enough.

```sh
docker compose up -d          # Postgres 17 with pgvector
export GEMINI_API_KEY=...
mix setup                     # deps, create the database, migrate
mix rag.index                 # chunk, embed and store the handbook
mix rag.server                # chat at http://localhost:4000
```

Or ask from the terminal, where each answer is followed by the chunks it was
given and their distances:

```sh
mix rag.ask "Can I buy a dragon?"
mix rag.ask --top-k 3 "What happens if I bring the dragon back late?"
```

Or from IEx (`iex -S mix`):

```elixir
ElixirRag.ask("Do you rent unicorns?")
ElixirRag.ask("and the deposit?", history: [{:user, "Tell me about Hazel"}, {:assistant, "..."}])
ElixirRag.retrieve("hoard", top_k: 3)
```

**"permission denied to create extension vector"**: the migration runs
`CREATE EXTENSION vector`, which needs a superuser. If your database role
isn't one, run `CREATE EXTENSION vector;` once in each database as a
superuser, then migrate again. The Docker setup doesn't have this problem.

## How it works

```
index time                              query time

priv/docs/*.md                          "How much is the deposit?"
     │                                         │
     ▼                                         ▼
Chunker.chunk/2  (400 chars, 60 overlap)    standalone/2  (rewrites follow-ups)
     │                                         │
     ▼                                         ▼
LLM.embed_documents/1 (RETRIEVAL_DOCUMENT)  LLM.embed_query/1  (RETRIEVAL_QUERY)
     │                                         │
     ▼                                         ▼
VectorStore.replace_source/4 ──► chunks ◄── VectorStore.search/2  (ORDER BY embedding <=> $1)
                                 table             │
                                                   ▼
                                            numbered passages + question
                                                   │
                                                   ▼
                                            LLM.generate/2 → Voice.check/3 → answer with [n]
```

Greetings, thanks and "who are you?" skip all of that and get the voice's
own fixed reply.

| Module | Job |
|---|---|
| `ElixirRag` | `ask/2` and `retrieve/2`, the query side; `standalone/2` rewrites follow-ups |
| `ElixirRag.Chunker` | Splits text into overlapping chunks at paragraph boundaries |
| `ElixirRag.Indexer` | Reads files, chunks, embeds, stores; reports whether the index is stale |
| `ElixirRag.VectorStore` | Inserts chunks and runs cosine-distance search with pgvector |
| `ElixirRag.LLM` | Behaviour for the model provider |
| `ElixirRag.LLM.Gemini` | Gemini over Req, with batching and rate-limit-aware retries |
| `ElixirRag.Voice` | Grounding rules, personas, small talk, and the answer check |
| `ElixirRag.Web` | The chat page and `POST /api/ask` |

## Using your own documents

Put `.md` or `.txt` files in `priv/docs`, or point the indexer at a folder:

```sh
mix rag.index --dir path/to/docs
```

Re-running the task re-embeds every file and removes chunks of files that were
deleted. Retrieval works best when every paragraph stands on its own: keep
each one under `:chunk_size` and name its subject in it ("A Ridgeback costs
25 gold an hour", not "They cost 25 gold an hour"), because a chunk loses the
heading above it.

When an answer is wrong, check the cited passages first. If the right one
wasn't retrieved, the fix is usually in the documents, not the prompt.

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
to match and run `mix rag.index` again. Every chunk is stamped with the model
it was embedded by, and `mix rag.ask` warns when the index was built by a
different one: vectors from different models are not comparable, and
searching them gives poor matches without any error.

## Voices

Every voice shares the same grounding rules: answer only from the retrieved
passages, cite them, and say so when they don't contain the answer. A voice
adds a persona on top, fixed replies for small talk, and a list of phrases its
answers must never contain.

`ElixirRag.Voice.Dragonkeeper` is Nesta Ashryver, the roost's head keeper:
dry, warm and fond of every dragon. She answers first, may add one aside, and
calls the dragons by name, but her asides never add facts, she drops them
after bad news, and she never pressures or invents offers. An answer with a
forbidden phrase ("act now", "limited time", talk of "the documents") or a
greeting nobody asked for is logged and regenerated once with a reminder; if
the retry fails too, the request fails rather than show it.

To write your own, implement `persona/0`, `no_answer/0`, `small_talk/1` and
`forbidden/0` from `ElixirRag.Voice` and set
`config :elixir_rag, voice: MyVoice`.

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
client is tested against `Req.Test` stubs. A handbook test checks that every
paragraph fits in one chunk and that prices agree everywhere they appear.

## License

MIT
