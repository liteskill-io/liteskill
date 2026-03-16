defmodule LiteskillWeb.MemoriesLive do
  @moduledoc false

  use LiteskillWeb, :live_view

  alias Liteskill.Memories
  alias Liteskill.Memories.Memory
  alias LiteskillWeb.MemoriesComponents

  @page_size 20

  @impl true
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_user.id

    {memories, total} =
      if connected?(socket) do
        {Memories.list_memories(user_id, limit: @page_size), Memories.count_memories(user_id)}
      else
        {[], 0}
      end

    {:ok,
     assign(socket,
       memories: memories,
       total: total,
       page: 1,
       page_size: @page_size,
       search: "",
       category_filter: nil,
       editing_memory: nil,
       memory_form: nil,
       show_form: false,
       confirm_delete_id: nil,
       page_title: "Memories",
       has_admin_access: connected?(socket) && Liteskill.Rbac.has_any_admin_permission?(user_id),
       single_user_mode: Liteskill.SingleUser.enabled?()
     ), layout: {LiteskillWeb.Layouts, :chat}}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen">
      <LiteskillWeb.Layouts.sidebar
        sidebar_open={true}
        live_action={:memories}
        conversations={[]}
        current_user={@current_user}
        has_admin_access={@has_admin_access}
        single_user_mode={@single_user_mode}
      />
      <main class="flex-1 flex flex-col min-w-0">
        <header class="px-4 py-3 border-b border-base-300 flex-shrink-0">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-2">
              <.icon name="hero-light-bulb-micro" class="size-5 text-warning" />
              <h1 class="text-lg font-semibold">Memories</h1>
              <span class="text-sm text-base-content/50">({@total})</span>
            </div>
            <button phx-click="new_memory" class="btn btn-primary btn-sm gap-1">
              <.icon name="hero-plus-micro" class="size-4" /> New Memory
            </button>
          </div>
        </header>

        <div class="p-4 border-b border-base-300 flex items-center gap-3">
          <form phx-change="search" phx-submit="search" class="flex-1">
            <input
              type="text"
              name="search"
              value={@search}
              placeholder="Search memories..."
              class="input input-bordered input-sm w-full max-w-sm"
              phx-debounce="300"
              autocomplete="off"
            />
          </form>
          <div class="flex gap-1">
            <button
              :for={cat <- ["all" | Memory.categories()]}
              phx-click="filter_category"
              phx-value-category={cat}
              class={[
                "btn btn-xs",
                if((@category_filter == nil && cat == "all") || @category_filter == cat,
                  do: "btn-primary",
                  else: "btn-ghost"
                )
              ]}
            >
              {cat}
            </button>
          </div>
        </div>

        <div class="flex-1 overflow-y-auto p-4">
          <div :if={@memories != []} class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            <MemoriesComponents.memory_card :for={memory <- @memories} memory={memory} />
          </div>
          <p :if={@memories == []} class="text-center text-base-content/50 py-12">
            {if @search != "" || @category_filter,
              do: "No memories match your filters.",
              else: "No memories yet. Save insights from your conversations!"}
          </p>

          <div
            :if={@total > @page_size}
            class="flex justify-center items-center gap-2 py-4 mt-4"
          >
            <button
              :if={@page > 1}
              phx-click="page"
              phx-value-page={@page - 1}
              class="btn btn-ghost btn-sm"
            >
              Previous
            </button>
            <span class="text-sm text-base-content/60">
              Page {@page} of {ceil(@total / @page_size)}
            </span>
            <button
              :if={@page * @page_size < @total}
              phx-click="page"
              phx-value-page={@page + 1}
              class="btn btn-ghost btn-sm"
            >
              Next
            </button>
          </div>
        </div>
      </main>

      <MemoriesComponents.memory_form_modal
        :if={@show_form}
        form={@memory_form}
        title={if @editing_memory, do: "Edit Memory", else: "New Memory"}
      />

      <LiteskillWeb.ChatComponents.confirm_modal
        show={@confirm_delete_id != nil}
        title="Delete memory"
        message="Are you sure you want to delete this memory?"
        confirm_event="confirm_delete"
        cancel_event="cancel_delete"
        confirm_label="Delete"
      />
    </div>
    """
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, reload_memories(assign(socket, search: String.trim(search), page: 1))}
  end

  @impl true
  def handle_event("filter_category", %{"category" => "all"}, socket) do
    {:noreply, reload_memories(assign(socket, category_filter: nil, page: 1))}
  end

  @impl true
  def handle_event("filter_category", %{"category" => cat}, socket) do
    {:noreply, reload_memories(assign(socket, category_filter: cat, page: 1))}
  end

  @impl true
  def handle_event("page", %{"page" => page}, socket) do
    {:noreply, reload_memories(assign(socket, page: String.to_integer(page)))}
  end

  @impl true
  def handle_event("new_memory", _params, socket) do
    form = to_form(%{"title" => "", "content" => "", "category" => "insight"}, as: :memory)
    {:noreply, assign(socket, show_form: true, memory_form: form, editing_memory: nil)}
  end

  @impl true
  def handle_event("edit_memory", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id

    case Memories.get_memory(id, user_id) do
      {:ok, memory} ->
        form =
          to_form(
            %{"title" => memory.title, "content" => memory.content, "category" => memory.category},
            as: :memory
          )

        {:noreply, assign(socket, show_form: true, memory_form: form, editing_memory: memory)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Memory not found")}
    end
  end

  @impl true
  def handle_event("close_save_memory", _params, socket) do
    {:noreply, assign(socket, show_form: false, memory_form: nil, editing_memory: nil)}
  end

  @impl true
  def handle_event("save_memory", %{"memory" => params}, socket) do
    user_id = socket.assigns.current_user.id

    result =
      if socket.assigns.editing_memory do
        Memories.update_memory(socket.assigns.editing_memory.id, atomize_keys(params), user_id)
      else
        Memories.create_memory(atomize_keys(params), user_id)
      end

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(show_form: false, memory_form: nil, editing_memory: nil)
         |> put_flash(:info, "Memory saved")
         |> reload_memories()}

      {:error, changeset} ->
        {:noreply, assign(socket, memory_form: to_form(changeset, as: :memory))}
    end
  end

  @impl true
  def handle_event("delete_memory", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirm_delete_id: id)}
  end

  @impl true
  def handle_event("confirm_delete", _params, socket) do
    user_id = socket.assigns.current_user.id

    case Memories.delete_memory(socket.assigns.confirm_delete_id, user_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(confirm_delete_id: nil)
         |> put_flash(:info, "Memory deleted")
         |> reload_memories()}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(confirm_delete_id: nil)
         |> put_flash(:error, "Failed to delete memory")}
    end
  end

  @impl true
  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, confirm_delete_id: nil)}
  end

  defp reload_memories(socket) do
    user_id = socket.assigns.current_user.id
    search = socket.assigns.search
    category = socket.assigns.category_filter

    opts =
      [limit: socket.assigns.page_size, offset: (socket.assigns.page - 1) * socket.assigns.page_size]
      |> then(fn o -> if search == "", do: o, else: Keyword.put(o, :search, search) end)
      |> then(fn o -> if category, do: Keyword.put(o, :category, category), else: o end)

    memories = Memories.list_memories(user_id, opts)
    total = Memories.count_memories(user_id, opts)

    assign(socket, memories: memories, total: total)
  end

  defp atomize_keys(params) do
    Map.new(params, fn {k, v} -> {String.to_existing_atom(k), v} end)
  end
end
