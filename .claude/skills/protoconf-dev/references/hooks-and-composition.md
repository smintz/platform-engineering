# Hooks and composition

This is the conceptual heart of idiomatic Protoconf code. The vocabulary is small but composes deeply, so it's worth spending a few minutes here before writing or modifying hook-based code.

## The hook signature

A hook is a two-argument function:

```python
def hook(msg, next):
    # 1. Inspect or mutate `msg`
    # 2. Optionally short-circuit by NOT calling next
    # 3. Pass control along by calling next(msg)
    return next(msg)
```

`msg` is the value flowing through the chain — usually a Protocol Buffer message under construction, but it can be any object. `next` is a callback that runs the rest of the chain. Returning `next(msg)` propagates the result; returning something else can transform or replace what later hooks see.

A *factory* is a function that returns a hook with arguments captured by closure:

```python
def WithName(name):
    def hook(msg, next):
        msg.name = name
        return next(msg)
    return hook
```

This is the `WithX(...)` shape you'll see throughout any Protoconf project. Each factory is an orthogonal concern — you compose them by stacking calls.

## Chaining

A typical chain primitive:

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

Each hook decides whether (and when) to call `next`, so you get arbitrary control flow: short-circuit, wrap, transform, conditionally branch.

A common variant is `ChainWithLast`, which appends a terminal hook that just returns the message without calling `next`. This lets every hook in the chain unconditionally call `next(msg)` without worrying about being last:

```python
def Last(c, _):
    return c

def ChainWithLast(msg, *hooks):
    return Chain(msg, *(hooks + (Last,)))
```

## Why this pattern

Four benefits:

1. **Orthogonality.** Each `With*` factory does one thing. Stacking them in a call site reads top-to-bottom like a recipe, and you can reorder or remove any single line without affecting the others (as long as the dependencies are honored).
2. **Conditional composition for free.** Define `If(cond, *hooks)` once and you can sprinkle it anywhere:
   ```python
   def If(cond, *hooks):
       def condition(t, next):
           if cond:
               t = ChainWithLast(t, *hooks)
           return next(t)
       return condition
   ```
3. **Cross-cutting state via closures or shared dicts.** A hook can stash partial results in the message, in a `tmp` dict carried alongside it, or in a closure captured at factory time. Later hooks read it back. This avoids passing 15 arguments through 4 layers of helpers.
4. **One concept, many fields.** A real-world concern often touches several places in the output at once — declaring a port on a Nomad job spec might mean (a) adding a `port` to the network block, (b) declaring a `service` that advertises that port, and (c) attaching the port to a specific `task`/container. Without hooks, the caller has to remember all three fields and keep them in sync. With hooks, you write one `WithPort(name, container=...)` factory that fans out to all three, and the call site just says `WithPort("http", container="api")`. Adding/removing/renaming a port becomes a one-line change instead of a three-place edit, and inconsistency becomes structurally impossible.

   Sketch:
   ```python
   def WithPort(name, container, port=None):
       def hook(job, next):
           # 1. declare the port on the network
           job.network.ports.append(NetworkPort(name=name, static=port))
           # 2. declare a service advertising it
           job.services.append(Service(name=name, port_label=name))
           # 3. attach it to the named container
           for task in job.tasks:
               if task.name == container:
                   task.port_labels.append(name)
           return next(job)
       return hook
   ```
   Same pattern works for "add an env var that's also stored as a secret and granted via IAM," "expose a metric that's also scraped and also dashboarded," etc. — anywhere a single user-facing concept legally requires several coordinated mutations.

## Shared transient state (`tmp`)

Some chains need to assemble a side-structure before serializing it onto the final message. The convention is a `tmp` dict on the message-being-built:

```python
def WithItem(name, value):
    def hook(t, next):
        t.tmp.setdefault("items", {})
        t.tmp["items"][name] = value
        return next(t)
    return hook

def Finalize():
    def hook(t, next):
        t.message.items_json = json.encode(t.tmp.get("items", {}))
        return next(t)
    return hook
```

The convention varies: sometimes `tmp` is a real attribute, sometimes the chain runs over a `struct(message=..., tmp={}, ...)` wrapper. Match what neighbouring code does in the project you're working in.

## Inspecting a chain before changing it

Before adding a new hook to an existing chain, read the chain definition top-to-bottom and answer:

