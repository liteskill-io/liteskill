defmodule LiteskillWeb.ChatLive.NotationHandler do
  @moduledoc false

  use LiteskillWeb, :html

  import Phoenix.LiveView, only: [consume_uploaded_entries: 3, push_event: 3, push_navigate: 2, put_flash: 3]

  alias Liteskill.Chat.ConversationNotation

  def assigns do
    [
      show_json_viewer: false,
      json_content: nil,
      json_notation: nil
    ]
  end

  @events ~w(toggle_json_view download_json import_conversation)

  def events, do: @events

  def handle_event("toggle_json_view", _params, socket) do
    if socket.assigns.show_json_viewer do
      {:noreply, assign(socket, show_json_viewer: false, json_content: nil, json_notation: nil)}
    else
      conversation = socket.assigns.conversation
      user_id = socket.assigns.current_user.id

      case ConversationNotation.export(conversation.id, user_id) do
        {:ok, notation} ->
          {:ok, json} = ConversationNotation.encode(notation)
          {:noreply, assign(socket, show_json_viewer: true, json_content: json, json_notation: notation)}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Failed to export conversation.")}
      end
    end
  end

  def handle_event("download_json", _params, socket) do
    notation = socket.assigns.json_notation

    if notation do
      {:ok, json} = ConversationNotation.encode(notation)
      title = get_in(notation, ["conversation", "title"]) || "conversation"
      safe_title = title |> String.replace(~r/[^\w\s-]/, "") |> String.replace(~r/\s+/, "_") |> String.slice(0, 50)
      filename = "#{safe_title}.json"
      {:noreply, push_event(socket, "download_json", %{filename: filename, content: json})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("import_conversation", _params, socket) do
    user_id = socket.assigns.current_user.id

    results =
      consume_uploaded_entries(socket, :conversation_import, fn %{path: path}, _entry ->
        json = File.read!(path)
        {:ok, ConversationNotation.import_conversation(json, user_id)}
      end)

    case results do
      [{:ok, conversation} | _] ->
        {:noreply,
         socket
         |> put_flash(:info, "Conversation imported successfully.")
         |> push_navigate(to: "/c/#{conversation.id}")}

      [{:error, :invalid_json} | _] ->
        {:noreply, put_flash(socket, :error, "Invalid JSON file.")}

      [{:error, :invalid_notation} | _] ->
        {:noreply, put_flash(socket, :error, "Invalid notation format.")}

      [{:error, :forbidden} | _] ->
        {:noreply, put_flash(socket, :error, "You don't have permission to create conversations.")}

      [{:error, _reason} | _] ->
        {:noreply, put_flash(socket, :error, "Failed to import conversation.")}

      [] ->
        {:noreply, put_flash(socket, :error, "No file selected.")}
    end
  end

  # --- Components ---

  attr :show_json_viewer, :boolean, required: true
  attr :json_notation, :map, default: nil

  def json_viewer(assigns) do
    ~H"""
    <div
      :if={@show_json_viewer && @json_notation}
      class="flex-1 flex flex-col min-h-0 overflow-hidden"
    >
      <div class="flex items-center gap-2 px-4 py-2 border-b border-base-300 bg-base-200/50 flex-shrink-0">
        <span class="text-sm font-semibold text-base-content/70">JSON Notation</span>
        <div class="flex-1" />
        <button phx-click="download_json" class="btn btn-ghost btn-xs" title="Download">
          <.icon name="hero-arrow-down-tray-micro" class="size-4" />
        </button>
        <button
          id="copy-json-btn"
          phx-hook="CopyToClipboard"
          data-copy-target="json-viewer-content"
          class="btn btn-ghost btn-xs"
          title="Copy to clipboard"
        >
          <.icon name="hero-clipboard-micro" class="size-4" />
        </button>
      </div>
      <div id="json-viewer-content" class="flex-1 overflow-y-auto px-4 py-3 font-mono text-sm">
        <.json_node value={@json_notation} key_name={nil} open={true} depth={0} />
      </div>
    </div>
    """
  end

  attr :value, :any, required: true
  attr :key_name, :any, default: nil
  attr :open, :boolean, default: true
  attr :depth, :integer, default: 0

  defp json_node(%{value: value} = assigns) when is_map(value) do
    assigns = assign(assigns, entries: Enum.to_list(value), count: map_size(value))

    ~H"""
    <details open={@open} class="ml-4">
      <summary class="cursor-pointer hover:bg-base-200 rounded px-1 -ml-4 list-none">
        <span :if={@key_name} class="text-info">{inspect(@key_name)}</span>
        <span :if={@key_name} class="text-base-content/40">: </span>
        <span class="text-base-content/40">&lbrace;</span>
        <span class="text-base-content/30 text-xs ml-1">{@count} keys</span>
      </summary>
      <div :for={{k, v} <- @entries}>
        <.json_node value={v} key_name={k} open={@depth < 1} depth={@depth + 1} />
      </div>
      <div class="-ml-0 text-base-content/40">&rbrace;</div>
    </details>
    """
  end

  defp json_node(%{value: value} = assigns) when is_list(value) do
    assigns = assign(assigns, items: Enum.with_index(value), count: length(value))

    ~H"""
    <details open={@open} class="ml-4">
      <summary class="cursor-pointer hover:bg-base-200 rounded px-1 -ml-4 list-none">
        <span :if={@key_name} class="text-info">{inspect(@key_name)}</span>
        <span :if={@key_name} class="text-base-content/40">: </span>
        <span class="text-base-content/40">[</span>
        <span class="text-base-content/30 text-xs ml-1">{@count} items</span>
        <%= if @key_name == "messages" do %>
          <.message_badges items={Enum.map(@items, &elem(&1, 0))} />
        <% end %>
      </summary>
      <div :for={{item, idx} <- @items}>
        <%= if @key_name == "messages" && is_map(item) do %>
          <.message_node message={item} idx={idx} depth={@depth + 1} />
        <% else %>
          <.json_node value={item} key_name={nil} open={@depth < 1} depth={@depth + 1} />
        <% end %>
      </div>
      <div class="-ml-0 text-base-content/40">]</div>
    </details>
    """
  end

  defp json_node(%{value: value} = assigns) when is_binary(value) do
    assigns = assign(assigns, :truncated, String.length(value) > 200)

    ~H"""
    <div class="ml-4 flex flex-wrap items-baseline gap-1">
      <span :if={@key_name} class="text-info">{inspect(@key_name)}</span>
      <span :if={@key_name} class="text-base-content/40">: </span>
      <%= if @truncated do %>
        <details class="inline">
          <summary class="cursor-pointer text-success">
            {inspect(String.slice(@value, 0, 200))}<span class="text-base-content/40">...</span>
          </summary>
          <pre class="whitespace-pre-wrap break-all text-success bg-base-200 rounded p-2 mt-1 text-xs">{@value}</pre>
        </details>
      <% else %>
        <span class="text-success">{inspect(@value)}</span>
      <% end %>
    </div>
    """
  end

  defp json_node(%{value: value} = assigns) when is_number(value) do
    ~H"""
    <div class="ml-4">
      <span :if={@key_name} class="text-info">{inspect(@key_name)}</span>
      <span :if={@key_name} class="text-base-content/40">: </span>
      <span class="text-warning">{inspect(@value)}</span>
    </div>
    """
  end

  defp json_node(%{value: value} = assigns) when is_boolean(value) do
    ~H"""
    <div class="ml-4">
      <span :if={@key_name} class="text-info">{inspect(@key_name)}</span>
      <span :if={@key_name} class="text-base-content/40">: </span>
      <span class="text-accent">{inspect(@value)}</span>
    </div>
    """
  end

  defp json_node(assigns) do
    ~H"""
    <div class="ml-4">
      <span :if={@key_name} class="text-info">{inspect(@key_name)}</span>
      <span :if={@key_name} class="text-base-content/40">: </span>
      <span class="text-base-content/50">null</span>
    </div>
    """
  end

  attr :items, :list, required: true

  defp message_badges(assigns) do
    ~H"""
    <span class="ml-2">
      <span
        :for={msg <- @items}
        :if={is_map(msg)}
        class={[
          "inline-block w-2 h-2 rounded-full mr-0.5",
          msg["role"] == "user" && "bg-primary",
          msg["role"] == "assistant" && "bg-secondary"
        ]}
        title={msg["role"]}
      />
    </span>
    """
  end

  attr :message, :map, required: true
  attr :idx, :integer, required: true
  attr :depth, :integer, default: 0

  defp message_node(assigns) do
    role = assigns.message["role"]

    content_preview =
      case assigns.message["content"] do
        [%{"text" => text} | _] -> String.slice(text, 0, 80)
        [%{"toolUse" => %{"name" => name}} | _] -> "tool: #{name}"
        [%{"toolResult" => _} | _] -> "tool result"
        _ -> ""
      end

    assigns = assign(assigns, role: role, content_preview: content_preview)

    ~H"""
    <details class="ml-4" open={false} id={"msg-#{@idx}"} phx-hook="ExpandChildren">
      <summary class="cursor-pointer hover:bg-base-200 rounded px-1 -ml-4 list-none">
        <span class={[
          "inline-block px-1.5 py-0.5 rounded text-xs font-medium mr-1",
          @role == "user" && "bg-primary/20 text-primary",
          @role == "assistant" && "bg-secondary/20 text-secondary"
        ]}>
          {@role}
        </span>
        <span class="text-base-content/50 text-xs">{@content_preview}</span>
      </summary>
      <.json_node value={@message} key_name={nil} open={true} depth={@depth} />
    </details>
    """
  end

  attr :uploads, :any, required: true

  def import_section(assigns) do
    ~H"""
    <div class="mt-4">
      <form
        id="import-form"
        phx-change="validate_import"
        phx-submit="import_conversation"
        class="flex flex-col items-center gap-2"
      >
        <label class="btn btn-outline btn-sm gap-2 cursor-pointer">
          <.icon name="hero-arrow-up-tray-micro" class="size-4" /> Import from JSON
          <.live_file_input upload={@uploads.conversation_import} class="hidden" />
        </label>
        <%= for entry <- @uploads.conversation_import.entries do %>
          <div class="flex items-center gap-2 text-sm text-base-content/70">
            <span>{entry.client_name}</span>
            <button type="submit" class="btn btn-primary btn-xs">Import</button>
          </div>
        <% end %>
      </form>
    </div>
    """
  end
end
