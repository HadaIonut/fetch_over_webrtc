import command_decoder
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/otp/actor
import mist
import rooms
import server_state

pub fn handle_ws_text(msg, conn, state: server_state.State, rooms_actor) {
  case msg {
    command_decoder.Join(request_id, room_id) ->
      handle_ws_join(
        rooms_actor,
        room_id,
        state.user_id,
        state,
        conn,
        request_id,
      )
    command_decoder.Leave(request_id, room_id) ->
      handle_ws_leave(
        rooms_actor,
        room_id,
        state.user_id,
        state,
        conn,
        request_id,
      )
    command_decoder.Create(request_id) ->
      handle_ws_room_create(rooms_actor, state, request_id, conn)
    command_decoder.Offer(request_id, room_id, sdp_cert) ->
      handle_ws_offer(rooms_actor, state, conn, room_id, sdp_cert, request_id)
    command_decoder.OfferReply(_, room_id, to_user, sdp_cert) -> {
      let _ = case
        process.call(
          rooms_actor,
          rooms.OfferReply(state.user_id, room_id, to_user, sdp_cert, _),
          10,
        )
      {
        Ok(_) -> mist.send_text_frame(conn, "good")
        Error(err) -> mist.send_text_frame(conn, err)
      }
      state
    }
    command_decoder.SendIce(_, room_id, target_user_id, ice_candidate) -> {
      let _ = case
        process.call(
          rooms_actor,
          rooms.SendICE(
            state.user_id,
            target_user_id,
            room_id,
            ice_candidate,
            _,
          ),
          10,
        )
      {
        Ok(_) -> mist.send_text_frame(conn, "good")
        Error(err) -> mist.send_text_frame(conn, err)
      }
      state
    }
    command_decoder.Err -> {
      io.debug("recieved unknown message type")
      state
    }
  }
  |> actor.continue()
}

fn handle_ws_join(
  rooms_actor,
  room_id,
  user_id,
  state: server_state.State,
  conn,
  request_id,
) {
  let room =
    process.call(
      rooms_actor,
      rooms.Join(room_id, rooms.User(user_id, state.self), _),
      10,
    )
  case room {
    Error(err) -> {
      let _ = mist.send_text_frame(conn, err)
      state
    }
    Ok(room) -> {
      let response =
        json.object([
          #("type", json.string("join")),
          #("requestId", json.string(request_id)),
          #("room", rooms.room_encoder(room)),
        ])
        |> json.to_string()

      let _ = mist.send_text_frame(conn, response)

      server_state.State(..state, rooms: list.prepend(state.rooms, room_id))
    }
  }
}

fn handle_ws_leave(
  rooms_actor,
  room_id,
  user_id,
  state: server_state.State,
  conn,
  _request_id,
) {
  case process.call(rooms_actor, rooms.Leave(room_id, user_id, _), 10) {
    Error(err) -> {
      let _ = mist.send_text_frame(conn, err)
      state
    }
    Ok(room) -> {
      let _ =
        mist.send_text_frame(
          conn,
          "left" <> list.length(room.members) |> int.to_string(),
        )

      server_state.State(
        ..state,
        rooms: list.filter(state.rooms, fn(room) { room == room_id }),
      )
    }
  }
}

fn handle_ws_room_create(
  rooms_actor,
  state: server_state.State,
  request_id,
  conn,
) {
  let room =
    process.call(
      rooms_actor,
      rooms.Create(state.user_id, rooms.Star, state.self, _),
      10,
    )

  let _ =
    json.object([
      #("type", json.string("create")),
      #("requestId", json.string(request_id)),
      #("roomId", json.string(room.room_id)),
    ])
    |> json.to_string()
    |> mist.send_text_frame(conn, _)

  state
}

fn handle_ws_offer(
  rooms_actor,
  state: server_state.State,
  conn,
  room_id,
  sdp_cert,
  request_id,
) {
  let status = case
    process.call(
      rooms_actor,
      rooms.Offer(state.user_id, room_id, sdp_cert, _),
      10,
    )
  {
    Ok(_) -> "good"
    Error(err) -> err
  }

  let _ =
    json.object([
      #("type", json.string("offer")),
      #("requestId", json.string(request_id)),
      #("status", json.string(status)),
    ])
    |> json.to_string()
    |> mist.send_text_frame(conn, _)

  state
}
