defmodule LiteskillWeb.ChatLive.MemoryHandler do
  @moduledoc false

  use LiteskillWeb, :html

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Liteskill.Memories

  def assigns do
    [
      show_memory_form: false,
      memory_form: nil,
      memory_suggestions: [],
      show_memory_suggestions: false
    ]
  end

  @events ~w(open_save_memory close_save_memory save_memory
             dismiss_memory_suggestions save_memory_suggestion
             remove_memory_suggestion)

  def events, do: @events

  def handle_event("open_save_memory", _params, socket) do
    form =
      to_form(
        %{"title" => "", "content" => "", "category" => "insight"},
        as: :memory
      )

    {:noreply, assign(socket, show_memory_form: true, memory_form: form)}
  end

  def handle_event("close_save_memory", _params, socket) do
    {:noreply, assign(socket, show_memory_form: false, memory_form: nil)}
  end

  def handle_event("save_memory", %{"memory" => params}, socket) do
    user_id = socket.assigns.current_user.id
    conversation_id = socket.assigns.conversation && socket.assigns.conversation.id

    attrs = %{
      title: params["title"],
      content: params["content"],
      category: params["category"],
      conversation_id: conversation_id
    }

    case Memories.create_memory(attrs, user_id) do
      {:ok, _memory} ->
        {:noreply,
         socket
         |> assign(show_memory_form: false, memory_form: nil)
         |> put_flash(:info, "Memory saved")}

      {:error, changeset} ->
        {:noreply, assign(socket, memory_form: to_form(changeset, as: :memory))}
    end
  end

  def handle_event("save_memory_suggestion", %{"index" => index}, socket) do
    index = String.to_integer(index)
    suggestion = Enum.at(socket.assigns.memory_suggestions, index)

    if suggestion do
      user_id = socket.assigns.current_user.id
      conversation_id = socket.assigns.conversation && socket.assigns.conversation.id

      case Memories.create_memory(Map.put(suggestion, :conversation_id, conversation_id), user_id) do
        {:ok, _} ->
          remaining = List.delete_at(socket.assigns.memory_suggestions, index)
          show = remaining != []

          {:noreply,
           socket
           |> assign(memory_suggestions: remaining, show_memory_suggestions: show)
           |> put_flash(:info, "Memory saved")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to save memory")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_memory_suggestion", %{"index" => index}, socket) do
    index = String.to_integer(index)
    remaining = List.delete_at(socket.assigns.memory_suggestions, index)
    show = remaining != []
    {:noreply, assign(socket, memory_suggestions: remaining, show_memory_suggestions: show)}
  end

  def handle_event("dismiss_memory_suggestions", _params, socket) do
    {:noreply, assign(socket, show_memory_suggestions: false, memory_suggestions: [])}
  end
end
