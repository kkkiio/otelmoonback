# otelmoonback

OpenTelemetry HTTP server instrumentation for [Moonback](https://github.com/moonbitlang/moonback). It creates SERVER spans and extracts W3C trace context through the [opentelemetry.mbt](https://github.com/moonbit-community/opentelemetry.mbt) public API, and can record request duration.

## Install

```bash
moon add KKKIIO/otelmoonback
```

## Usage

The program below serves one real HTTP request and prints one HTTP SERVER span plus a child span, then exits. It uses the same API as the [runnable example](examples/basic/main.mbt), which also shows the duration metric and explicit flush/shutdown.

```moonbit nocheck
///|
async fn main {
  let exporter = @sdktrace.InMemorySpanExporter::new()
  let traces = @sdktrace.SdkTracerProvider::builder()
    .with_sampler(
      @sdktrace.Sampler::parent_based(@sdktrace.Sampler::always_on()),
    )
    .with_simple_exporter(exporter.into_span_exporter())
    .build()
  let tracer = traces.into_tracer_provider().tracer("my-service")
  let meter = @metrics_noop.NoopMeterProvider::new()
    .into_meter_provider()
    .meter("my-service")
  let app = @moonback.App(ctx => {
    ctx.add_middleware(
      @otelmoonback.new_middleware(tracer~, meter~, filter=req => {
        req.path != "/health"
      }),
    )
    ctx.get("/users/:id", (req, res) => {
      @otelmoonback.set_route(req, "/users/:id")
      let parent = @otelmoonback.get_context(req).unwrap()
      let child = tracer.start_with_context("load-user", parent)
      defer (@async.protect_from_cancel(() => {
        @async.with_timeout(1000, () => child.end())
      }) catch {
        _ => ()
      })
      res.send_text("user=\{req.params["id"]}")
    })
  })
  @async.with_task_group(group => {
    let listener = @moonback.listen()
    let serving = group.spawn(() => app.serve(listener))
    let (response, body) = @http.get(
      "http://127.0.0.1:\{listener.addr.port()}/users/42",
    )
    println("HTTP \{response.code}: \{body.text()}")
    serving.cancel()
  })
  app.close()
  for span in exporter.finished_spans() {
    println(span.name)
  }
  guard traces.shutdown() is Ok(_) else { fail("trace shutdown failed") }
}
```

## Features

- [x] HTTP SERVER spans (downstream middleware, the handler, and in-handler streaming writes)
- [x] W3C `traceparent` / `tracestate` extraction
- [x] Request-scoped OTel context with per-request isolation
- [x] HTTP status and exception recording
  - [ ] Final status of framework-generated responses (needs a Moonback request-end hook)
- [x] Explicit `http.route` template via `set_route`
  - [ ] Automatic route templates (needs Moonback to expose the matched route and mount prefix)
- [x] `http.server.request.duration` histogram (seconds; recorded even when unsampled)
  - [ ] Full network lifetime (needs a Moonback request-completion hook)
- [x] Request filter
- [x] Span naming hooks
- [ ] WebSocket instrumentation (needs Moonback upgrade-result and session-close events)
- [ ] Response body size (needs a unified Moonback byte count covering streams, compression, and generated responses)

## Limits

- **Framework-generated 500**: an error escaping the handler records an exception event and Error status; the final HTTP 500 Moonback sends afterwards is not observable. An error raised after the response started keeps the seen status and records the exception.
- **Route template**: pass the full template to `set_route`, e.g. `/api/users/:id`. The default span name is `GET`; with a template it becomes `GET /api/users/:id`. Keep naming-hook values low-cardinality. Raw paths, queries, headers and bodies are not collected; exception events may carry application error messages.
- **WebSocket**: every request with an `Upgrade` header (including failed handshakes and plain-HTTP responses) gets no span or duration.
- **Cancellation**: records Error status and `error.type="cancelled"`; span end is still attempted in a protected scope. Export is not guaranteed on hard exits, and disconnects, application cancellation, timeouts and shutdown cannot be told apart.
- **Exporter lifecycle**: the app owns the provider/exporter — background workers, `force_flush`, `shutdown` and their results. A failing or slow export still preserves the HTTP outcome; telemetry may be lost.
- **Metric scope**: duration ends when the handler returns — it includes in-handler writes and excludes export time and the framework's network tail. OpenTelemetry 0.1.8 histograms expose count/sum/min/max only; no explicit buckets or exemplars.
- **Scheme**: `scheme="http"` by default; set `scheme="https"` when TLS is terminated upstream. Proxy trust is the app's decision.

See [examples/basic/README.md](examples/basic/README.md) for the lifecycle and SDK operational notes.

Apache-2.0.
