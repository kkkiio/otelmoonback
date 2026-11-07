///|
let test_meter : @metrics.Meter = @metrics_noop.NoopMeterProvider::new()
  .into_meter_provider()
  .meter("otelmoonback-test")

///|
async test "remote parent, child context, route and duration over HTTP" {
  let exporter = @sdktrace.InMemorySpanExporter::new()
  let provider = @sdktrace.SdkTracerProvider::builder()
    .with_sampler(
      @sdktrace.Sampler::parent_based(@sdktrace.Sampler::always_on()),
    )
    .with_simple_exporter(exporter.into_span_exporter())
    .build()
  let tracer = provider.into_tracer_provider().tracer("otelmoonback-test")
  let metrics = @sdkmetrics.SdkMeterProvider::builder().build()
  let meter = metrics.into_meter_provider().meter("otelmoonback-test")
  let app = @moonback.App(ctx => {
    ctx.add_middleware(@otelmoonback.new_middleware(tracer~, meter~))
    ctx.get("/users/:id", (req, res) => {
      @otelmoonback.set_route(req, "/users/:id")
      guard @otelmoonback.get_span(req) is Some(server) else {
        fail("missing server span")
      }
      guard @otelmoonback.get_context(req) is Some(parent) else {
        fail("missing context")
      }
      assert_true(!server.has_ended())
      let child = tracer.start_with_context("lookup", parent)
      child.end()
      res.send_text("user=\{req.params["id"]}", status=201)
    })
  })
  defer app.close()
  @async.with_timeout(3000, () => {
    @async.with_task_group(group => {
      let listener = @moonback.listen()
      let serving = group.spawn(() => app.serve(listener))
      let (response, body) = @http.get(
        "http://127.0.0.1:\{listener.addr.port()}/users/42?token=secret",
        headers={
          "TrAcEpArEnT": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
          "TraceState": "vendor=value,other=two",
        },
      )
      assert_eq(response.code, 201)
      assert_eq(body.text(), "user=42")
      serving.cancel()
    })
  })
  let spans = exporter.finished_spans()
  assert_eq(spans.length(), 2)
  let child = spans[0]
  let server = spans[1]
  assert_eq(server.name, "GET /users/:id")
  assert_true(server.kind is @sdktrace.SpanKind::Server)
  assert_eq(
    server.span_context.trace_id().to_hex(),
    "4bf92f3577b34da6a3ce929d0e0e4736",
  )
  let remote = server.parent_span_context.unwrap()
  assert_true(remote.is_remote())
  assert_eq(remote.span_id().to_hex(), "00f067aa0ba902b7")
  assert_eq(server.span_context.trace_state().get("vendor"), Some("value"))
  assert_eq(server.span_context.trace_state().get("other"), Some("two"))
  assert_eq(
    child.parent_span_context.unwrap().span_id(),
    server.span_context.span_id(),
  )
  assert_true(server.status.code is @sdktrace.StatusCode::Unset)
  assert_true(
    server.attributes.contains(
      @common.KeyValue::new("http.response.status_code", Int64(201L)),
    ),
  )
  assert_true(server.end_time_unix_nano.unwrap() >= server.start_time_unix_nano)
  assert_eq(server.attributes.length(), 4)
  let points = metrics.collect()
  assert_eq(points.length(), 1)
  assert_eq(points[0].name, "http.server.request.duration")
  assert_eq(points[0].unit, Some("s"))
  assert_true(
    points[0].attributes.contains(
      @common.KeyValue::new("http.route", String("/users/:id")),
    ),
  )
  guard points[0].aggregation is Histogram(summary) else {
    fail("expected histogram")
  }
  assert_eq(summary.count, 1L)
  guard summary.sum is Double(seconds) else { fail("expected seconds") }
  assert_true(seconds >= 0.0)
  assert_true(provider.shutdown() is Ok(_))
  assert_true(metrics.shutdown() is Ok(_))
}

