///|
async fn main {
  let exporter = @sdktrace.InMemorySpanExporter::new()
  let traces = @sdktrace.SdkTracerProvider::builder()
    .with_sampler(
      @sdktrace.Sampler::parent_based(@sdktrace.Sampler::always_on()),
    )
    .with_simple_exporter(exporter.into_span_exporter())
    .build()
  let metrics = @sdkmetrics.SdkMeterProvider::builder().build()
  let tracer = traces.into_tracer_provider().tracer("otelmoonback-example")
  let meter = metrics.into_meter_provider().meter("otelmoonback-example")
  let app = @moonback.App(ctx => {
    // Register cancellation boundaries first so the cancellation they apply
    // downstream is observed by instrumentation.
    ctx.add_middleware(@moonback.cancel_on_shutdown())
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
  // Keep provider shutdown outside request handling, after serve has drained.
  @async.with_timeout(3000, () => {
    @async.with_task_group(group => {
      let listener = @moonback.listen()
      let serving = group.spawn(() => app.serve(listener))
      let (response, body) = @http.get(
        "http://127.0.0.1:\{listener.addr.port()}/users/42",
        headers={
          "traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
        },
      )
      println("HTTP \{response.code}: \{body.text()}")
      serving.cancel()
    })
  })
  app.close()
  for span in exporter.finished_spans() {
    println("span: \{span.name} trace=\{span.span_context.trace_id().to_hex()}")
  }
  for point in metrics.collect() {
    println(@debug.to_string(point))
  }
  guard traces.force_flush() is Ok(_) else { fail("trace flush failed") }
  guard traces.shutdown() is Ok(_) else { fail("trace shutdown failed") }
  guard metrics.shutdown() is Ok(_) else { fail("metric shutdown failed") }
}
