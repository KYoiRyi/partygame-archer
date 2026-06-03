#!/usr/bin/env bash
set -e

echo "=== ARCHER MOBA: Roguelike online pushing game - Build Script ==="

# 1. Ensure target distribution directory exists
echo "Creating distribution folder 'dist'..."
mkdir -p dist

# 2. Compile the Go Multiplayer Server
echo "Compiling the Go multiplayer server..."
cd server
go build -o ../game_server
cd ..
echo "Go server compiled successfully to './game_server'!"

# 3. Export the Godot Game Client
echo "Exporting Godot game client to HTML5/WebAssembly..."
if [ -f "./godot" ]; then
    ./godot --headless --path client --export-release "Web" ../dist/index.html
    echo "Godot web client successfully exported to './dist/'!"
else
    echo "Error: Godot executable not found at './godot'."
    exit 1
fi

echo "=========================================================="
echo "BUILD COMPLETE!"
echo "To run your online game server and serve the web client on port 8090:
  ./game_server -port=8090

Then, open your web browser and navigate to:
  http://prts.kyoiryi.top/archer/  (or http://localhost:8090)
================================================================"