1. **What's the type of `msg` flowing through this chain?** A bare proto message? A wrapper struct with `tmp`/`var`/`resource` namespaces (common in protoconf-terraform)? Match the conventions of the existing hooks.
2. **Where does state your hook depends on come from?** If you read `t.tmp["containers"]`, find the hook that populates it — your hook must run after it.
3. **Where is your hook's output consumed?** If you write to `msg.foo`, find the hook (or final serialization) that reads `msg.foo` — your hook must run before it.

Order matters in a chain. New hooks usually go at a specific point relative to existing ones, not just "at the end."

## Common combinators worth knowing

- **`If(cond, *hooks)`** — run inner hooks only if `cond` is truthy.
- **`From(value)`** — replace the chain's current message with a different value:
  ```python
  def From(v):
      def do(_, next):
          return next(v)
      return do
  ```
  Useful at the start of a chain to inject a freshly constructed message.
- **`Group(*hooks)`** — run a sub-chain that mutates the same message but as a logical unit (helpful for readability).
- **A `Linker` factory** — when you need to wire fields between messages already added to a parent (the linker is the last hook in the chain and reads back what earlier hooks added). See the protoconf-terraform reference for the canonical case.

## Typed hooks: one hook list, several messages

A chain assumes every hook understands the message flowing through it. That breaks down as soon as one call site configures more than one message — a component that has *both* its own proto fields *and* a map of Terraform configs, say. You want to write

```python
Component(
    "api-task",
    described("api task"),                          # mutates the Component message
    TerraformConfig(LeapTerraform(region, "api")),  # mutates the Terraform config
)
```

and have each hook land on the right message. The trick is to let each hook declare the type it targets and pass through anything else. `type(msg)` on a proto value returns its fully-qualified name (`"infra.components.v1.Component"`, `"terraform.v1.Terraform"`) — for both instances *and* message types, so either works as the prototype:

```python
# run hooks only on messages of p's type; anything else passes straight through
def message_filter(p, *hooks):
    want = type(p)

    def wrapper(msg, next):
        if type(msg) != want:
            return next(msg)

        queue = list(hooks)

        def run_next(current):
            if not queue:
                return next(current)      # hand control back to the OUTER chain
            return queue.pop(0)(current, run_next)

        return run_next(msg)

    return wrapper


def component_filter(*hooks):
    return message_filter(component_proto, *hooks)


def terraform_filter(*hooks):
    return message_filter(tf.Terraform(), *hooks)
```

The subtle part is the inner `run_next`: when the sub-chain is exhausted it calls the outer `next`, not `return current`. Get that wrong and the rest of the outer chain silently never runs.

Now the same hook list can be run over several messages and each hook fires only on its own:

```python
mutate_config(component, MAIN_CONFIG, *hooks)   # Terraform-typed hooks fire
component = chain(component, *hooks)            # Component-typed hooks fire
```

Filtering is per-hook, declared by the hook's author. An unwrapped hook fires on every chain it's in, which is a real footgun — wrap factories in the filter for their target type at the point of definition (`return component_filter(do)`), not at the call site.

## Markers: things a hook can't express

Some call-site declarations aren't "mutate this message." A dependency on another component, a hook that should run *later* on a *different* message, a hook that should propagate to child components — none of these fit the `(msg, next)` signature. Trying to force them in produces hooks that mutate global state or run at the wrong time.

The pattern that works: pass a **marker** — a `module(...)` value carrying data — in the same variadic list, and have the constructor pull markers out and act on them itself. `type(x)` is `"module"` for markers and `"function"` for hooks, which is all you need to partition:

```python
def ForDownstream(*hooks):
    return module("ForDownstream", kind="downstream", hooks=hooks)

def Inherit(*hooks):
    return module("Inherit", kind="inherit", hooks=hooks)

def WithDeps(*deps):
    return module("WithDeps", kind="deps", deps=deps)


def Component(slug, *hooks):
    markers = [h for h in hooks if type(h) == "module"]
    deferred = [h for m in markers if m.kind == "downstream" for h in m.hooks]
    inherited = [h for m in markers if m.kind == "inherit" for h in m.hooks]
    deps = [d for m in markers if m.kind == "deps" for d in m.deps]
    hooks = [h for h in hooks if type(h) != "module"] + inherited
    ...
```

Three markers worth knowing, because the shapes recur:

