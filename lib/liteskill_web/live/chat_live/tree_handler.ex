defmodule LiteskillWeb.ChatLive.TreeHandler do
  @moduledoc false

  use LiteskillWeb, :html

  import Phoenix.LiveView, only: [push_navigate: 2, put_flash: 3]

  alias Liteskill.Chat

  def assigns do
    [
      show_tree_panel: false,
      tree_nodes: [],
      tree_diff: nil,
      tree_diff_conversation_id: nil
    ]
  end

  @events ~w(toggle_tree_panel fork_at_message show_branch_diff close_branch_diff)

  def events, do: @events

  def handle_event("toggle_tree_panel", _params, socket) do
    show = !socket.assigns.show_tree_panel

    socket =
      if show && socket.assigns.conversation do
        user_id = socket.assigns.current_user.id

        case Chat.get_conversation_tree(socket.assigns.conversation.id, user_id) do
          {:ok, nodes} -> assign(socket, tree_nodes: nodes, show_tree_panel: true)
          {:error, _} -> assign(socket, tree_nodes: [], show_tree_panel: true)
        end
      else
        assign(socket, show_tree_panel: false, tree_diff: nil, tree_diff_conversation_id: nil)
      end

    {:noreply, socket}
  end

  def handle_event("fork_at_message", %{"position" => position}, socket) do
    user_id = socket.assigns.current_user.id
    conversation = socket.assigns.conversation

    case Chat.fork_conversation(conversation.id, user_id, String.to_integer(position)) do
      {:ok, new_conv} ->
        {:noreply, push_navigate(socket, to: "/c/#{new_conv.id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Fork failed: #{inspect(reason)}")}
    end
  end

  def handle_event("show_branch_diff", %{"conversation-id" => other_id}, socket) do
    user_id = socket.assigns.current_user.id
    conversation = socket.assigns.conversation

    case Chat.diff_branches(conversation.id, other_id, user_id) do
      {:ok, diff} ->
        {:noreply, assign(socket, tree_diff: diff, tree_diff_conversation_id: other_id)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not load branch diff")}
    end
  end

  def handle_event("close_branch_diff", _params, socket) do
    {:noreply, assign(socket, tree_diff: nil, tree_diff_conversation_id: nil)}
  end
end
