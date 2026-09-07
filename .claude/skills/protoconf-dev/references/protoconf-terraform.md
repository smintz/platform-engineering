# protoconf-terraform

[`protoconf-terraform`](https://github.com/protoconf/protoconf-terraform) is the bridge between Protoconf and Terraform. It does two things:

1. **Generates `.proto` schemas** for Terraform providers, resources, and data sources. After running it, the `src/terraform/` tree contains one `.proto` file per provider × kind. These are loaded into your `.pinc`/`.mpconf` code just like any other proto, so you build Terraform configs by constructing typed messages.
2. **Ships a helper library** at `src/terraform/v1/util.pinc` (the `util` namespace) with composition primitives — `util.Resource`, `util.Data`, `util.Link`, `util.Provider`, `util.From`, `util.Module`, `util.Group`, plus `util.Terraform`, `util.Output`, `util.Chain`, `util.ChainWithLast`. These are the hook factories you'll use to assemble a Terraform JSON output from typed pieces.

**Treat `src/terraform/` as a vendored dependency.** Do not hand-edit anything under it. Regenerate via the protoconf-terraform tool when you need a new provider version, missing resource, or a schema fix.

## How a Terraform output gets built

A typical Terraform-producing `.mpconf` returns a dict whose keys end in `.tf.json`. Each value is a `Terraform()` message constructed by chaining hooks:

```python
load("//terraform/v1/util.pinc", "util")
load("//terraform/aws/provider/v5/aws.proto", "Aws")
load("//terraform/aws/resources/v5/foo.proto", "AwsFoo")

def main():
    return {
        "my-config/main.tf.json": util.Terraform(
            util.Provider(Aws(region="us-east-1")),
            util.Resource("foo_a", AwsFoo(name="alpha")),
            util.Resource("foo_b", AwsFoo(name="beta")),
        ),
    }
```

Behind the scenes each `util.Resource(...)` call is a hook that adds the resource into the Terraform message's `resource` block; `util.Provider(...)` registers the provider once and pins its version; the chain is consumed by `util.Terraform`. The materialized output is plain Terraform JSON that `terraform init`/`validate`/`plan`/`apply` consume directly.

## The wrapper struct that flows through `util.Link`

This is the part that trips people up. Most real Terraform configs need to **wire fields between resources** — for example, "resource A's `vpc_id` should be resource B's `id`." `util.Link` exists for that. It takes named resources/data sources as kwargs plus a `linker(t, next)` callback. Inside the linker, `t` is a `struct` with these namespaces:

| Namespace | What it is | Example |
|---|---|---|
| `t.resource.<name>` | The actual proto message you passed in. Mutate fields here. | `t.resource.subnet.vpc_id = ...` |
| `t.data.<name>` | Same as `t.resource` but for data sources. | `t.data.ami.most_recent = True` |
| `t.var.<name>` | Reference strings (Terraform interpolation) for cross-resource wiring. Reading `t.var.foo.id` returns `"${aws_foo.foo.id}"` — a string Terraform resolves at plan time. | `t.resource.b.parent_id = t.var.a.id` |
| `t.var.data.<name>` | Same idea for data sources: `"${data.aws_x.foo.attr}"`. | `t.resource.x.vpc_id = t.var.data.vpc.id` |
| `t.tmp` | Empty dict for transient state shared between hooks. | `t.tmp["containers"] = {...}` |
| `t.prefix` / `t.suffix` | The prefix/suffix passed to `util.Link` — used to namespace resource names when you instantiate the same module multiple times. | `name = t.prefix + "x" + t.suffix` |
| `t.Chain(*hooks)` | Append more hooks dynamically (often used to add policies/sub-resources discovered at link time). | `t.Chain(util.Resource(...))` |

So the pattern is:

```python
def ProvisionThing(region):
    def linker(t, next):
        # wire fields between resources
        t.resource.b.parent_id = t.var.a.id
        t.resource.b.subnet_ids = [t.var.data.subnet.id]
        return next(t)

    return util.Terraform(
        util.Provider(Aws(region=region)),
        util.Link(
            linker,
            a=AwsA(name="alpha"),
            b=AwsB(name="beta"),
            subnet=AwsSubnetData(tags={"Name": "main"}),  # data source — package path determines resource vs. data
        ),
    )
```

`util.Link` introspects each kwarg's type to decide whether it's a `resource` or `data` (the proto package path contains either `.resources.` or `.datasources.`). It registers each as a `util.Resource(...)` or `util.Data(...)` under the prefixed/suffixed name, then runs your `linker` so you can wire them. After the linker returns, the chain continues.

## Why `t.var.foo.id` returns a string

Terraform's JSON model uses interpolation strings like `"${aws_foo.bar.id}"` to reference one resource's attribute from another. `t.var.foo.id` is *not* the resolved value (which doesn't exist yet — it's known only to Terraform at plan time). It's the **interpolation string** that Terraform will resolve. So when you write:

```python
t.resource.b.parent_id = t.var.a.id
```

…you're setting `b.parent_id` to the literal string `"${aws_a.a.id}"`. The `util.link()` helper builds these strings from the resource type name (snake_cased from the proto type) and the resource name you passed.

This means you can also string-concat references where Terraform supports interpolation:

```python
t.resource.x.image_uri = "${data.aws_ecr_repository.repo.repository_url}:" + tag
```

## Re-instantiating the same module under different names

Pass `prefix=` and/or `suffix=` to `util.Link` to namespace all resources it creates. This is how you stamp out N copies of a sub-module without name collisions:

```python
for env in ["dev", "staging", "prod"]:
    t.Chain(
        util.Link(
            linker,
            suffix="_" + env,
            web=AwsInstance(...),
            db=AwsDbInstance(...),
        ),
    )
```

Inside the linker, `t.prefix` and `t.suffix` are available so factories that need to construct unique sub-resource names can read them.

## Sub-resources discovered at link time

Sometimes a resource needs companion resources whose names depend on the parent's name (e.g. an IAM policy attached to a role created in the same Link). The pattern is to call `t.Chain(util.Resource(...))` from inside the linker:

```python
def linker(t, next):
    t.Chain(
        util.Resource(
            t.prefix + "policy" + t.suffix,
            AwsIamRolePolicy(role=t.var.role.id, policy=json.encode({...})),
        ),
    )
    return next(t)
```

`t.Chain` enqueues additional hooks against the same Terraform message; they run as part of the same compile.

## Backend, providers, default tags

Set the Terraform backend and shared provider config via `util.Provider(...)` and a small wrapper of your own. A typical project has an `AcmeTerraform`-style helper (named for the project — pick whatever your codebase uses) that:

- Calls `util.Provider(Aws(region=..., default_tags=[...]))` once.
- Sets the backend (e.g. S3) by mutating `tf.terraform.backend` in a custom hook.
- Then forwards into `util.Link(linker, **kwargs)`.

Look at the project's existing wrapper before writing new infra; reuse it so backend and tagging stay consistent.

## Validating the generated Terraform

Once `protoconf compile .` writes `outputs/<name>/main.tf.json`:

```bash
AWS_PROFILE=<profile> terraform -chdir=outputs/<name> init
AWS_PROFILE=<profile> terraform -chdir=outputs/<name> validate
AWS_PROFILE=<profile> terraform -chdir=outputs/<name> plan
```

If `validate` complains about a missing required field, the usual cause is one of:

- A default value (`0`, `""`, empty list) that Protoconf elided. Set it to a non-default explicitly, often inside the linker.
- A required field of a nested message that wasn't constructed (e.g. forgot `propagate_at_launch=True` inside an autoscaling tag).
- A field that should be a Terraform interpolation string but you set it to a Starlark value Terraform can't resolve.

If `plan` shows changes you didn't expect after a refactor that was supposed to be no-op, run `git diff outputs/` first — the JSON diff is usually clearer than Terraform's output.
