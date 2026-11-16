// Compile- and link-level check that a packaged Node bundle can be embedded the
// way Godot's JavaScript module needs it: the engine keeps its own main loop and
// its own isolate, Node must not take over the process, and everything Node needs
// has to come out of the archives in the bundle.
//
// Built and run by verify_node_bundle.sh. It only includes headers that Node's own
// header install step ships (node.h, node_api.h, node_buffer.h, v8.h, uv.h), so
// what passes here is what a bundle built from a public header set supports.
// Anything that needs Node's private src/ headers is deliberately left out.

#include "node.h"
#include "node_api.h"
#include "node_buffer.h"
#include "uv.h"
#include "v8.h"
#include "cppgc/platform.h"
// GodotJS's V8 layer pulls these two in through its precompiled header, and the
// debugger derives from the inspector interfaces. Node's header installer does
// not ship them, so package_node.sh copies them out of deps/v8/include; naming
// them here is what proves they arrived and still spell the same.
#include "v8-inspector.h"
#include "v8-version-string.h"

#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

#if !defined(_WIN32)
#  include <fcntl.h>
#endif

namespace {

std::vector<std::string> failures;

void Fail(const std::string& step, const std::string& detail) {
  failures.push_back(step + ": " + detail);
  // Printed straight away as well: a check that crashes the process later would
  // otherwise take its diagnosis with it.
  std::fprintf(stderr, "  FAIL %s - %s\n", step.c_str(), detail.c_str());
}

void Ok(const std::string& step, const std::string& detail) {
  std::fprintf(stderr, "  ok  %s - %s\n", step.c_str(), detail.c_str());
}

void Note(const std::string& step, const std::string& detail) {
  std::fprintf(stderr, "  --  %s - %s\n", step.c_str(), detail.c_str());
}

#define CHECK(step, condition, detail)                                       \
  do {                                                                       \
    if (condition) Ok(step, detail);                                         \
    else Fail(step, detail);                                                 \
  } while (0)

// ---------------------------------------------------------------------------
// 1. RTTI
// ---------------------------------------------------------------------------

// Godot installs its own ArrayBuffer allocator: a class derived from a V8
// abstract base. Node builds itself with -fno-rtti, so unless the bundle was
// rebuilt with RTTI on, the link fails on "undefined reference to typeinfo for
// v8::ArrayBuffer::Allocator".
class HostArrayBufferAllocator : public v8::ArrayBuffer::Allocator {
 public:
  void* Allocate(size_t length) override { return AllocateUninitialized(length); }
  void* AllocateUninitialized(size_t length) override { return std::malloc(length); }
  void Free(void* data, size_t) override { std::free(data); }
};

// Named, never constructed: these are the shapes bridge/jsb_debugger.cpp relies
// on (it derives from Channel and V8InspectorClient, and calls create()).
namespace inspector_names {
using Channel = v8_inspector::V8Inspector::Channel;
using Client = v8_inspector::V8InspectorClient;
using Session = v8_inspector::V8InspectorSession;
using ContextInfo = v8_inspector::V8ContextInfo;
using Buffer = v8_inspector::StringBuffer;
using View = v8_inspector::StringView;
using Create = decltype(&v8_inspector::V8Inspector::create);
[[maybe_unused]] constexpr v8_inspector::V8Inspector::ClientTrustLevel kTrustLevel =
    v8_inspector::V8Inspector::ClientTrustLevel::kFullyTrusted;
}  // namespace inspector_names

// A N-API symbol is what a .node addon needs; taking its address proves the
// symbol is in the archives without registering anything.
extern "C" napi_status napi_get_version(napi_env env, uint32_t* result);

void CheckHeaders(const std::string& step) {
  // Headers and library have to come from the same build: a V8 header tree over a
  // different V8 library links fine and then fails in ways that look like memory
  // corruption. V8_VERSION_STRING is compiled from the shipped v8-version.h,
  // GetVersion() comes out of the archives.
  const char* library_version = v8::V8::GetVersion();
  const size_t header_length = std::strlen(V8_VERSION_STRING);
  const bool same =
      library_version != nullptr &&
      std::strncmp(V8_VERSION_STRING, library_version, header_length) == 0;
  CHECK(step, same,
        std::string("V8 headers say ") + V8_VERSION_STRING + ", the library reports " +
            (library_version != nullptr ? library_version : "(nothing)") +
            ", and the inspector names the debugger uses are present");
}

void CheckRtti(const std::string& step) {
  std::shared_ptr<node::ArrayBufferAllocator> node_allocator =
      node::ArrayBufferAllocator::Create();
  std::shared_ptr<HostArrayBufferAllocator> host_allocator =
      std::make_shared<HostArrayBufferAllocator>();
  void* pointer = host_allocator->Allocate(64);
  const bool rtti_works =
      dynamic_cast<v8::ArrayBuffer::Allocator*>(host_allocator.get()) != nullptr &&
      pointer != nullptr;
  host_allocator->Free(pointer, 64);
  CHECK(step,
        rtti_works && node_allocator != nullptr,
        "a class derived from v8::ArrayBuffer::Allocator links and dynamic_casts");
  CHECK(step, &napi_get_version != nullptr,
        "N-API entry points are in the archives (napi_get_version)");
}

// ---------------------------------------------------------------------------
// 2. Node leaves the host process alone
// ---------------------------------------------------------------------------

void NoopSignalHandler(int signal_number) { (void)signal_number; }

// Which file stdout/stderr were before Node got a chance to rearrange them.
struct StdioIdentity {
  dev_t dev;
  ino_t ino;
};

StdioIdentity StdioOf(int fd) {
  struct stat info;
  if (fstat(fd, &info) != 0) return StdioIdentity{0, 0};
  return StdioIdentity{info.st_dev, info.st_ino};
}

StdioIdentity stdout_before_init = StdioOf(STDOUT_FILENO);
StdioIdentity stderr_before_init = StdioOf(STDERR_FILENO);

// An engine that embeds Node must not inherit Node's idea of what a process looks
// like: the terminal, the resource limits, and the signal handlers belong to the
// engine. Node 26 makes each of these an opt-out, and the bundle has to honour
// them; this runs after InitializeOncePerProcess() so it measures the real thing.
void CheckNodeLeavesProcessAlone(const std::string& step) {
#if !defined(_WIN32)
  struct rlimit nofile;
  if (getrlimit(RLIMIT_NOFILE, &nofile) == 0) {
    CHECK(step, nofile.rlim_cur > 512,
          "RLIMIT_NOFILE was not lowered for the process (soft " +
              std::to_string(static_cast<long>(nofile.rlim_cur)) + ")");
  } else {
    Fail(step, "getrlimit(RLIMIT_NOFILE) failed");
  }

  // Node's default startup redirects stdout/stderr to temporary files when it
  // owns the stdio setup. With the embedder flags used here the two descriptors
  // have to still be the same file they were before Node started - which is what
  // this compares, because "is it seekable" is not a usable answer when the
  // harness redirects the output to a log file.
  fflush(stdout);
  const StdioIdentity stdout_now = StdioOf(STDOUT_FILENO);
  const StdioIdentity stderr_now = StdioOf(STDERR_FILENO);
  CHECK(step,
        stdout_now.dev == stdout_before_init.dev &&
            stdout_now.ino == stdout_before_init.ino &&
            stderr_now.dev == stderr_before_init.dev &&
            stderr_now.ino == stderr_before_init.ino,
        "stdout and stderr are still the same files Node was started with");

  struct sigaction action;
  std::memset(&action, 0, sizeof(action));
  action.sa_handler = NoopSignalHandler;
  sigemptyset(&action.sa_mask);
  struct sigaction before;
  if (sigaction(SIGUSR2, nullptr, &before) == 0 && sigaction(SIGUSR2, &action, nullptr) == 0) {
    const bool ours_after_init = before.sa_handler == SIG_DFL ||
                                 before.sa_handler == SIG_IGN ||
                                 before.sa_handler == NoopSignalHandler;
    CHECK(step, ours_after_init,
          "Node did not install a handler for SIGUSR2 during startup");
    raise(SIGUSR2);
  } else {
    Note(step, "SIGUSR2 is not usable here, skipped");
  }
#endif
}

// ---------------------------------------------------------------------------
// 3. The host drives the event loop
// ---------------------------------------------------------------------------

// Godot pumps the loop once per frame with uv_run(UV_RUN_NOWAIT). If Node wanted
// to own the loop, this is where it shows: the callback either never runs or the
// call does not return.
void CheckHostOwnsEventLoop(const std::string& step,
                            node::MultiIsolatePlatform* platform,
                            uv_loop_t* loop) {
  int fired = 0;
  uv_timer_t timer;
  uv_timer_init(loop, &timer);
  timer.data = &fired;
  uv_timer_start(
      &timer,
      [](uv_timer_t* handle) { *static_cast<int*>(handle->data) += 1; },
      10,
      0);

  const uint64_t deadline = uv_hrtime() + 2ull * 1000 * 1000 * 1000;
  do {
    uv_run(loop, UV_RUN_NOWAIT);
    platform->DrainTasks(v8::Isolate::GetCurrent());
    if (uv_hrtime() > deadline) break;
  } while (fired == 0);

  CHECK(step, fired == 1, "one uv_run(UV_RUN_NOWAIT) pass ran a libuv timer");
  // Stopping a handle is not closing one: uv_loop_close() reports the loop busy
  // until every handle is closed and the close callbacks have run.
  uv_timer_stop(&timer);
  uv_close(reinterpret_cast<uv_handle_t*>(&timer), [](uv_handle_t* handle) {
    (void)handle;
  });
  for (int i = 0; i < 10; i++) uv_run(loop, UV_RUN_NOWAIT);
}

// ---------------------------------------------------------------------------
// 4. A Node Environment that can run JS and be stopped
// ---------------------------------------------------------------------------

// V8 14 removed Value::GetIsolate() and Context::GetIsolate(), so anything that
// needs the isolate has to be given it.
v8::Local<v8::Function> MakeFunction(v8::Isolate* isolate,
                                     v8::Local<v8::Context> context,
                                     const char* source) {
  v8::EscapableHandleScope handle_scope(isolate);
  v8::Local<v8::String> text;
  if (!v8::String::NewFromUtf8(isolate, source).ToLocal(&text)) return {};
  v8::Local<v8::Script> compiled;
  if (!v8::Script::Compile(context, text).ToLocal(&compiled)) return {};
  v8::Local<v8::Value> value;
  if (!compiled->Run(context).ToLocal(&value)) return {};
  if (!value->IsFunction()) return {};
  return handle_scope.Escape(value.As<v8::Function>());
}

// Runs `source` in `context` and reports a JS exception instead of crashing.
bool RunScript(const std::string& step,
               v8::Isolate* isolate,
               v8::Local<v8::Context> context,
               const char* source,
               const std::string& what) {
  v8::TryCatch try_catch(isolate);
  v8::Local<v8::String> text;
  if (!v8::String::NewFromUtf8(isolate, source).ToLocal(&text)) {
    Fail(step, std::string("could not read the script text for ") + what);
    return false;
  }
  v8::Local<v8::Script> compiled;
  if (!v8::Script::Compile(context, text).ToLocal(&compiled)) {
    v8::String::Utf8Value message(isolate, try_catch.Exception());
    Fail(step, std::string(what) + " did not compile: " + (*message ? *message : "?"));
    return false;
  }
  v8::Local<v8::Value> result;
  if (!compiled->Run(context).ToLocal(&result)) {
    v8::String::Utf8Value message(isolate, try_catch.Exception());
    Fail(step, std::string(what) + " threw: " + (*message ? *message : "?"));
    return false;
  }
  Ok(step, what);
  return true;
}

// Returns the setup it built, so that the caller can destroy it after these V8
// scopes are gone: disposing an isolate while the thread still has it entered
// aborts V8 ("v8::Isolate::Deinitialize() Deinitializing the isolate that is
// entered by a thread").
void CheckEnvironment(const std::string& step,
                      node::MultiIsolatePlatform* platform,
                      std::unique_ptr<node::CommonEnvironmentSetup>* keep_alive) {
  std::vector<std::string> args = {"node", "node_link_probe"};
  std::vector<std::string> exec_args;
  std::vector<std::string> errors;
  std::unique_ptr<node::CommonEnvironmentSetup> setup =
      node::CommonEnvironmentSetup::Create(platform, &errors, args, exec_args);
  if (setup == nullptr) {
    std::string joined;
    for (const std::string& error : errors) joined += error + " | ";
    Fail(step, "CommonEnvironmentSetup::Create() failed: " + joined);
    return;
  }
  Ok(step, "CommonEnvironmentSetup created isolate, context and environment");

  v8::Isolate* isolate = setup->isolate();
  uv_loop_t* loop = setup->event_loop();
  {
    v8::Isolate::Scope isolate_scope(isolate);
    v8::HandleScope handle_scope(isolate);
    // setup->context() hands out a handle, so the scope has to be open before it is
    // called; V8 aborts with "Cannot create a handle without a HandleScope" if not.
    v8::Local<v8::Context> context = setup->context();
    CHECK(step, isolate != nullptr && !context.IsEmpty() && loop != nullptr,
          "isolate(), context() and event_loop() are all reachable from node.h");
    v8::Context::Scope context_scope(context);

  // CommonEnvironmentSetup gives you the isolate, the context and the Environment,
  // but the JavaScript side - process, the streams, the built-in modules - only
  // exists after LoadEnvironment() has run Node's bootstrap against a main module.
  // An embedder that skips this finds process.getBuiltinModule missing.
  {
    v8::TryCatch bootstrap_catch(isolate);
    v8::MaybeLocal<v8::Value> bootstrap =
        node::LoadEnvironment(setup->env(), "'probe bootstrap';");
    CHECK(step, !bootstrap.IsEmpty() && !bootstrap_catch.HasCaught(),
          "node::LoadEnvironment() ran Node's bootstrap (process, streams, built-ins)");
  }

  // The built-in modules. Each of these pulls in an archive that a link line
  // without --whole-archive would drop: fs (zlib and the bindings), crypto
  // (OpenSSL), and the whole built-in JavaScript bundle.
  //
  // process.getBuiltinModule() is used instead of require(): require is not a
  // global in Node, it only exists inside the module loader, and a script an
  // embedder compiles itself runs outside of that loader.
  RunScript(step, isolate, context,
            "{ const assert = process.getBuiltinModule('node:assert');"
            "const fs = process.getBuiltinModule('node:fs');"
            "const os = process.getBuiltinModule('node:os');"
            "const crypto = process.getBuiltinModule('node:crypto');"
            "const zlib = process.getBuiltinModule('node:zlib');"
            "assert.strictEqual(fs.readFileSync('/dev/null').length, 0);"
            "assert.ok(os.platform().length > 0);"
            "assert.strictEqual(crypto.createHash('sha256').update('x').digest('hex').length, 64);"
            "assert.strictEqual(zlib.gunzipSync(zlib.gzipSync(Buffer.from('abcdefghij'))).toString(), 'abcdefghij');"
            "'built-in modules loaded'; }",
            "process.getBuiltinModule() of fs/os/crypto/zlib works");

  // Whether this bundle has the Temporal API is a build-time decision, not a detail:
  // Temporal is Rust code in deps/crates, and ./configure drops it - with a single
  // warning line - when cargo is missing or too old. The manifest records which way the
  // build went, and verify_node_bundle.sh passes that here, so a bundle whose manifest
  // and live runtime disagree fails instead of surprising somebody at runtime.
  {
    const char* requested = std::getenv("NODE_PROBE_TEMPORAL");
    const std::string expected = requested != nullptr ? std::string(requested) : "unknown";
    bool present = false;
    v8::TryCatch temporal_catch(isolate);
    v8::Local<v8::String> temporal_text;
    if (v8::String::NewFromUtf8(isolate, "typeof Temporal == 'undefined' ? 0 : 1")
            .ToLocal(&temporal_text)) {
      v8::Local<v8::Script> temporal_script;
      v8::Local<v8::Value> temporal_value;
      if (v8::Script::Compile(context, temporal_text).ToLocal(&temporal_script) &&
          temporal_script->Run(context).ToLocal(&temporal_value)) {
        present = temporal_value->Uint32Value(context).FromMaybe(0) == 1;
      }
    }
    const std::string found = present ? "present" : "absent";
    if (expected == "yes" && !present) {
      Fail(step, "manifest says this bundle has Temporal, but the runtime has no Temporal");
    } else if (expected == "no" && present) {
      Fail(step, "manifest says this bundle was built without Temporal, but the runtime has it");
    } else {
      Ok(step, "`Temporal` in the runtime is " + found + " (manifest says " + expected + ")");
    }
  }

  // Full ICU data, which is what makes Intl.Collator, Intl.Segmenter and
  // \\p{Script=Han} work. The V8-only bundle needs an icudtl.dat file next to the
  // executable; Node compiles the data into libicudata.a instead, so nothing has
  // to be shipped or found at runtime.
  RunScript(step, isolate, context,
            "{ const assert = process.getBuiltinModule('node:assert');"
            "assert.strictEqual(new Intl.NumberFormat('en-US').format(1234.5), '1,234.5');"
            "assert.ok(new Intl.Collator('zh').compare('\\u7532', '\\u4e59') !== 0);"
            "assert.strictEqual(Array.from(new Intl.Segmenter('zh', {granularity: 'word'})"
            "  .segment('\\u4e2d\\u6587\\u5206\\u8bcd'))[0].segment, '\\u4e2d\\u6587');"
            "assert.ok(new Intl.DateTimeFormat('zh-CN', {dateStyle: 'full'}).format(0).length > 0);"
            "assert.strictEqual(/\\p{Script=Han}/u.test('\\u4e2d'), true);"
            "assert.strictEqual(new Date(0).toLocaleDateString('en-US'), '1/1/1970');"
            "'full ICU data'; }",
            "Intl (collation, segmentation, date formatting) and \\p{Script=Han} work");

  // Node's own console: the engine reports JS errors through it, so it has to
  // work without throwing. console.warn writes to stderr, which keeps the probe's
  // own report readable.
  {
    v8::TryCatch quiet(isolate);
    RunScript(step, isolate, context,
              "console.warn('probe: a message through Node\\'s console');",
              "Node's console writes without throwing");
    if (quiet.HasCaught()) Fail(step, "console.warn raised a JS exception");
  }

  // An unhandled error inside a callback must stay inside the isolate: Godot
  // installs process.on('uncaughtException') and keeps running.
  {
    RunScript(step, isolate, context,
              "globalThis.__probe_uncaught = 0;"
              "process.on('uncaughtException', () => { globalThis.__probe_uncaught++; });"
              "setImmediate(() => { throw new Error('probe'); });",
              "uncaughtException handler installed");
    bool caught = false;
    for (int i = 0; i < 30 && !caught; i++) {
      uv_run(loop, UV_RUN_NOWAIT);
      platform->DrainTasks(isolate);
      v8::Local<v8::Value> counter;
      v8::Local<v8::String> key;
      if (v8::String::NewFromUtf8(isolate, "__probe_uncaught").ToLocal(&key) &&
          context->Global()->Get(context, key).ToLocal(&counter) && counter->IsNumber() &&
          counter.As<v8::Number>()->Value() > 0) {
        caught = true;
      }
    }
    CHECK(step, caught,
          "a JS error thrown from a libuv callback was caught by the handler");
  }

  // Godot runs a script with a different global object (GDEngineRunner's
  // runCode path). Node's context and the host's own context have to be usable
  // one after the other in the same isolate, and functions crossing between them
  // still have to be callable.
  {
    v8::Local<v8::Function> callback =
        MakeFunction(isolate, context, "(function () { return 7; })");

    // A second script context the way Node creates them.
    v8::Local<v8::Context> node_scratch = node::NewContext(isolate);
    CHECK(step, !node_scratch.IsEmpty(),
          "node::NewContext() creates a second script context in the same isolate");

    // A context the host created itself, then handed to Node. This is the case an
    // engine with its own contexts has to be able to use.
    v8::Maybe<bool> host_initialised = v8::Just(false);
    {
      v8::Local<v8::Context> host_scratch = v8::Context::New(isolate);
      host_initialised = node::InitializeContext(host_scratch);
    }
    CHECK(step, host_initialised.FromMaybe(false),
          "node::InitializeContext() accepts a context the host created itself");

    bool callable = false;
    v8::Local<v8::Value> value;
    const v8::Local<v8::Value> receiver = context->Global();
    if (!callback.IsEmpty() && !node_scratch.IsEmpty()) {
      v8::Context::Scope scratch_scope(node_scratch);
      callable = callback->Call(context, receiver, 0, nullptr).ToLocal(&value);
    }
    CHECK(step, callable && value->IsNumber() && value.As<v8::Number>()->Value() == 7,
          "a function from Node's context runs with another context current");

    // The inspector and Node's promise hooks are attached per registered context.
    if (!node_scratch.IsEmpty()) {
      node::RegisterContext(setup->env(), node_scratch);
      node::UnregisterContext(setup->env(), node_scratch);
      Ok(step, "node::RegisterContext()/UnregisterContext() link and run");
    }
  }
  }  // the V8 scopes close here, before the environment is torn down

  // Clean shutdown: node::Stop() tears the environment down while the loop is
  // still being pumped, which is what happens when the engine quits. The V8 scopes
  // above are closed by now, which is what makes the teardown below legal.
  const int exit_code = node::Stop(setup->env());
  CHECK(step, exit_code == 0, "node::Stop() shut the environment down (exit code 0)");
  for (int i = 0; i < 20; i++) {
    uv_run(loop, UV_RUN_NOWAIT);
    platform->DrainTasks(isolate);
  }
  keep_alive->swap(setup);
  Ok(step, "the environment stopped; it is destroyed by the caller once the V8 scopes are closed");
}

}  // namespace

