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
      mist.Custom(server_state.SendSdpCert(source_user_id, sdp_cert)) -> {
        let _ =
          json.object([
            #("sourceUserId", json.string(source_user_id)),
            #("sdpCert", json.string(sdp_cert)),
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
      handle_ws_join(rooms_actor, room_id, state.user_id, state, conn)
    Ok(command_decoder.Leave(request_id, room_id)) ->
      handle_ws_leave(rooms_actor, room_id, state.user_id, state, conn)
    Ok(command_decoder.Create(request_id)) -> {
      let room =
        process.call(
          rooms_actor,
          rooms.Create(state.user_id, state.self, _),
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
    Ok(command_decoder.Offer(request_id, room_id, sdp_cert)) -> {
      let _ = case
        process.call(
          rooms_actor,
          rooms.Offer(state.user_id, room_id, sdp_cert, _),
          10,
        )
      {
        Ok(_) -> mist.send_text_frame(conn, "good")
        Error(err) -> mist.send_text_frame(conn, err)
      }

      state
    }
    Ok(command_decoder.OfferReply(request_id, room_id, to_user, sdp_cert)) -> {
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
    Ok(_) -> panic
    Error(_) -> {
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
      let _ =
        mist.send_text_frame(
          conn,
          "joined" <> list.length(room.members) |> int.to_string(),
        )

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
