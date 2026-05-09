@runtime @render-contract
Feature: Render Contract
  As a store author
  I want one declaration to drive Elixir typespecs, TypeScript types, render-output validation, and identity rules
  So that the wire contract has a single source of truth and child stores compose explicitly with predictable lifecycle and identity

  Background:
    Given a connected client
    And a page runtime mounted on the client's transport session

  Rule: state do declares the public output shape

    Scenario: Field types drive Elixir typespec and TypeScript codegen
      Given a store declares state with field "status" typed as String.t()
      Then the runtime exposes an Elixir typespec equivalent to %{status: String.t()}
      And the codegen produces TypeScript shape { status: string }

  Rule: to_state(socket) returns a value matching the state shape, with child(...) placeholders allowed

    Scenario: Render output uses child placeholders for nested store fields
      Given a store declares field "header" typed as HeaderStore.state()
      When to_state(socket) returns %{header: child(HeaderStore, id: "header", current_user: u)}
      Then the resolver substitutes the child's render output into the header field

    Scenario: Render output uses raw maps for nested store types
      Given a store declares field "header" typed as HeaderStore.state()
      When to_state(socket) returns %{header: %{user_name: "Alice", avatar_url: nil}}
      Then validation accepts the raw map as long as it conforms to HeaderStore.state()
      And no child store node is mounted for the header field

  Rule: child(...) is a render-time placeholder resolved bottom-up

    Scenario: Resolver evaluates child placeholders before the parent's output is finalized
      Given the root store renders three child placeholders
      When the runtime resolves the root output
      Then each child store's render runs before the root's output is treated as complete

  Rule: Child store identity is (parent_path, module, id), and assigns survive identity-stable re-renders

    Scenario: Reordering a keyed list preserves child assigns
      Given the root renders a list of children keyed [{id: "a"}, {id: "b"}] under the same parent
      And each child has accumulated some internal assigns
      When the next render reorders the list to [{id: "b"}, {id: "a"}]
      Then both children's assigns are preserved
      And neither mount is invoked

    Scenario: Changing a child's module remounts a fresh node
      Given a child(FilterStoreV1, id: "filters") rendered last cycle
      When this cycle the parent renders child(FilterStoreV2, id: "filters")
      Then the V1 node is discarded
      And a fresh V2 node mounts with no preserved assigns

  Rule: Two child(...) with identical (parent_path, module, id) in one render is an error

    Scenario: Duplicate ids in a list reconcile to a hard runtime error
      When a single render output contains two child(SameModule, id: "static") entries under the same parent
      Then the runtime raises during reconcile with the conflicting path

  Rule: A child(...) must declare an id, and the id must be a string

    Scenario: Missing id is rejected
      When render returns child(FilterStore, current_user: u) with no id
      Then the runtime rejects the placeholder

    Scenario: Non-string id is rejected
      When render returns child(LineItemStore, id: 42, ...)
      Then the runtime rejects the placeholder
      And the developer is expected to call to_string/1 on numeric ids

  Rule: Lifecycle for child stores is mount(socket) and update(new_assigns, socket); no per-child unmount callback

    Scenario: First appearance triggers mount and render
      Given a child identity that does not yet exist
      When the parent's render emits a child(...) placeholder for that identity
      Then mount(socket) runs once
      And to_state(socket) runs after mount

    Scenario: Subsequent parent re-renders trigger update
      Given a mounted child receives the same identity in a later parent render with new parent-passed assigns
      Then update(new_assigns, socket) runs
      And to_state(socket) runs after update returns {:ok, socket}

    Scenario: Disappearance silently discards the node
      Given a mounted child node
      When the parent's next render output no longer includes that child(...)
      Then the node is dropped without invoking any callback
      And any async tasks the node had spawned continue running
      And their results, when they arrive, are lazy-discarded with [:arbor, :async, :lazy_discard] telemetry

  Rule: The root page store may define terminate(reason, socket)

    Scenario: Root terminate fires on runtime exit
      Given the root page store implements terminate(reason, socket)
      When the page runtime exits with reason :shutdown
      Then terminate(:shutdown, socket) is invoked before the runtime fully terminates

  Rule: A store may omit update/2; the default merges new_assigns into socket.assigns

    Scenario: Implicit merge in absence of update/2
      Given a store does not define update/2
      When the parent re-renders with new parent-passed assigns
      Then the runtime merges new_assigns into socket.assigns automatically
      And to_state(socket) runs against the merged assigns

  Rule: attr declares a parent-supplied assign with required, type, and default options

    Scenario: Required attr missing at the parent's child(...) call raises at the parent's render time
      Given a child store declares attr :current_user, User.t(), required: true
      When the parent renders child(ChildStore, id: "x") without current_user
      Then the parent's render raises with a message identifying the missing required attr

    Scenario: Default value applies when the parent omits a non-required attr
      Given a child store declares attr :selected, boolean(), default: false
      When the parent renders child(ChildStore, id: "x", product: p) without selected
      Then the child's socket.assigns.selected is false

    Scenario: Function-valued attr is invocable from the child
      Given the child declares attr :on_select, (%{id: String.t()} -> any()), required: true
      When the child invokes socket.assigns.on_select.(%{id: socket.assigns.product.id})
      Then the function returns its result to the child

  Rule: Function references must not appear in the resolved render output

    Scenario: Render that surfaces a function reference is rejected
      Given a buggy render returns %{handler: socket.assigns.on_select}
      When validation runs on the resolved output
      Then validation raises and identifies the offending field path

  Rule: A re-render of the root tree is triggered after each mutating callback

    Scenario Outline: Callbacks that mutate socket trigger a root render
      Given the runtime processes a <callback>
      When the callback returns with a new socket
      Then the runtime walks the tree from the root and resolves placeholders
      And validation and the diff engine see the updated output

      Examples:
        | callback        |
        | mount           |
        | update          |
        | handle_command  |
        | handle_async    |
        | handle_info     |

  Rule: A child whose socket.assigns is reference-equal to last cycle skips update/2 and to_state/1

    Scenario: Unrelated sibling re-renders without re-rendering this child
      Given a sibling's command mutates only the sibling's socket.assigns
      And this child's socket.assigns reference is unchanged from the previous cycle
      When the runtime walks the tree
      Then this child's update/2 is not invoked
      And this child's to_state/1 is not invoked
      And the previously resolved output for this child is reused

    Scenario: A no-op write breaks ref equality and forces re-render
      Given a handler writes the same value to the same assigns key (e.g., assign(socket, :status, socket.assigns.status))
      When the runtime walks the tree
      Then the assigns map reference has changed
      And update/2 and to_state/1 run for that child even though the value is semantically unchanged

  Rule: A disappeared child is unmounted; reappearance is a fresh mount with no preserved assigns

    Scenario: Toggling :if=false then :if=true on the same identity remounts
      Given child(NotificationStore, id: "n") rendered conditionally on :if={@show}
      When @show toggles false then true
      Then the first cycle drops the child node
      And the second cycle mounts a fresh node with new assigns

  Rule: invoke/3 calls a parent-supplied function attr with the payload as its single argument

    Scenario: Child calls an inline closure the parent passed via child(...)
      Given the parent renders child(ChildStore, id: "x", on_select: fn payload -> ...end)
      And the child reads socket.assigns.on_select
      When the child runs invoke(socket, :on_select, %{id: "prod_1"})
      Then the function at socket.assigns.on_select is called with the single argument %{id: "prod_1"}
      And invoke returns the child's socket (chainable via |>)

    Scenario: invoke on a missing callback raises
      Given the child has no value at socket.assigns.<callback_name>
      When the child runs invoke(socket, :missing, payload)
      Then the runtime raises a "missing callback" error pointing at the offending call site

  Rule: Render-output validation is run by the to_state validation hook after child resolution

    Scenario: Invalid output is rejected before diffing
      Given a store declares field :title, String.t()
      When render returns %{title: 42}
      Then validation raises before the diff engine runs

  Rule: Render-output validation is default-on in dev/test, telemetry-only in prod

    Scenario: Validation behaviour depends on environment
      Given the page runtime's :after_to_state hook list configures Arbor.Hooks.ValidateToState for dev/test
      When validation finds a shape mismatch in dev
      Then the runtime raises
      And in prod the same misshape is recorded as telemetry without raising

  Rule: A to_state/1 exception terminates the page runtime

    Scenario: Render raise crashes the runtime
      When to_state/1 raises a KeyError
      Then the page runtime exits
      And the supervisor restarts a fresh runtime
      And the next reconnect re-runs mount/1 from scratch

  Rule: Arbor.State modules declare reusable output types only

    Scenario: A state module is not a store
      Given MoneyState is defined as use Arbor.State with state do field :amount, integer() end
      Then MoneyState has no commands, no attr, no lifecycle, no runtime identity
      And child(MoneyState, id: ...) is rejected

  Rule: to_state/1 must be free of observable side effects

    Scenario: Database writes inside render are a contract violation
      Given a to_state/1 implementation calls Repo.insert!/1
      Then the implementation violates the contract
      And the runtime is permitted to invoke to_state/1 multiple times for diagnostic or telemetry purposes

  Rule: mount/1 and update/2 must return {:ok, socket}; non-conforming returns raise

    Scenario: Returning {:error, reason} from mount raises
      Given mount/1 returns {:error, :db_unavailable}
      Then the runtime raises with a "bad callback response" error
      And the page runtime exits per let-it-crash semantics

  Rule: Nullable state fields always emit the key with value null

    Scenario: Null value is encoded as JSON null
      Given a store declares field :avatar_url, String.t() | nil
      When the avatar_url is absent
      Then the resolved render output contains {"avatar_url": null}
      And the key is never omitted

  Rule: Variants in state are expressed as native typespec unions of literal-tagged maps

    Scenario: Discriminated union codegen
      Given a store declares field :event, %{type: :active} | %{type: :paused, value: integer()}
      Then codegen emits TypeScript { type: "active" } | { type: "paused"; value: number }
      And no custom variant() macro is required

  Rule: A field typed as another store's state can be populated by a raw map or a child placeholder

    Scenario: Raw map populates the field without mounting a child store
      Given a store declares field :header, HeaderStore.state()
      When render returns %{header: %{user_name: "Alice", avatar_url: nil}}
      Then validation accepts the value
      And no HeaderStore child node is mounted

    Scenario: child placeholder populates the field by mounting a child store
      Given a store declares field :header, HeaderStore.state()
      When render returns %{header: child(HeaderStore, id: "header", current_user: u)}
      Then the runtime mounts a HeaderStore child node and substitutes its render output

  Rule: child/2 is a plain function returning a sentinel; the runtime acts on it only when it appears in render output

    Scenario: child(...) called inside mount has no effect
      Given mount/1 calls assign(socket, :tmp, child(SomeStore, id: "x"))
      Then the runtime does not raise or warn
      And the sentinel sits in socket.assigns.tmp as inert data
      And no child node is mounted unless that value reaches to_state/1's output later