int main() {
  std::fprintf(stderr, "node_link_probe: checking a packaged Node bundle\n");
  CheckHeaders("the bundled headers match the bundled library");
  CheckRtti("RTTI and N-API symbols");

  // V8 needs a platform before anything else, and Node can use the same one. This
  // is the platform whose tasks have to be drained from the host's loop.
  std::unique_ptr<node::MultiIsolatePlatform> platform =
      node::MultiIsolatePlatform::Create(4);
  v8::V8::InitializePlatform(platform.get());

  // The flags bundle Node provides for embedders that must not change the
  // process: no stdio takeover, no signal handlers, no resource-limit changes, no
  // NODE_OPTIONS, no OpenSSL config, and V8 / the V8 platform / cppgc are left to
  // the host. See docs/node-26.md, "what an embedder has to switch off".
  //
  // Order matters and is not obvious: Node's startup parses its own options and
  // hands them to V8 as flags, and V8 refuses flag changes once it is initialized
  // ("Check failed: !IsFrozen()"). So V8::Initialize() goes *after*
  // InitializeOncePerProcess(), because that flag bundle tells Node not to
  // initialize V8 itself.
  const std::vector<std::string> init_args = {"node_link_probe"};
  std::shared_ptr<node::InitializationResult> init = node::InitializeOncePerProcess(
      init_args, node::ProcessInitializationFlags::kLegacyInitializeNodeWithArgsBehavior);
  const std::string init_step = "Node initializes once per process";
  CHECK(init_step, init != nullptr && !init->early_return(),
        "InitializeOncePerProcess() with the embedder flags did not bail out");
  for (const std::string& error : init->errors()) {
    Note(init_step, "startup message: " + error);
  }

  v8::V8::Initialize();
  Ok(init_step, "v8::V8::Initialize() accepted the flags Node had already set");

  // The legacy flag bundle includes kNoInitializeCppgc, so Node leaves cppgc to the
  // host - but v8::V8::Initialize() brings cppgc up itself when the host
  // initializes V8, and initializing it a second time aborts the process
  // ("Check failed: !internal::g_page_allocator"). Asking first is what makes the
  // same code correct whichever way V8 was initialized.
  bool host_owns_cppgc = false;
  if (!cppgc::IsInitialized()) {
    cppgc::InitializeProcess(platform->GetPageAllocator());
    host_owns_cppgc = true;
  }
  CHECK(init_step, cppgc::IsInitialized(),
        "cppgc is initialised" + std::string(host_owns_cppgc ? " by the host"
                                                            : " by v8::V8::Initialize()"));

  CheckNodeLeavesProcessAlone("Node left the host process alone");

  {
    const std::string step = "the host drives the event loop";
    uv_loop_t loop;
    uv_loop_init(&loop);
    std::shared_ptr<node::ArrayBufferAllocator> allocator =
        node::ArrayBufferAllocator::Create();
    v8::Isolate* isolate = node::NewIsolate(allocator, &loop, platform.get());
    if (isolate == nullptr) {
      Fail(step, "node::NewIsolate() returned null");
    } else {
      node::IsolateData* isolate_data =
          node::CreateIsolateData(isolate, &loop, platform.get(), allocator.get());
      {
        v8::Isolate::Scope isolate_scope(isolate);
        CheckHostOwnsEventLoop(step, platform.get(), &loop);
      }
      // DisposeIsolate() disposes the isolate and unregisters it from the platform
      // in the order Node requires; doing isolate->Dispose() by hand leaves a
      // dangling registration behind.
      platform->DisposeIsolate(isolate);
      node::FreeIsolateData(isolate_data);
      Ok(step, "the isolate created with node::NewIsolate() was disposed cleanly");
    }

    std::unique_ptr<node::CommonEnvironmentSetup> env_setup;
    CheckEnvironment("the Node environment runs JS and stops", platform.get(), &env_setup);
    env_setup.reset();
    Ok("teardown", "the Node environment was destroyed after its scopes were closed");

    for (int i = 0; i < 20; i++) uv_run(&loop, UV_RUN_NOWAIT);
    const int uv_close_result = uv_loop_close(&loop);
    CHECK("the host closes its own loop", uv_close_result == 0,
          uv_close_result == 0
              ? std::string("uv_loop_close() succeeded after Node's environment was destroyed")
              : std::string("uv_loop_close() reported ") + uv_strerror(uv_close_result));
  }

  {
    const std::string step = "vendored libraries came from the bundle";
    CHECK(step, std::strlen(uv_version_string()) > 0,
          std::string("libuv ") + uv_version_string() + " is linked in");
    // The version from the shipped node_version.h, which has to match the archives
    // the engine links against.
    CHECK(step, std::strlen(NODE_VERSION) > 0,
          std::string("node_version.h says ") + NODE_VERSION);
  }

  node::TearDownOncePerProcess();
  if (host_owns_cppgc) cppgc::ShutdownProcess();
  v8::V8::Dispose();
  v8::V8::DisposePlatform();
  // The platform object itself has no explicit shutdown in Node 26; destroying it
  // joins its worker threads.
  platform.reset();
  std::fprintf(stderr, "node_link_probe: teardown finished\n");

  if (failures.empty()) {
    std::fprintf(stderr, "node_link_probe: PASS\n");
    return 0;
  }
  std::fprintf(stderr, "node_link_probe: %zu check(s) FAILED\n", failures.size());
  for (const std::string& failure : failures) {
    std::fprintf(stderr, "FAIL %s\n", failure.c_str());
  }
  return 1;
}