///|
async test "HTTP statuses and handler exceptions preserve response semantics" {
  let exporter = @sdktrace.InMemorySpanExporter::new()
  let provider = @sdktrace.SdkTracerProvider::builder()
    .with_sampler(
      @sdktrace.Sampler::parent_based(@sdktrace.Sampler::always_on()),
    )
    .with_simple_exporter(exporter.into_span_exporter())
    .build()
  let tracer = provider.into_tracer_provider().tracer("statuses")
  let app = @moonback.App(ctx => {
    ctx.add_middleware(@otelmoonback.new_middleware(tracer~, meter=test_meter))
    ctx.get("/ok", (_, res) => res.send_void(status=204))
    ctx.get("/busy", (_, res) => res.send_void(status=503))
    ctx.get("/fail", (_, _) => fail("database unavailable"))
    ctx.get("/partial", (_, res) => {
      res.send_text("partial", status=202)
      fail("after headers")
    })
  })
  defer app.close()
  @async.with_timeout(3000, () => {
    @async.with_task_group(group => {
      let listener = @moonback.listen()
      let serving = group.spawn(() => app.serve(listener))
      for
        (path, expected) in ["/ok", "/missing", "/busy", "/fail", "/partial"].zip([
            204, 404, 503, 500, 202,
          ],
        ) {
        let (response, _) = @http.get(
          "http://127.0.0.1:\{listener.addr.port()}\{path}",
        )
        assert_eq(response.code, expected)
      }
      serving.cancel()
    })
  })
  let spans = exporter.finished_spans()
  assert_eq(spans.length(), 5)
  for i in 0..<2 {
    assert_true(spans[i].status.code is @sdktrace.StatusCode::Unset)
  }
  for i in 2..<5 {
    assert_true(spans[i].status.code is @sdktrace.StatusCode::Error)
  }
  assert_eq(spans[2].events.length(), 0)
  assert_true(
    spans[2].attributes.contains(
      @common.KeyValue::new("error.type", String("503")),
    ),
  )
  assert_eq(spans[3].events.length(), 1)
  assert_eq(spans[3].events[0].name, "exception")
  assert_eq(
    spans[3].attributes
    .filter(kv => kv.key.as_string() == "http.response.status_code")
    .length(),
    0,
  )
  assert_true(
    spans[4].attributes.contains(
      @common.KeyValue::new("http.response.status_code", Int64(202L)),
    ),
  )
  assert_true(provider.shutdown() is Ok(_))
}

///|
async test "malformed propagation starts independent roots" {
  let exporter = @sdktrace.InMemorySpanExporter::new()
  let provider = @sdktrace.SdkTracerProvider::builder()
    .with_sampler(
      @sdktrace.Sampler::parent_based(@sdktrace.Sampler::always_on()),
    )
    .with_simple_exporter(exporter.into_span_exporter())
    .build()
  let tracer = provider.into_tracer_provider().tracer("propagation")
  let app = @moonback.App(ctx => {
    ctx.add_middleware(@otelmoonback.new_middleware(tracer~, meter=test_meter))
    ctx.get("/", (_, res) => res.send_void())
  })
  defer app.close()
  let invalid = [
    "bad", "00-00000000000000000000000000000000-00f067aa0ba902b7-01", "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01",
    "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01,00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
  ]
  @async.with_timeout(3000, () => {
    @async.with_task_group(group => {
      let listener = @moonback.listen()
      let serving = group.spawn(() => app.serve(listener))
      for value in invalid {
        let (response, _) = @http.get(
          "http://127.0.0.1:\{listener.addr.port()}/",
          headers={ "traceparent": value },
        )
        assert_eq(response.code, 200)
      }
      serving.cancel()
    })
  })
  let spans = exporter.finished_spans()
  assert_eq(spans.length(), invalid.length())
  for span in spans {
    assert_eq(span.parent_span_context, None)
    assert_true(span.span_context.is_valid())
    assert_eq(span.name, "GET")
  }
  assert_true(provider.shutdown() is Ok(_))
}

///|
async test "filter excludes exact paths and skips websocket upgrade" {
  let exporter = @sdktrace.InMemorySpanExporter::new()
  let provider = @sdktrace.SdkTracerProvider::builder()
    .with_sampler(
      @sdktrace.Sampler::parent_based(@sdktrace.Sampler::always_on()),
    )
    .with_simple_exporter(exporter.into_span_exporter())
    .build()
  let tracer = provider.into_tracer_provider().tracer("filter")
  let seen : Array[Bool] = []
  let metrics = @sdkmetrics.SdkMeterProvider::builder().build()
  let app = @moonback.App(ctx => {
    ctx.add_middleware(
      @otelmoonback.new_middleware(
        tracer~,
        meter=metrics.into_meter_provider().meter("filter"),
        filter=req => req.path != "/health" && req.path != "/private",
      ),
    )
    for path in ["/health", "/health/detail", "/private", "/public"] {
      ctx.get(path, (req, res) => {
        seen.push(@otelmoonback.get_context(req) is Some(_))
        res.send_text("ok")
      })
    }
    ctx.get("/ws", (req, res) => {
      assert_eq(@otelmoonback.get_context(req), None)
      let ws = res.upgrade(req)
      defer ws.close()
      ws.send_text("hello")
    })
  })
  defer app.close()
  @async.with_timeout(3000, () => {
    @async.with_task_group(group => {
      let listener = @moonback.listen()
      let serving = group.spawn(() => app.serve(listener))
      for path in ["/health", "/health/detail", "/private", "/public"] {
        let (_, body) = @http.get(
          "http://127.0.0.1:\{listener.addr.port()}\{path}",
        )
        assert_eq(body.text(), "ok")
      }
      let ws = @websocket.connect("ws://127.0.0.1:\{listener.addr.port()}/ws")
      defer ws.close()
      let message = ws.recv()
      assert_eq(message.read_all().text(), "hello")
      serving.cancel()
    })
  })
  @debug.assert_eq(seen, [false, true, false, true])
  assert_eq(exporter.finished_spans().length(), 2)
  let points = metrics.collect()
  assert_eq(points.length(), 1)
  guard points[0].aggregation is Histogram(summary) else {
    fail("expected histogram")
  }
  assert_eq(summary.count, 2L)
  assert_true(provider.shutdown() is Ok(_))
  assert_true(metrics.shutdown() is Ok(_))
}

