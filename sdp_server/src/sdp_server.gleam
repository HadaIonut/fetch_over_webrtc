import gleam/bytes_tree
import gleam/erlang/process
import gleam/function
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/io
import gleam/json
import gleam/option.{Some}
import gleam/otp/actor
import gluid
import mist.{type Connection, type ResponseData}
import rooms
import server_state
import websocket_text_handler

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
      mist.Text(msg) ->
        case json.parse(msg, websocket_text_handler.decoder()) {
          Ok(msg) ->
            websocket_text_handler.handle_ws_text(msg, conn, state, rooms_actor)
          Error(err) -> {
            io.debug(err)
            let _ = mist.send_text_frame(conn, "something went wrong")
            actor.continue(state)
          }
        }
      mist.Binary(_) -> actor.continue(state)
      mist.Custom(message) ->
        server_state.handle_custom_broadcast(message, conn, state)
      mist.Closed | mist.Shutdown -> actor.Stop(process.Normal)
    }
  }
}
