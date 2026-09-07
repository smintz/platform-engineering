---
name: protoconf-dev
description: Author, edit, and debug Protoconf code (Starlark `.pinc`/`.mpconf`/`.pconf` files, `.proto` schemas, `.proto-validator` validators, and the protoconf compile pipeline). Use this whenever the user is working in a Protoconf repository — adding configuration, defining new message schemas, writing reusable hook libraries, wiring mutable runtime values, adding compile-time validation rules (single-field via `validate.proto`/`buf.validate.field` annotations or cross-field via `add_validator` Starlark files), or anywhere they mention `protoconf compile`, `mpconf`, `pinc`, `pconf`, `proto-validator`, `materialized_JSON`, hook chains, or Starlark-for-config. Trigger even if the user does not name "protoconf" — file extensions like `.pinc` or `.proto-validator`, or directories like `mutable_config/` and `materialized_config/`, are strong signals. Skip only for plain Protocol Buffers questions unrelated to Protoconf compilation.
---

# Protoconf development

Protoconf is a configuration-as-code system. Starlark code (in `.pinc`/`.mpconf`/`.pconf` files) constructs Protocol Buffer messages (defined in `.proto` files), and the `protoconf` compiler materializes them as JSON. The materialized JSON is the source of truth for whatever consumes it — Terraform, CI workflows, application config, infrastructure tools, anything that wants typed configuration.

## Mental model

Three things to keep straight:

1. **The schema is a `.proto` file.** Protoconf's "objects" are Protocol Buffer messages. A `.proto` defines the shape; Starlark constructs instances of that shape. Field names in Starlark match proto field names (snake_case). Setting an unknown field is an error.
2. **`.pinc` files are libraries; `.mpconf`/`.pconf` files are entry points.** Only entry points produce output. `.pinc` files are imported via `load(...)` — they expose functions, constants, and `struct` namespaces but materialize nothing on their own.
3. **The output map is the API.** An `.mpconf` returns a `dict` from `main()`; each key becomes a materialized output file. The key's *path and extension* determine where the output lands. See "Output mapping" below — getting this wrong is the most common source of "I changed it but nothing happened."

## File types and what they do

| Extension | Role | Produces output? |
|---|---|---|
| `.proto` | Message schema (Protocol Buffers) | No — defines types only |
| `.pinc` | Starlark library (functions, constants, hooks) | No — only loaded via `load()` |
| `.pconf` | Single-config entry point (returns one message) | Yes — one file |
| `.mpconf` | Multi-config entry point (`main()` returns a `dict`) | Yes — one file per dict key |
| `.pinc.template` | Go-template that generates a `.pinc` at compile time (typically used to build indices over `mutable_config/`) | Generates a `.pinc` |
| `.proto-validator` | Starlark file co-located with a `.proto`, registers cross-field validators via `add_validator(MessageType, fn)` | No — runs during compile; failures block output |
| `.materialized_JSON` | Materialized output (compiler-written; do not hand-edit unless under `mutable_config/`) | Is the output |

`mutable_config/**.materialized_JSON` is the **input** side: hand-written or workflow-written runtime values consumed via `load("mutable:...", ...)`. `materialized_config/**.materialized_JSON` is the **output** side: the compiler writes it from your Starlark.

## Output mapping (file path → on-disk output)

The compiler writes outputs from two sources:

**From `.pconf`:** `src/path/to/config.pconf` → `materialized_config/path/to/config.materialized_JSON` (one file).

**From `.mpconf`:** for each key `K` in the dict returned by `main()` → `materialized_config/path/to/configs/K.materialized_JSON`.

**Side-channel output (this is the trick that lets Protoconf drive other tools):** if a key (or `.pconf` filename) ends in `.json`, `.yaml`, `.yml`, or `.toml` *before* the `.materialized_JSON` suffix, the compiler **also** writes the materialized content as that format to `outputs/path/to/config.<ext>`. So a dict key like `"some/path/main.tf.json"` lands at `outputs/some/path/main.tf.json` as plain Terraform JSON; `"workflow.yaml"` lands at `outputs/workflow.yaml` as plain YAML.

If you want a generated file to be consumed by another tool, name the dict key with the appropriate extension. Forgetting this means your config materializes inside `materialized_config/` but nothing downstream sees it.

## The dev/debug loop

This is your tightest feedback loop. Use it constantly.

```bash
# Compile the whole repo (validates everything, writes outputs/ + materialized_config/):
protoconf compile .

# Compile one file (much faster — strip the `src/` prefix from the path):
protoconf compile . path/to/config.pconf
protoconf compile . path/to/config.mpconf

# Process .pinc.template files too (regenerates index files from mutable_config/):
protoconf compile -process-templates .
```

Exit code `0` = success and `materialized_config/` (plus `outputs/` for side-channel formats) reflect the new state. On error the compiler prints a Starlark traceback pointing at the offending file/line.

