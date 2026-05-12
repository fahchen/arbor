# VoteCast

A real-time live polling app built with Arbor. Demonstrates multi-page
architecture with child store composition, streamed options, async vote
casting, PubSub-driven cross-user updates, and polling status gating.

## Pages

| Page | Root Store | Child Stores | Key features |
| :-- | :-- | :-- | :-- |
| Dashboard | `MyApp.Stores.DashboardStore` | `DashboardHeaderStore` | Child store composition, streamed poll cards, PubSub refresh |
| Poll Room | `MyApp.Stores.PollRoomStore` | (none — single store) | Streamed options, async vote commands, PubSub live updates |

## Store trees

```text
MyApp.Stores.DashboardStore (root)
  state:
    header   MyApp.Stores.DashboardHeaderStore — poll counts
    polls    stream of MyApp.PollSummary

  MyApp.Stores.DashboardHeaderStore ("header")
    attrs: active_count, closed_count, total_count
    state:
      active_count, closed_count, total_count

MyApp.Stores.PollRoomStore (root)
  attrs: poll_id
  state:
    poll       MyApp.PollDetail
    options    stream of MyApp.PollOption
    user_vote  AsyncResult<string | nil>
```

## Commands

### Poll Room

| Command | Payload | Reply | Behavior |
| :-- | :-- | :-- | :-- |
| `vote` | `{ option_id: string }` | `{ status: "voted" \| "closed" }` | Casts or changes your vote on the active poll. |
| `reset_vote` | `{}` | `{ status: "reset" }` | Removes your vote. |
| `toggle_status` | `{}` | `{ status: "active" \| "closed" }` | Opens or closes the poll. |

## Start the example

From the repository root:

```sh
cd examples/poll_app
mix deps.get
mix compile
mix run --no-halt
```

In another terminal:

```sh
cd examples/poll_app/ui
pnpm install
pnpm dev
```

Open http://localhost:4103. Open a second browser tab to see live cross-user
updates via PubSub.

## Seeded polls

Six polls are seeded on startup:

| Poll ID | Title | Options |
| :-- | :-- | :-- |
| `food-poll` | What should we eat? | Tacos, Pizza, Sushi, Ramen |
| `lang-poll` | Favorite language? | Elixir, Rust, TypeScript |
| `editor-poll` | Best code editor? | VS Code, Neovim, Helix, Zed |
| `work-poll` | Remote or office? | Remote, Office, Hybrid |
| `coffee-poll` | Coffee or tea? | Coffee, Tea, Neither — water |
| `season-poll` | Favorite season? | Spring, Summer, Autumn, Winter |
