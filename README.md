# Recall

Paste your lecture notes and Recall turns them into a drawer of question cards. You answer each one in your own words and it grades you against your notes. Cards you miss come back sooner; cards you know move up a drawer and retire. Questions are written by a Llama model on Groq; grading runs locally, in Elixir, with a small sentence model and a scoring line fitted to answers that teaching assistants graded by hand.

[![pipeline](https://github.com/evannwilsonn/recall/actions/workflows/pipeline.yml/badge.svg)](https://github.com/evannwilsonn/recall/actions/workflows/pipeline.yml)

**Live demo:** a Hugging Face Space, deployed from `main` by the pipeline (see [Deployment](#7-deployment)).

Project 13b of my AI project roadmap, the capstone, built three times in a language I hadn't used before. The other two are [Lure](https://github.com/evannwilsonn/lure) and [Squiggle](https://github.com/evannwilsonn/squiggle).

## 1. Problem

Rereading notes feels like studying but mostly isn't; answering questions from memory is what makes things stick, and it works best when the questions you miss come back. The goal is a tool that does both from your own notes: writes questions only from what the notes say, grades a free-text answer, and schedules the next card. The hard part is the grading, so that's what gets measured: how close the grader's score is to a person's, and how often it puts an answer in the same band (got it, partly, not yet).

## 2. Data

The grader is fitted and tested on the [Mohler short-answer grading set](https://huggingface.co/datasets/nkazi/MohlerASAG) (Mohler, Bunescu and Mihalcea, 2011; CC BY 4.0): 2,273 answers by students in an introductory data structures course, to 81 questions. Each answer comes with the instructor's answer and two graders' scores from 0 to 5; the average is the target.

- The split is **by question**, not by answer, because Recall grades questions it has never seen: 52 questions (1,455 answers) to fit on, 13 (360) to choose settings, 16 (458) to test. The split comes from a hash of the question id.
- People's bands: got it at 4 or more, partly from 2.5, not yet below. In the test answers, 69% are "got it", 25% "partly" and 6% "not yet".
- `mix recall.eval` fetches the rows from Hugging Face's dataset viewer API and keeps them in `priv/data/`.

## 3. Baseline

- **Average score:** give every answer the training average. RMSE 1.10. Because most answers are good, always saying "got it" already agrees with people 69% of the time, which is why accuracy alone is a poor measure here. Its balanced accuracy, with each band counted equally, is 33%.
- **Word coverage:** the share of the instructor's key words that appear in the answer, after dropping stop words and trimming endings. A line fitted to it gives RMSE 0.91, correlation 0.57.

## 4. Model

```
notes ─► Groq (Llama 3.3 70B, JSON) ─► cards: prompt, answer, quote checked against the notes
      └► no key or over budget ─► cards from the notes' own sentences ("What is…?", fill the gap)

your answer ─┬► MiniLM embedding ─┐
card answer ─┘                    ├► cosine "meaning" ┐
                 key-word coverage ┤                   ├► fitted line ─► score /5 ─► band ─► Leitner box
                 length ratio ─────┘                   ┘
```

- **Writing:** with a `GROQ_API_KEY`, `llama-3.3-70b-versatile` is told to use only the notes, treat them as data rather than instructions, and return JSON cards with a supporting quote. Each card is checked: the prompt and answer must be present, and a quote is kept only if it really is in the notes. Without a key, or past the rate limit (3 decks a minute per visitor, 25 overall), a plain-Elixir writer turns defining sentences ("A hash table is…") into "What is a hash table?" and blanks out a recurring key word in the rest.
- **Grading:** `sentence-transformers/all-MiniLM-L6-v2` runs in Elixir through Bumblebee and EXLA, behind an `Nx.Serving` that batches concurrent requests. Three features (meaning, coverage, length) go into a straight line fitted by least squares (with a touch of ridge) on the training questions. The band cut-offs are chosen on the validation questions to maximise balanced accuracy.
- **Scheduling:** Leitner boxes counted in turns. Right moves a card up a drawer, partly keeps it, not yet sends it back to drawer 1, and missed cards come back two answers later. A card right in drawer 3 is learned. The deck is saved in the browser and sent back when the page reconnects; nothing about your notes is stored on the server.

## 5. Evaluation

On the 458 test answers (16 questions never seen while fitting):

| Grader | RMSE | Correlation | Same band as people | Balanced |
|---|---|---|---|---|
| Average score | 1.102 | 0.00 | 68.6% | 33.3% |
| Word coverage | 0.914 | 0.57 | 66.2% | **59.5%** |
| MiniLM meaning | 0.952 | 0.50 | 48.3% | 53.0% |
| **Meaning + coverage + length (shipped)** | **0.900** | **0.58** | 56.3% | 56.8% |

The shipped grader was chosen by validation RMSE before the test set was scored; on test, coverage alone has slightly better balanced accuracy. A correlation around 0.58 is in the range reported for classic methods on this set, not state of the art.

What the bands mean in practice, on the test answers:

| People said ↓ / grader said → | got it | partly | not yet |
|---|---|---|---|
| got it (314) | 215 | 44 | 55 |
| partly (115) | 28 | 18 | 69 |
| not yet (29) | 1 | 3 | 25 |

It waves through 1 of 29 wrong answers, which is the mistake that matters most for studying. The cost is that it's strict: 55 good answers were called "not yet". That's why every graded card has an "I was right" button, and "Just show me" lets you rate yourself.

## 6. Improvement

- **Choosing cut-offs.** The first version picked the band cut-offs for plain accuracy. Since most answers are good, that pushed the grader toward "got it" for nearly everything: 24 of 29 wrong test answers got through. Tuning for balanced accuracy instead brought that down to 1 of 29.
- **Cleaner reference text.** Mohler's text has parser escapes (`-LRB-` for a bracket) and `<STOP>` markers; both are cleaned before embedding.
- **Readable feedback.** "Words you left out" first showed trimmed stems ("stor"). It now shows the words as the notes spell them.

## 7. Deployment

```
push to main ─► check: format, compile --warnings-as-errors, mix test
              └► image: docker build ─► smoke test on :7860 (page + framing header) ─► ghcr.io/evannwilsonn/recall
                                                                                       └► Hugging Face Space
```

- **Container:** a Phoenix release on Debian slim, uid 1000, port 7860, with MiniLM's weights baked in at build time (`BUMBLEBEE_OFFLINE=true`). The fitted grader is `priv/model/grader.json`.
- **Groq key:** set `GROQ_API_KEY` as a secret in the Space's settings. Without it the app still works, with questions from the notes' own sentences.
- **Space:** the pipeline's last job pushes a one-line Dockerfile (`FROM ghcr.io/evannwilsonn/recall:<commit>`) and the Space card. It runs once the repo has a variable `HF_SPACE` (like `name/recall`) and a secret `HF_TOKEN`, and needs the GHCR package to be public.
- **Pipeline board:** the run shows up on [Conveyor](https://evannwilsonn.github.io/conveyor/).

## Reproducing the numbers

```sh
mix deps.get
mix recall.eval     # fetches Mohler, fits and scores the graders, writes priv/model/grader.json
mix test            # never calls Groq
GROQ_API_KEY=... mix phx.server
```

## Layout

```
lib/recall/          writer (Groq + local), grader, embedder, deck, mohler, limit
lib/mix/tasks/       recall.eval
lib/recall_web/live/ study_live.ex: the page
priv/model/          grader.json, eval.json
results/eval.json    the evaluation this README quotes
```

## Limits

- The grader learned from one course's answers about data structures. It compares your answer with the card's answer and can't tell whether a differently worded answer is still right; trust your own judgment when they disagree.
- It can be fooled by an answer that uses the right words in a wrong sentence.
- Questions written by the model can still be off. Each card shows the sentence from your notes it came from, so you can check.
- Notes you paste are sent to Groq to write the questions and aren't stored by Recall.
