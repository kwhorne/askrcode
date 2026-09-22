# AI

Claude through the Messages API. There is no official Pascal SDK, so this is
raw HTTP against `POST /v1/messages`. The protocol is documented and stable;
what Askr owns is the serialisation, and `Askr.Core.Json` handles both
directions.

```pascal
uses Askr.Ai;

K := TAiClient.Create;            { key from ANTHROPIC_API_KEY }
try
  WriteLn(K.Ask('Summarise this order in one sentence.'));
finally
  K.Free;
end;
```

## What has actually been run

All four of these have been exercised against `api.anthropic.com` with a
real key — text, streaming, tool calls and structured output, and adaptive
thinking besides. The run is `examples/ai/aiprobe.lpr`, and it is an
example rather than a test: a suite that only runs for people holding a
credential is a suite most people cannot run.

**What that run found is the reason it was worth doing.** The tool loop
sent the assistant's turn back without the `tool_use` blocks it had asked
with, and the API refuses the results that follow:

> each `tool_result` block must have a corresponding `tool_use` block in
> the previous message

The suite had been green the whole time. It is built on
`TFakeAiTransport`, which holds the JSON that gets sent up against what it
should be — and "what it should be" was the author's belief, not the API's
requirement. **That is the limit of any fake**, and it is worth knowing
before you trust one of your own.

A second half of the same bug: every tool result was in its own message,
so only the first sat after the assistant turn it answered. A round with a
single tool call could not show it. The suite now has one with two
parallel calls.

**Adaptive thinking is not on every model.** Haiku 4.5 answers `400` with
`adaptive thinking is not supported on this model`, which is the error
path working. Use a model that has it, or leave thinking off.

## The model

```pascal
K.Model := 'claude-sonnet-5';
```

The default is **`claude-opus-5`** — not because it is cheapest, but because
model choice is the app's decision, not the framework's.
`claude-sonnet-5` and `claude-haiku-4-5` are there for lower cost.

## Options

```pascal
K.System_ := 'You are terse.';
K.MaxTokens := 1024;
K.SetTemperature(0.2);       { unset by default; the API picks }
K.ClearTemperature;
K.Thinking := atAdaptive;
K.MaxTurns := 8;             { the tool loop's ceiling }
K.BaseUrl := '...';
```

> **Thinking is sent as `{"type":"adaptive"}`, never with `budget_tokens`.**
> The old form is deprecated on the 4.6 models and **rejected with a 400** on
> Opus 5, Sonnet 5 and Fable 5. It is a trap precisely because it is the form
> you remember. There is a test that fails if `budget_tokens` appears in a
> request at all.

The header is **`x-api-key`**, not `Authorization: Bearer`. A bearer token
there gives 401 with no explanation.

## Conversations

```pascal
R := K.Send([
  UserMsg('What is in this order?'),
  AssistantMsg('Two books and a lamp.'),
  UserMsg('What did it cost?')]);
```

```pascal
R.Text;          R.Thinking;
R.StopReason;    R.Model;
R.Usage.InputTokens;  R.Usage.OutputTokens;
R.ToolCalls;     R.WantsTool;
R.Raw;           { the whole response, for anything not picked out }
```

## Streaming

```pascal
function TWriter.Delta(const S: string): Boolean;
begin
  Write(S);
  Result := True;      { False stops the stream }
end;

R := K.Stream('Write a short story.', @Writer.Delta);
```

The callback gets the text as it arrives; the returned response still has
the whole text assembled, so you have both.

`StreamMessages` takes a full message list.

## Tools

A tool is a Pascal function. The handler gets the arguments as JSON text and
returns a result as text — the model reads it as text anyway, and demanding
JSON back would be a rule without a reason.

```pascal
function Weather(const InputJson: string): string;
begin
  Result := '{"temp_c": 7, "sky": "rain"}';
end;

K.AddTool('weather', 'Look up the weather for a place',
  '{"type":"object","properties":{"place":{"type":"string"}},' +
  '"required":["place"]}', @Weather);

R := K.RunTools('What is the weather in Oslo?');
```

`RunTools` runs the loop: send, execute what the model asked for, send the
results back, repeat — until the model is done or `MaxTurns` is used up.

Three things it does on purpose:

- A **tool result is a `tool_result` block in a `user` message**, not a role
  of its own. That is the most common mistake when building the loop by hand.
- **A tool that raises becomes a message to the model**, marked `is_error`,
  not an exception out of the loop. The model can try something else.
- **A tool the model invented** gets the same treatment, rather than taking
  anything down.

The loop has a ceiling because a model can go in circles.

## Structured output

```pascal
Json := K.Structured('Who is she?',
  '{"type":"object","properties":{"name":{"type":"string"},' +
  '"age":{"type":"integer"}},"required":["name"]}');
```

Implemented as a tool the model is **forced** to use with `tool_choice`.
That form works across models and cannot answer with prose alongside. If the
model answers with text anyway, that is an error, not an empty string the
caller has to guess about.

`Structured` does not change the client it was called on — the tools are set
aside and restored.

## Errors

```pascal
except
  on E: EAiError do
  begin
    E.Status;      { 401, 429, 529, ... }
    E.Kind;        { Anthropic's own type }
  end;
end;
```

`Kind` is the type as the API writes it, without decoration:
`overloaded_error` to retry, `invalid_request_error` not to. The
parentheses belong to the message text.

An HTML error page from a proxy becomes a readable error too, not a parse
crash.

## Testing without a network

```pascal
F := TFakeAiTransport.Create;
K := TAiClient.Create('test-key');
K.UseTransport(F, True);

F.Enqueue('{"content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn"}');
AssertEqual(K.Ask('say hi'), 'hi', 'the simplest call');

{ And assert on what was actually sent }
AssertTrue(Pos('"model":"claude-opus-5"', F.Sent[0]) > 0, 'default model');
```

`EnqueueStream` queues an SSE body for `Stream`.

## Keys

From the environment, through the configuration layer, and never logged:

```
ANTHROPIC_API_KEY=sk-ant-...
```

```pascal
K := TAiClient.Create;                { CfgOrFail('anthropic.api.key') }
K := TAiClient.Create(SomeOtherKey);
```

## What is not here

**Embeddings and vector search.** They come after the four above, and
`pgvector` exists for Postgres but not for SQLite — it would be the first
place the data layer has to say "Postgres only".

**`eager_input_streaming`.** It would make the client responsible for
validating tool arguments against the schema, and Askr has no JSON Schema
validator. Turning it on without one trades a known limitation for a silent
one.

**Images, audio, transcription, reranking, agents with memory.** Not built.
