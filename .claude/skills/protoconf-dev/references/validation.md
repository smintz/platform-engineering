# Validation

Protoconf validates configs at **compile time** — `protoconf compile .` will exit non-zero with a useful error if any rule fails. Two complementary mechanisms exist; pick one (or both) per the decision rule below.

## Decision rule: which mechanism?

- **Single-field rule** (`port` is between 1 and 65535, `email` is a valid email, `image` is a non-empty string, `cidr` is a valid CIDR) → use **inline `validate.proto` annotations** on the proto field. Cheap, declarative, lives next to the schema, applies wherever that message is built.
- **Multi-field / cross-cutting rule** (`response_timeout >= connect_timeout`, "if `tls_enabled` then `cert_path` must be set", "exactly one of A/B/C must be present", set-membership across slices, conditional requiredness) → use a **`.proto-validator` Starlark file** with `add_validator(MessageType, fn)`.

Both run during `protoconf compile`, so you don't pay for one over the other at runtime — pick whichever expresses the rule more clearly.

You can mix them on the same message. Inline rules cover the per-field invariants; the `.proto-validator` covers what those rules can't see.

## Inline rules with `validate/validate.proto`

This is the [protovalidate](https://github.com/bufbuild/protovalidate-go) ruleset. You annotate proto fields with `(buf.validate.field).<rule>` (or `(validate.rules).<rule>` depending on the ruleset version your repo uses) and the compiler enforces them whenever a message of that type is materialized.

### Importing the rules

Add an import at the top of your `.proto` file:

```proto
syntax = "proto3";
package myproject.v1;

import "buf/validate/validate.proto";   // protovalidate (modern)
// or, in older codebases:
// import "validate/validate.proto";

message ServerConfig {
  string ip          = 1 [(buf.validate.field).string.ip = true];
  uint32 port        = 2 [(buf.validate.field).uint32 = {gte: 1, lte: 65535}];
  string email       = 3 [(buf.validate.field).string.email = true];
  string hostname    = 4 [(buf.validate.field).string.hostname = true];
  string region      = 5 [(buf.validate.field).string = {in: ["us-east-1", "eu-west-1"]}];
  repeated string tags = 6 [(buf.validate.field).repeated = {min_items: 1, unique: true}];
  google.protobuf.Duration timeout = 7 [(buf.validate.field).duration.gte = {seconds: 1}];
}
```

Match the import path your repo already uses — both `buf/validate/validate.proto` (protovalidate) and the older `validate/validate.proto` (protoc-gen-validate) shapes exist in the wild and they share the same general feel but slightly different option syntax. Look at a neighbouring `.proto` in the project to confirm which one is wired up.

### What inline rules are good for

- Simple per-field invariants the schema can express: numeric ranges, string formats (email/IP/hostname/uri/uuid/regex), repeated min/max/unique, enum membership, required.
- Rules that should apply **everywhere** the message is constructed — including in other configs you don't own, future configs that haven't been written yet, and configs the user doesn't think to validate explicitly. This is the "make invalid states unrepresentable" leverage.

### What inline rules can't do

They can't read another field's value. They can't reach outside the message. They can't conditionally apply based on a sibling. The moment your rule needs two fields, escalate to a `.proto-validator`.

## Cross-field rules with `.proto-validator` files

A `.proto-validator` file is a Starlark file (formatted with `black` like the rest, the project Makefile usually has it in the formatter include list — e.g. `--include='\.(pconf|mpconf|pinc|proto-validator)'`). It loads the message type, defines one or more validator functions, and registers them with `add_validator(MessageType, validator_fn)`.

### Anatomy

`src/myproject/v1/server_config.proto-validator`:

```python
load("//myproject/v1/server_config.proto", "ServerConfig")


def validate_server_config(config):
    # Cross-field: response timeout must be >= connect timeout.
    if config.response_timeout.seconds < config.connect_timeout.seconds:
        fail(
            "response_timeout (%ds) must be >= connect_timeout (%ds)"
            % (config.response_timeout.seconds, config.connect_timeout.seconds),
        )

    # Conditional requiredness: TLS on means cert/key must be set.
    if config.tls_enabled:
        if not config.tls_cert_path:
            fail("tls_cert_path is required when tls_enabled is true")
        if not config.tls_key_path:
            fail("tls_key_path is required when tls_enabled is true")

    # Exactly-one-of across siblings (if you can't model it as a proto `oneof`).
    backends = [
        bool(config.s3_backend),
        bool(config.gcs_backend),
        bool(config.local_backend),
    ]
    if sum(backends) != 1:
        fail("exactly one of s3_backend / gcs_backend / local_backend must be set")

    # Referential integrity across repeated fields.
    declared = {p.name: True for p in config.ports}
    for svc in config.services:
        if svc.port_name not in declared:
            fail("service %r references unknown port %r" % (svc.name, svc.port_name))


add_validator(ServerConfig, validate_server_config)
```

### Registration semantics

`add_validator(MessageType, fn)` registers `fn` to run on **every** materialized config whose top-level message is `MessageType`. So if you produce 12 different `ServerConfig` outputs from various `.pconf`/`.mpconf` files, all 12 get validated.

You can register multiple validators per type by calling `add_validator` multiple times — they're independent and each can `fail()` on its own. This is useful for keeping rules grouped by concern (security rules vs. resource-budget rules vs. naming conventions) instead of one mega-function.

You can also register validators for *nested* message types — if `ServerConfig` embeds a `RetryPolicy`, you can register a validator on `RetryPolicy` and it'll fire whenever a `RetryPolicy` is materialized inside any parent.

### Failure model

`fail("...")` aborts the compile with a non-zero exit and prints the message. **When validation fails, the corresponding `materialized_config/...materialized_JSON` is not written** — the compiler deliberately refuses to produce an output that violates its own rules, so an invalid config can never sneak into a commit. This is the safety property that makes validators worth writing: if the file exists, it passed. If your downstream tool can't find a freshly-changed config after compile, check for a validation failure in the compiler output before assuming a bug.

Make the failure message *actionable* — name the field, show the bad value, and ideally hint at the fix:

```python
fail(
    "max_connections=%d exceeds per-host kernel limit (%d). "
    "Either lower max_connections or raise the limit via sysctl."
    % (config.max_connections, KERNEL_LIMIT),
)
```

The user reading the error usually doesn't know your validator code; the message is the only context they get.

### What you can use inside a validator

It's plain Starlark, so you have:

- Built-in operators, list/dict/string ops, comprehensions.
- `load(...)` to import constants or helper `.pinc` libraries (great for reusing thresholds across multiple validators).
- `fail(msg)` to abort with an error.
- `print(...)` for ad-hoc compile-time debugging (remove before commit).

You **don't** have I/O, network, or filesystem access. Validators are pure functions of the materialized message.

### Patterns worth knowing

**Reusable threshold module:**

```python
# src/myproject/limits.pinc
limits = struct(
    MAX_CONNECTIONS = 10000,
    MIN_TIMEOUT_SECONDS = 1,
    MAX_TIMEOUT_SECONDS = 300,
)
```

```python
# src/myproject/v1/server_config.proto-validator
load("//myproject/limits.pinc", "limits")
load("//myproject/v1/server_config.proto", "ServerConfig")

def validate(config):
    if config.max_connections > limits.MAX_CONNECTIONS:
        fail("max_connections=%d exceeds limit %d" % (config.max_connections, limits.MAX_CONNECTIONS))

add_validator(ServerConfig, validate)
```

This keeps thresholds in one place; the proto-validator becomes "what" without baking in "how much."

**Splitting a complex validator:**

```python
def _check_timeouts(c):
    if c.response_timeout.seconds < c.connect_timeout.seconds:
        fail("response_timeout < connect_timeout")

def _check_tls(c):
    if c.tls_enabled and not (c.tls_cert_path and c.tls_key_path):
        fail("TLS enabled but cert/key paths not set")

def validate(c):
    _check_timeouts(c)
    _check_tls(c)

add_validator(ServerConfig, validate)
```

Or register them separately — each gets its own `fail` line, which can be easier to read in CI logs.

## Where to put validators

Convention: co-locate with the proto. If `src/myproject/v1/server_config.proto` defines `ServerConfig`, put the validator at `src/myproject/v1/server_config.proto-validator`. The compiler discovers it automatically.

For shared thresholds and helpers, a sibling `.pinc` file (e.g. `src/myproject/limits.pinc`) is fine and idiomatic.

## Workflow when adding validation to existing configs

1. Identify the rule. Single-field? → inline. Multi-field? → `.proto-validator`.
2. For inline: add the `(buf.validate.field).*` annotation to the `.proto` field.
3. For cross-field: create or extend the `<message>.proto-validator` next to the `.proto`.
4. Run `protoconf compile .` and confirm it now fails with a useful error against a *bad* config (deliberately break something to verify the rule fires).
5. Fix the bad config (or revert the deliberate break). Compile again — exit 0.
6. Commit the rule and any config fixes together.

Step 4 is the part people skip. A validator that never fires is no better than no validator at all — verify the trap actually catches what you think it does before declaring the work done.

## Debugging a validator

- **Validator doesn't seem to run** — confirm the message type you registered is actually the *top-level* materialized type for the configs you care about (or that it's reached as a nested field from one). Add a `print("validator fired for", config)` at the top to confirm.
- **Validator runs on configs you didn't expect** — that's by design. `add_validator` fires for *every* instance of that message type anywhere in the tree. If you only want a rule to apply to specific instances, inspect a discriminating field at the top of the validator and `return` early when it doesn't apply.
- **Cryptic Starlark traceback** — usually a typo in a field name (`config.max_connection` vs `config.max_connections`). Field access on a proto returns the zero value for missing fields but raises for fields that don't exist on the schema.
- **Need to see the actual values** — `print(config)` dumps the whole message; field-by-field `print("x =", config.x)` is often more readable.
