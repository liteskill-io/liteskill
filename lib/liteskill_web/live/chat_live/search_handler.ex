defmodule LiteskillWeb.ChatLive.SearchHandler do
  @moduledoc false

  use LiteskillWeb, :html

  alias Liteskill.Chat

  def assigns do
    [
      show_search: false,
      search_query: "",
      search_results: [],
      search_loading: false
    ]
  end

  @events ~w(toggle_search search_messages clear_search)

  def events, do: @events

  def handle_event("toggle_search", _params, socket) do
    show = !socket.assigns.show_search

    socket =
      if show do
        assign(socket, show_search: true)
      else
        assign(socket, show_search: false, search_query: "", search_results: [])
      end

    {:noreply, socket}
  end

  def handle_event("search_messages", %{"query" => query}, socket) do
    query = String.trim(query)

    if query == "" do
      {:noreply, assign(socket, search_query: query, search_results: [])}
    else
      user_id = socket.assigns.current_user.id
      results = Chat.search_messages(user_id, query, limit: 20)
      {:noreply, assign(socket, search_query: query, search_results: results)}
    end
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, assign(socket, search_query: "", search_results: [], show_search: false)}
  end
end
