{ Askr.Http.Welcome — siden man ser før man har skrevet noe selv.

  Et nytt prosjekt gikk fra `askr new` rett til en blank side: ruta går
  gjennom Inertia, og Inertia trenger en Vite-server som ikke kjører ennå.
  Serveren virket hele tiden, men ingenting viste det.

  Denne siden viser det, og den gjør det uten noe som helst: ingen npm,
  ingen byggesteg, ingen filer ved siden av binæren, ingen nett. Alt ligger
  her — også fontene, som er systemets egne, fordi en maskin uten nett skal
  se det samme som en med.

  Det den faktisk viser fram, er arenaen. Tallene er lest av den arenaen som
  gjengir akkurat denne requesten, i det øyeblikket den gjengis. Det er det
  ene Askr gjør annerledes enn alt annet, og det er verdt mer enn en logo.

  **Teksten på siden er på engelsk.** Kildekoden her er norsk som resten av
  rammeverket, men dette er det første et internasjonalt publikum ser, og da
  er norsk feil valg. Endrer du teksten, hold den på engelsk. }
unit Askr.Http.Welcome;

{$mode Delphi}{$H+}

interface

uses
  SysUtils, Askr.Core.Arena, Askr.Core.Text,
  Askr.Http.Request, Askr.Http.Response;

{ Velkomstsiden for et nytt prosjekt. Kalles fra kontrolleren `askr new`
  lager, og er ment å bli slettet derfra så snart appen har noe eget å vise. }
function WelcomePage(Req: TRequest; const AppName: string): TResponse;

implementation

