defmodule ServerProxy do
  def start(callback_pid) do
    Task.start(fn -> loop(%{callback_pid: callback_pid}) end)
  end

  defp loop(state) do
    receive do
      {:relay,
       {%Message.Header{
          RequestType: request_type,
          Route: route,
          RequestHeaders: request_headers,
          ContentType: content_type
        } = req_headers, body}, peer_connection, data_channel} ->
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
              headers = Map.drop(headers, ["Content-Type"])
              IO.inspect(body)
              textContent = Map.get(body, :TextContent)

              multiparts_text =
                textContent
                |> Map.keys()
                |> Enum.reduce(%{}, fn elem, acc ->
                  Map.put(acc, elem, Map.get(textContent, elem))
                end)

              IO.inspect(multiparts_text)

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

        {_, resp} = Req.run(req)

        encoded =
          req_headers
          |> Map.put(:ContentType, "application/json")
          |> WebRTCMessageEncoder.encode_message(resp.body)

        Enum.each(encoded, fn part ->
          ExWebRTC.PeerConnection.send_data(peer_connection, data_channel, part)
        end)

        loop(state)

      unknown ->
        IO.inspect("unknown message received #{inspect(unknown)}")
    end
  end
end
