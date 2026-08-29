Seshat is an MCP server written in Elixir. Phoenix hosts its streamable HTTP
transport; there is no browser application.

> **Read [CLAUDE.md](CLAUDE.md) first** — it covers what this project actually
> is and how it's put together. This file keeps the framework-level guidance
> that applies to every session.
>
> Seshat has **no database and no Ecto**. Ignore any Ecto guidance you find
> here or infer from Phoenix conventions.
>
> Path-scoped rulesets live in [.claude/rules/](.claude/rules/) and load
> automatically when the matching files are touched:
> - [phoenix-web.md](.claude/rules/phoenix-web.md) — Phoenix HTTP endpoint
>   rules (`lib/seshat_web/**`)
> - [osc.md](.claude/rules/osc.md) — OSC address safety and Seshat
>   conventions (`lib/**`)
> - [testing.md](.claude/rules/testing.md) — ExUnit and Seshat testing rules
>   (`test/**`)
>
> If you are an agent that does not auto-load `.claude/rules/`, read the
> relevant file above before editing matching paths.

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included `:req` (`Req`) library for HTTP requests; **avoid**
  `:httpoison`, `:tesla`, and `:httpc`. Req is Seshat's preferred HTTP client.
- **Everything the installed Ableton Live Object Model exposes is fair game
  for Seshat.** If AbletonOSC lacks an address for a LOM capability, add it to
  Seshat's fork. A missing fork address is routine implementation scope, never
  a capability limitation, architectural objection, or reason to reject,
  defer, downgrade, or rank a feature lower.

## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Ecto Guidelines

Not applicable — Seshat has no database and no Ecto dependency. Session state
lives in memory in `Seshat.Session.State`, mirrored from Ableton over OSC.

If you find yourself reaching for a schema, changeset, or migration, stop:
you've misread the architecture. See [CLAUDE.md](CLAUDE.md).
