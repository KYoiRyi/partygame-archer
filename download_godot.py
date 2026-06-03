import urllib.request
import zipfile
import os
import sys

URL = "https://github.com/godotengine/godot/releases/download/4.2.2-stable/Godot_v4.2.2-stable_linux.x86_64.zip"
ZIP_PATH = "godot.zip"
EXE_PATH = "godot"
FINAL_NAME = "Godot_v4.2.2-stable_linux.x86_64"

def progress_callback(block_num, block_size, total_size):
    downloaded = block_num * block_size
    percent = (downloaded / total_size) * 100 if total_size > 0 else 0
    sys.stdout.write(f"\rDownloading: {downloaded / 1024 / 1024:.2f} MB / {total_size / 1024 / 1024:.2f} MB ({percent:.2f}%)")
    sys.stdout.flush()

def main():
    print(f"Starting download from {URL}...")
    try:
        urllib.request.urlretrieve(URL, ZIP_PATH, reporthook=progress_callback)
        print("\nDownload finished! Extracting...")
        
        with zipfile.ZipFile(ZIP_PATH, 'r') as zip_ref:
            zip_ref.extractall(".")
            
        print("Extraction complete!")
        if os.path.exists(FINAL_NAME):
            os.rename(FINAL_NAME, EXE_PATH)
            os.chmod(EXE_PATH, 0o755)
            print("Godot executable renamed to 'godot' and made executable.")
        else:
            print(f"Warning: Expected file {FINAL_NAME} not found. Check extracted files.")
            
        # Clean up
        if os.path.exists(ZIP_PATH):
            os.remove(ZIP_PATH)
            print("Temporary zip file deleted.")
            
        print("Setup successful!")
    except Exception as e:
        print(f"\nError: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
