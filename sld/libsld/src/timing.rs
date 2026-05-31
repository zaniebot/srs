//! Code for reporting linking phase timing and writing structured timing traces.
//!
//! `--time` prints the existing concise timing tree. Setting `SLD_TIMING_TRACE_OUT` to a file path
//! additionally writes an agent-readable JSON document containing both phase and detailed worker
//! spans. Structured tracing starts after argument parsing, before thread-pool activation.

use crate::args::CounterKind;
use crate::error::AlreadyInitialised;
use crate::error::Result;
use crate::perf::CounterList;
use anyhow::Context;
use anyhow::anyhow;
use crossbeam_queue::ArrayQueue;
use serde::Serialize;
use std::collections::BTreeMap;
use std::fmt::Display;
use std::io::Write;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::OnceLock;
use std::sync::atomic::AtomicU64;
use std::sync::atomic::Ordering;
use std::time::Duration;
use std::time::Instant;
use tracing::field::Visit;

const PERFETTO_ENV_VAR: &str = "SLD_PERFETTO_OUT";
const TIMING_TRACE_ENV_VAR: &str = "SLD_TIMING_TRACE_OUT";
const DETAILED_TIMING_TARGET: &str = "libsld::timing::detail";
const STRUCTURED_TIMING_TARGET: &str = "libsld::timing::structure";

static STRUCTURED_TRACE: OnceLock<Arc<StructuredTrace>> = OnceLock::new();

pub fn setup() -> Result {
    if perfetto_output_file().is_some() {
        perfetto_recorder::start().map_err(
            |_: perfetto_recorder::TracingDisabledAtBuildTime| {
                anyhow!("{PERFETTO_ENV_VAR} was set, but sld was built without --features perfetto")
            },
        )?;
    }
    Ok(())
}

#[macro_export]
macro_rules! timing_guard {
    ($($args:tt)*) => {
        (tracing::info_span!($($args)*).entered(), perfetto_recorder::start_span!($($args)*))
    };
}

#[macro_export]
macro_rules! timing_phase {
    ($($args:tt)*) => {
        let _guard = $crate::timing_guard!($($args)*);
    };
}

/// More verbose timing instrumentation that by default doesn't show up in the output of --time.
/// Suitable for use from threads other than main.
#[macro_export]
macro_rules! verbose_timing_phase {
    ($($args:tt)*) => {
        let _structured_timing_guard = $crate::timing_trace_requested()
            .then(|| tracing::info_span!(target: "libsld::timing::detail", $($args)*).entered());
        perfetto_recorder::scope!($($args)*);
    };
}

struct TimingLayer {
    counter_pool: Option<ArrayQueue<CounterList>>,
    print_human_output: bool,
    structured_trace: Option<Arc<StructuredTrace>>,
}

struct Data {
    start: Instant,
    child_count: u32,
    attributes_string: String,
    counters: Option<CounterList>,
    detailed: bool,
    human_visible: bool,
    trace_span: Option<TraceSpanStart>,
}

#[derive(Default)]
pub struct ValuesFormatter {
    out: String,
    structured: BTreeMap<String, String>,
}

impl ValuesFormatter {
    fn finish(mut self) -> String {
        if !self.out.is_empty() {
            self.out.push(']');
        }
        self.out
    }

    fn structured(&self) -> BTreeMap<String, String> {
        self.structured.clone()
    }
}

impl Visit for ValuesFormatter {
    fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
        use std::fmt::Write;

        let value = format!("{value:?}");
        self.structured
            .insert(field.name().to_owned(), value.clone());

        if self.out.is_empty() {
            write!(&mut self.out, " [").unwrap();
        } else {
            write!(&mut self.out, ", ").unwrap();
        }
        match field.name() {
            "message" => {
                write!(&mut self.out, "{value}").unwrap();
            }
            name => {
                write!(&mut self.out, "{name}={value}").unwrap();
            }
        }
    }
}

struct StructuredTrace {
    start: Instant,
    next_span_id: AtomicU64,
    spans: Mutex<Vec<RecordedSpan>>,
}

struct TraceSpanStart {
    id: u64,
    parent_id: Option<u64>,
    thread_id: String,
    start_ns: u64,
    attributes: BTreeMap<String, String>,
}

#[derive(Debug, Serialize)]
struct TraceDocument<'a> {
    format: &'static str,
    schema_version: u32,
    clock: &'static str,
    time_unit: &'static str,
    capture_start: &'static str,
    semantics: TraceSemantics,
    spans: &'a [RecordedSpan],
}

#[derive(Debug, Serialize)]
struct TraceSemantics {
    invocation: &'static str,
    interval: &'static str,
    parent_id: &'static str,
    thread_id: &'static str,
    parallel_work: &'static str,
    detail: &'static str,
}

