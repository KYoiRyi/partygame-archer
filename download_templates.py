import urllib.request
import zipfile
import os
import sys

URL = "https://github.com/godotengine/godot/releases/download/4.2.2-stable/Godot_v4.2.2-stable_export_templates.tpz"
ZIP_PATH = "templates.tpz"
TARGET_DIR = os.path.expanduser("~/.local/share/godot/export_templates/4.2.2.stable")

def progress_callback(block_num, block_size, total_size):
    downloaded = block_num * block_size
    percent = (downloaded / total_size) * 100 if total_size > 0 else 0
    sys.stdout.write(f"\rDownloading templates: {downloaded / 1024 / 1024:.2f} MB / {total_size / 1024 / 1024:.2f} MB ({percent:.2f}%)")
    sys.stdout.flush()

def main():
    print(f"Ensuring target directory exists: {TARGET_DIR}")
    os.makedirs(TARGET_DIR, exist_ok=True)
    
    print(f"Starting download from {URL}...")
    try:
        urllib.request.urlretrieve(URL, ZIP_PATH, reporthook=progress_callback)
        print("\nDownload finished! Extracting only Web templates...")
        
        with zipfile.ZipFile(ZIP_PATH, 'r') as zip_ref:
            # List all files inside the TPZ zip file
            all_files = zip_ref.namelist()
            print(f"Total files in package: {len(all_files)}")
            
            # Find the web templates
            web_files = [f for f in all_files if "web_" in f]
            print(f"Found web template files: {web_files}")
            
            for file_in_zip in web_files:
                filename = os.path.basename(file_in_zip)
                target_path = os.path.join(TARGET_DIR, filename)
                print(f"Extracting {file_in_zip} -> {target_path}")
                
                # Read content and write to target
                with zip_ref.open(file_in_zip) as source, open(target_path, "wb") as target:
                    target.write(source.read())
                    
        print("Extraction complete!")
        if os.path.exists(ZIP_PATH):
            os.remove(ZIP_PATH)
            print("Temporary TPZ file deleted.")
            
        print("Export templates setup successful!")
    except Exception as e:
        print(f"\nError during export template setup: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