function Esc(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    case S[I] of
      '&': Result := Result + '&amp;';
      '<': Result := Result + '&lt;';
      '>': Result := Result + '&gt;';
      '"': Result := Result + '&quot;';
    else
      Result := Result + S[I];
    end;
end;

{ Tusenskille med smalt mellomrom, slik tall skrives på norsk. }
function Number(V: QWord): string;
var
  S: string;
  I, N: Integer;
begin
  S := IntToStr(V);
  Result := '';
  N := 0;
  for I := Length(S) downto 1 do
  begin
    Result := S[I] + Result;
    Inc(N);
    if (N mod 3 = 0) and (I > 1) then
      Result := '&#8201;' + Result;
  end;
end;

{ Andel av det reserverte, som bredde i prosent. Minimum en hårstrek, ellers
  forsvinner en request på 400 byte helt mot 64 kB — og nettopp den
  forskjellen er det bjelken skal vise. }
function Andel(Del, Hele: PtrUInt): string;
var
  Tidels: Int64;
begin
  { Heltallsregning, ikke FormatFloat. Flyttallsformatering drar inn
    systemets desimalskilletegn, og et komma her ville gjort bredden til
    ugyldig CSS på en maskin med norsk locale. }
  if Hele = 0 then
    Exit('0.4');
  Tidels := (Int64(Del) * 1000) div Int64(Hele);
  if Tidels < 4 then
    Tidels := 4;
  if Tidels > 1000 then
    Tidels := 1000;
  Result := IntToStr(Tidels div 10) + '.' + IntToStr(Tidels mod 10);
end;

function Vert(Req: TRequest): string;
var
  H: TStr;
begin
  H := Req.Header('Host');
  if H.Len > 0 then
    Result := Esc(H.ToString)
  else
    Result := 'localhost';
end;

function WelcomePage(Req: TRequest; const AppName: string): TResponse;
var
  A: TArena;
  Name_, Html: string;
begin
  A := Req.Arena;
  Name_ := Esc(AppName);

  Html :=
'<!doctype html>'#10 +
'<html lang="en">'#10 +
'<head>'#10 +
'<meta charset="utf-8">'#10 +
'<meta name="viewport" content="width=device-width, initial-scale=1">'#10 +
'<title>' + Name_ + ' is running</title>'#10 +
'<style>'#10 +
':root {'#10 +
'  --ground:  #0a1014;'#10 +
'  --raised:  #101b21;'#10 +
'  --text:    #e9f1f4;'#10 +
'  --dim:     #7b909c;'#10 +
'  --rule:    #1c2a32;'#10 +
'  --aurora:  #3fe0a8;'#10 +
'  --ember:   #ffb068;'#10 +
'  --sans: system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue",'#10 +
'          Arial, sans-serif;'#10 +
'  --mono: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas,'#10 +
'          "DejaVu Sans Mono", monospace;'#10 +
'}'#10 +
'@media (prefers-color-scheme: light) {'#10 +
'  :root {'#10 +
'    --ground: #f7f9f9;'#10 +
'    --raised: #ffffff;'#10 +
'    --text:   #0c1519;'#10 +
'    --dim:    #5d7382;'#10 +
'    --rule:   #dde5e8;'#10 +
'    --aurora: #0c8f68;'#10 +
'    --ember:  #a5620f;'#10 +
'  }'#10 +
'}'#10 +
'* { box-sizing: border-box; }'#10 +
'html { -webkit-text-size-adjust: 100%; }'#10 +
'body {'#10 +
'  margin: 0;'#10 +
'  background: var(--ground);'#10 +
'  color: var(--text);'#10 +
'  font-family: var(--sans);'#10 +
'  font-size: 16px;'#10 +
'  line-height: 1.55;'#10 +
'  -webkit-font-smoothing: antialiased;'#10 +
'}'#10 +
'main { max-width: 44rem; margin: 0 auto; padding: 4.5rem 1.5rem 6rem; }'#10 +
                                                                              #10 +
'.live {'#10 +
'  display: inline-flex; align-items: center; gap: 0.5rem;'#10 +
'  font-family: var(--mono); font-size: 0.78rem; letter-spacing: 0.04em;'#10 +
'  text-transform: uppercase; color: var(--aurora); margin-bottom: 1.5rem;'#10 +
'}'#10 +
'.dot {'#10 +
'  width: 0.5rem; height: 0.5rem; border-radius: 50%;'#10 +
'  background: var(--aurora); box-shadow: 0 0 0 0 var(--aurora);'#10 +
'  animation: pulse 2.4s ease-out infinite;'#10 +
'}'#10 +
'@keyframes pulse {'#10 +
'  0%   { box-shadow: 0 0 0 0 rgba(63,224,168,0.55); }'#10 +
'  70%  { box-shadow: 0 0 0 0.65rem rgba(63,224,168,0); }'#10 +
'  100% { box-shadow: 0 0 0 0 rgba(63,224,168,0); }'#10 +
'}'#10 +
                                                                              #10 +
'h1 {'#10 +
'  font-size: clamp(2.4rem, 7vw, 3.9rem);'#10 +
'  font-weight: 800; line-height: 1.02; letter-spacing: -0.035em;'#10 +
'  margin: 0 0 0.75rem; text-wrap: balance;'#10 +
'}'#10 +
'.addr {'#10 +
'  font-family: var(--mono); font-size: 1rem; color: var(--dim);'#10 +
'  margin: 0 0 3.5rem;'#10 +
'}'#10 +
'.addr b { color: var(--aurora); font-weight: 400; }'#10 +
                                                                              #10 +
'.gauge { margin: 0 0 1.25rem; }'#10 +
'.gauge h2 {'#10 +
'  font-size: 0.78rem; font-weight: 600; letter-spacing: 0.08em;'#10 +
'  text-transform: uppercase; color: var(--dim); margin: 0 0 1.1rem;'#10 +
'}'#10 +
'.track {'#10 +
'  position: relative; height: 2.6rem; border-radius: 0.3rem;'#10 +
'  background: var(--raised); border: 1px solid var(--rule);'#10 +
'  overflow: hidden; margin-bottom: 0.5rem;'#10 +
'}'#10 +
'.fill {'#10 +
'  position: absolute; inset: 0 auto 0 0; width: var(--w);'#10 +
'  animation: grow 1.1s cubic-bezier(.16,1,.3,1) both;'#10 +
'}'#10 +
'.fill.peak { background: color-mix(in srgb, var(--aurora) 26%, transparent); }'#10 +
'.fill.now  { background: var(--aurora); }'#10 +
'@keyframes grow { from { width: 0; } to { width: var(--w); } }'#10 +
'@media (prefers-reduced-motion: reduce) {'#10 +
'  .fill { animation: none; } .dot { animation: none; }'#10 +
'}'#10 +
'.legend {'#10 +
'  font-family: var(--mono); font-size: 0.82rem; color: var(--dim);'#10 +
'  margin: 0 0 1.6rem;'#10 +
'}'#10 +
'.legend b { color: var(--text); font-weight: 500; }'#10 +
                                                                              #10 +
'.figures { display: flex; flex-wrap: wrap; gap: 2.5rem; margin: 2.25rem 0 0; }'#10 +
'.figures div { min-width: 0; }'#10 +
'.figures dt {'#10 +
'  font-size: 0.78rem; letter-spacing: 0.06em; text-transform: uppercase;'#10 +
'  color: var(--dim); margin-bottom: 0.25rem;'#10 +
'}'#10 +
'.figures dd {'#10 +
'  margin: 0; font-family: var(--mono); font-size: 1.75rem; font-weight: 500;'#10 +
'  letter-spacing: -0.02em; font-variant-numeric: tabular-nums;'#10 +
'}'#10 +
'.figures .unit { font-size: 0.95rem; color: var(--dim); }'#10 +
                                                                              #10 +
'.lede { color: var(--dim); max-width: 34rem; margin: 2.5rem 0 0; }'#10 +
                                                                              #10 +
'h3 {'#10 +
'  font-size: 0.78rem; font-weight: 600; letter-spacing: 0.08em;'#10 +
'  text-transform: uppercase; color: var(--dim);'#10 +
'  margin: 4.5rem 0 1.5rem;'#10 +
'}'#10 +
'.step { display: block; padding: 1rem 0; border-top: 1px solid var(--rule); }'#10 +
'.step:last-of-type { border-bottom: 1px solid var(--rule); }'#10 +
'.step code {'#10 +
'  display: block; font-family: var(--mono); font-size: 0.92rem;'#10 +
'  color: var(--aurora); margin-bottom: 0.3rem; overflow-wrap: anywhere;'#10 +
'}'#10 +
'.step code.pending { color: var(--ember); }'#10 +
'.step p { margin: 0; color: var(--dim); }'#10 +
'.step p code { display: inline; margin: 0; font-size: 0.88em; }'#10 +
                                                                              #10 +
'.note { margin-top: 3rem; font-size: 0.88rem; color: var(--dim); }'#10 +
'.note code { font-family: var(--mono); color: var(--text); }'#10 +
                                                                              #10 +
'@media (max-width: 34rem) {'#10 +
'  main { padding-top: 3rem; }'#10 +
'  .figures { gap: 1.75rem; }'#10 +
'  .figures dd { font-size: 1.45rem; }'#10 +
'}'#10 +
'</style>'#10 +
'</head>'#10 +
'<body>'#10 +
'<main>'#10 +
                                                                              #10 +
'<p class="live"><span class="dot"></span>serving</p>'#10 +
'<h1>' + Name_ + ' is running</h1>'#10 +
'<p class="addr">on <b>' + Vert(Req) + '</b></p>'#10 +
                                                                              #10 +
'<section class="gauge">'#10 +
'<h2>Arena, this worker</h2>'#10 +
'<div class="track">'#10 +
'  <div class="fill peak" style="--w:' + Andel(A.HighWaterMark, A.BytesReserved) + '%"></div>'#10 +
'  <div class="fill now" style="--w:' + Andel(A.BytesLive, A.BytesReserved) + '%"></div>'#10 +
'</div>'#10 +
'<p class="legend"><b>' + Andel(A.HighWaterMark, A.BytesReserved) + '%</b>'#10 +
' of the <b>' + Number(A.BytesReserved) + ' B</b> this worker reserved once'#10 +
' and keeps reusing</p>'#10 +
                                                                              #10 +
'<dl class="figures">'#10 +
'<div><dt>This request</dt>'#10 +
'     <dd>' + Number(A.BytesLive) + '<span class="unit"> B</span></dd></div>'#10 +
'<div><dt>Peak</dt>'#10 +
'     <dd>' + Number(A.HighWaterMark) + '<span class="unit"> B</span></dd></div>'#10 +
'<div><dt>Requests served</dt>'#10 +
'     <dd>' + Number(A.ResetCount) + '</dd></div>'#10 +
'</dl>'#10 +
'</section>'#10 +
                                                                              #10 +
'<p class="lede">The bright bar is what this page has cost so far; the faint'#10 +
'one is the most this worker has ever held. Nearly empty is the point — a'#10 +
'request costs a fraction of a block that gets reserved once and reused for'#10 +
'every request after it. Reload and the numbers jump: every worker has its'#10 +
'own arena, and you will not hit the same one twice in a row.</p>'#10 +
                                                                              #10 +
'<h3>From here</h3>'#10 +
                                                                              #10 +
'<div class="step">'#10 +
'  <code>app.lpr</code>'#10 +
'  <p>The route lives here. <code>R.Get(''/'', Home.Index)</code> is the'#10 +
'  line that sent you to this page.</p>'#10 +
'</div>'#10 +
                                                                              #10 +
'<div class="step">'#10 +
'  <code>app/Http/App.Http.HomeController.pas</code>'#10 +
'  <p>The response is built here. Replace the call to'#10 +
'  <code>WelcomePage</code> with your own, and this page is gone.</p>'#10 +
'</div>'#10 +
                                                                              #10 +
'<div class="step">'#10 +
'  <code class="pending">cd frontend &amp;&amp; npm install</code>'#10 +
'  <p>Inertia and Svelte are set up but not installed yet. Run this, restart'#10 +
'  with <code>askr serve</code>, and <code>/demo</code> becomes a Svelte'#10 +
'  page.</p>'#10 +
'</div>'#10 +
                                                                              #10 +
'<div class="step">'#10 +
'  <code>askr make:model Customer --migration</code>'#10 +
'  <p>Creates a model and a migration. <code>askr migrate</code> runs it, and'#10 +
'  <code>askr schema</code> writes typed columns out of the database.</p>'#10 +
'</div>'#10 +
                                                                              #10 +
'<p class="note">This page comes from <code>Askr.Http.Welcome</code> in the'#10 +
'framework, not from your project. It reads no files and needs no'#10 +
'network.</p>'#10 +
                                                                              #10 +
'</main>'#10 +
'</body>'#10 +
'</html>'#10;

  Result := RespondHtml(Html);
end;

end.
