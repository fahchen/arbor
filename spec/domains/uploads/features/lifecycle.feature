@uploads @lifecycle
Feature: Uploads Lifecycle
  As a store author
  I want to declare named upload slots whose lifecycle the client drives
  So that the server accepts file uploads with per-entry validation and limits without me composing wire markers by hand

  Background:
    Given a connected client
    And a page runtime mounted on the client's transport session

  Rule: A store declares an upload via upload :name, opts at the top level of the module

    Scenario: Simple top-level declaration
      Given a store source contains "upload :avatar, accept: ~w(.png), max_entries: 1, max_file_size: 5_000_000"
      When the project compiles
      Then the compiler registers an upload named :avatar on the store
      And the upload config carries accept [".png"], max_entries 1, max_file_size 5_000_000

    Scenario: Defaults apply when options are omitted
      Given a store declares upload :doc, accept: ~w(.pdf)
      Then max_entries defaults to 1
      And max_file_size defaults to 8_000_000
      And chunk_size defaults to 64_000
      And chunk_timeout defaults to 10_000

    Scenario: Required accept option
      Given a store source contains "upload :doc, max_entries: 1"
      When the project compiles
      Then the compiler reports a missing :accept error pointing at the upload declaration

    Scenario: Accept :any
      Given a store declares upload :anything, accept: :any
      Then the upload config records accept as :any
      And the preflight reply carries "any" in the accept config field

  Rule: Upload names are unique within one store

    Scenario: Duplicate upload name in one store
      Given a store source contains two declarations of upload :avatar
      When the project compiles
      Then the compiler reports a duplicate-upload error pointing at the second declaration

  Rule: Upload names must not collide with state field names

    Scenario: Upload name collides with state field
      Given a store source declares state field :avatar
      And the same store source declares upload :avatar, accept: ~w(.png)
      When the project compiles
      Then the compiler reports a name-collision error that names both the state field and the upload declaration sites

  Rule: Upload declarations are only allowed at the top level of a store

    Scenario: Upload inside state do
      Given a store source contains "state do upload :avatar, accept: ~w(.png) end"
      When the project compiles
      Then the compiler reports an "upload not allowed inside state" error

    Scenario: Upload inside a nested field block
      Given a store source contains "state do field :section do upload :avatar, accept: ~w(.png) end end"
      When the project compiles
      Then the compiler reports an "upload not allowed inside field" error

    Scenario: Upload inside a stream block
      Given a store source contains "state do stream :messages do upload :avatar, accept: ~w(.png) end end"
      When the project compiles
      Then the compiler reports an "upload not allowed inside stream" error

    Scenario: Upload inside a list type spec
      Given a store source contains a list type spec referencing upload :avatar
      When the project compiles
      Then the compiler reports an "upload not allowed inside list" error

  Rule: The framework injects an upload marker into the wire output

    Scenario: Single upload, no upload-related code in render
      Given a store declares upload :avatar, accept: ~w(.png)
      And the store's render/1 returns %{title: "Hi"}
      When the runtime renders the store
      Then the resolved wire output is %{"title" => "Hi", "avatar" => %{"__musubi_upload__" => "avatar"}, "__musubi_store_id__" => []}

    Scenario: Multiple uploads
      Given a store declares upload :avatar and upload :cover
      And the store's render/1 returns %{}
      When the runtime renders the store
      Then the wire output contains both %{"__musubi_upload__" => "avatar"} and %{"__musubi_upload__" => "cover"} at the store root

  Rule: Hand-written upload markers are rejected

    Scenario: Application returns a marker map from render
      Given a store declares upload :avatar
      And the store's render/1 returns %{avatar: %{"__musubi_upload__" => "avatar"}}
      When the runtime resolves the render
      Then the runtime raises a "hand-written upload marker" error pointing at the avatar path

    Scenario: Application references an undeclared upload
      Given the store does not declare any uploads
      And the store's render/1 returns %{avatar: %{"__musubi_upload__" => "avatar"}}
      When the runtime resolves the render
      Then the runtime raises an "unknown upload" error

  Rule: Per-item dynamic uploads use a child store per item

    Scenario: Child store carries the upload
      Given a CartLineStore declares upload :attachment, accept: ~w(.pdf)
      And a CartStore renders a list of CartLineStore children keyed by line id
      When the runtime renders both lines
      Then each child render output carries its own %{"__musubi_upload__" => "attachment"} marker
      And upload_ops for the children carry distinct store_id values matching the child's path
