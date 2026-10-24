---
title: "Building Your First RAG in Elixir"
description: "What retrieval-augmented generation is, how each part of it actually works, and how to build one from scratch in Elixir, with Postgres, pgvector, Gemini and a dragon rental roost."
author: "Srishti Dutta"
---

## Introduction

How do you get a language model to answer questions about documents it has never seen?

Think of a company handbook, a product spec, or a policy someone wrote last month. None of it was on the internet when the model was trained. Ask the model about it and it will either refuse or, more often, give a confident answer that sounds right and isn't.

What we want is a model that answers from *our* documents, shows where each answer came from, and says "I don't know" when the documents don't cover the question. The standard way to get that is **retrieval-augmented generation**, or RAG.

This post builds RAG up from the ideas underneath it: what a model knows and doesn't, what an embedding is, how "similar meaning" becomes a number, and how retrieved text becomes a grounded answer. Each idea is followed by the Elixir code that uses it, so by the end you'll have a working RAG and know why every piece of it is there.

> 💡 **Note**
> The finished code is on GitHub: [rag_elixir](https://github.com/srishtiii28/rag_elixir). The post shows the code behind each idea; the repo has every file, ready to run.

## What does a model actually know?

A large language model learns from its training data by adjusting billions of numbers, its **weights**. Everything it "knows" is spread across those weights. This is sometimes called *parametric* knowledge: knowledge stored in the parameters.

Parametric knowledge has three problems for our use case:

1. **It's frozen.** The model knows what was in its training data when it was trained. The roost's new Fire Cover policy isn't in there.
2. **It's not inspectable.** You can't point at the weights that hold a fact, so the model can't tell you where an answer came from.
3. **It's confidently wrong when it doesn't know.** A model is trained to produce plausible text. When it has no fact to draw on, plausible text is still what comes out. That's what people mean by *hallucination*.

But a model has a second source of information: the text you give it in the prompt. Everything in the prompt, its **context window**, is something the model can read directly, quote, and reason about. A model that's bad at remembering your late-return policy is very good at reading your late-return policy and answering a question about it.

So the question becomes: how do we get the right text into the prompt?

### Three ways to teach a model your documents

| Approach | How it works | Why it's not enough on its own |
|---|---|---|
| **Fine-tuning** | Train the model further on your documents | Expensive, slow to update, and it teaches style and patterns more reliably than facts. Still no citations. |
| **Put everything in the prompt** | Paste all your documents into every request | Every question pays for every document. Context windows have limits, and models are measurably worse at using information buried in the middle of a long prompt ([Liu et al., 2023](https://arxiv.org/abs/2307.03172)). |
| **Retrieve, then generate** | Put only the few passages relevant to *this* question in the prompt | This is RAG. |

RAG keeps the knowledge outside the model, in documents you can edit, and fetches just the part each question needs.

## The idea of RAG

Imagine a customer asks:

> How much is the deposit for a Ridgeback?

The answer is in one paragraph of one file. If we can find that paragraph and hand it to the model with the question, the model no longer needs to *remember* the answer. It only needs to *read* it.

That's the whole idea:

1. **retrieve** the passages most likely to contain the answer
2. **augment** the prompt with them
3. **generate** an answer from them

A RAG system therefore runs in two phases, at different times:

```
INDEX TIME (once, or when documents change)

  documents ──► split into chunks ──► embed each chunk ──► store chunk + vector


QUERY TIME (every question)

  question ──► embed the question ──► find the nearest stored vectors
                                                │
                                                ▼
              answer ◄── model ◄── prompt: numbered chunks + question
```

Steps 2 and 3 are easy: building a string and calling an API. Step 1 is where the interesting ideas live. Given a question, how do we decide which passage is "most likely to contain the answer"?

The obvious idea is to search for matching words. It doesn't get far. "My kid is 14, can she fly a dragon by herself?" shares almost no words with "Under-16s can ride with a parent or guardian who signs the hire agreement." The words are different but the meaning is the same, so we need a way to compare *meaning*.

> 🤔 **Food for thought**
> How would you turn "these two sentences are about the same thing" into something a computer can compute?

We'll answer that in a moment. First, let's meet the documents we'll be working with and see where we're headed.

### What we're building

Our documents are the handbook of **Ember & Scale Dragon Hire**, a roost on Cinder Hill that rents out dragons by the hour. It doesn't exist, sadly, but its handbook makes a good test: prices, rules, exceptions, and questions people can phrase a hundred different ways.

By the end of the post, you'll be able to ask it this:

```
$ mix rag.ask "my kid is 14, can she fly a dragon by herself?"
No, a fourteen-year-old cannot hire a dragon on their own, as riders must be
at least 16 to hire one independently [1]. Children aged 8 to 15 can take the
Young Riders course, but it requires a parent or guardian to sign the hire
agreement [5]. At least they'll get a wooden pin out of it, provided they
don't lose the certificate right after [5].

[1] policies.md #7  distance 0.227
[5] riding-school.md #5  distance 0.267
...
```

That's the word-matching problem from above, solved. The handbook never says "kid", "14" or "by herself", yet the answer comes from the right paragraphs, and each `[n]` points to the one it used. It also has a voice: Nesta Ashryver, the roost's head keeper, who is dry, fond of her dragons, and not allowed to make anything up. We'll put a small chat page in front of her too.

You'll need Elixir 1.15 or newer, Docker (or a Postgres with the [pgvector](https://github.com/pgvector/pgvector) extension), and a free [Gemini API key](https://aistudio.google.com/apikey).

## Step 1: Get the code running

The post shows the code that carries each idea. The setup around it (config files, the Ecto repo, Mix tasks, tests) is ordinary Elixir and lives in the repo, so start there:

```sh
git clone https://github.com/srishtiii28/rag_elixir.git
cd rag_elixir
docker compose up -d          # Postgres 17 with pgvector
export GEMINI_API_KEY=your-key-here
mix setup                     # deps, create the database, migrate
```

The dependencies tell you what the project is made of. `ecto_sql` and `postgrex` talk to the database, `pgvector` adds its column type, `req` does HTTP and `jason` JSON. `plug` and `bandit` serve the chat page at the end, and `mox` is only for tests:

```elixir
# mix.exs
defp deps do
  [
    {:ecto_sql, "~> 3.12"},
    {:postgrex, "~> 0.19"},
    {:pgvector, "~> 0.3"},
    {:req, "~> 0.5"},
    {:jason, "~> 1.4"},
    {:plug, "~> 1.16"},
    {:bandit, "~> 1.5"},
    {:mox, "~> 1.2", only: :test}
  ]
end
```

One line of setup is worth seeing, because without it Postgres can't send or receive vectors. Postgrex, the database driver, has to be told about pgvector's `vector` type:

```elixir
# lib/elixir_rag/postgrex_types.ex
Postgrex.Types.define(
  ElixirRag.PostgrexTypes,
  Pgvector.extensions() ++ Ecto.Adapters.Postgres.extensions(),
  []
)
```

The settings you'll tune later are in [`config/config.exs`](https://github.com/srishtiii28/rag_elixir/blob/main/config/config.exs): `top_k`, `max_distance`, `chunk_size`, `chunk_overlap`, the voice, and the Gemini models. Each is explained where it's used.

## What is an embedding?

An **embedding** is a fixed-length list of numbers, a vector, computed from a piece of text so that texts with related meanings get vectors pointing in similar directions. An **embedding model** is the neural network that computes it. Everything in retrieval rests on that one property, so it's worth seeing where it comes from.

### A toy version

Imagine a model that describes every text with three numbers: how much it's about dragons, about money, and about time.

| Text | dragons | money | time |
|---|---:|---:|---:|
| "How much is the deposit?" | 0.2 | 0.9 | 0.1 |
| "The deposit is 250 gold." | 0.3 | 0.8 | 0.0 |
| "We open from dawn until sunset." | 0.1 | 0.0 | 0.9 |

Each text is now an arrow from the origin in three-dimensional space. The question and the deposit sentence point almost the same way; the opening hours point somewhere else. That works even though the question doesn't contain "250" or "gold", because the numbers describe what each text is *about*, not which words it uses.

<!-- FIGURE: the three vectors as arrows in 3D, with the small angle between the question and the deposit sentence highlighted. -->

Real embedding models differ from the toy in two ways. They use many more numbers: `gemini-embedding-001`, the model we'll use, produces 3,072 by default, and we'll ask for 768. And the dimensions don't have names. Nobody decides that dimension 14 means money; the model arranges the space itself during training, and individual numbers usually mean nothing on their own. Only the direction of the whole vector, relative to other vectors, is meaningful.

### From text to a vector

Here's what happens inside a typical transformer embedding model when you send it "The deposit is 250 gold for a Ridgeback.":

1. **Tokenize.** The text is split into tokens, and each token is replaced by its integer ID in the model's vocabulary.
2. **Look up token vectors.** Each ID indexes a row of a learned table, giving one vector per token. At this point "deposit" has the same vector in every sentence it appears in.
3. **Contextualize.** The vectors pass through a stack of transformer layers. In each layer, every token's vector is updated with information from the other tokens via attention. After a few layers, the vector at "deposit" encodes "deposit, in a sentence about a price for a Ridgeback", and the vector for "bank" in "river bank" has drifted away from the one in "bank account". Unlike a chat model, an embedding model can let every token attend to tokens on both sides.
4. **Pool.** We need one vector for the whole text, not one per token. The common approaches are to average all the token vectors (**mean pooling**) or to take the vector at a special summary token.
5. **Project.** A final learned linear layer maps the pooled vector to the output size.

The [Gemini Embedding paper](https://arxiv.org/abs/2503.07891) describes this recipe for `gemini-embedding-001`: the model is initialised from a Gemini language model, uses bidirectional attention, mean-pools the token vectors and applies a linear projection. That's why an embedding model can understand paraphrases and typos: it starts from a model that has already learned a great deal about language.

### How training creates the geometry

Nothing in steps 1 to 5 forces related texts to land near each other. That comes from training. Embedding models are trained on enormous numbers of pairs that belong together: a search query and the passage a user clicked, a question and its accepted answer, a title and its article, two paraphrases.

The usual objective is **contrastive**. Take a batch of $B$ pairs $(q_i, p_i)$. For each query $q_i$, its own passage $p_i$ is the positive, and the other $B - 1$ passages in the batch serve as negatives, for free. The loss for one query is:

$$
\mathcal{L}_i = -\log \frac{\exp(\text{sim}(q_i, p_i) / \tau)}{\sum_{j=1}^{B} \exp(\text{sim}(q_i, p_j) / \tau)}
$$

where $\text{sim}$ is the cosine similarity of the two vectors (more on that below) and $\tau$ is a small constant called the *temperature*. Read the fraction as a softmax: the model is being asked to pick the right passage out of the batch, and the loss is small only when $q_i$ is much more similar to $p_i$ than to every other passage. Minimising it pulls each query towards its passage and pushes it away from the rest. The small $\tau$ sharpens the softmax, so even slightly-too-close negatives produce a noticeable penalty.

Random negatives are easy to tell apart, so training also mixes in **hard negatives**: passages that look relevant but aren't, like a passage about Ridgeback *prices* for a question about Ridgeback *deposits*. Those teach the fine distinctions. The Gemini Embedding paper describes this setup: a contrastive loss with in-batch negatives, plus mined hard negatives.

After billions of these comparisons the model has learned a space where distance tracks relatedness. One consequence is easy to miss: **"related" means whatever the training pairs meant.** A model trained only on paraphrase pairs puts "Can I feed it goat?" next to "May I give it goat?". A model trained on question-and-answer pairs puts it next to "Never feed it goat after 6pm", which isn't a paraphrase at all. Retrieval wants the second kind, which is why the task types in Step 3 matter.

### Why real distances are less dramatic than the toy

In the toy, the deposit sentence and the opening hours are almost at right angles. Real embeddings don't spread out like that. I embedded three sentences with nothing to do with each other, "The deposit is 250 gold for a Ridgeback.", "Quarterly tax filings are due on the fifteenth." and "Photosynthesis converts light into chemical energy.", and measured the cosine distance between each pair (distance is defined properly below; 0 means same direction, 1 means unrelated):

| Pair | Cosine distance |
|---|---:|
| deposit / tax filings | 0.359 |
| deposit / photosynthesis | 0.386 |
| tax filings / photosynthesis | 0.316 |

Completely unrelated sentences are nowhere near 1. Trained embedding spaces tend to be **anisotropic**: the vectors crowd into a narrow cone instead of filling every direction, so everything is somewhat similar to everything ([Ethayarajh, 2019](https://arxiv.org/abs/1909.00512) measured this in contextual word vectors). Within the handbook, the effect is stronger still, because every passage is about dragons and the roost. For the question "What happens if I bring the dragon back late?", the distances to all 127 chunks of the handbook's first version fall between 0.209 and 0.402, with a median of 0.335.

So absolute distances say little. What carries the information is the *order*: the late-returns chunk is at 0.209, and the fifth nearest is already at 0.274.

### Fewer numbers: Matryoshka embeddings

`gemini-embedding-001` is trained with **Matryoshka Representation Learning** ([Kusupati et al., 2022](https://arxiv.org/abs/2205.13147)), named after nesting dolls. During training, the contrastive loss is applied not just to the full 3,072-number vector but also to its first 768, first 1,536 and so on. The model therefore learns to pack the most important information into the first numbers, and you can keep a prefix of the vector and still have a usable embedding. We ask for it with the `outputDimensionality` parameter.

How much does shortening cost? I embedded the handbook at three sizes and asked 16 questions where I know which file holds the answer, counting how often a chunk from that file came back first. (This and the other measurements in the post were made on the first version of the handbook, eleven files and 127 chunks. It has grown since, so rerunning them on the repo gives slightly different numbers.)

| Dimensions | Storage per chunk | Right file ranked 1st | Right file in top 3 |
|---:|---:|---:|---:|
| 3,072 | 12 KB | 15 of 16 | 16 of 16 |
| 768 | 3 KB | 16 of 16 | 16 of 16 |
| 128 | 0.5 KB | 11 of 16 | 15 of 16 |

The difference between 3,072 and 768 is one question out of 16, which on a set this small is noise, not evidence that 768 is better. At 128 the ranking clearly degrades. 768 is a common choice for exactly this reason: a quarter of the storage and comparison cost, with no measurable loss on this data.

## Why chunks, not whole documents?

We could embed each file as a whole. It works badly, because a single vector has to summarise everything in the file. `policies.md` covers deposits, payment, fire damage, cancellations, late returns, age limits, accessibility, hoarded items and complaints; mean pooling averages all of that into one direction that's close to none of those topics in particular. A question is usually about one thing, and it matches best against a vector that's about one thing.

So we split documents into **chunks** and embed each one separately. The trade-off:

- **Small chunks** are about one thing and match sharply, but they lose context. "The deposit is 250 gold" is useless without "for a Ridgeback".
- **Large chunks** keep context, but their vector is an average over several topics, and they put more irrelevant text in front of the model.

The rule here:

1. split on blank lines, because a paragraph is the closest thing a document has to one topic
2. pack paragraphs together until the next one would push the chunk past 400 characters (about 100 tokens)
3. start each new chunk with the last 60 characters of the previous one, cut at a word boundary

Step 3 is **overlap**. Without it, a fact that straddles a boundary is split across two chunks and neither matches a question about it well.

### Measuring the chunk size

I indexed the handbook at two sizes and asked the same 16 questions:

| Chunk size | Chunks | Right file ranked 1st | Right file in top 3 |
|---:|---:|---:|---:|
| 400 characters | 127 | 16 of 16 | 16 of 16 |
| 800 characters | 55 | 14 of 16 | 16 of 16 |

The two misses at 800 show the averaging problem directly. For "Can I fly a Thunderwing in a thunderstorm?", the nearest 800-character chunk, at 0.306, was the end of the paragraph about Ridgebacks swimming in the lake followed by the whole Thunderwing section: prices, speed, the helmet rule and the roaring on landing. It's about Thunderwings, so it's near the question, but it says nothing about storms. The chunk with the weather rules came third. A big chunk is near lots of questions and very near none.

I also tried 200 characters, which is how I found the chunker bug described in the next step: the chunks repeated text, so those numbers measured the bug as much as the size, and I've left them out.

Two more things matter more than the exact number:

- **Write documents so paragraphs stand alone.** A chunk loses the heading above it, so a paragraph that says "They cost 25 gold an hour" depends on context retrieval won't provide. The roost's handbook names its subject in every paragraph ("A Ridgeback costs 25 gold an hour") and keeps each paragraph under 400 characters, so no paragraph is ever split.
- **Overlap has a cost.** A 60-character tail carried into the next chunk is usually a sentence fragment without its subject. We'll see this mislead the model in [When the model misreads](#when-the-model-misreads).

## Step 2: The chunker

The rule above is a pipeline in [`lib/elixir_rag/chunker.ex`](https://github.com/srishtiii28/rag_elixir/blob/main/lib/elixir_rag/chunker.ex):

```elixir
def chunk(text, opts \\ []) do
  size = Keyword.get(opts, :size, 400)
  overlap = Keyword.get(opts, :overlap, 60)

  text
  |> String.split(~r/\n\s*\n/)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))
  |> Enum.flat_map(&split_long(&1, size, overlap))
  |> pack(size, overlap)
end
```

Split on blank lines, trim, drop empties, cut any paragraph that's too long on its own into overlapping windows (`split_long/3`), then pack paragraphs into chunks (`pack/3`). When a chunk is full, the next one starts with the tail of the previous one, with the partial word at its start dropped.

The windows needed one fix, found by the 200-character experiment. Windows cut from one long paragraph already overlap each other, and the first version of `pack/3` treated them like ordinary paragraphs and carried another overlap in front of them. The last window of a paragraph would then come out as `"gold a day and covers da\n\nfteen gold a day and covers damage."`: the same words twice, with a paragraph break inserted mid-word. Now a window always starts a fresh chunk as it is.

Try it in IEx (`iex -S mix`) with a tiny chunk size so the behaviour is visible:

```elixir
iex> text = """
...> We open from dawn until sunset.
...>
...> The deposit is 250 gold for a Ridgeback.
...>
...> Every hire includes a fireproof cloak.
...>
...> Never feed a dragon goat after 6pm.
...> """
iex> ElixirRag.Chunker.chunk(text, size: 80, overlap: 30)
["We open from dawn until sunset.\n\nThe deposit is 250 gold for a Ridgeback.",
 "is 250 gold for a Ridgeback.\n\nEvery hire includes a fireproof cloak.",
 "includes a fireproof cloak.\n\nNever feed a dragon goat after 6pm."]
```

The first two paragraphs fit in 80 characters together. Each later chunk starts with the end of the one before: "is 250 gold for a Ridgeback.", then "includes a fireproof cloak." Notice that the carried text starts with "is", not "The deposit": overlap is cut by characters, not sentences.

## Talking to the model

The pipeline needs three things from a model provider:

1. embed passages, at index time
2. embed a question, at query time
3. generate an answer from a prompt

The first two are separate because a question and the passage that answers it don't look alike. "Can I feed it a goat?" is short and interrogative; the answer is a declarative paragraph about feeding times. Models like `gemini-embedding-001` take a `taskType`, `RETRIEVAL_QUERY` for questions and `RETRIEVAL_DOCUMENT` for passages, so the same text can be embedded differently depending on which side of the search it's on. Training on query-and-passage pairs with these task types teaches the model to place a question near the passages that *answer* it.

This is easy to check. I embedded the 16 test questions as if they were documents, with `RETRIEVAL_DOCUMENT`, and searched the same index:

| Questions embedded as | Right file ranked 1st | Nearest distances | "Can I hire a griffin instead?" |
|---|---:|---|---:|
| `RETRIEVAL_QUERY` | 16 of 16 | 0.202 to 0.348 | 0.261 |
| `RETRIEVAL_DOCUMENT` | 13 of 16 | 0.113 to 0.256 | 0.185 |

With the wrong task type, every distance shrinks, because questions and passages now land in the same region, but the ranking gets worse. "Am I covered if my dragon burns down a barn?" matched the "Can a dragon breathe fire on command?" heading in the odd-questions page ahead of the Fire Cover policy, a passage that *resembles* the question instead of one that answers it. And the griffin question, which the handbook can't answer, moved closer to the handbook than most real questions had been.

## Step 3: The model behaviour and the Gemini client

We describe what we need from a model as an Elixir **behaviour**, a set of functions a module promises to implement:

```elixir
# lib/elixir_rag/llm.ex
@callback embed_documents(texts :: [String.t()]) :: {:ok, [[float()]]} | {:error, term()}
@callback embed_query(text :: String.t()) :: {:ok, [float()]} | {:error, term()}
@callback generate(system :: String.t(), prompt :: String.t()) ::
            {:ok, String.t()} | {:error, term()}
@callback embedding_signature() :: String.t()
```

Nothing else in the project calls Gemini directly; everything goes through `ElixirRag.LLM.impl()`, which reads the module from config. Switching providers means writing one module and changing one line, and tests can swap in a fake model with no network calls.

`embedding_signature/0` returns a name like `"gemini-embedding-001@768"`. We'll store it with every chunk, for a reason explained in [What can go wrong](#what-can-go-wrong).

The Gemini implementation, [`lib/elixir_rag/llm/gemini.ex`](https://github.com/srishtiii28/rag_elixir/blob/main/lib/elixir_rag/llm/gemini.ex), is plain HTTP with [Req](https://github.com/wojtekmach/req). The heart of it is the embedding request, where the two ideas from the last two sections become two fields:

```elixir
requests =
  Enum.map(texts, fn text ->
    %{
      model: "models/#{model}",
      content: %{parts: [%{text: text}]},
      taskType: task_type,
      outputDimensionality: config(:embedding_dimensions)
    }
  end)

post("/models/#{model}:batchEmbedContents", %{requests: requests})
```

`task_type` is `"RETRIEVAL_DOCUMENT"` from `embed_documents/1` and `"RETRIEVAL_QUERY"` from `embed_query/1`. `outputDimensionality` is the Matryoshka prefix length, 768.

Four parts of this need explaining.

**Batching and rate limits.** `embed_documents/1` sends up to 100 texts per `batchEmbedContents` call, the API's maximum. That saves round trips, but not quota: on the free tier, each text in a batch counts as one request against a limit of 100 per minute. The handbook has 182 chunks, so indexing it always runs into the limit partway through.

**Retries.** Req retries only GET-style requests by default, and every Gemini call is a POST, so we pass our own `retry/2`. When Gemini rejects a request with status 429, its error body says how long to wait, in a field like `"retryDelay": "33s"`. My first version used Req's standard `:transient` retry, which waits 1, 2 and then 4 seconds. Against a per-minute quota that's useless: all three retries land inside the same minute and fail, and indexing died partway through the handbook on every run. `retry_delay/1` reads Gemini's own delay instead. One more surprise: Req runs the retry decision *before* it decompresses and decodes the response, so the body arrives as raw, possibly gzipped bytes, not as a map.

**Thinking.** Recent Gemini models can reason in hidden "thinking" tokens before answering, and those come out of the same `maxOutputTokens` budget as the answer. Left on, a model can spend the whole budget thinking and return an empty answer. `thinking_config/1` turns it down; Gemini 3 and Gemini 2.x name the setting differently.

**Temperature.** For each next token, the model produces a score $z_i$ (a *logit*) for every token in its vocabulary. Those scores become probabilities with a softmax divided by the temperature $T$:

$$
p_i = \frac{\exp(z_i / T)}{\sum_j \exp(z_j / T)}
$$

Say that after "The deposit is" the model scores "250" at 5.0, "100" at 4.0 and "800" at 3.0. At $T = 1$ those become probabilities of 0.665, 0.245 and 0.090, so a third of the time it would pick a number other than its best guess. At $T = 0.2$ the scores are divided by 0.2 before the softmax, becoming 25, 20 and 15, and the probabilities become 0.9933, 0.0067 and 0.00005. Low temperature makes the model consistently pick its highest-scoring continuation, which, when the right passage is in the prompt, is usually the one copied from it. We use 0.2.

Here's a real embedding, from `iex -S mix`:

```elixir
iex> {:ok, v} = ElixirRag.LLM.Gemini.embed_query("How much is the deposit?")
iex> length(v)
768
```

## Measuring closeness

We have a vector for the question and one for every chunk. How do we turn "pointing in a similar direction" into a number?

### Cosine similarity and distance

The **dot product** of two vectors multiplies matching entries and adds them up: $a \cdot b = \sum_i a_i b_i$. Geometrically, it equals the product of the two lengths and the cosine of the angle between them:

$$
a \cdot b = \lVert a \rVert \, \lVert b \rVert \cos\theta
\qquad\Longrightarrow\qquad
\cos\theta = \frac{a \cdot b}{\lVert a \rVert \, \lVert b \rVert}
$$

where $\lVert a \rVert = \sqrt{\sum_i a_i^2}$ is the length. Dividing by both lengths removes length from the comparison and leaves only direction. The cosine is 1 for the same direction, 0 at right angles and −1 for opposite directions. Databases sort ascending, so pgvector uses **cosine distance**:

$$
\text{distance}(a, b) = 1 - \cos\theta
$$

which is 0 for the same direction, 1 for unrelated and 2 for opposite.

### By hand

With the toy vectors from earlier, question $q = (0.2, 0.9, 0.1)$, deposit sentence $A = (0.3, 0.8, 0.0)$ and opening hours $B = (0.1, 0.0, 0.9)$:

$$
q \cdot A = 0.2 \times 0.3 + 0.9 \times 0.8 + 0.1 \times 0.0 = 0.78
$$

$$
\lVert q \rVert = \sqrt{0.04 + 0.81 + 0.01} \approx 0.927, \qquad \lVert A \rVert = \sqrt{0.09 + 0.64} \approx 0.854
$$

$$
\text{distance}(q, A) = 1 - \frac{0.78}{0.927 \times 0.854} \approx 1 - 0.984 = 0.016
$$

And for the opening hours:

$$
q \cdot B = 0.02 + 0 + 0.09 = 0.11, \qquad \lVert B \rVert \approx 0.906, \qquad \text{distance}(q, B) = 1 - \frac{0.11}{0.927 \times 0.906} \approx 0.869
$$

Searching means computing this for every stored chunk and keeping the smallest few. Real distances, as we saw, are squeezed into a much narrower band.

### Why cosine, and not straight-line distance?

pgvector offers three measures:

| Operator | Measure | Affected by vector length? |
|---|---|---|
| `<->` | Euclidean (straight-line) distance | Yes |
| `<#>` | Negative dot product | Yes |
| `<=>` | Cosine distance | No |

The training objective compares *cosine* similarities, so direction is what the model optimised. Length isn't reliably meaningful, and with shortened Gemini embeddings it varies for a mechanical reason: Gemini scales its full 3,072-number vectors to length 1, but a prefix of a unit vector is shorter than 1. In our index, the 768-number vectors have length about 0.59, the 3,072-number ones exactly 1.0, and 128-number ones about 0.35. Cosine divides the length out, so it doesn't matter. If you normalise every vector to length 1 yourself, all three operators give the same ranking, and the negative dot product is the cheapest to compute.

## Finding the nearest, fast

The simplest search compares the question with every stored vector and sorts: **exact**, or brute-force, nearest-neighbour search. Its cost is easy to estimate. One cosine distance on 768 numbers is about 768 multiply-adds; the handbook's 182 chunks are roughly 140,000 of them per question, which takes microseconds. Ten million chunks would be nearly 8 billion per question, plus reading 30 GB of vectors.

For that scale, vector databases use **approximate nearest neighbour** (ANN) indexes, which give up the guarantee of finding *the* nearest vectors in exchange for finding *almost all* of them while looking at a tiny fraction of the data.

### HNSW

pgvector's main ANN index is **HNSW**, Hierarchical Navigable Small World ([Malkov & Yashunin, 2016](https://arxiv.org/abs/1603.09320)). It's a graph:

- **Every vector is a node**, linked to some of its nearest neighbours. Following links from any node gets you to any other in a few hops, which is the "small world" property.
- **Nodes live on layers.** When a vector is inserted it's assigned a top layer at random, with each higher layer exponentially less likely (with the default settings, roughly one node in 16 reaches layer 1, one in 256 layer 2, and so on). Every node is on layer 0; upper layers hold progressively fewer nodes, so their links span long distances.
- **Insertion** searches for the new vector's nearest neighbours on each of its layers and links it to up to `m` of them (pgvector's default `m` is 16, with twice that allowed on layer 0). `ef_construction` (default 64) is how many candidates that search keeps; larger values build a better graph more slowly.
- **Search** starts at an entry node on the top layer and walks greedily: move to whichever neighbour is closer to the query, until no neighbour is closer. Then it drops a layer and repeats from there. On layer 0 it switches to a wider search that keeps a list of the best `ef_search` candidates found so far (default 40, set with `SET hnsw.ef_search`) and explores their neighbours, returning the best of them.

<!-- FIGURE: three stacked layers of dots, with a search path hopping across the sparse top layer and descending to a precise neighbour at the bottom. -->

The upper layers get you to the right region in a few long jumps, and layer 0 refines. A search visits a few hundred nodes, regardless of whether there are thousands or millions.

The approximation comes from the greedy steps: a walk can settle on a node whose neighbours are all further from the query, even though a closer node exists elsewhere. Raising `ef_search` keeps more candidates alive and makes that less likely, at the cost of speed. For RAG, an occasional miss rarely matters; if the fifth-best chunk comes back sixth, the prompt barely changes.

Two practical details:

- **Filters.** With `WHERE category = 'policies'`, the index returns its `ef_search` best candidates and Postgres then applies the filter, which can leave fewer rows than your `LIMIT`. pgvector 0.8 added iterative index scans (`SET hnsw.iterative_scan = relaxed_order`) that keep searching until enough rows pass the filter.
- **The alternative, IVFFlat,** clusters vectors with k-means and searches only the closest few clusters (`probes`). It builds faster and uses less memory than HNSW, but needs data present before it's built and is usually less accurate at the same speed.

At our size none of this happens. With 182 rows, Postgres's planner estimates that reading the whole table and sorting is cheaper than using the index, and `EXPLAIN` shows a sequential scan. The index only kicks in once the table is big enough to make it worth it, or if you force it with `SET enable_seqscan = off`. That's fine: brute force on 182 rows *is* the right plan.

pgvector puts vectors, distance operators and these indexes inside the Postgres we already use, so chunks are backed up with everything else, can be joined against other tables, and can be replaced inside a transaction.

## Step 4: The vector store

The table holds, for each chunk: its text, the file it came from and its position in that file, its vector, and the signature of the model that produced the vector. From the migration:

```elixir
create table(:chunks) do
  add :source, :string, null: false
  add :chunk_index, :integer, null: false
  add :content, :text, null: false
  add :embedding, :vector, size: 768, null: false
  add :embedding_model, :string, null: false

  timestamps(type: :utc_datetime)
end

create unique_index(:chunks, [:source, :chunk_index])

execute "CREATE INDEX chunks_embedding_hnsw ON chunks USING hnsw (embedding vector_cosine_ops)"
```

- `size: 768` has to match `embedding_dimensions: 768` in the config, or every insert fails.
- The unique index on `[:source, :chunk_index]` stops a file's chunks being stored twice.
- The HNSW index is built with `vector_cosine_ops`, matching the `<=>` operator we search with. An index built for a different operator is simply ignored by the planner.

If `mix setup` failed with `permission denied to create extension "vector"`, your database role isn't a superuser. Run `CREATE EXTENSION vector;` once in the database as a superuser (`psql -d elixir_rag_dev`), then `mix ecto.migrate`. The Docker setup doesn't have this problem.

All of retrieval is one query in [`lib/elixir_rag/vector_store.ex`](https://github.com/srishtiii28/rag_elixir/blob/main/lib/elixir_rag/vector_store.ex):

```elixir
def search(embedding, top_k \\ 5) do
  vector = Pgvector.new(embedding)

  from(c in Chunk,
    order_by: cosine_distance(c.embedding, ^vector),
    limit: ^top_k,
    select: %{
      source: c.source,
      chunk_index: c.chunk_index,
      content: c.content,
      distance: cosine_distance(c.embedding, ^vector)
    }
  )
  |> Repo.all()
end
```

Order by cosine distance, keep the first `top_k`. `cosine_distance/2` compiles to SQL's `embedding <=> $1`, the operator the HNSW index serves.

The same module's `replace_source/4` deletes a file's old chunks and inserts its new ones in one transaction, so re-indexing is safe to repeat and a search never sees a half-indexed file.

## Step 5: Indexing the documents

The roost's handbook is seventeen files in [`priv/docs`](https://github.com/srishtiii28/rag_elixir/tree/main/priv/docs): the dragons and their prices, a roster of all 21 dragons by name, policies, flying rules, your first hire step by step, the riding school, dragon manners, how the dragons are looked after, routes and landing fields, the seasons, weddings and festivals, gifts and group visits, working at the roost, the town's Dragon Charter, the roost's history, odd questions, and why you can't buy a dragon. A sample:

```markdown
## Feeding

Your dragon is fed before every hire, so it only needs the treats in your
bag. Never feed it anything else, and never feed it goat after 6pm: it will be
awake all night, and so will everyone within a mile. Dragons that ask for more
treats are lying.
```

The whole index phase, for one file, is one `with` in [`lib/elixir_rag/indexer.ex`](https://github.com/srishtiii28/rag_elixir/blob/main/lib/elixir_rag/indexer.ex):

```elixir
def index_file(path, source) do
  llm = LLM.impl()

  chunks =
    path
    |> File.read!()
    |> Chunker.chunk(
      size: Application.fetch_env!(:elixir_rag, :chunk_size),
      overlap: Application.fetch_env!(:elixir_rag, :chunk_overlap)
    )

  with {:ok, embeddings} <- llm.embed_documents(chunks),
       :ok <- same_length(chunks, embeddings),
       {:ok, count} <-
         VectorStore.replace_source(source, chunks, embeddings, llm.embedding_signature()) do
    {:ok, count}
  end
end
```

Chunk the file, embed every chunk in one call, check there's one vector per chunk, and replace the file's rows. `index_dir/1` runs it over a folder and deletes chunks of files that were removed, and `mix rag.index` calls that:

```
$ mix rag.index
[info] Indexed buying-and-adopting.md: 8 chunks
[info] Indexed caring-for-the-dragons.md: 7 chunks
[warning] retry: got response with status 429, will retry in 59500ms, 1 attempt left
[info] Indexed dragon-manners.md: 8 chunks
[info] Indexed dragons.md: 26 chunks
...
[info] Indexed your-first-hire.md: 10 chunks
Indexed 182 chunks from .../priv/docs
```

The 429 is the free tier's 100-embeddings-a-minute limit; the client waits the minute out and carries on. Retrieval already works:

```elixir
iex> {:ok, q} = ElixirRag.LLM.Gemini.embed_query("my kid is 14, can she fly a dragon by herself?")
iex> ElixirRag.VectorStore.search(q, 2) |> Enum.map(&{&1.source, &1.chunk_index, &1.distance})
[{"policies.md", 7, 0.227...}, {"gifts-and-groups.md", 6, 0.263...}]
```

Chunk 7 of `policies.md` is the "Who can ride" section with the age limits, found from a question that shares almost none of its words.

## From passages to an answer

Retrieval hands us the five nearest chunks. The rest is building a prompt.

### The prompt

The chunks are numbered and placed above the question, nearest first:

```
Passages:

[1] (source: policies.md)
knows the way home even when you don't.

## Who can ride

Riders must be at least 16 to hire a dragon on their own and at least 18 to
hire a Thunderwing. Under-16s can ride with a parent or guardian who signs the
hire agreement. ...

[2] (source: gifts-and-groups.md)
...

Question: my kid is 14, can she fly a dragon by herself?
```

(The first line of passage [1] is the overlap carried over from the end of the previous paragraph, about late returns.) The system prompt says how to use them:

```
You answer questions using only the numbered passages you are given.
Cite the passages you used, like [1] or [2][3].
If the passages don't contain the answer, say that you don't know. Don't guess.
```

Each instruction targets one of the problems from the start of the post.

**"Using only the numbered passages"** is **grounding**. A chat model has been trained, on top of next-token prediction, to follow instructions like this one, and with the answer sitting a few hundred tokens earlier in the context, copying it is the highest-probability path. The instruction tips the balance further towards the passages and away from whatever the weights would have produced.

**"Cite the passages"** makes each claim checkable. The numbers mean nothing to the model beyond labels, but asking it to emit them forces it to tie each sentence to a passage, and a citation that points at a passage that doesn't say what the sentence claims is an easy error to catch, for a reader or for code.

**"Say that you don't know"** supplies the missing "I don't know" from earlier. Without an explicit exit, a model given five irrelevant passages tends to produce an answer anyway.

Putting the nearest chunk first isn't arbitrary either: models attend to the start of a context better than the middle, so the passage most likely to hold the answer goes where it's least likely to be overlooked.

### When the model misreads

Grounding makes hallucination less likely, not impossible, and the remaining failures are subtle because they arrive with citations attached. Two real examples from the handbook:

**"which dragon is scared of pigeons"** got: *"Toast is terrified of pigeons, which can lead to sudden landings in duck ponds or weddings [1]. Lady Pemberton is also scared of pigeons, along with loud sneezes and a particular scarecrow on the Brightwater road [4]."* Passage [4] says *Puddlewyrms* in general are brave about everything except pigeons, loud sneezes and the scarecrow. The roster describes Lady Pemberton as the calmest dragon at the roost. The model attached a breed's trait to a named dragon of that breed, and cited the passage it misread.

**"i dont have a dragon license yet"** got: *"You will need a flying certificate from an evening lesson, which costs 25 gold [2]."* The handbook says the opposite: you don't need a licence for a Puddlewyrm or a Ridgeback. But that paragraph wasn't retrieved. Passage [2] begins with the 60-character overlap carried over from the end of it:

```
Flying certificate, from an evening lesson for 25
gold.

We don't hire dragons to anyone who has been drinking. ...
```

"Flying certificate, from an evening lesson for 25 gold", with its subject ("Mistgliders need our Night") cut off, reads like a requirement for everyone. The overlap that exists to keep facts whole handed the model half a fact.

Both are failures of **faithfulness**, the answer not matching its sources, and they're the reason citations are worth having: each took seconds to catch by opening the cited passage. Overlap cut at sentence boundaries instead of characters would have prevented the second one.

### When nothing relevant comes back

Retrieval always returns the *nearest* chunks, even when nothing is near. Ask "Do you rent unicorns?" and you still get five chunks, just unhelpful ones, and the system prompt has to produce the "I don't know".

You can also refuse earlier. `ask/2` takes a `:max_distance` option: chunks further than that are dropped, and if none are left, a fixed answer is returned without calling the model. Choosing the threshold is harder than it looks. These are nearest-chunk distances from the handbook:

| Question | Nearest chunk | Does the handbook answer it? |
|---|---:|---|
| Which dragon should a first-time rider pick? | 0.202 | yes |
| What happens if I bring the dragon back late? | 0.209 | yes |
| How much is a Ridgeback for a whole week? | 0.219 | yes |
| Can I buy a dragon? | 0.238 | yes |
| **Can I hire a griffin instead?** | **0.261** | **no** |
| Can I fly a Thunderwing in a thunderstorm? | 0.288 | yes |
| **Do you rent unicorns?** | **0.316** | **no** |
| is it ok to bring my cat along | 0.326 | yes |
| best place for a picnic | 0.348 | yes |
| **What is the wifi password?** | **0.424** | **no** |
| **What is the capital of France?** | **0.485** | **no** |

The griffin question, which the handbook doesn't answer, is closer than the thunderstorm, cat and picnic questions, which it does. It's about hiring a flying creature, so it lands among the hiring chunks; an embedding captures *topic*, not whether a passage contains an answer. No threshold separates those rows. A loose threshold such as 0.4 is useful for skipping clearly off-topic questions like the wifi password, and the "say that you don't know" instruction has to handle everything closer. Note also that distances shift with the embedding settings (at 128 dimensions, the same questions had nearest distances around 0.08 to 0.19), so a threshold has to be re-tuned whenever the model or size changes.

## Step 6: Giving the RAG a voice

A grounded answer is accurate and flat:

> A Puddlewyrm is the best choice for first-time riders [1].

The roost wants its assistant to sound like its head keeper, Nesta Ashryver, who is fond of every dragon and talks about them like difficult relatives. That's a **voice**, and it raises a real design question: how do you change *how* the model speaks without loosening *what* it's allowed to say?

### Two layers

The system prompt has two layers:

1. **Grounding rules**, shared by every voice: answer only from the passages, cite them, say when you don't know.
2. **A persona** on top: who's speaking, and how.

Retrieval and grounding decide what's true; the persona should only change the delivery. In practice the two pull against each other, because a persona is itself an instruction, and a vivid character gives the model permission to say things in character, which can include things that aren't in the passages.

### What the first persona did

My first draft asked Nesta to be dry, warm and fond of the dragons, and allowed her "one short keeper's aside to make the answer fun", with the rule that jokes must never add facts. Here are real answers from that draft:

| Question | Answer (first draft) |
|---|---|
| What happens if I bring the dragon back late? | "Hello there. Late returns cost 10 gold an hour... [1] ... Honestly, the griffins charge union rates and they are terrible gossips." |
| Can I fly a Thunderwing in a thunderstorm? | "Hello. No, Thunderwings are never flown in storms [3]. Honestly, trying to fly one in a thunderstorm would just give Saffron another story to brag about for the next two decades, and nobody needs that." |
| Can I hire a griffin instead? | "I don't know anything about griffins. We only have dragons here, twenty-three of them on Cinder Hill..." |
| Can I buy a dragon? | "Hello there. Well, you can't buy a dragon from us... I suppose if they *did* agree, they'd still probably just mail themselves back to the roost anyway." |

The facts with citations were right. Everything around them was a quiet grounding failure:

- **The jokes invent facts.** Nothing in the handbook says the search griffins gossip or charge union rates. Worse, the Saffron joke mixes two dragons up: the roster says it's *Vortigern* who brags about crossing the Grey Mountains. A joke is content; "jokes must never add facts" doesn't stop a model from writing new ones, because to the model a funny invented detail doesn't feel like a fact.
- **"We only have dragons"** sounds like a policy, but the handbook never says it; it just doesn't mention griffins. *Not mentioned* and *not offered* are different, and a customer can't tell which one they're getting.
- **"Hello there"** opened four of the twelve answers, to people who hadn't said hello.

### What changed

The fix was to say *where* the humour should come from. The handbook is already full of jokes (the dragons that ask for more treats are lying; the ravens spend gold; Toast has landed in two duck ponds and one wedding), so the persona now says to take the humour from the passages and never make up a new habit, story or trait, or move one dragon's habit to another. It also says to greet only when greeted, and gives a concrete example of the not-offered rule: say "I don't know anything about unicorns", never "we only have dragons".

The same questions, after the change:

| Question | Answer (revised) |
|---|---|
| What happens if I bring the dragon back late? | "Late returns cost 10 gold an hour, up to the price of one extra day [1]. ... Mind you, they do know the way home if you give three short blasts on your whistle or send a raven [2]." |
| Can I fly a Thunderwing in a thunderstorm? | "Thunderwings are never flown in storms [3]. If the weather turns, you must land at the nearest landing field and wait it out [1]." |
| Can I buy a dragon? | "No, we don't sell dragons for any amount of gold... Mind you, a dragon that hasn't agreed to being sold usually doesn't stay sold for very long anyway [2]." |
| Can I hire a griffin instead? | "Hello there. I don't know anything about griffins." |

The asides now come from the handbook, with citations. The greeting rule is followed only some of the time, and the pigeon mix-up above happened under the revised persona. Instructions shift probabilities; they don't guarantee anything. That's why a voice also needs a check in code.

### Checking the output

Every answer is checked against a list of patterns the voice must never produce: pressure ("act now", "limited time", "don't miss out"), invented guarantees, talk of "the passages" or "the documents", and runs of exclamation marks. A second check catches the stray greeting: an answer that opens with "Hello" or "Hi" when the question didn't. If either fires, the answer is regenerated once with a note appended to the system prompt saying what to avoid. If the retry fails the check too, the request fails with an error rather than showing the customer an off-voice answer.

This caught something real while I was writing this post. Asked about thunderstorms with only one passage, the first answer said something about what "the passages" contained, was rejected, and the retry came back without it. Regex can only catch wording, not meaning: no pattern can tell a handbook joke from an invented one, so for that, the persona and a human reading answers next to their sources are still the defence.

### The voice in code

A voice is a behaviour too, with four callbacks:

```elixir
# lib/elixir_rag/voice.ex
@callback persona() :: String.t()
@callback no_answer() :: String.t()
@callback small_talk(:greeting | :thanks | :introduction) :: String.t()
@callback forbidden() :: [Regex.t()]
```

`persona/0` is the character, `no_answer/0` is what to say when retrieval comes back empty, `small_talk/1` is what to say to "hi", "thanks" and "who are you?" (more on that below), and `forbidden/0` is the list of patterns. The check that runs on every answer:

```elixir
def check(voice, question, text) do
  cond do
    pattern = Enum.find(voice.forbidden(), &Regex.match?(&1, text)) ->
      {:error, {:forbidden, pattern.source}}

    Regex.match?(@greeting, text) and not Regex.match?(@greeting, question) ->
      {:error, :unprompted_greeting}

    true ->
      :ok
  end
end
```

### Small talk

"hi", "thanks" and "who are you?" aren't questions about the handbook, and they took three tries to get right.

A strictly grounded model answers "hi" with "I don't know", so the grounding rules got an exception: reply to greetings and questions about who you are in a sentence or two, in character, without citations. But those messages still went through retrieval, and the model still received five passages, which it couldn't leave alone:

> **Who are you?**
> Hello there. I'm Nesta Ashryver, head dragonkeeper here... Questions about who we are aren't really my department, but I can tell you that every dragon here already has a name they're quite fond of, even Captain Mopsy [5].

Retrieval for "who are you?" had found the passage about naming dragons, and Nesta dutifully cited it. Worse, the stray-greeting check rejected answers that opened "Hello, I'm Nesta…", because "who are you?" isn't a greeting, so the question sometimes failed outright.

The second try skipped retrieval for small talk and sent the model the question alone. With no passages to anchor it, the persona filled the gap with invention: "Step carefully around the middle paddock—Ignis is shedding again, and nobody wants that mess on their boots." There is no Ignis. A visitor who asks about Ignis next gets "I don't know" about a dragon the assistant just named.

The fix was to take the model out of it. Small talk is recognised with three anchored patterns, so "hi" matches but "hi, how much is the deposit?" doesn't, and each voice supplies its own replies:

```elixir
# lib/elixir_rag/voice/dragonkeeper.ex
def small_talk(:thanks), do: "You're welcome. Mind your fingers on the way out."
```

`ask/2` checks for small talk before anything else, so these replies cost no API call at all, and they can't invent anything because nothing generates them. Fixed lines are less lively than generated ones, but a greeting is the one place where every visitor should get the same safe answer.

The full persona is in [`lib/elixir_rag/voice/dragonkeeper.ex`](https://github.com/srishtiii28/rag_elixir/blob/main/lib/elixir_rag/voice/dragonkeeper.ex). Its serious-news rule is there because a quip after "my dragon burned down my neighbour's barn" is tone-deaf; under it, that question gets the Fire Cover terms and nothing else.

## Step 7: Answering questions

The query phase, end to end, in [`lib/elixir_rag.ex`](https://github.com/srishtiii28/rag_elixir/blob/main/lib/elixir_rag.ex):

```elixir
def ask(question, opts \\ []) do
  voice = Keyword.get(opts, :voice, Voice.impl())

  case Voice.small_talk(question) do
    nil ->
      with {:ok, question} <- standalone(question, Keyword.get(opts, :history, [])),
           {:ok, chunks} <- retrieve(question, opts) do
        answer(question, chunks, voice)
      end

    kind ->
      {:ok, %{answer: voice.small_talk(kind), question: question, sources: []}}
  end
end

def build_prompt(question, chunks) do
  passages =
    chunks
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {chunk, n} ->
      "[#{n}] (source: #{chunk.source})\n#{chunk.content}"
    end)

  "Passages:\n\n#{passages}\n\nQuestion: #{question}"
end
```

Read `ask/2` against the diagram at the start. Small talk gets the voice's fixed reply, as described in Step 6. `standalone/2` turns a follow-up into a question that makes sense on its own; with no earlier messages it returns the question unchanged, so ignore it until [Step 10](#step-10-follow-up-questions). `retrieve/2` embeds the question, calls `VectorStore.search/2` and drops chunks beyond `:max_distance`. `build_prompt/2` numbers the passages. `answer/3` returns the voice's `no_answer/0` when nothing is left; otherwise it calls the model, runs `Voice.check/3`, and retries once with the reminder (shortened here; the real one also logs each rejection):

```elixir
case {Voice.check(voice, question, text), retry} do
  {:ok, _} -> {:ok, %{answer: text, sources: chunks}}
  {{:error, _reason}, false} -> generate(question, chunks, voice, true)
  {{:error, reason}, true} -> {:error, {:off_voice, reason}}
end
```

Every step returns `{:ok, _}` or `{:error, _}`, so a failure anywhere reaches the caller unchanged. `mix rag.ask` prints the answer with each source and its distance, so you can see what retrieval did:

```
$ mix rag.ask "What happens if I bring the dragon back late?"
Late returns cost 10 gold an hour, up to the price of one extra day [1].
Dragons must be back by the second bell after sunset, though Mistgliders have
until the midnight bell [1][2]. If a dragon is more than 24 hours late without
word, we send out the search griffins, and the usual 150 gold cost comes out of
your deposit [1]. Mind you, they do know the way home if you give three short
blasts on your whistle or send a raven [2].

[1] policies.md #5  distance 0.209
[2] policies.md #6  distance 0.221
[3] flying.md #7  distance 0.261
...
```

## How do you know it works?

A RAG answer can go wrong in two separate places, and they need separate checks.

### Retrieval

Retrieval fails when the passage with the answer isn't among the chunks sent to the model; no prompt can recover from that. Two standard measures, for a set of questions where you know where the answer is:

- **Recall at k**: the fraction of questions whose answer is somewhere in the top $k$ results.
- **Mean reciprocal rank (MRR)**: the average of $1/\text{rank}$ of the first correct result, $\text{MRR} = \frac{1}{|Q|}\sum_{i} \frac{1}{\text{rank}_i}$. It's 1.0 if the answer is always first, 0.5 if it's always second, and it rewards getting the answer near the top rather than just inside the cut-off.

You can measure both in IEx with `retrieve/2`:

```elixir
cases = [
  {"Which dragon should a first-time rider pick?", ["dragons.md"]},
  {"my kid is 14, can she fly a dragon by herself?", ["policies.md"]},
  {"Can I fly a Thunderwing in a thunderstorm?", ["flying.md"]},
  {"Can I buy a dragon?", ["buying-and-adopting.md"]},
  {"my dragon is lying flat with its chin on the ground and won't move", ["dragon-manners.md"]},
  # ... 16 in all
]

for {question, expected} <- cases do
  {:ok, chunks} = ElixirRag.retrieve(question, top_k: 5)
  rank = Enum.find_index(chunks, &(&1.source in expected))
  {question, rank && rank + 1}
end
```

With the settings in this post, all 16 questions had a chunk from the right file first: recall at 1 of 16/16, MRR 1.0. That's a misleadingly good number, and the reason why is worth knowing.

I checked at the level of *files*. For "Can I fly a Thunderwing in a thunderstorm?", the top chunk is `flying.md` #10, so it counts as a hit. But chunk 10 doesn't contain the storm rule. It starts with the overlap from chunk 9, "turns, land at the nearest landing field and wait it out", followed by paragraphs about fog, wind and snow. Chunk 9, which says "Thunderwings love storms, which is exactly why riders are not allowed to fly them in one", wasn't in the top five at all. With `--top-k 1` the model correctly said it didn't know; with five passages it got the answer from a roster entry that happens to mention "Thunderwings are still never flown in storms". A serious evaluation labels the exact chunk, or better the exact fact, that answers each question.

Sixteen questions also aren't a benchmark. They're enough to compare settings against each other, which is how the chunk-size and dimension tables above were made, and to catch regressions when documents or settings change.

### Generation

Generation fails when the right passage was retrieved but the answer doesn't match it, as with Lady Pemberton and the pigeons. The measure is **faithfulness**: is every claim in the answer supported by the passage it cites? On a small scale, you check it by reading answers next to their sources, which is how every persona problem in this post was found. At larger scale, people use a second model as a grader, given the passages and one claim at a time.

## Step 8: Testing without an API

Unit tests shouldn't call a paid API. In tests, `:llm` points at a [Mox](https://github.com/dashbitco/mox) mock, which we stub with a fake model.

The fake still needs embedding *behaviour*. If it returned the same vector for every text, every chunk would be equally close and retrieval tests would pass without testing anything. So the fake builds a **bag-of-words** vector: it counts the words in a text and hashes each word into one of 768 slots.

```elixir
# test/support/fake_llm.ex
def vector(text) do
  counts =
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.reject(&(&1 in @stopwords))
    |> Enum.map(&String.trim_trailing(&1, "s"))
    |> Enum.frequencies_by(&:erlang.phash2(&1, @dims - 1))

  [0.01 | for(i <- 0..(@dims - 2), do: Map.get(counts, i, 0) * 1.0)]
end
```

Texts that share words point in similar directions; texts that don't, don't. The `0.01` in the first slot gives a text with no words a direction. The fake has no idea that "kid" and "under-16" are related, which makes it useless for judging retrieval quality, but it's enough to check the plumbing:

```elixir
test "answers from the most relevant passage and returns the sources" do
  expect(MockLLM, :generate, fn system, prompt ->
    assert system =~ "using only the numbered passages"
    assert prompt =~ "[1] (source: roost.md)\nThe deposit is 100 gold"
    {:ok, "250 gold [1]."}
  end)

  assert {:ok, %{answer: "250 gold [1].", sources: [best | _]}} =
           ElixirRag.ask("How big is the deposit for a Ridgeback?")

  assert best.content =~ "deposit"
end
```

The test stores three passages (opening hours, deposits, what's included), asks about the deposit, and checks that the deposit passage became `[1]`. The other tests in [`test/elixir_rag_test.exs`](https://github.com/srishtiii28/rag_elixir/blob/main/test/elixir_rag_test.exs) check that `:top_k` limits the passages, that `:max_distance` skips the model, that an off-voice answer is retried once and fails if the retry is off too, that a follow-up is rewritten before retrieval, and that errors come back unchanged.

I tried, briefly, to test retrieval over the real handbook with this fake, asserting that questions like "Can I buy a dragon?" find the right file. It failed for reasons that had nothing to do with the real system: the fake can't match "buy" with "Buying" or "sulking" with "sulks". Retrieval quality is measured against the real model, as in the previous section; unit tests check the plumbing.

```
$ mix test
52 tests, 0 failures
```

They run against a real Postgres with real pgvector and never touch the network. Besides the query phase, they cover the chunker (including the double-overlap bug), the vector store, the indexer, the voice, the handbook's own consistency, the chat page and the Gemini client.

<details>
<summary><b>Testing the Gemini client and cosine distance</b></summary>

The fake model bypasses the Gemini client, so the client is tested at the HTTP layer. `Req.Test` routes requests to a function in the test (the `req_options` line in `config/test.exs`), so a test can inspect the exact request body:

```elixir
Req.Test.stub(ElixirRag.LLM.Gemini, fn conn ->
  {:ok, body, conn} = Plug.Conn.read_body(conn)
  %{"requests" => [request]} = Jason.decode!(body)
  assert request["taskType"] == "RETRIEVAL_QUERY"
  assert request["outputDimensionality"] == 768

  Req.Test.json(conn, %{"embeddings" => [%{"values" => [0.1, 0.2]}]})
end)

assert ElixirRag.LLM.Gemini.embed_query("hello") == {:ok, [0.1, 0.2]}
```

`retry_delay/1` is tested directly with real 429 bodies, as a map, as a JSON string, and gzipped.

The vector store tests use vectors whose distances can be worked out by hand. With $e_0$ and $e_1$ the first two axes:

| Stored vector | Distance from $e_0$ |
|---|---:|
| $5e_0$ | 0, because cosine ignores length |
| $e_0 + e_1$ | $1 - 1/\sqrt{2} \approx 0.293$ |
| $e_1$ | 1 |

</details>

## Step 9: A chat page

Customers want a chat window, not a terminal. Since `ask/2` is an ordinary function, a web page in front of it takes one small Plug router, [`lib/elixir_rag/web.ex`](https://github.com/srishtiii28/rag_elixir/blob/main/lib/elixir_rag/web.ex). Its one interesting route:

```elixir
post "/api/ask" do
  question = conn.body_params |> Map.get("question") |> text()
  history = conn.body_params |> Map.get("history") |> history()

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
```

(The real route also turns away empty questions and ones over 500 characters.) `GET /` serves a single HTML page, [`priv/static/index.html`](https://github.com/srishtiii28/rag_elixir/blob/main/priv/static/index.html), with no build step; it renders each `[n]` as a seal that opens the passage it cites. The off-voice failure from Step 6 surfaces here as the generic 502 message, with the details in the log.

```sh
mix rag.server        # chat at http://localhost:4000
```

It listens only on your own machine.

Open it and you're at the roost's front desk: a dark page with embers drifting up it, the Ember & Scale crest, and "Where would you like to fly?" Below that are a few questions to start with, from "Who are you?" to "A dragon stole my keys!". Nesta answers on a parchment card, each `[n]` becomes a red wax seal, and clicking a seal opens the passage it cites, with all five retrieved passages folded away underneath. This is the best place to play with what you've built: ask something the handbook covers, something it doesn't, and something badly phrased, then open the seals and check her work. Follow-ups like "how much does she cost?" work too, and the next step shows how.

<!-- FIGURE: screenshot of the chat page with an answer card and an open citation -->

## Step 10: Follow-up questions

A chat page invites a conversation, and the first version of this one couldn't hold one:

> **is hazel available**
> Tobias flies Hazel for our rescue riders, and she is also the fastest of our Ridgebacks [1][3][4]. I don't know if she is available for your booking, as Maud is the one who runs the bookings and answers every raven [3].
>
> **okay how much does she cost**
> Mistglider costs 35 gold, 120 gold a night, or 400 gold [3]...

Nothing was wrong with the retrieval or the model; they did exactly what they were built to do. Retrieval embeds the question it's given, and "okay how much does she cost" doesn't contain "Hazel". Its nearest chunks were the ones that best matched "she" and "cost", which happened to be about Mistgliders ("She doesn't like lanterns..."), and the model answered from those faithfully, with citations.

There are three ways to give the pipeline a memory, and only one of them works well:

- **Send the conversation to the model, but keep retrieving with the last message.** The model now knows who "she" is, but the passages with Hazel's price were never retrieved, so it can only say it doesn't know, or worse, answer from the wrong ones.
- **Embed the whole conversation.** "Who is the fastest", "is Hazel available" and "how much does she cost" averaged into one vector is the big-chunk problem again: a vector near several topics and very near none.
- **Rewrite the question.** Before retrieval, ask the model to turn the last message into one that makes sense on its own, then run the normal pipeline on that. This is called **query rewriting**, and it's what we'll do.

The rewrite is one more call to `generate/2`, with its own short system prompt:

```elixir
@rewrite """
You rewrite the visitor's last message so that it makes sense on its own.
Replace words like "she", "it" or "that one" with what they refer to in the conversation.
If the message already makes sense on its own, or is a greeting or thanks, return it unchanged.
Reply with the rewritten message only.
"""

def standalone(question, []), do: {:ok, question}

def standalone(question, history) do
  conversation =
    Enum.map_join(history, "\n", fn
      {:user, text} -> "Visitor: #{text}"
      {:assistant, text} -> "Keeper: #{text}"
    end)

  LLM.impl().generate(@rewrite, "Conversation:\n\n#{conversation}\n\nLast message: #{question}")
end
```

`ask/2` takes the earlier messages as a `:history` option and calls `standalone/2` first, as we saw in Step 7. With no history, the first clause returns the question untouched, so a first question costs nothing extra and `mix rag.ask` behaves exactly as before.

The page keeps the conversation in an array and sends the last six messages with each question. The route keeps only well-formed `user` and `assistant` entries, so a broken request can't put anything else in the prompt. The response now includes the question that was actually answered, and when it differs from what you typed, the page shows it above the answer as "Asked as: …". The same conversation now goes:

```
> okay how much does she cost
  Asked as: okay how much does Hazel cost

> and the deposit?
  Asked as: what is the deposit for a Ridgeback?
  The deposit for a Ridgeback is 250 gold [4]. We return it within 5 days of the
  dragon coming home in a good mood, provided you didn't try to pay in livestock [4].
```

Showing the rewrite isn't decoration. A bad rewrite fails the same quiet way as everything else in this post: the wrong question retrieves the wrong passages, and the answer arrives with confident citations. With the rewrite on screen, a reader can see at once that "she" was taken to mean the wrong dragon.

It also shows the limit of the fix. "How much does Hazel cost" is a better question, but the handbook prices *breeds*, not named dragons, and nothing in the question says Hazel is a Ridgeback, so retrieval found a Ridgeback weekly price rather than the hourly one. The rewrite fixes the reference; it can't fill the gap between "Hazel" and "Ridgeback" that the documents leave.

That gap is a documents problem, so the fix went into the documents: the roster now has a "Hiring a dragon by name" section that lists every dragon under its kind, with the price. The same follow-up now gets:

```
> okay how much does she cost
  Asked as: how much does hazel cost
  Hazel is a Ridgeback, so she costs 25 gold an hour or 120 gold for a full
  day, with a 250 gold deposit [1].
```

## Making it faster

None of this is tuned for speed, and you'll notice it on the page: there's a pause before each answer appears. The time goes almost entirely to waiting on the model API. Searching Postgres is the fast part; every question makes two or three calls to Gemini in a row, and each must finish before the next starts:

1. **Rewrite** the follow-up into a standalone question (follow-ups only).
2. **Embed** the question.
3. **Generate** the answer, the slowest step, since the model writes it token by token.

And when the voice check rejects an answer, step 3 runs a second time. Here are the main ways to cut the wait, roughly in order of how much they help:

- **Stream the answer.** Gemini has a `streamGenerateContent` endpoint that sends text as it's generated, Req can consume a streaming response with its `into:` option, and Plug can pass it on with `send_chunked/2`. The answer takes as long to finish, but the reader starts reading almost at once, which is what makes a chat feel fast. The catch is the voice check: it reads the whole answer before anyone sees it. With streaming you'd check as sentences arrive and stop a bad answer partway, or check at the end and replace it.
- **Retry less.** A rejected answer costs a whole second generation. The stray-greeting check fires often, and an opening "Hello there." could simply be cut from the start of the answer in code instead of asking the model again. Save regeneration for problems code can't fix.
- **Rewrite only when it's needed, or in parallel.** Most follow-ups are already standalone ("Can I buy a dragon?"), yet each one waits for the rewrite. You could skip it for messages with no pronouns, use a smaller, faster model for it, or start embedding the original question while the rewrite runs and use that result if the rewrite comes back unchanged. Elixir makes the last one easy with `Task.async/1`.
- **Cache.** The suggested questions on the welcome screen are the same for every visitor, so their embeddings, or even their whole answers, can be kept in an ETS table. The cache has to be cleared whenever you re-index or change the voice, or it serves stale answers.
- **Ask for less text.** Generation time grows with the length of the answer, so a persona that asks for two to five short sentences is also a speed setting. A lower `top_k` and a shorter system prompt cut the input the model reads.
- **Embed locally.** A small embedding model run in the BEAM with [Bumblebee](https://github.com/elixir-nx/bumblebee) and Nx removes a network round trip from every question. You'd re-index with that model, and its retrieval quality would need checking against the 16 questions from [How do you know it works?](#how-do-you-know-it-works).

Indexing isn't optimised either: `mix rag.index` re-embeds every file each time, even unchanged ones, which is what runs into the free tier's rate limit. Storing a hash of each file's content and skipping files whose hash hasn't changed would make re-indexing nearly free.

## What can go wrong

Most failures in a RAG pipeline don't crash anything. They make answers slightly worse, which is why they're easy to miss.

**Mismatched sizes.** A `vector(3072)` column and a model returning 768 numbers fails every insert with `expected 3072 dimensions, not 768`. That one is loud and immediate, which makes it the easy case.

**Changing the embedding model.** Each embedding model learns its own space; dimension 14 of one model has no relationship to dimension 14 of another, even at the same size. If documents were embedded with one model and questions with another, inserts work and searches return five chunks, but "nearest" is close to random. Nothing errors. That's why every chunk stores `embedding_model` from `embedding_signature/0`, `Indexer.status/0` returns `:stale` on a mismatch, and `mix rag.ask` warns about it.

**Rate limits that retries can't fix.** Covered in Step 3: a retry policy designed for brief outages (1, 2, 4 seconds) can't outlast a per-minute quota. Read the server's own retry delay.

**A persona that drifts from the documents.** As Step 6 showed, a character invites invention, and invented details arrive in the same confident tone as real ones. Read your voice's answers next to their sources, especially answers to questions the documents don't cover.

**Overlap fragments and boundaries.** Both the licence misreading and the thunderstorm miss came from character-based overlap: a fragment without its subject, and a chunk ranked first for the wrong reason. Sentence-aligned overlap, or no overlap with paragraph-sized chunks, avoids both.

**Gaps in the documents.** No tuning fixes a missing fact. When the original three-file handbook was asked "Can I buy a dragon?", the answer was "I don't have information about buying dragons", which was honest and unhelpful. The fix was a new document, not a better prompt. Log the questions your RAG answers with "I don't know"; they're a to-do list for your documents.

**Silent fallbacks.** Falling back to a canned answer when something fails is friendly to users, but it can hide a retired model name, an expired key or an empty "thinking" response. Log every fallback and retry, as `generate/4` does.

## Try these experiments

1. **Compare a near miss with a far one.** Ask "Can I hire a griffin instead?" and "What is the wifi password?" and compare the distances `mix rag.ask` prints. Then run `ElixirRag.ask("What is the wifi password?", max_distance: 0.4)` in IEx, which skips the model.
2. **Ask "Can I fly a Thunderwing in a thunderstorm?" with `--top-k 1`,** then with the default five, and look at which chunk each answer cites.
3. **Make the overlap sentence-aligned** in `Chunker.tail/2`, re-index, and ask "i dont have a dragon license yet" again.
4. **Write your own voice.** Implement the four `ElixirRag.Voice` callbacks, set `config :elixir_rag, voice: YourVoice`, and test it on questions the handbook *doesn't* answer.
5. **Change the chunk size or `embedding_dimensions`,** re-index (and change the migration's `vector` size for the latter), and rerun the retrieval cases from [How do you know it works?](#how-do-you-know-it-works).
6. **Point it at your own documents** with `mix rag.index --dir path/to/docs`.

## Beyond this post

This is the core every RAG system shares. Production systems add layers, each aimed at a weakness we ran into:

- **Hybrid search** runs a keyword search alongside the vector search and merges the two rankings. Keyword scoring, usually BM25, rewards rare exact terms ("Mistglider", a product code, a person's name) that embeddings can blur. A common way to merge is reciprocal rank fusion: each chunk scores $\sum 1/(60 + \text{rank})$ across the rankings it appears in.
- **Reranking** retrieves more candidates, say 20, and reorders them with a *cross-encoder*, a model that reads the question and a passage together instead of comparing two separately computed vectors. It's slower but can tell "mentions Thunderwings" from "answers the thunderstorm question", which is exactly the miss we saw.
- **Smarter chunking** splits on headings and sentence boundaries and keeps each chunk's heading with it, so "250 gold" stays attached to "Deposits".
- **Metadata filters** restrict search to a product, a date range or what the user may see, with an ordinary `WHERE` clause; one more benefit of keeping vectors in Postgres.
- **Longer conversation memory.** Step 10 sends the last six messages. Long conversations need more: a running summary of what was said, so the rewrite can still resolve "the one you mentioned at the start".

## Summary

A language model generates the most likely continuation of its context, so it answers best when the facts are in that context. RAG puts them there: documents are cut into chunks, each chunk becomes a vector through a model trained so that questions land near the passages that answer them, the nearest vectors to a question are found by cosine distance, and the model is told to answer only from those passages and cite them. Each step can fail quietly: a chunk can average too many topics, an overlap can strip a fact of its subject, the nearest chunk can be on topic without containing the answer, and a persona can invent details. Measuring retrieval against real questions and reading answers next to their sources is how you find out which is happening.

<details>
<summary><b>Reference: where everything lives in the repo</b></summary>

| File | Step | Job |
|---|---|---|
| `mix.exs`, `config/*.exs`, `docker-compose.yml` | 1 | Dependencies, settings, Postgres with pgvector |
| `lib/elixir_rag/repo.ex`, `postgrex_types.ex`, `application.ex` | 1 | Database connection |
| `lib/elixir_rag/chunker.ex` | 2 | Text → overlapping chunks |
| `lib/elixir_rag/llm.ex`, `lib/elixir_rag/llm/gemini.ex` | 3 | Embeddings, generation, rate-limit retries |
| `priv/repo/migrations/…_create_chunks.exs`, `lib/elixir_rag/chunk.ex` | 4 | The `chunks` table |
| `lib/elixir_rag/vector_store.ex` | 4 | Store chunks, cosine search |
| `lib/elixir_rag/indexer.ex`, `lib/mix/tasks/rag.index.ex` | 5 | Index time: files → chunks → vectors → Postgres |
| `lib/elixir_rag/voice.ex`, `lib/elixir_rag/voice/dragonkeeper.ex` | 6 | Grounding rules, persona, output checks |
| `lib/elixir_rag.ex`, `lib/mix/tasks/rag.ask.ex` | 7 | Query time: question → passages → answer |
| `test/support/*.ex`, `test/test_helper.exs`, `test/elixir_rag_test.exs` | 8 | Offline tests |
| `lib/elixir_rag/web.ex`, `lib/mix/tasks/rag.server.ex`, `priv/static/index.html` | 9 | The chat page |
| `lib/elixir_rag.ex` (`standalone/2`), `priv/static/index.html` | 10 | Follow-up questions |

</details>

<details>
<summary><b>Reference: the vocabulary in one place</b></summary>

| Term | Meaning |
|---|---|
| RAG | Retrieval-augmented generation: retrieve relevant passages, add them to the prompt, generate an answer |
| Token | The unit a model reads and writes; roughly four characters of English |
| Parametric knowledge | What a model learned in its weights during training |
| Context window | The maximum text a model reads in a single request |
| Attention | The mechanism that lets each token's computation draw on other tokens in the context |
| Hallucination | Fluent, confident output not supported by any source |
| Embedding | A vector representing a text, placed so related meanings point in similar directions |
| Mean pooling | Averaging the per-token vectors into one vector for the whole text |
| Contrastive learning | Training that pulls matching pairs together and pushes the rest of the batch apart |
| Hard negative | A training example that looks relevant but isn't |
| Anisotropy | Embeddings crowding into a narrow cone, so even unrelated texts look somewhat similar |
| Matryoshka embedding | A vector trained so its prefixes are usable embeddings on their own |
| Chunk | A passage of a document, embedded on its own (up to 400 characters here) |
| Overlap | Text repeated from the end of one chunk at the start of the next |
| `RETRIEVAL_QUERY` / `RETRIEVAL_DOCUMENT` | Gemini task types for embedding questions and passages |
| Cosine distance | $1 - \cos\theta$: 0 same direction, 1 unrelated, 2 opposite |
| `<=>` | pgvector's cosine distance operator |
| ANN / HNSW | Approximate nearest-neighbour search, and the layered graph index pgvector uses for it |
| `m`, `ef_construction`, `ef_search` | HNSW's links per node, build-time candidate list, and query-time candidate list |
| top k | How many nearest chunks go into the prompt (5 here) |
| Temperature | Divisor applied to logits before the softmax; low values make output more deterministic |
| Grounding | Instructing the model to answer only from the provided passages |
| Persona | The part of the system prompt that sets who is speaking and how |
| Recall at k | How often the answer is among the top k retrieved |
| MRR | Mean reciprocal rank: the average of 1/rank of the first correct result |
| Faithfulness | Whether every claim in an answer is supported by its cited passages |
| Query rewriting | Turning a follow-up into a standalone question before retrieval |
| Embedding signature | The model and size that produced a vector, e.g. `gemini-embedding-001@768` |

</details>

### References

- Lewis et al., [Retrieval-Augmented Generation for Knowledge-Intensive NLP Tasks](https://arxiv.org/abs/2005.11401) (2020), the paper that named RAG
- Lee et al., [Gemini Embedding: Generalizable Embeddings from Gemini](https://arxiv.org/abs/2503.07891) (2025)
- Kusupati et al., [Matryoshka Representation Learning](https://arxiv.org/abs/2205.13147) (2022)
- Ethayarajh, [How Contextual are Contextualized Word Representations?](https://arxiv.org/abs/1909.00512) (2019)
- Liu et al., [Lost in the Middle: How Language Models Use Long Contexts](https://arxiv.org/abs/2307.03172) (2023)
- Malkov & Yashunin, [Efficient and robust approximate nearest neighbor search using Hierarchical Navigable Small World graphs](https://arxiv.org/abs/1603.09320) (2016)
- [pgvector](https://github.com/pgvector/pgvector) and [pgvector-elixir](https://github.com/pgvector/pgvector-elixir)
- [Gemini API: embeddings](https://ai.google.dev/gemini-api/docs/embeddings)
- [Req](https://github.com/wojtekmach/req), [Bandit](https://github.com/mtrudel/bandit) and [Mox](https://github.com/dashbitco/mox)
