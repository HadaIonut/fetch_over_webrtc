import command_decoder
import gleam/bytes_tree
import gleam/erlang/process
import gleam/function
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/otp/actor
import gluid
import mist.{type Connection, type ResponseData}
import rooms
import server_state

pub fn main() {
  let rooms = rooms.start_rooms()

  let not_found =
    response.new(404)
    |> response.set_body(mist.Bytes(bytes_tree.new()))

  let assert Ok(_) =
    fn(req: Request(Connection)) -> Response(ResponseData) {
      case request.path_segments(req) {
        ["ws"] -> spawn_ws(req, rooms)
        _ -> not_found
      }
    }
    |> mist.new
    |> mist.port(3000)
    |> mist.start_http

  process.sleep_forever()
}

fn spawn_ws(req, rooms) {
  mist.websocket(
    request: req,
    on_init: fn(_conn) {
      let self = process.new_subject()
      let selector =
        process.new_selector()
        |> process.selecting(self, function.identity)

      #(
        server_state.State(user_id: gluid.guidv4(), rooms: [], self: self),
        Some(selector),
      )
    },
    on_close: fn(state) {
      process.send(rooms, rooms.DropUser(state.user_id, state.rooms))
    },
    handler: handle_ws_message(rooms),
  )
}

fn handle_ws_message(rooms_actor) {
  fn(state: server_state.State, conn, message) {
    case message {
      mist.Text("ping") -> {
        let assert Ok(_) = mist.send_text_frame(conn, "pong")
        actor.continue(state)
      }
      mist.Text(msg) -> handle_ws_text(msg, conn, state, rooms_actor)
      mist.Binary(_) -> actor.continue(state)
      mist.Custom(server_state.Broadcast(text)) -> {
        let assert Ok(_) = mist.send_text_frame(conn, text)
        actor.continue(state)
      }
      mist.Custom(server_state.SendNotifications(text)) -> {
        let _ = mist.send_text_frame(conn, text)
        actor.continue(state)
      }
      mist.Custom(server_state.SendSdpCert(
        source_user_id,
        source_room_id,
        sdp_cert,
      )) -> {
        let _ =
          json.object([
            #("type", json.string("userOffer")),
            #("sourceUserId", json.string(source_user_id)),
            #("roomId", json.string(source_room_id)),
            #("sdpCert", json.string(sdp_cert)),
          ])
          |> json.to_string()
          |> mist.send_text_frame(conn, _)

        actor.continue(state)
      }
      mist.Custom(server_state.SendSdpCertReply(
        source_user_id,
        source_room_id,
        sdp_cert,
      )) -> {
        let _ =
          json.object([
            #("type", json.string("userOfferReply")),
            #("sourceUserId", json.string(source_user_id)),
            #("roomId", json.string(source_room_id)),
            #("sdpCert", json.string(sdp_cert)),
          ])
          |> json.to_string()
          |> mist.send_text_frame(conn, _)

        actor.continue(state)
      }
      mist.Custom(server_state.SendICECandidate(
        ice_candidate,
        source_user_id,
        source_room_id,
      )) -> {
        let _ =
          json.object([
            #("type", json.string("ICECandidate")),
            #("sourceUserId", json.string(source_user_id)),
            #("sourceRoomId", json.string(source_room_id)),
            #("ICECandidate", json.string(ice_candidate)),
          ])
          |> json.to_string()
          |> mist.send_text_frame(conn, _)

        actor.continue(state)
      }
      mist.Closed | mist.Shutdown -> actor.Stop(process.Normal)
    }
  }
}

fn handle_ws_text(msg, conn, state: server_state.State, rooms_actor) {
  case json.parse(msg, command_decoder.decoder()) {
    Ok(command_decoder.Join(request_id, room_id)) ->
      handle_ws_join(
        rooms_actor,
        room_id,
        state.user_id,
        state,
        conn,
        request_id,
      )
    Ok(command_decoder.Leave(request_id, room_id)) ->
      handle_ws_leave(
        rooms_actor,
        room_id,
        state.user_id,
        state,
        conn,
        request_id,
      )
    Ok(command_decoder.Create(request_id)) -> {
      handle_ws_room_create(rooms_actor, state, request_id, conn)
      state
    }
    Ok(command_decoder.Offer(request_id, room_id, sdp_cert)) -> {
      handle_ws_offer(rooms_actor, state, conn, room_id, sdp_cert, request_id)
      state
    }
    Ok(command_decoder.OfferReply(_, room_id, to_user, sdp_cert)) -> {
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
    Ok(command_decoder.SendIce(_, room_id, target_user_id, ice_candidate)) -> {
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
    Ok(command_decoder.Err) -> {
      io.debug("recieved unknown message type")
      state
    }
    Error(err) -> {
      io.debug(err)
      let _ = mist.send_text_frame(conn, "something went wrong")
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
  request_id,
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
    process.call(rooms_actor, rooms.Create(state.user_id, state.self, _), 10)

  let _ =
    json.object([
      #("type", json.string("create")),
      #("requestId", json.string(request_id)),
      #("roomId", json.string(room.room_id)),
    ])
    |> json.to_string()
    |> mist.send_text_frame(conn, _)

  Nil
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

  Nil
}
