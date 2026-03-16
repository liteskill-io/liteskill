defmodule LiteskillWeb.MemoriesComponents do
  @moduledoc false

  use Phoenix.Component

  import LiteskillWeb.CoreComponents, only: [icon: 1]

  attr :memory, :map, required: true

  def memory_card(assigns) do
    ~H"""
    <div class="card card-bordered bg-base-100 shadow-sm">
      <div class="card-body p-4">
        <div class="flex items-start justify-between gap-2">
          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-2 mb-1">
              <.category_badge category={@memory.category} />
              <h3 class="font-medium text-sm truncate">{@memory.title}</h3>
            </div>
            <p class="text-sm text-base-content/70 line-clamp-2">{@memory.content}</p>
            <p class="text-xs text-base-content/40 mt-2">
              {Calendar.strftime(@memory.inserted_at, "%b %d, %Y")}
              <span :if={@memory.conversation_id}>
                · from conversation
              </span>
            </p>
          </div>
          <div class="flex items-center gap-1 flex-shrink-0">
            <button
              phx-click="edit_memory"
              phx-value-id={@memory.id}
              class="btn btn-ghost btn-xs btn-square"
              title="Edit"
            >
              <.icon name="hero-pencil-micro" class="size-3.5" />
            </button>
            <button
              phx-click="delete_memory"
              phx-value-id={@memory.id}
              class="btn btn-ghost btn-xs btn-square text-error/60 hover:text-error"
              title="Delete"
            >
              <.icon name="hero-trash-micro" class="size-3.5" />
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :category, :string, required: true

  def category_badge(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm",
      category_class(@category)
    ]}>
      {@category}
    </span>
    """
  end

  defp category_class("decision"), do: "badge-primary"
  defp category_class("fact"), do: "badge-info"
  defp category_class("insight"), do: "badge-warning"
  defp category_class("preference"), do: "badge-secondary"
  defp category_class(_), do: "badge-ghost"

  attr :form, :any, required: true
  attr :title, :string, default: "Save Memory"

  def memory_form_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box">
        <h3 class="font-bold text-lg mb-4">{@title}</h3>
        <.form for={@form} phx-submit="save_memory" class="space-y-4">
          <div class="form-control">
            <label class="label"><span class="label-text">Title</span></label>
            <input
              type="text"
              name="memory[title]"
              value={Phoenix.HTML.Form.input_value(@form, :title)}
              class="input input-bordered w-full"
              placeholder="Brief title for this memory"
              required
            />
          </div>
          <div class="form-control">
            <label class="label"><span class="label-text">Content</span></label>
            <textarea
              name="memory[content]"
              class="textarea textarea-bordered w-full"
              rows="4"
              placeholder="What should be remembered?"
              required
            >{Phoenix.HTML.Form.input_value(@form, :content)}</textarea>
          </div>
          <div class="form-control">
            <label class="label"><span class="label-text">Category</span></label>
            <select name="memory[category]" class="select select-bordered w-full">
              <option
                value="insight"
                selected={Phoenix.HTML.Form.input_value(@form, :category) == "insight"}
              >
                Insight
              </option>
              <option
                value="decision"
                selected={Phoenix.HTML.Form.input_value(@form, :category) == "decision"}
              >
                Decision
              </option>
              <option
                value="fact"
                selected={Phoenix.HTML.Form.input_value(@form, :category) == "fact"}
              >
                Fact
              </option>
              <option
                value="preference"
                selected={Phoenix.HTML.Form.input_value(@form, :category) == "preference"}
              >
                Preference
              </option>
            </select>
          </div>
          <div class="modal-action">
            <button type="button" phx-click="close_save_memory" class="btn btn-ghost">Cancel</button>
            <button type="submit" class="btn btn-primary">Save</button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop" phx-click="close_save_memory"></div>
    </div>
    """
  end

  attr :suggestions, :list, required: true

  def memory_suggestions_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-lg">
        <h3 class="font-bold text-lg mb-2">
          <.icon name="hero-light-bulb-micro" class="size-5 text-warning inline" /> Suggested Memories
        </h3>
        <p class="text-sm text-base-content/60 mb-4">
          These insights were extracted from the conversation. Save the ones you want to keep.
        </p>
        <div class="space-y-3">
          <div
            :for={{suggestion, index} <- Enum.with_index(@suggestions)}
            class="card card-bordered bg-base-200/50"
          >
            <div class="card-body p-3">
              <div class="flex items-start justify-between gap-2">
                <div class="flex-1 min-w-0">
                  <div class="flex items-center gap-2 mb-1">
                    <.category_badge category={suggestion.category} />
                    <span class="font-medium text-sm">{suggestion.title}</span>
                  </div>
                  <p class="text-sm text-base-content/70">{suggestion.content}</p>
                </div>
                <div class="flex items-center gap-1 flex-shrink-0">
                  <button
                    phx-click="save_memory_suggestion"
                    phx-value-index={index}
                    class="btn btn-primary btn-xs"
                  >
                    Save
                  </button>
                  <button
                    phx-click="remove_memory_suggestion"
                    phx-value-index={index}
                    class="btn btn-ghost btn-xs"
                  >
                    <.icon name="hero-x-mark-micro" class="size-3.5" />
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>
        <div class="modal-action">
          <button phx-click="dismiss_memory_suggestions" class="btn btn-ghost btn-sm">
            Dismiss All
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="dismiss_memory_suggestions"></div>
    </div>
    """
  end

  attr :results, :list, required: true
  attr :query, :string, required: true

  def search_results_panel(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-2xl max-h-[80vh]">
        <div class="flex items-center justify-between mb-4">
          <h3 class="font-bold text-lg">
            <.icon name="hero-magnifying-glass-micro" class="size-5 inline" /> Search Messages
          </h3>
          <button phx-click="clear_search" class="btn btn-ghost btn-sm btn-circle">
            <.icon name="hero-x-mark-micro" class="size-4" />
          </button>
        </div>
        <form phx-change="search_messages" phx-submit="search_messages" class="mb-4">
          <input
            type="text"
            name="query"
            value={@query}
            placeholder="Search across all conversations..."
            class="input input-bordered w-full"
            phx-debounce="300"
            autocomplete="off"
            autofocus
          />
        </form>
        <div class="space-y-2 overflow-y-auto max-h-[55vh]">
          <div
            :for={result <- @results}
            class="card card-bordered bg-base-200/30 hover:bg-base-200/60 transition-colors cursor-pointer"
          >
            <.link navigate={"/c/#{result.conversation_id}"} class="card-body p-3">
              <div class="flex items-center gap-2 mb-1">
                <span class={[
                  "badge badge-xs",
                  if(result.role == "user", do: "badge-primary", else: "badge-ghost")
                ]}>
                  {result.role}
                </span>
                <span class="text-sm font-medium truncate">
                  {result.conversation_title || "Untitled"}
                </span>
              </div>
              <p class="text-sm text-base-content/70 line-clamp-2">
                {highlight_snippet(result.snippet || "", @query)}
              </p>
            </.link>
          </div>
          <p
            :if={@results == [] && @query != ""}
            class="text-center text-sm text-base-content/50 py-8"
          >
            No results found
          </p>
          <p :if={@query == ""} class="text-center text-sm text-base-content/50 py-8">
            Type to search across all your conversations
          </p>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="clear_search"></div>
    </div>
    """
  end

  defp highlight_snippet(snippet, _query) when snippet == "", do: ""

  defp highlight_snippet(snippet, _query) do
    # FTS5 uses << >> markers, LIKE doesn't - just render plain text
    snippet
    |> String.replace("<<", "")
    |> String.replace(">>", "")
  end

  attr :nodes, :list, required: true
  attr :current_conversation_id, :string, required: true
  attr :diff, :any, default: nil
  attr :diff_conversation_id, :string, default: nil

  def tree_panel(assigns) do
    ~H"""
    <div class="w-72 border-l border-base-300 bg-base-200/50 flex flex-col overflow-hidden flex-shrink-0">
      <div class="flex items-center justify-between p-3 border-b border-base-300">
        <h3 class="text-sm font-semibold">
          <.icon name="hero-share-micro" class="size-4 inline rotate-90" /> Conversation Tree
        </h3>
        <button phx-click="toggle_tree_panel" class="btn btn-ghost btn-xs btn-circle">
          <.icon name="hero-x-mark-micro" class="size-4" />
        </button>
      </div>
      <div class="flex-1 overflow-y-auto p-2 space-y-1">
        <.tree_node
          :for={node <- build_tree(@nodes)}
          node={node}
          current_id={@current_conversation_id}
          depth={0}
        />
      </div>
      <%= if @diff do %>
        <div class="border-t border-base-300 p-3 max-h-[40%] overflow-y-auto">
          <div class="flex items-center justify-between mb-2">
            <span class="text-xs font-semibold text-base-content/70">Branch Diff</span>
            <button phx-click="close_branch_diff" class="btn btn-ghost btn-xs btn-circle">
              <.icon name="hero-x-mark-micro" class="size-3" />
            </button>
          </div>
          <div class="text-xs space-y-1">
            <p class="text-base-content/50">{length(@diff.shared)} shared messages</p>
            <div :if={@diff.branch_a != []} class="pl-2 border-l-2 border-primary">
              <p class="font-medium text-primary">Current ({length(@diff.branch_a)})</p>
              <p
                :for={msg <- Enum.take(@diff.branch_a, 3)}
                class="truncate text-base-content/60"
              >
                {msg.role}: {String.slice(msg.content || "", 0..60)}
              </p>
            </div>
            <div :if={@diff.branch_b != []} class="pl-2 border-l-2 border-secondary">
              <p class="font-medium text-secondary">Other ({length(@diff.branch_b)})</p>
              <p
                :for={msg <- Enum.take(@diff.branch_b, 3)}
                class="truncate text-base-content/60"
              >
                {msg.role}: {String.slice(msg.content || "", 0..60)}
              </p>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  attr :node, :map, required: true
  attr :current_id, :string, required: true
  attr :depth, :integer, required: true

  defp tree_node(assigns) do
    ~H"""
    <div style={"padding-left: #{@depth * 12}px"}>
      <div class={[
        "flex items-center gap-1 rounded-lg px-2 py-1.5 text-xs transition-colors",
        if(@node.id == @current_id,
          do: "bg-primary/15 text-primary font-medium",
          else: "hover:bg-base-200 text-base-content/70"
        )
      ]}>
        <.icon
          :if={@node.children != []}
          name="hero-chevron-down-micro"
          class="size-3 text-base-content/40"
        />
        <.icon
          :if={@node.children == []}
          name="hero-minus-micro"
          class="size-3 text-base-content/30"
        />
        <.link
          navigate={"/c/#{@node.id}"}
          class="flex-1 truncate"
        >
          {@node.title || "Untitled"}
        </.link>
        <button
          :if={@node.id != @current_id}
          phx-click="show_branch_diff"
          phx-value-conversation-id={@node.id}
          class="btn btn-ghost btn-xs btn-circle opacity-0 group-hover:opacity-100"
          title="Compare"
        >
          <.icon name="hero-arrows-right-left-micro" class="size-3" />
        </button>
      </div>
      <.tree_node
        :for={child <- @node.children}
        node={child}
        current_id={@current_id}
        depth={@depth + 1}
      />
    </div>
    """
  end

  defp build_tree(nodes) do
    by_parent = Enum.group_by(nodes, & &1.parent_conversation_id)
    roots = Map.get(by_parent, nil, [])
    Enum.map(roots, &build_subtree(&1, by_parent))
  end

  defp build_subtree(node, by_parent) do
    children =
      by_parent
      |> Map.get(node.id, [])
      |> Enum.map(&build_subtree(&1, by_parent))

    %{id: node.id, title: node.title, parent_id: node.parent_conversation_id, children: children}
  end
end
