///|
extenum @moonback.TypedBox += {
  RequestSpan(@trace.Span)
  RouteTemplate(String)
}

///|
let span_key : @moonback.TypedKey[@trace.Span] = TypedKey(
  name="otelmoonback.span",
  box=span => RequestSpan(span),
  unbox=value => {
    match value {
      RequestSpan(span) => Some(span)
      _ => None
    }
  },
)

///|
let route_key : @moonback.TypedKey[String] = TypedKey(
  name="otelmoonback.route",
  box=route => RouteTemplate(route),
  unbox=value => {
    match value {
      RouteTemplate(route) => Some(route)
      _ => None
    }
  },
)

///|
/// Returns this request's server span, when instrumentation accepted the request.
pub fn get_span(req : @moonback.Request) -> @trace.Span? {
  req.ctx.get_userdata(span_key)
}

///|
/// Returns an explicit parent context for child spans and outbound propagation.
pub fn get_context(req : @moonback.Request) -> @otelcontext.Context? {
  get_span(req).map(span => span.context())
}

///|
/// Sets this request's full, low-cardinality route template, used for the
/// final span name, the `http.route` attribute, and duration labels.
/// Moonback does not expose the matched route, so call at the start of
/// the matched handler with the registered path. Include mount prefixes,
/// e.g. `/api/users/:id`.
pub fn set_route(req : @moonback.Request, template : String) -> Unit {
  req.ctx.set_userdata(route_key, template)
}

///|
/// Creates an HTTP server instrumentation middleware using caller-owned
/// OTel API objects.
///
/// `filter` accepts requests to instrument.
///
/// Each span starts with `span_name(http_method, None)`; a `set_route`
/// template refines the name through a second `span_name` call when the
/// handler returns. Keep `span_name` side-effect free.
/// A sent response records `http.response.status_code`; 5xx marks Error
/// status with `error.type` set to the code, other statuses stay Unset.
/// An error escaping the handler records an exception event and Error
/// status. Cancellation records Error status and `error.type="cancelled"`;
/// no HTTP status is guessed and no exception event is recorded.
///
/// Limits:
/// - Any request carrying an Upgrade header is passed through uninstrumented.
/// - Moonback sends its own fallback response outside this scope, so
/// `http.response.status_code` is omitted unless a status was already
/// sent before the handler's error.
#warnings("-fragile_catch_all")
pub fn new_middleware(
  tracer~ : @trace.Tracer,
  meter~ : @metrics.Meter,
  scheme~ : String = "http",
  filter~ : (@moonback.Request) -> Bool = _ => true,
  span_name~ : (String, String?) -> String = (meth, route) => {
    match route {
      Some(route) => "\{meth} \{route}"
      None => meth
    }
  },
) -> @moonback.Middleware {
  let propagator = @propagation.TraceContextPropagator::new()
  let duration = meter
    .f64_histogram("http.server.request.duration")
    .with_unit("s")
    .with_description(
      "Time spent in the Moonback handler and downstream middleware",
    )
    .build()
  @moonback.Middleware(next => {
    (req, res) => {
      if req.headers.get("Upgrade") is Some(_) || !filter(req) {
        next(req, res)
        return
      }
      let carrier : Map[String, String] = Map([])
      for field in propagator.into_text_map().fields() {
        let values = req.headers.get_all(field)
        if field == "tracestate" && !values.is_empty() {
          carrier[field] = values.map(value => value.to_owned()).join(",")
        } else if values.length() == 1 {
          carrier[field] = values[0].to_owned()
        }
      }
      let parent = propagator.extract_with_context(
        @otelcontext.Context::empty(),
        carrier,
      )
      let http_method = match req.meth {
        Get => "GET"
        Head => "HEAD"
        Post => "POST"
        Put => "PUT"
        Delete => "DELETE"
        Connect => "CONNECT"
        Options => "OPTIONS"
        Trace => "TRACE"
        Patch => "PATCH"
      }
      let attributes = [
        @common.KeyValue::new("http.request.method", String(http_method)),
        @common.KeyValue::new("url.scheme", String(scheme)),
      ]
      let span = tracer.build_with_context(
        @trace.SpanBuilder::from_name(span_name(http_method, None))
        .with_kind(Server)
        .with_attributes(attributes),
        parent,
      )
      req.ctx.set_userdata(span_key, span)
      let started = @bench.monotonic_clock_start()
      let mut status : Int32? = None
      let mut error_type : String? = None
      defer {
        // Capture duration before export, including stack unwinding and streaming
        // writes performed by the handler, but excluding exporter latency.
        let seconds = @bench.monotonic_clock_end(started) / 1_000_000.0
        if @async.is_being_cancelled() {
          error_type = Some("cancelled")
          span.set_status(@trace.Status::error())
        }
        let final_route = req.ctx.get_userdata(route_key)
        span.update_name(span_name(http_method, final_route))
        if final_route is Some(template) {
          let attribute = @common.KeyValue::new("http.route", String(template))
          span.set_attribute(attribute)
          attributes.push(attribute)
        }
        if status is Some(code) {
          let attribute = @common.KeyValue::new(
            "http.response.status_code",
            Int64(code.to_int64()),
          )
          span.set_attribute(attribute)
          attributes.push(attribute)
          if code >= 500 && code <= 599 {
            span.set_status(@trace.Status::error())
            if error_type is None {
              error_type = Some(code.to_string())
            }
          }
        }
        if error_type is Some(error_type) {
          let attribute = @common.KeyValue::new(
            "error.type",
            String(error_type),
          )
          span.set_attribute(attribute)
          attributes.push(attribute)
        }
        duration.record(seconds, attributes~)
        // Export failure must not replace the HTTP outcome.
        @async.protect_from_cancel(() => span.end()) catch {
          _ => ()
        }
      }
      next(
        req,
        @moonback.Responder((code, headers) => {
          let writer = res.respond(status=code, headers~)
          status = Some(code)
          writer
        }),
      ) catch {
        err => {
          if !@async.is_being_cancelled() {
            error_type = Some("handler_error")
            span.record_error(err.to_string())
            span.set_status(@trace.Status::error())
          }
          raise err
        }
      }
    }
  })
}