**Debugging:** add `print(...)` statements anywhere in `.pinc`/`.mpconf` code. Output goes to stderr at compile time. Print a value to inspect its type, dump a partial message, or trace which branch fired. Remove them before committing.

**Refactor validation:** to confirm a refactor doesn't change generated output, compile and then `git diff materialized_config/ outputs/` — if the diff is empty, the refactor is behavior-preserving.

## Imports and module paths

`load()` paths are rooted at `src/` and use `//` for the root:

```python
load("//path/to/lib.pinc", "SomeFunction", "SomeConstant")
load("//path/to/schema.proto", "SomeMessage")     # .proto types are loaded too
load("encoding/json.star", "json")                # built-in Starlark stdlib
load("re.star", "re")
load("mutable:some/key", VAR="value")             # mutable_config/some/key.materialized_JSON
```

A few rules worth remembering:
- The thing in quotes after `load(...)` is the symbol name; rename with `Alias="OriginalName"`.
- For `mutable:` loads, the binding (`VAR="value"`) extracts the `value` field of the materialized message — most mutable values wrap a well-known type like `google.protobuf.StringValue` or `UInt32Value`.
- `.proto` files are loaded just like `.pinc` files — they expose their message types as Starlark constructors.

## Formatting and tooling

Starlark-for-Protoconf is conventionally formatted with `black` (yes, the Python formatter — Starlark is close enough). Most Protoconf repos have a `make fmt` target. Editor setup typically associates `.pinc`/`.mpconf`/`.pconf` with the Starlark language and `.materialized_JSON` with JSON; format-on-save runs black.

## The hook pattern (read this — it's the heart of Protoconf-style code)

Almost every reusable function in a mature Protoconf repo follows the same shape:

```python
def WithSomething(arg):
    def hook(msg, next):
        # mutate msg here
        msg.some_field = arg
        return next(msg)
    return hook
```

A *hook* takes the current message and a `next` callback; it mutates (or wraps) the message, then calls `next(msg)` to pass it along. Hooks are composed into a chain so each one runs in order. This gives you middleware-style composition: orthogonal concerns stack independently, conditional hooks are easy (`If(cond, *hooks)`), and you can build up complex configurations from small building blocks.

A typical chain primitive looks like this:

```python
def Chain(msg, *hooks):
    queue = list(hooks)
    def run_next(c):
        if not queue:
            return c
        nxt = queue.pop(0)
        return nxt(c, run_next)
    first = queue.pop(0)
    return first(msg, run_next)
```

When you write a new helper for a Protoconf project that already uses hooks, follow the same shape unless you have a reason not to — it slots into existing chains for free. When the user asks you to extend a `With*`-style factory, look at neighbouring factories first to see what state they read/write (often a shared `tmp` dict, or fields on the message being built).

Two extensions of the pattern show up once a repo models more than flat config, both covered in the reference:

- **Typed hooks.** When one call site configures several messages at once (a component with its own fields *plus* a map of Terraform configs), each hook declares the message type it targets via a `message_filter` wrapper and passes through everything else. The same hook list then runs over each message and each hook fires only on its own type.
- **Markers.** Some call-site declarations aren't mutations of the message — a dependency on another component, hooks that should run later against a *different* message, hooks that should propagate to children. Those are passed as `module(...)` values in the same variadic list and interpreted by the constructor (`type(x) == "module"` distinguishes them from hooks). Forcing them into the `(msg, next)` shape produces hooks that fire at the wrong time.

For a deeper walk through the hook idiom, typed hooks, markers, and packing configs into `google.protobuf.Any`, see **`references/hooks-and-composition.md`**.

## protoconf-terraform

If a repo has a populated `src/terraform/` directory, it's almost certainly using **`protoconf-terraform`** (https://github.com/protoconf/protoconf-terraform) — a tool that generates `.proto` schemas for Terraform providers, data sources, and resources, plus a `.pinc` helper library (`terraform/v1/util.pinc`) with composition primitives like `util.Resource`, `util.Data`, `util.Link`, `util.Provider`, `util.From`, `util.Module`, and `util.Group`. **These files are generated — do not hand-edit them.** Treat `src/terraform/` as a vendored dependency: regenerate via the protoconf-terraform tool rather than patching.

When a Protoconf repo is producing Terraform JSON, the typical shape is: build a `Terraform()` value, attach a `Provider(...)`, attach `Resource(...)`/`Data(...)` for each resource/data source, then run a `linker(t, next)` callback that wires output references between them (e.g. `t.resource.foo.bar = t.var.baz.id`). For the vocabulary (`t.var` vs `t.resource`/`t.data`/`t.tmp`, prefix/suffix, the linker pattern, `util.Link` semantics), read **`references/protoconf-terraform.md`**.

## Validation

Protoconf enforces config validity at compile time. Two mechanisms, picked by the shape of the rule:

