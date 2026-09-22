{ A real call to api.anthropic.com, with a real key.

  WHY THIS IS AN EXAMPLE AND NOT A TEST

  It costs money and needs a credential, so it cannot be part of `./askr
  test` -- a suite that only runs for people holding a key is a suite most
  people cannot run. Everything about the request shape is tested against
  TFakeAiTransport, which checks the JSON that would be sent.

  What no fake can tell you is whether the other end agrees. Until this was
  run, the framework's claim about its AI layer rested on a 401: a real
  call without a valid key, which proved DNS, TLS, the request shape and
  the error path, and nothing about a reply with content in it.

  So this exercises the four things the layer offers, in order:

    1. text generation
    2. streaming
    3. tool calls
    4. structured output

  Run it where the key already is. Do not move a credential to run a test.

    ANTHROPIC_API_KEY=... ./aiprobe

  The key is read through the configuration layer and is never printed. }
program aiprobe;

{$mode Delphi}{$H+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  SysUtils,
  Askr.Core.Env, Askr.Core.Config, Askr.Ai;

var
  Failures: Integer = 0;

procedure Step(const What: string);
begin
  WriteLn;
  WriteLn('== ', What);
end;

procedure Ok(const What: string);
begin
  WriteLn('  ok    ', What);
end;

procedure Bad(const What, Detail: string);
begin
  WriteLn('  FAIL  ', What);
  if Detail <> '' then
    WriteLn('        ', Detail);
  Inc(Failures);
end;

procedure Check(Cond: Boolean; const What: string; const Detail: string = '');
begin
  if Cond then
    Ok(What)
  else
    Bad(What, Detail);
end;

{ ---- streaming ---- }

var
  Chunks: Integer = 0;

function OnDelta(const Delta: string): Boolean;
begin
  Inc(Chunks);
  Result := True;
end;

{ ---- a tool ---- }

var
  ToolCalled: Boolean = False;

function LookUpPort(const InputJson: string): string;
begin
  { The model gets whatever this returns, as text. Only the tool knows
    what its own fields are, so the argument arrives as JSON. }
  ToolCalled := True;
  Result := '{"port": 8080}';
end;

var
  C: TAiClient;
  Text_: string;
  R: TAiResponse;
  Json: string;
begin
  LoadEnvUpwards;
  LoadConfig(GetCurrentDir);

  if Env('ANTHROPIC_API_KEY') = '' then
  begin
    WriteLn('ANTHROPIC_API_KEY is not set. Nothing to prove without it.');
    Halt(2);
  end;

  C := TAiClient.Create;
  try
    { Haiku: this is a proof that the layer talks to the API, not a
      demonstration of a model. The cheapest one that can do all four is
      the honest choice. }
    C.Model := 'claude-haiku-4-5-20251001';
    C.MaxTokens := 256;
    WriteLn('askr - ai, against ', C.BaseUrl);
    WriteLn('model ', C.Model);

    Step('1. text generation');
    Text_ := C.Ask('Reply with exactly one word: askr');
    Check(Text_ <> '', 'a reply came back', 'empty');
    Check(Pos('askr', LowerCase(Text_)) > 0, 'and it is the reply asked for',
      'got: ' + Copy(Text_, 1, 60));

    Step('2. streaming');
    Chunks := 0;
    R := C.Stream('Count from one to five, in words, one per line.',
      TAiDeltaCallbackProc(@OnDelta));
    Check(Chunks > 1, 'the text arrived in more than one piece',
      'chunks: ' + IntToStr(Chunks));
    Check(R.Text <> '', 'and the whole thing was collected too');
    Check(Pos('three', LowerCase(R.Text)) > 0, 'with the content in it',
      'got: ' + Copy(R.Text, 1, 60));

    Step('3. tool calls');
    ToolCalled := False;
    C.AddTool('lookup_port',
      'Returns the port the Askr development server listens on.',
      '{"type":"object","properties":{},"additionalProperties":false}',
      TAiToolHandlerProc(@LookUpPort));
    R := C.RunTools('Which port does the Askr development server listen ' +
      'on? Use the tool, then answer with just the number.');
    Check(ToolCalled, 'the model called the tool');
    Check(Pos('8080', R.Text) > 0, 'and answered from what it returned',
      'got: ' + Copy(R.Text, 1, 60));
    C.ClearTools;

    Step('4. structured output');
    Json := C.Structured(
      'The Askr framework is written in Free Pascal and ships as one binary.',
      '{"type":"object","properties":{' +
      '"language":{"type":"string"},' +
      '"binaries":{"type":"integer"}},' +
      '"required":["language","binaries"]}');
    Check(Pos('{', Json) = 1, 'the answer is JSON and nothing else',
      'got: ' + Copy(Json, 1, 80));
    Check(Pos('"language"', Json) > 0, 'with the fields the schema asked for');
    Check(Pos('Pascal', Json) > 0, 'and the content is right',
      'got: ' + Copy(Json, 1, 80));

    { Adaptive thinking is not on every model -- Haiku 4.5 answers 400
      with `adaptive thinking is not supported on this model`, which is
      the error path working. So this one step moves to a model that has
      it. The old budget_tokens form is rejected by these models too;
      there is a test that no request can contain it at all. }
    Step('5. thinking, which must never send budget_tokens');
    C.Model := 'claude-sonnet-5';
    C.Thinking := atAdaptive;
    C.MaxTokens := 2048;
    Text_ := C.Ask('What is 17 * 23? Answer with the number only.');
    Check(Pos('391', Text_) > 0, 'adaptive thinking answers',
      'got: ' + Copy(Text_, 1, 60));
    C.Thinking := atOff;
  except
    on E: EAiError do
      Bad('the call failed', E.ClassName + ' ' + IntToStr(E.Status) +
        ' ' + E.Kind + ': ' + E.Message);
    on E: Exception do
      Bad('the call failed', E.ClassName + ': ' + E.Message);
  end;
  C.Free;

  WriteLn;
  if Failures > 0 then
  begin
    WriteLn(Failures, ' failed.');
    Halt(1);
  end;
  WriteLn('All four work against the real API.');
end.