#[derive(Debug, Serialize)]
struct RecordedSpan {
    id: u64,
    parent_id: Option<u64>,
    name: String,
    detail: bool,
    thread_id: String,
    start_ns: u64,
    duration_ns: u64,
    attributes: BTreeMap<String, String>,
}

impl StructuredTrace {
    fn new() -> Self {
        Self {
            start: Instant::now(),
            next_span_id: AtomicU64::new(1),
            spans: Mutex::new(Vec::new()),
        }
    }

    fn start_span(
        &self,
        parent_id: Option<u64>,
        attributes: BTreeMap<String, String>,
    ) -> TraceSpanStart {
        TraceSpanStart {
            id: self.next_span_id.fetch_add(1, Ordering::Relaxed),
            parent_id,
            thread_id: format!("{:?}", std::thread::current().id()),
            start_ns: duration_ns(self.start.elapsed()),
            attributes,
        }
    }

    fn finish_span(&self, name: &str, detailed: bool, start: TraceSpanStart) {
        self.spans
            .lock()
            .expect("structured timing trace mutex poisoned")
            .push(RecordedSpan {
                id: start.id,
                parent_id: start.parent_id,
                name: name.to_owned(),
                detail: detailed,
                thread_id: start.thread_id,
                start_ns: start.start_ns,
                duration_ns: duration_ns(self.start.elapsed()).saturating_sub(start.start_ns),
                attributes: start.attributes,
            });
    }

    fn write_to_file(&self, path: &std::path::Path) -> Result {
        let mut spans = self
            .spans
            .lock()
            .expect("structured timing trace mutex poisoned");
        spans.sort_unstable_by_key(|span| (span.start_ns, span.id));

        let file = std::fs::File::create(path)
            .with_context(|| format!("Failed to create timing trace `{}`", path.display()))?;
        let mut writer = std::io::BufWriter::new(file);
        serde_json::to_writer_pretty(
            &mut writer,
            &TraceDocument {
                format: "sld-timing-trace",
                schema_version: 1,
                clock: "monotonic",
                time_unit: "nanoseconds",
                capture_start: "after_argument_parsing_before_thread_pool_activation",
                semantics: TraceSemantics {
                    invocation: "The single detail=false Invocation interval covers all recorded work and is the measured linker wall-time interval for this trace.",
                    interval: "Each span covers [start_ns, start_ns + duration_ns).",
                    parent_id: "A parent is present only for a span created inside another recorded span on the same tracing execution context.",
                    thread_id: "Thread identifiers are opaque and comparable only within this trace.",
                    parallel_work: "Overlapping spans may run concurrently; do not sum durations to obtain wall time.",
                    detail: "detail=false records coarse phases also visible with --time; detail=true records fine-grained work, including parallel worker activity.",
                },
                spans: &spans,
            },
        )
        .with_context(|| format!("Failed to serialize timing trace `{}`", path.display()))?;
        writeln!(writer)?;

        Ok(())
    }
}

fn duration_ns(duration: Duration) -> u64 {
    duration.as_nanos().try_into().unwrap_or(u64::MAX)
}

