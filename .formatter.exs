# Used by "mix format"
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  import_deps: [:typed_structor],
  locals_without_parens: [
    # Musubi DSL macros — keep call sites paren-free.
    attr: 2,
    attr: 3,
    command: 1,
    command: 2,
    field: 2,
    field: 3,
    payload: 2,
    payload: 3,
    state: 1,
    stream: 2,
    stream: 3,
    stream_async: 2,
    stream_async: 3
  ]
]
