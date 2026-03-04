defmodule LiteskillWeb.CommandPalette do
  @moduledoc false
  use LiteskillWeb, :html

  attr :conversations, :list, default: []

  def command_palette(assigns) do
    assigns = assign(assigns, :actions, actions())

    ~H"""
    <div
      id="command-palette"
      class="fixed inset-0 z-50 command-palette-backdrop"
      phx-click="close_command_palette"
      phx-window-keydown="close_command_palette"
      phx-key="Escape"
    >
      <div class="flex justify-center pt-[15vh]">
        <div
          class="w-full max-w-lg bg-base-200 rounded-xl shadow-2xl border border-base-300 overflow-hidden command-palette-panel"
          phx-click-away="close_command_palette"
        >
          <div class="p-3 border-b border-base-300">
            <input
              id="command-palette-input"
              type="text"
              placeholder="Search conversations and actions..."
              class="input input-bordered w-full"
              name="query"
              autocomplete="off"
              autofocus
              phx-hook="CommandPaletteFocus"
            />
          </div>
          <div class="max-h-80 overflow-y-auto p-1" id="command-palette-results">
            <div class="px-2 py-1 text-xs text-base-content/40 font-semibold uppercase tracking-wider">
              Actions
            </div>
            <button
              :for={action <- @actions}
              class="flex items-center gap-3 w-full px-3 py-2 rounded-lg text-sm hover:bg-base-300 transition-colors text-left"
              phx-click="command_palette_navigate"
              phx-value-path={action.path}
            >
              <.icon name={action.icon} class="size-4 text-base-content/50" />
              <span>{action.name}</span>
            </button>
            <div
              :if={@conversations != []}
              class="px-2 py-1 mt-2 text-xs text-base-content/40 font-semibold uppercase tracking-wider"
            >
              Recent Conversations
            </div>
            <button
              :for={conv <- Enum.take(@conversations, 10)}
              class="flex items-center gap-3 w-full px-3 py-2 rounded-lg text-sm hover:bg-base-300 transition-colors text-left"
              phx-click="command_palette_navigate"
              phx-value-path={"/c/#{conv.id}"}
            >
              <.icon name="hero-chat-bubble-left" class="size-4 text-base-content/50" />
              <span class="truncate">{conv.title || "Untitled"}</span>
            </button>
          </div>
          <div class="p-2 border-t border-base-300 flex items-center gap-4 text-xs text-base-content/40">
            <span>
              <kbd class="kbd kbd-xs">Esc</kbd> close
            </span>
            <span>
              <kbd class="kbd kbd-xs">Enter</kbd> select
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp actions do
    [
      %{name: "New Conversation", path: "/", icon: "hero-plus"},
      %{name: "Conversations", path: "/conversations", icon: "hero-chat-bubble-left-right"},
      %{name: "Wiki", path: "/wiki", icon: "hero-book-open"},
      %{name: "Data Sources", path: "/sources", icon: "hero-circle-stack"},
      %{name: "Tools", path: "/mcp", icon: "hero-wrench-screwdriver"},
      %{name: "Reports", path: "/reports", icon: "hero-document-text"},
      %{name: "Agent Studio", path: "/agents", icon: "hero-cpu-chip"},
      %{name: "Settings", path: "/settings", icon: "hero-cog-6-tooth"}
    ]
  end
end
