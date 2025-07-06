defmodule ServerProxy do
  @text_encoding_types ["text/plain", "text/html", "text/css", "text/javascript", "text/csv"]
  use GenServer

  @impl true
  def init(state \\ %{}) do
    {:ok, state}
  end

  @impl true
  def handle_cast(
        {:relay,
         {%Message.Header{
            RequestType: request_type,
            Route: route,
            RequestHeaders: request_headers,
            ContentType: content_type
          } = req_headers, body}, request_id, peer_connection, data_channel},
        state
      ) do
    headers =
      case content_type do
        "" -> request_headers
        _ -> Map.put(request_headers, "Content-Type", content_type)
      end

    req =
      case content_type do
        "" ->
          Req.new(url: route, headers: headers, method: request_type)

        "application/json" ->
          Req.new(url: route, headers: headers, method: request_type, json: body)

        "multipart/form-data" ->
          multipart_req(headers, body, route, request_type)

        val when val in @text_encoding_types ->
          Req.new(url: route, headers: headers, method: request_type, body: body)
      end

    {_, resp} = Req.run(req)

    resp_header =
      resp.headers["content-type"] |> Enum.at(0) |> String.split(";") |> Enum.at(0)

    IO.inspect("received req_id #{request_id}")

    encoded =
      req_headers
      |> Map.put(:ContentType, resp_header)
      |> WebRTCMessageEncoder.encode_message(resp.body, request_id)

    Enum.each(encoded, fn part ->
      ExWebRTC.PeerConnection.send_data(peer_connection, data_channel, part, :binary)
    end)

    {:noreply, state}
  end

  def relay(pid, element) do
    GenServer.cast(pid, element)
  end

  defp multipart_req(headers, body, route, request_type) do
    headers = Map.drop(headers, ["Content-Type"])
    textContent = Map.get(body, :TextContent)

    multiparts_text =
      textContent
      |> Map.keys()
      |> Enum.reduce(%{}, fn elem, acc ->
        Map.put(acc, elem, Map.get(textContent, elem))
      end)

    multipart =
      Map.get(body, :Files)
      |> Enum.reduce(multiparts_text, fn elem, acc ->
        Map.put(
          acc,
          Map.get(elem, :FileName),
          {Map.get(elem, :FileContent), filename: Map.get(elem, :FileName)}
        )
      end)

    Req.new(
      url: route,
      headers: headers,
      method: request_type,
      form_multipart: multipart
    )
  end
end