///|
async test "route resolver and naming hooks include configured scheme" {
  let exporter = @sdktrace.InMemorySpanExporter::new()
  let provider = @sdktrace.SdkTracerProvider::builder()
    .with_sampler(
      @sdktrace.Sampler::parent_based(@sdktrace.Sampler::always_on()),
    )
    .with_simple_exporter(exporter.into_span_exporter())
    .build()
  let tracer = provider.into_tracer_provider().tracer("naming")
  let app = @moonback.App(ctx => {
    ctx.add_middleware(
      @otelmoonback.new_middleware(tracer~, meter=test_meter, scheme="https", span_name=(
        meth,
        route,
      ) => "api \{meth} \{route.unwrap_or("unknown")}"),
    )
    ctx.get("/api/:id", (req, res) => {
      @otelmoonback.set_route(req, "/api/:id")
      res.send_void()
    })
  })
  defer app.close()
  @async.with_timeout(3000, () => {
    @async.with_task_group(group => {
      let listener = @moonback.listen()
      let serving = group.spawn(() => app.serve(listener))
      ignore(@http.get("http://127.0.0.1:\{listener.addr.port()}/api/7"))
      serving.cancel()
    })
  })
  let spans = exporter.finished_spans()
  assert_eq(spans[0].name, "api GET /api/:id")
  assert_true(
    spans[0].attributes.contains(
      @common.KeyValue::new("url.scheme", String("https")),
    ),
  )
  assert_true(provider.shutdown() is Ok(_))
}

///|
async test "concurrent requests keep independent parent contexts" {
  let exporter = @sdktrace.InMemorySpanExporter::new()
  let provider = @sdktrace.SdkTracerProvider::builder()
    .with_sampler(
      @sdktrace.Sampler::parent_based(@sdktrace.Sampler::always_on()),
    )
    .with_simple_exporter(exporter.into_span_exporter())
    .build()
  let tracer = provider.into_tracer_provider().tracer("concurrent")
  let arrived = @async.Semaphore(1, initial_value=0)
  let release = @async.Semaphore(1, initial_value=0)
  let app = @moonback.App(ctx => {
    ctx.add_middleware(@otelmoonback.new_middleware(tracer~, meter=test_meter))
    ctx.get("/:id", (req, res) => {
      @otelmoonback.set_route(req, "/:id")
      let before = @otelmoonback.get_context(req).unwrap()
      arrived.release()
      release.acquire()
      assert_eq(@otelmoonback.get_context(req), Some(before))
      let child = tracer.start_with_context(req.params["id"], before)
      child.end()
      res.send_text(before.span_context().unwrap().trace_id().to_hex())
    })
  })
  defer app.close()
  @async.with_timeout(3000, () => {
    @async.with_task_group(group => {
      let listener = @moonback.listen()
      let serving = group.spawn(() => app.serve(listener))
      let a = group.spawn(() => {
        @http.get("http://127.0.0.1:\{listener.addr.port()}/a", headers={
          "traceparent": "00-11111111111111111111111111111111-1111111111111111-01",
        })
      })
      let b = group.spawn(() => {
        @http.get("http://127.0.0.1:\{listener.addr.port()}/b", headers={
          "traceparent": "00-22222222222222222222222222222222-2222222222222222-01",
        })
      })
      arrived.acquire()
      arrived.acquire()
      release.release()
      release.release()
      assert_eq(a.wait().1.text(), "11111111111111111111111111111111")
      assert_eq(b.wait().1.text(), "22222222222222222222222222222222")
      serving.cancel()
    })
  })
  let spans = exporter.finished_spans()
  assert_eq(spans.length(), 4)
  for child in spans.filter(span => span.name != "GET /:id") {
    let parent = spans
      .iter()
      .find_first(span => {
        span.span_context.span_id() ==
        child.parent_span_context.unwrap().span_id()
      })
      .unwrap()
    assert_eq(child.span_context.trace_id(), parent.span_context.trace_id())
  }
  assert_true(provider.shutdown() is Ok(_))
}

