# basic

Minimal runnable consumer example: one real HTTP request produces one SERVER
span, one child span and one duration data point, then exits.

Run:

```bash
moon run examples/basic --target native
```

## Lifecycle shown

1. Build an SdkTracerProvider / SdkMeterProvider, Sampler and exporter, then
   obtain public API handles via `into_tracer_provider()` /
   `into_meter_provider()` and pass them to `new_middleware`.
2. `cancel_on_shutdown` is registered first so the downstream cancellation it
   applies is observed by instrumentation.
3. The handler calls `set_route` first to annotate the route template, and
   `get_context` for an explicit parent when creating child spans.
4. After `serve` drains, call `app.close`, then `force_flush` / `shutdown`
   both providers within the app's budget and check the results.

## SDK operational notes

- Batch/Periodic setups need the app to call
  `spawn_batch_processor_tasks(group)` / `spawn_periodic_readers(group)` in a
  held `async.TaskGroup`; creating a batch exporter alone does not export on a
  schedule, and without workers an explicit `force_flush` is required.
- The SDK's `shutdown_with_timeout` currently forwards without enforcing a
  timeout; wrap the real shutdown in `protect_from_cancel` + `with_timeout`
  when a shutdown budget is needed.
- The 0.1.8 SimpleSpanProcessor ignores an `Err` returned by the exporter;
  wrap the exporter and record failures when export monitoring matters.
- This example uses an in-memory exporter for direct visibility; end-to-end
  delivery to a real collector is not verified.
