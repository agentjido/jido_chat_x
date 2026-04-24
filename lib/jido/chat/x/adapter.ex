defmodule Jido.Chat.X.Adapter do
  @moduledoc "X/Twitter Direct Messages `Jido.Chat.Adapter` implementation."
  use Jido.Chat.Adapter

  alias Jido.Chat.{
    Author,
    EventEnvelope,
    Incoming,
    Message,
    MessagePage,
    Response,
    WebhookRequest,
    WebhookResponse
  }

  alias Jido.Chat.X.Transport.XdkClient

  @impl true
  def channel_type, do: :x

  @impl true
  def capabilities do
    %{
      send_message: :native,
      delete_message: :native,
      fetch_messages: :native,
      webhook: :native,
      verify_webhook: :native,
      parse_event: :native,
      format_webhook_response: :native,
      send_file: :fallback,
      edit_message: :unsupported,
      start_typing: :unsupported,
      post_ephemeral: :unsupported,
      open_modal: :unsupported
    }
  end

  @impl true
  def transform_incoming(%{"dm_event" => event} = payload),
    do: {:ok, incoming_from_dm(event, payload)}

  def transform_incoming(%{"type" => "MessageCreate"} = event),
    do: {:ok, incoming_from_dm(event, event)}

  def transform_incoming(%{"event_type" => "MessageCreate"} = event),
    do: {:ok, incoming_from_dm(event, event)}

  def transform_incoming(_), do: {:error, :unsupported_payload}

  @impl true
  def send_message(room_id, text, opts \\ []) do
    result =
      if String.starts_with?(to_string(room_id), "conversation:") do
        conversation_id = String.replace_prefix(to_string(room_id), "conversation:", "")
        transport(opts).send_conversation_message(conversation_id, text, opts)
      else
        transport(opts).send_dm(to_string(room_id), text, opts)
      end

    with {:ok, raw} <- result do
      {:ok, response_from_send(raw, room_id)}
    end
  end

  @impl true
  def delete_message(_room_id, event_id, opts \\ []) do
    transport(opts).delete_dm_event(to_string(event_id), opts)
  end

  @impl true
  def fetch_messages(room_id, opts \\ []) do
    conversation_id = String.replace_prefix(to_string(room_id), "conversation:", "")

    with {:ok, raw} <- transport(opts).fetch_conversation_messages(conversation_id, opts) do
      events = raw["data"] || raw[:data] || raw

      messages =
        events
        |> List.wrap()
        |> Enum.map(&message_from_event(&1, room_id))

      {:ok, MessagePage.new(%{messages: messages, metadata: %{"raw" => raw}})}
    end
  end

  @impl true
  def verify_webhook(%WebhookRequest{method: method} = request, opts \\ []) do
    consumer_secret =
      Keyword.get(opts, :consumer_secret) || System.get_env("X_CONSUMER_SECRET") ||
        System.get_env("SECRET_KEY")

    cond do
      consumer_secret in [nil, ""] ->
        {:error, :missing_consumer_secret}

      String.upcase(method || "POST") == "GET" and crc_token(request) not in [nil, ""] ->
        :ok

      true ->
        signature = WebhookRequest.header(request, "x-twitter-webhooks-signature")

        if signature not in [nil, ""] and
             secure_compare(signature, "sha256=" <> hmac(consumer_secret, raw_body(request))) do
          :ok
        else
          {:error, :invalid_signature}
        end
    end
  end

  @impl true
  def parse_event(%WebhookRequest{method: method} = request, _opts \\ []) do
    if String.upcase(method || "POST") == "GET" do
      {:ok, :noop}
    else
      events =
        request.payload["direct_message_events"] || request.payload["dm_events"] ||
          request.payload["data"] || []

      case List.wrap(events) do
        [event | _] ->
          with {:ok, incoming} <- transform_incoming(%{"dm_event" => event}) do
            {:ok,
             EventEnvelope.new(%{
               adapter_name: :x,
               event_type: :message,
               thread_id: thread_id(incoming.external_room_id),
               channel_id: to_string(incoming.external_room_id),
               message_id: to_string(incoming.external_message_id),
               payload: incoming,
               raw: request.payload,
               metadata: %{"for_user_id" => request.payload["for_user_id"]}
             })}
          end

        [] ->
          {:ok, :noop}
      end
    end
  end

  @impl true
  def format_webhook_response(%WebhookRequest{method: method} = request, opts)
      when is_binary(method) do
    if String.upcase(method) == "GET" and crc_token(request) do
      secret =
        Keyword.get(opts, :consumer_secret) || System.get_env("X_CONSUMER_SECRET") ||
          System.get_env("SECRET_KEY")

      WebhookResponse.new(%{
        status: 200,
        body: %{"response_token" => "sha256=" <> hmac_base64(secret, crc_token(request))}
      })
    else
      WebhookResponse.accepted()
    end
  end

  def format_webhook_response({:ok, _chat, _incoming}, _opts), do: WebhookResponse.accepted()
  def format_webhook_response({:ok, :noop}, _opts), do: WebhookResponse.accepted()

  def format_webhook_response({:error, reason}, _opts),
    do: WebhookResponse.error(400, inspect(reason))

  def format_webhook_response(_, _opts), do: WebhookResponse.accepted()

  defp incoming_from_dm(event, payload) do
    id = event["id"] || event["dm_event_id"]

    conversation_id =
      event["dm_conversation_id"] || event["conversation_id"] ||
        get_in(event, ["dm_conversation", "id"])

    sender_id = event["sender_id"] || get_in(event, ["message_create", "sender_id"])
    text = event["text"] || get_in(event, ["message_create", "message_data", "text"]) || ""

    Incoming.new(%{
      external_room_id: "conversation:#{conversation_id || sender_id}",
      external_thread_id: conversation_id && to_string(conversation_id),
      external_message_id: id && to_string(id),
      external_user_id: sender_id && to_string(sender_id),
      text: text,
      timestamp: event["created_at"],
      author: author(sender_id),
      chat_type: :direct_message,
      raw: payload,
      metadata: %{"conversation_id" => conversation_id}
    })
  end

  defp message_from_event(event, room_id) do
    Message.new(%{
      id: to_string(event["id"] || event["dm_event_id"] || Jido.Chat.ID.generate!()),
      thread_id: thread_id(room_id),
      channel_id: to_string(room_id),
      text: event["text"] || get_in(event, ["message_create", "message_data", "text"]),
      raw: event,
      author: author(event["sender_id"] || get_in(event, ["message_create", "sender_id"])),
      created_at: event["created_at"],
      external_message_id: to_string(event["id"] || event["dm_event_id"]),
      external_room_id: room_id
    })
  end

  defp response_from_send(raw, room_id) do
    data = raw["data"] || raw[:data] || raw

    Response.new(%{
      external_message_id: data["dm_event_id"] || data[:dm_event_id] || data["id"],
      external_room_id:
        "conversation:#{data["dm_conversation_id"] || data[:dm_conversation_id] || room_id}",
      channel_type: :x,
      raw: raw
    })
  end

  defp author(nil), do: nil

  defp author(user_id),
    do: Author.new(%{user_id: to_string(user_id), user_name: to_string(user_id)})

  defp transport(opts), do: Keyword.get(opts, :transport, XdkClient)
  defp thread_id(room_id), do: "x:#{room_id}"
  defp crc_token(%WebhookRequest{query: query}), do: query["crc_token"] || query[:crc_token]
  defp raw_body(%WebhookRequest{raw: raw}) when is_binary(raw), do: raw
  defp raw_body(%WebhookRequest{metadata: %{"raw_body" => raw}}) when is_binary(raw), do: raw
  defp raw_body(%WebhookRequest{metadata: %{raw_body: raw}}) when is_binary(raw), do: raw
  defp raw_body(%WebhookRequest{payload: payload}), do: Jason.encode!(payload)
  defp hmac(secret, data), do: :crypto.mac(:hmac, :sha256, secret, data) |> Base.encode64()
  defp hmac_base64(secret, data), do: hmac(secret, data)
  defp secure_compare(a, b) when byte_size(a) == byte_size(b), do: :crypto.hash_equals(a, b)
  defp secure_compare(_, _), do: false
end
