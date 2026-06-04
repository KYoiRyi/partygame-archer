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
    
    # 4. Patch index.html to disable the secure context (HTTPS) check for LAN support
    echo "Patching 'dist/index.html' to bypass secure context (HTTPS) check for LAN play..."
    python3 -c "
with open('dist/index.html', 'r', encoding='utf-8') as f:
    content = f.read()

target = 'if (missing.length !== 0) {'
replacement = 'missing = missing.filter(function(x) { return !x.includes(\"Secure Context\"); });\n\tif (missing.length !== 0) {'

if target in content:
    content = content.replace(target, replacement)
    with open('dist/index.html', 'w', encoding='utf-8') as f:
        f.write(content)
    print('Successfully disabled secure context check!')
else:
    print('Warning: target string not found in index.html, skipping patch.')
"
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
