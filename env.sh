# Create a new window and navigate to the directory
tmux rename-window "javascript"
tmux send-keys "cd ~/projects/fetch_over_webrtc/javascript_client/" C-m
tmux send-keys "nvim ." C-m

tmux new-window  -n "elixir"
tmux send-keys "cd ~/projects/fetch_over_webrtc/server_proxy/" C-m
tmux send-keys "nvim ." C-m

tmux new-window  -n "proxyServer"
tmux send-keys "cd ~/projects/fetch_over_webrtc/server_proxy/" C-m
tmux send-keys "iex -S mix" C-m

tmux new-window  -n "sdpServer"
tmux send-keys "cd ~/projects/fetch_over_webrtc/sdp_server/" C-m
tmux send-keys "gleam run" C-m

tmux new-window  -n "goTestingServer"
tmux send-keys "cd ~/projects/demo_api/" C-m
tmux send-keys "go run ." C-m

tmux new-window  -n "jsServer"
tmux send-keys "cd ~/projects/fetch_over_webrtc/javascript_client/" C-m
tmux send-keys "python3 -m http.server 6969" C-m

tmux select-window -t 0


# Attach to the session
tmux attach -t $SESSION
