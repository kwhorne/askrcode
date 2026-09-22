{ A real send through api.resend.com, with a real key.

  WHY THIS IS AN EXAMPLE AND NOT A TEST

  It costs a credential and it sends something. `./askr test` cannot do
  either -- a suite that only runs for people holding a key is a suite most
  people cannot run, and one that emits mail as a side effect is worse.
  Everything about the request is tested against a fake, and one test goes
  through a raw socket to read the bytes that actually leave.

  What no fake can tell you is whether the other end agrees. Until this was
  run, the framework's claim about its Resend transport rested on a 401: a
  real call without a valid key, which proved DNS, TLS, the request shape
  and the error path, and nothing about a message being accepted.

  WHERE IT SENDS, AND WHERE IT DOES NOT

  `onboarding@resend.dev` and `delivered@resend.dev` are Resend's own
  addresses for exactly this: the first sends without a verified domain,
  the second accepts without a mailbox behind it. No real inbox is touched
  and nobody's address goes into a third party's payload.

  That means this proves the message was **accepted**, with an id back --
  not that anything arrived in a human inbox. No API call can prove the
  second, and saying otherwise would be the sort of claim this file exists
  to stop.

  Run it where the key already is:

    RESEND_API_KEY=... ./resendprobe

  The key is read through the configuration layer and is never printed. }
program resendprobe;

{$mode Delphi}{$H+}

uses
{$IFDEF UNIX}
  cthreads,
{$ENDIF}
  SysUtils,
  Askr.Core.Env, Askr.Core.Config, Askr.Mail, Askr.Mail.Resend;

const
  { Resend's own test pair. Documented for this, and it keeps a real
    address out of a third party's payload.

    The sender is taken from mail.from when there is one, because then the
    run exercises the domain the application will actually send from --
    which is where the 403 lives if it was never verified. The recipient
    stays a test address either way: proving the transport works does not
    require putting anybody's inbox in the loop. }
  FallbackFrom = 'Askr <onboarding@resend.dev>';
  ToAddr = 'delivered@resend.dev';

var
  FromAddr: string;
  { Unique per run, stable within it. A key fixed in the source looks
    right and is not: Resend scopes it to the body for 24 hours, so a
    second run with anything changed -- a different sender, say -- gets a
    409 saying the key was used with a different body. Which is the
    feature working, and the first version of this file walking into
    it. }
  IdemKey: string;

var
  Failures: Integer = 0;

procedure Step(const What: string);
begin
  WriteLn;
  WriteLn('== ', What);
end;

procedure Check(Cond: Boolean; const What: string; const Detail: string = '');
begin
  if Cond then
    WriteLn('  ok    ', What)
  else
  begin
    WriteLn('  FAIL  ', What);
    if Detail <> '' then
      WriteLn('        ', Detail);
    Inc(Failures);
  end;
end;

var
  T: TResendTransport;
  M: TMailMessage;
  FirstId, SecondId: string;
begin
  LoadEnvUpwards;
  LoadConfig(GetCurrentDir);

  if Env('RESEND_API_KEY') = '' then
  begin
    WriteLn('RESEND_API_KEY is not set. Nothing to prove without it.');
    Halt(2);
  end;

  IdemKey := 'askr-probe-' + FormatDateTime('yyyymmdd-hhnnss', Now);
  FromAddr := Trim(Cfg('mail.from', ''));
  if FromAddr = '' then
    FromAddr := FallbackFrom;

  T := TResendTransport.Create;
  try
    WriteLn('askr - resend');
    WriteLn('from ', FromAddr, '  to ', ToAddr);

    Step('1. a message is accepted, and comes back with an id');
    M := TMailMessage.Create;
    try
      M.From(FromAddr).AddTo(ToAddr)
       .Subject('Askr probe')
       .Text('A real send from the Askr Resend transport.');
      T.Send(M);
      FirstId := T.LastId;
    finally
      M.Free;
    end;
    Check(FirstId <> '', 'an id came back', 'empty');
    Check(Length(FirstId) > 20, 'and it looks like one',
      'got: ' + FirstId);

    { The key that goes out cannot be read back from the transport -- it
      is on the fake, for the suite. What can be seen from here is the
      behaviour it exists for, which is the better claim anyway. }
    Step('2. the same idempotency key does not send a second message');
    M := TMailMessage.Create;
    try
      M.From(FromAddr).AddTo(ToAddr)
       .Subject('Askr probe, idempotent')
       .Text('Sent twice on purpose.')
       .Idempotency(IdemKey);
      T.Send(M);
      SecondId := T.LastId;
      Check(SecondId <> '', 'the first of the pair was accepted');
    finally
      M.Free;
    end;

    { The same key again. A queue that retries builds the message afresh,
      so the fallback -- the Message-ID, which is new each time -- does not
      cover the case that actually happens. This is why the key is the
      caller's to set. }
    M := TMailMessage.Create;
    try
      M.From(FromAddr).AddTo(ToAddr)
       .Subject('Askr probe, idempotent')
       .Text('Sent twice on purpose.')
       .Idempotency(IdemKey);
      T.Send(M);
      Check(T.LastId = SecondId,
        'sending it again with the same key gives the same id, not a ' +
        'second message',
        'first: ' + SecondId + '  second: ' + T.LastId);
    finally
      M.Free;
    end;

    Step('3. an error comes back as an error, with status and type');
    M := TMailMessage.Create;
    try
      { A from-address on a domain this account has not verified. Resend
        refuses it, and the point is that the refusal arrives as
        EResendError with the status and the name Resend used -- not as a
        stray exception or, worse, as silence. }
      M.From('nobody@example.invalid').AddTo(ToAddr)
       .Subject('Askr probe, should fail')
       .Text('This one is meant to be refused.');
      try
        T.Send(M);
        Check(False, 'an unverified sender is refused', 'it went through');
      except
        on E: EResendError do
        begin
          Check(E.Status >= 400, 'it came back as EResendError',
            'status ' + IntToStr(E.Status));
          Check(E.Name_ <> '', 'with the name Resend gave it',
            'name: ' + E.Name_);
          WriteLn('        (', E.Status, ' ', E.Name_, ': ',
            Copy(E.Message, 1, 90), ')');
        end;
      end;
    finally
      M.Free;
    end;
  except
    on E: EResendError do
    begin
      WriteLn('  FAIL  the send failed');
      WriteLn('        ', E.ClassName, ' ', E.Status, ' ', E.Name_, ': ',
        E.Message);
      Inc(Failures);
    end;
    on E: Exception do
    begin
      WriteLn('  FAIL  the send failed');
      WriteLn('        ', E.ClassName, ': ', E.Message);
      Inc(Failures);
    end;
  end;
  T.Free;

  WriteLn;
  if Failures > 0 then
  begin
    WriteLn(Failures, ' failed.');
    Halt(1);
  end;
  WriteLn('Accepted by Resend, with an id. Delivery to a human inbox is ' +
    'a different claim, and this does not make it.');
end.