impl<S> tracing_subscriber::Layer<S> for TimingLayer
where
    S: tracing::Subscriber + for<'span> tracing_subscriber::registry::LookupSpan<'span>,
{
    fn max_level_hint(&self) -> Option<tracing::level_filters::LevelFilter> {
        Some(tracing::level_filters::LevelFilter::INFO)
    }

    fn on_new_span(
        &self,
        attributes: &tracing::span::Attributes,
        id: &tracing::span::Id,
        ctx: tracing_subscriber::layer::Context<S>,
    ) {
        if *attributes.metadata().level() > tracing::Level::INFO {
            return;
        }
        let span = ctx.span(id).expect("valid span ID");

        let mut formatted = ValuesFormatter::default();
        attributes.values().record(&mut formatted);

        let detailed = attributes.metadata().target() == DETAILED_TIMING_TARGET;
        if detailed && self.structured_trace.is_none() {
            return;
        }
        let human_visible = attributes.metadata().target() != STRUCTURED_TIMING_TARGET;

        let counters = (!detailed && human_visible)
            .then(|| self.counter_pool.as_ref().and_then(|list| list.pop()))
            .flatten();
        let parent_id = span.parent().and_then(|parent| {
            parent
                .extensions()
                .get::<Data>()?
                .trace_span
                .as_ref()
                .map(|s| s.id)
        });
        let trace_span = self
            .structured_trace
            .as_ref()
            .map(|trace| trace.start_span(parent_id, formatted.structured()));

        span.extensions_mut().insert(Data {
            start: Instant::now(),
            counters,
            child_count: 0,
            attributes_string: formatted.finish(),
            detailed,
            human_visible,
            trace_span,
        });
    }

    fn on_enter(&self, id: &tracing::span::Id, ctx: tracing_subscriber::layer::Context<S>) {
        let span = ctx.span(id).expect("valid span ID");
        if let Some(data) = span.extensions_mut().get_mut::<Data>() {
            data.start = Instant::now();
            if let Some(counters) = data.counters.as_mut() {
                counters.start();
            }
        }
    }

    fn on_close(&self, id: tracing::span::Id, ctx: tracing_subscriber::layer::Context<S>) {
        let span = ctx.span(&id).expect("valid span ID");
        let metadata = span.metadata();
        if *metadata.level() > tracing::Level::INFO {
            return;
        }

        if let Some(data) = span.extensions_mut().get_mut::<Data>() {
            let trace_span = data.trace_span.take();
            if let Some(trace_span) = trace_span
                && let Some(trace) = self.structured_trace.as_ref()
            {
                trace.finish_span(metadata.name(), data.detailed, trace_span);
            }
            if data.detailed || !data.human_visible || !self.print_human_output {
                return;
            }

            let parent_child_count = span
                .parent()
                .and_then(|parent| {
                    parent
                        .extensions_mut()
                        .get_mut::<Data>()
                        .and_then(|parent_data| {
                            parent_data.human_visible.then(|| {
                                parent_data.child_count += 1;
                                parent_data.child_count
                            })
                        })
                })
                .unwrap_or(0);
            let scope_depth = span
                .scope()
                .filter(|scope| scope.metadata().target() != STRUCTURED_TIMING_TARGET)
                .count()
                - 1;
            let name = metadata.name();
            let wall = data.start.elapsed();

            let mut counters = data.counters.take();

            let counter_values = counters
                .as_mut()
                .map(|c| c.disable_and_read())
                .unwrap_or_default();

            if let Some(counters) = counters
                && let Some(pool) = self.counter_pool.as_ref()
            {
                let _ = pool.push(counters);
            }

            let reading = Reading {
                wall,
                counter_values,
            };

            let indent = Indent {
                scope_depth,
                child_count: data.child_count,
                parent_child_count,
            };

            println!("{indent}{reading} {name}{}", data.attributes_string);
        };
    }
}

pub(crate) fn timing_trace_requested() -> bool {
    timing_trace_output_file().is_some()
}

pub(crate) fn structured_invocation_guard() -> Option<tracing::span::EnteredSpan> {
    timing_trace_requested()
        .then(|| tracing::info_span!(target: STRUCTURED_TIMING_TARGET, "Invocation").entered())
}

pub(crate) fn init_tracing(
    opts: &[CounterKind],
    print_human_output: bool,
) -> Result<(), AlreadyInitialised> {
    use tracing_subscriber::prelude::*;

    let mut counter_pool = None;

    if print_human_output && !opts.is_empty() {
        // Our pool size limits the depth of nested measurements. At the time of writing, we don't
        // have more than 4 levels. Note, we need to create all counters now and can't create more
        // on-demand, since once our worker threads are started, any newly created counters won't
        // apply to them.
        let pool_size = 5;

        let pool = ArrayQueue::new(pool_size);
        for _ in 0..pool_size {
            let _ = pool.push(CounterList::from_kinds(opts));
        }

        counter_pool = Some(pool);
    }

    let structured_trace = timing_trace_requested().then(|| Arc::new(StructuredTrace::new()));
    let layer = TimingLayer {
        counter_pool,
        print_human_output,
        structured_trace: structured_trace.clone(),
    };

    let subscriber = tracing_subscriber::Registry::default().with(layer);
    tracing::subscriber::set_global_default(subscriber).map_err(|_| AlreadyInitialised)?;
    if let Some(trace) = structured_trace {
        let _ = STRUCTURED_TRACE.set(trace);
    }
    Ok(())
}

struct Reading {
    wall: Duration,
    counter_values: Vec<u64>,
}

struct Indent {
    scope_depth: usize,
    parent_child_count: u32,
    child_count: u32,
}

impl Display for Indent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if self.scope_depth == 0 {
            write!(f, "└─")?;
            return Ok(());
        }
        for _ in 0..self.scope_depth - 1 {
            write!(f, "│ ")?;
        }
        if self.parent_child_count >= 2 {
            write!(f, "├─")?;
        } else {
            write!(f, "┌─")?;
        }
        if self.child_count > 0 {
            write!(f, "┴─")?;
        } else {
            write!(f, "──")?;
        }
        Ok(())
    }
}

impl Display for Reading {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let ms = self.wall.as_secs_f64() * 1000.0;
        write!(f, "{ms:>8.2}")?;

        if !self.counter_values.is_empty() {
            write!(f, " (")?;
            let mut first = true;
            for value in &self.counter_values {
                if first {
                    first = false;
                } else {
                    write!(f, ", ")?;
                }
                write!(f, "{value}")?;
            }
            write!(f, ")")?;
        }