- **Single-field rules** (numeric range, string format, regex, enum membership, IP/email/hostname, repeated min/max) — annotate the proto field directly with `(buf.validate.field).<rule>` (or `(validate.rules).<rule>` in older codebases). Backed by [protovalidate](https://github.com/bufbuild/protovalidate-go).
- **Cross-field rules** (`response_timeout >= connect_timeout`, conditional requiredness, exactly-one-of across siblings, referential integrity between repeated fields) — write a `.proto-validator` Starlark file alongside the `.proto`, define a function, and register it with `add_validator(MessageType, fn)`.

Both run during `protoconf compile`. Crucially: **if a validator fails, the corresponding `materialized_config/...materialized_JSON` is not written** — you can't accidentally commit a config that violates its own rules. If a downstream tool can't find a freshly-changed materialized file, check the compiler output for a validation error before assuming a bug elsewhere.

When adding a rule, deliberately break a config to confirm the validator actually fires, then fix it. A validator that never trips on bad input is worse than no validator at all — it gives false confidence.

For full syntax, registration semantics, decision rules, debugging tips, and worked examples of both styles, read **`references/validation.md`**.

## Common gotchas

- **Default values are omitted from output.** Setting `count=0`, an empty list, or a zero-valued enum won't appear in the JSON. If a downstream tool requires the field, set it to a non-default value or assign it inside a linker after the fact.
- **Snake_case strictness for fields.** Field names in Starlark match the proto exactly (snake_case as written in the `.proto`). Mistyping a field name fails at compile.
- **`*hooks` goes last in calls.** Variadic positional args (`*hooks`) collect trailing positional arguments. Don't put kwargs after them by accident.
- **`json.encode(...)` for embedded JSON strings.** When a downstream schema requires a JSON-string field (IAM policies, container definitions, etc.), use `load("encoding/json.star", "json")` and `json.encode({...})` rather than trying to inline the structure.
- **Forgetting the file extension in an `.mpconf` dict key** means the output lands at `materialized_config/.../<key>.materialized_JSON` and **not** at `outputs/...`. If your downstream tool can't find the generated file, check the key.
- **Don't hand-edit `materialized_config/` or `outputs/`** — they're regenerated on every compile. The exception is `mutable_config/`, which is hand-written input.
- **Module-level dicts and lists are frozen after `load()`.** Mutating a constant from another module fails with `cannot insert into frozen hash table`. Merge into a fresh local (`known = {}; known.update(CONST); known.update(overrides)`) instead of updating the constant in place. The same applies to a function's default argument if it defaults to a module-level value.
- **`type()` on a proto value returns its fully-qualified message name** (`"terraform.v1.Terraform"`), for message types and instances alike — which is what makes type-dispatched hooks possible. Starlark functions are `"function"` and `module(...)`/`struct(...)` values are `"module"`/`"struct"`, so a variadic list can carry a mix and be partitioned by `type()`.
- **`any.star` has exactly `any.new` and `any.unpack`** — `any.new(msg)` packs, `any.unpack(packed, Prototype())` unpacks and *requires* the target prototype. There is no `any.pack`, and no way to unpack without knowing the type, so anything holding a `map<string, Any>` needs a `type_url -> prototype` registry.
- **Compiling a single file writes nothing unless the path is right.** `protoconf compile . path/to/x.pconf` silently exits 0 and produces no output if the path is wrong (e.g. you left the `src/` prefix on). If a compile "succeeds" but no file appears, compile the whole repo before hunting for a bug in the config.
- **Generated `.pinc.template` outputs need `-process-templates`.** Index files built from `mutable_config/` only refresh when you pass `-process-templates` to the compiler. If you added or removed a mutable file and the consuming code can't see it, that's why.

## When to read the references

- **`references/hooks-and-composition.md`** — read when writing or modifying anything that uses chained hooks, `Chain`/`ChainWithLast`, conditional hook combinators, or shared `tmp` state. Also read it before writing a new `With*` factory in an existing project so the shape matches neighbouring code, before dispatching hooks by message type, before modelling dependencies between configs (component graphs, deferred or inherited hooks), and before storing heterogeneous messages in a `map<string, google.protobuf.Any>`.
- **`references/protoconf-terraform.md`** — read when the repo has `src/terraform/` populated (i.e. uses protoconf-terraform), and the user is touching Terraform-shaped configs: adding a resource/data source, wiring outputs between resources, writing a `linker(t, next)`, or debugging `t.var.*` references.
- **`references/validation.md`** — read when adding, modifying, or debugging compile-time validation: inline `(buf.validate.field).*` / `(validate.rules).*` annotations on proto fields, `.proto-validator` Starlark files, `add_validator(...)` registration, or when the user reports "validator didn't fire" / "compile failed but I don't understand the rule" / "materialized file isn't getting written."