- **Deferred hooks (`ForDownstream`)** — parked on the constructed value and fired later, by whoever consumes it. In a component graph: hooks an upstream declares, run against the *downstream* component when the dependency is wired. Lets a database say "anything that depends on me gets this endpoint output" once, instead of every consumer remembering.
- **Inherited hooks (`Inherit`)** — applied here *and* forwarded to every child. Re-wrap them when forwarding (`factory(Inherit(*inherited))`) so inheritance is transitive rather than one level deep. Good for anything that describes context rather than content: failure domain, environment, region, ownership.
- **Dependency factories (`WithDeps`)** — dependencies declared *uninstantiated*, as functions taking `*hooks`. The constructor calls them with the inherited hooks, so a dependency picks up context from whatever depends on it. Pass built values instead and there's no way to inject anything — that's the whole reason for the factory indirection:
  ```python
  # dep factory: def AuroraComponent(*hooks): return Component("aurora", ..., *hooks)
  for dep_factory in deps:
      dep = dep_factory(Inherit(*inherited))
      component.upstreams.components.append(dep.msg)
      dep.RunForDownstream(component)
  ```
  Parameterized factories close over their arguments and return a factory:
  ```python
  def AuroraUserComponent(user):
      return lambda *hooks: Component("aurora-user-" + user, ..., *hooks)
  ```

**Ordering.** Markers make ordering explicit and therefore worth thinking about once: build the value's sub-configs *before* running the main chain, because deferred hooks fire during dependency wiring and a `From`-style hook later in the chain would replace the message they just mutated. Compute derived keys (paths, names built from `domain`/`name`) *after* everything, when the fields are final — otherwise inherited context that arrives late leaves a stale key behind.

**Returning a module instead of a message.** A constructor that owns deferred behaviour returns a `module` with the message plus the operations others need, not the bare message:

```python
return module(
    "Component",
    msg=component,
    MutateConfig=MutateConfig,
    RunForDownstream=RunForDownstream,
)
```

Callers then reach `.msg` for the proto and call the operations. When a helper needs to work on the bare message (a hook only ever sees the message, never the module), factor the operation into a message-level function and have the module method delegate to it:

```python
def mutate_config(component, key, *hooks):   # usable from any hook
    ...

def MutateConfig(key, *hooks):               # module method delegates
    mutate_config(component, key, *hooks)
```

## Packing messages into `google.protobuf.Any`

Component-style containers often hold heterogeneous configs as `map<string, google.protobuf.Any>`. The Starlark API is `load("any.star", "any")` with exactly two functions:

```python
packed = any.new(msg)                    # message -> Any
msg = any.unpack(packed, Terraform())    # Any -> message; the 2nd arg is REQUIRED
```

`any.unpack` needs a target prototype, so anything reading a heterogeneous map needs a `type_url -> prototype` registry. Keep prototypes as *constructors*, not instances, so each unpack gets a fresh message:

```python
CONFIG_TYPES = {"type.googleapis.com/terraform.v1.Terraform": tf.Terraform}

proto = CONFIG_TYPES[cfg_any.type_url]
cfg = any.unpack(cfg_any, proto())
```

`fail()` on an unregistered `type_url` rather than skipping it — silently dropping a config the user explicitly set is much worse than a compile error naming the missing type.

One limit worth knowing before designing around it: the `.mpconf` output writer resolves types for the whole emitted message, and it cannot resolve an `Any` nested inside another message from a different proto file (`unknown message type "terraform.v1.Terraform"`). Storing a message that itself carries `Any` fields as a config compiles fine but fails at output. Flatten before emitting.

## Writing a new hook factory: checklist

- [ ] Single responsibility — one orthogonal concern per factory.
- [ ] Closure captures the arguments; returns a `def hook(msg, next): ...` function.
- [ ] Always calls `next(msg)` at the end (use `ChainWithLast` if you can't).
- [ ] Doesn't assume position — works whether it runs first, last, or middle, as long as its data dependencies are satisfied.
- [ ] Mirrors the naming and shape of neighbouring factories (`WithX`, `OnX`, `OverrideX`, `Provision*`, etc. — pick what's already established).
- [ ] If exposed as a library symbol, register it in the project's `struct(...)` namespace export so callers find it via the same import as its siblings.
- [ ] If the chain it joins carries more than one message type, wrap it in that type's filter at definition, so it can't fire on the wrong message.
- [ ] If what it declares isn't a mutation of the message (a dependency, deferred work, inherited context), make it a marker the constructor interprets — not a hook that reaches around the chain.