        Ok(())
    }
}

fn perfetto_output_file() -> Option<PathBuf> {
    std::env::var(PERFETTO_ENV_VAR).ok().map(PathBuf::from)
}

fn timing_trace_output_file() -> Option<&'static std::path::Path> {
    static OUTPUT_FILE: OnceLock<Option<PathBuf>> = OnceLock::new();

    OUTPUT_FILE
        .get_or_init(|| std::env::var(TIMING_TRACE_ENV_VAR).ok().map(PathBuf::from))
        .as_deref()
}

pub(crate) fn finalise_traces() -> Result {
    finalise_structured_trace()?;
    finalise_perfetto_trace()
}

fn finalise_structured_trace() -> Result {
    let Some(path) = timing_trace_output_file() else {
        return Ok(());
    };
    let trace = STRUCTURED_TRACE.get().context(
        "SLD_TIMING_TRACE_OUT was set, but structured timing tracing was not initialised",
    )?;
    trace.write_to_file(path)
}

fn finalise_perfetto_trace() -> Result {
    let Some(path) = perfetto_output_file() else {
        return Ok(());
    };

    let mut trace = perfetto_recorder::TraceBuilder::new()?;

    trace.process_thread_data(&perfetto_recorder::ThreadTraceData::take_current_thread());
    let trace = Mutex::new(trace);

    rayon::in_place_scope(|scope| {
        scope.spawn_broadcast(|_scope, _ctx| {
            trace
                .lock()
                .unwrap()
                .process_thread_data(&perfetto_recorder::ThreadTraceData::take_current_thread());
        });
    });

    trace
        .into_inner()
        .unwrap()
        .write_to_file(&path)
        .with_context(|| format!("Failed to write perfetto trace to `{}`", path.display()))?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tracing_subscriber::layer::SubscriberExt;

    #[test]
    fn structured_trace_describes_nested_detail_spans() {
        let trace = Arc::new(StructuredTrace::new());
        let subscriber = tracing_subscriber::Registry::default().with(TimingLayer {
            counter_pool: None,
            print_human_output: true,
            structured_trace: Some(trace.clone()),
        });

        tracing::subscriber::with_default(subscriber, || {
            let _invocation = tracing::info_span!(
                target: STRUCTURED_TIMING_TARGET,
                "Invocation"
            )
            .entered();
            let _outer = crate::timing_guard!("Link", invocation = "test");
            {
                let _detail = tracing::info_span!(
                    target: "libsld::timing::detail",
                    "Read symbols",
                    file_count = 2
                )
                .entered();
            }
        });

        let directory = tempfile::tempdir().expect("create timing trace test directory");
        let path = directory.path().join("timing.json");
        trace
            .write_to_file(&path)
            .expect("write structured timing trace");
        let bytes = std::fs::read(path).expect("read structured timing trace");
        let document: serde_json::Value =
            serde_json::from_slice(&bytes).expect("parse structured timing trace");
        let spans = document["spans"]
            .as_array()
            .expect("structured timing trace spans array");
        let link = spans
            .iter()
            .find(|span| span["name"] == "Link")
            .expect("coarse Link span");
        let invocation = spans
            .iter()
            .find(|span| span["name"] == "Invocation")
            .expect("root Invocation span");
        let read_symbols = spans
            .iter()
            .find(|span| span["name"] == "Read symbols")
            .expect("detailed Read symbols span");

        assert_eq!(document["format"], "sld-timing-trace");
        assert_eq!(document["schema_version"], 1);
        assert_eq!(document["clock"], "monotonic");
        assert_eq!(document["time_unit"], "nanoseconds");
        assert_eq!(
            document["capture_start"],
            "after_argument_parsing_before_thread_pool_activation"
        );
        assert_eq!(
            document["semantics"]["invocation"],
            "The single detail=false Invocation interval covers all recorded work and is the measured linker wall-time interval for this trace."
        );
        assert_eq!(
            document["semantics"]["parallel_work"],
            "Overlapping spans may run concurrently; do not sum durations to obtain wall time."
        );
        assert_eq!(link["parent_id"], invocation["id"]);
        assert_eq!(invocation["parent_id"], serde_json::Value::Null);
        assert_eq!(invocation["detail"], false);
        assert_eq!(read_symbols["parent_id"], link["id"]);
        assert_eq!(link["detail"], false);
        assert_eq!(read_symbols["detail"], true);
        assert_eq!(link["attributes"]["invocation"], "\"test\"");
        assert_eq!(read_symbols["attributes"]["file_count"], "2");
        assert!(read_symbols["start_ns"].as_u64().is_some());
        assert!(read_symbols["duration_ns"].as_u64().is_some());
        assert!(read_symbols["thread_id"].as_str().is_some());
    }
}