///|
async test "shutdown cancellation ends the span and records a cancelled outcome" {
  let exporter = @sdktrace.InMemorySpanExporter::new()
  let provider = @sdktrace.SdkTracerProvider::builder()
    .with_sampler(
      @sdktrace.Sampler::parent_based(@sdktrace.Sampler::always_on()),
    )
    .with_simple_exporter(exporter.into_span_exporter())
    .build()
  let tracer = provider.into_tracer_provider().tracer("cancel")
  let started = @async.Semaphore(1, initial_value=0)
  let blocked = @async.CondVar::Cond()
  let mut server_span = None
  let app = @moonback.App(
    ctx => {
      // Instrumentation must be inside cancel_on_shutdown's cancellation boundary.
      ctx.add_middleware(@moonback.cancel_on_shutdown())
      ctx.add_middleware(
        @otelmoonback.new_middleware(tracer~, meter=test_meter),
      )
      ctx.get("/", (req, _) => {
        server_span = @otelmoonback.get_span(req)
        started.release()
        blocked.wait()
      })
    },
    config=@moonback.Config(stop_timeout=0.01),
  )
  defer app.close()
  @async.with_timeout(3000, () => {
    @async.with_task_group(group => {
      let listener = @moonback.listen()
      let serving = group.spawn(() => app.serve(listener))
      let client = @socket.Tcp::connect_to_host(
        "127.0.0.1",
        port=listener.addr.port(),
      )
      defer client.close()
      client.write("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
      started.acquire()
      serving.cancel()
      serving.wait() catch {
        _ => ()
      }
    })
  })
  assert_true(server_span.unwrap().has_ended())
  let spans = exporter.finished_spans()
  assert_eq(spans.length(), 1)
  assert_true(spans[0].status.code is @sdktrace.StatusCode::Error)
  assert_eq(spans[0].events.length(), 0)
  assert_true(
    spans[0].attributes.contains(
      @common.KeyValue::new("error.type", String("cancelled")),
    ),
  )
  assert_true(provider.shutdown() is Ok(_))
}

///|
async test "unsampled parent keeps context and duration without exporting a span" {
  let exporter = @sdktrace.InMemorySpanExporter::new()
  let provider = @sdktrace.SdkTracerProvider::builder()
    .with_sampler(
      @sdktrace.Sampler::parent_based(@sdktrace.Sampler::always_on()),
    )
    .with_simple_exporter(exporter.into_span_exporter())
    .build()
  let tracer = provider.into_tracer_provider().tracer("sampling")
  let metrics = @sdkmetrics.SdkMeterProvider::builder().build()
  let mut context = None
  let app = @moonback.App(ctx => {
    ctx.add_middleware(
      @otelmoonback.new_middleware(
        tracer~,
        meter=metrics.into_meter_provider().meter("sampling"),
      ),
    )
    ctx.get("/", (req, res) => {
      context = @otelmoonback.get_context(req)
      assert_true(!@otelmoonback.get_span(req).unwrap().is_recording())
      res.send_void()
    })
  })
  defer app.close()
  @async.with_timeout(3000, () => {
    @async.with_task_group(group => {
      let listener = @moonback.listen()
      let serving = group.spawn(() => app.serve(listener))
      ignore(
        @http.get("http://127.0.0.1:\{listener.addr.port()}/", headers={
          "traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00",
        }),
      )
      serving.cancel()
    })
  })
  let span_context = context.unwrap().span_context().unwrap()
  assert_true(!span_context.is_sampled())
  assert_eq(
    span_context.trace_id().to_hex(),
    "4bf92f3577b34da6a3ce929d0e0e4736",
  )
  assert_eq(exporter.finished_spans().length(), 0)
  assert_eq(metrics.collect().length(), 1)
  assert_true(provider.shutdown() is Ok(_))
  assert_true(metrics.shutdown() is Ok(_))
}

///|
async test "export failure and slow export preserve HTTP outcomes" {
  for slow in [false, true] {
    let mut calls = 0
    let exporter = @sdktrace.SpanExporter::new(_ => {
      calls += 1
      if slow {
        @async.sleep(30)
      } else {
        fail("export transport failed")
      }
      Ok(())
    })
    let provider = @sdktrace.SdkTracerProvider::builder()
      .with_sampler(@sdktrace.Sampler::always_on())
      .with_simple_exporter(exporter)
      .build()
    let tracer = provider.into_tracer_provider().tracer("export")
    let app = @moonback.App(ctx => {
      ctx.add_middleware(
        @otelmoonback.new_middleware(tracer~, meter=test_meter),
      )
      ctx.get("/ok", (_, res) => res.send_text("ok"))
      ctx.get("/fail", (_, _) => fail("handler failed"))
    })
    defer app.close()
    @async.with_timeout(3000, () => {
      @async.with_task_group(group => {
        let listener = @moonback.listen()
        let serving = group.spawn(() => app.serve(listener))
        let (response, body) = @http.get(
          "http://127.0.0.1:\{listener.addr.port()}/ok",
        )
        assert_eq(response.code, 200)
        assert_eq(body.text(), "ok")
        let (response, _) = @http.get(
          "http://127.0.0.1:\{listener.addr.port()}/fail",
        )
        assert_eq(response.code, 500)
        serving.cancel()
      })
    })
    assert_eq(calls, 2)
    assert_true(provider.shutdown() is Ok(_))
  }
}

///|
async test "batch export is flushed and shut down by its owner" {
  let exporter = @sdktrace.InMemorySpanExporter::new()
  let provider = @sdktrace.SdkTracerProvider::builder()
    .with_sampler(@sdktrace.Sampler::always_on())
    .with_batch_exporter(exporter.into_span_exporter())
    .build()
  let tracer = provider.into_tracer_provider().tracer("batch")
  let app = @moonback.App(ctx => {
    ctx.add_middleware(@otelmoonback.new_middleware(tracer~, meter=test_meter))
    ctx.get("/", (_, res) => res.send_void())
  })
  @async.with_timeout(3000, () => {
    @async.with_task_group(group => {
      let listener = @moonback.listen()
      let serving = group.spawn(() => app.serve(listener))
      ignore(@http.get("http://127.0.0.1:\{listener.addr.port()}/"))
      serving.cancel()
    })
  })
  app.close()
  assert_true(!exporter.is_shutdown())
  assert_eq(exporter.finished_spans().length(), 0)
  assert_true(provider.force_flush() is Ok(_))
  assert_eq(exporter.finished_spans().length(), 1)
  assert_true(provider.shutdown() is Ok(_))
  assert_true(exporter.is_shutdown())
}

///|
async test "streaming duration includes handler writes and excludes export latency" {
  let finished = @sdktrace.InMemorySpanExporter::new()
  let exporter = @sdktrace.SpanExporter::new(batch => {
    @async.sleep(100)
    finished.into_span_exporter().export_batch(batch)
  })
  let provider = @sdktrace.SdkTracerProvider::builder()
    .with_sampler(@sdktrace.Sampler::always_on())
    .with_simple_exporter(exporter)
    .build()
  let tracer = provider.into_tracer_provider().tracer("stream")
  let metrics = @sdkmetrics.SdkMeterProvider::builder().build()
  let meter = metrics.into_meter_provider().meter("stream")
  let app = @moonback.App(ctx => {
    ctx.add_middleware(@otelmoonback.new_middleware(tracer~, meter~))
    ctx.get("/stream", (req, res) => {
      @otelmoonback.set_route(req, "/stream")
      let writer = res.respond(headers={ "Transfer-Encoding": "chunked" })
      writer.write("ab")
      writer.flush()
      @async.sleep(20)
      writer.write("cd")
    })
  })
  defer app.close()
  let start = @bench.monotonic_clock_start()
  @async.with_timeout(3000, () => {
    @async.with_task_group(group => {
      let listener = @moonback.listen()
      let serving = group.spawn(() => app.serve(listener))
      let (response, body) = @http.get(
        "http://127.0.0.1:\{listener.addr.port()}/stream",
      )
      assert_eq(response.code, 200)
      assert_eq(body.text(), "abcd")
      serving.cancel()
    })
  })
  let wall_seconds = @bench.monotonic_clock_end(start) / 1_000_000.0
  let point = metrics.collect()[0]
  guard point.aggregation is Histogram(summary) else {
    fail("expected histogram")
  }
  guard summary.sum is Double(duration) else { fail("expected seconds") }
  assert_true(duration >= 0.015)
  assert_true(wall_seconds - duration >= 0.08)
  assert_eq(finished.finished_spans().length(), 1)
  assert_true(provider.shutdown() is Ok(_))
  assert_true(metrics.shutdown() is Ok(_))
}
